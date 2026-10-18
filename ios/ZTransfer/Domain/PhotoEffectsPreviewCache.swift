import Foundation
import UIKit

/// SettingsScreen rotates its source on Dispatchers.Default once per source /
/// direction, before filter/comparison/prefetch consumers share it. Retain just
/// the current source and one rotated bitmap, with the existing cancellation gate.
@MainActor
final class PhotoEffectsRotatedSourceCache {
    typealias Renderer = @Sendable (UIImage, Int) throws -> UIImage
    private let cache = PhotoEffectsPreviewCachePool<UIImage>(capacity: 1)
    private let renderer: Renderer
    private var source: UIImage?
    private var rotation: Int?

    init(renderer: @escaping Renderer = PhotoEffectsSourceRotation.rotate) { self.renderer = renderer }

    func image(_ source: UIImage, quarterTurns: Int) async throws -> UIImage {
        try Task.checkCancellation()
        let turns = ((quarterTurns % 4) + 4) % 4
        // Keep identity alive while cached: a deallocated UIImage address must
        // never be reused as the identity of a different source.
        if self.source !== source || rotation != turns {
            cache.close(); self.source = source; rotation = turns
        }
        guard turns != 0 else { return source }
        let renderer = renderer
        return try await cache.value(key: "rotated", context: "\(ObjectIdentifier(source))|\(turns)") { cancelled in
            if cancelled() { throw CancellationError() }
            return try await PhotoEffectsPreviewRenderGate.render {
                if cancelled() { throw CancellationError() }
                return try renderer(source, turns)
            }
        }
    }

    func close() { cache.close(); source = nil; rotation = nil }
}

enum PhotoEffectsSourceRotation {
    /// Metadata-only wrapper for the temporary source view. UIImage/SwiftUI
    /// fits the final oriented size, avoiding pre-rotation pixel-rounding drift.
    nonisolated static func displayImage(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let normal: [UIImage.Orientation] = [.up, .left, .down, .right]
        let mirrored: [UIImage.Orientation] = [.upMirrored, .leftMirrored, .downMirrored, .rightMirrored]
        let cycle = normal.contains(image.imageOrientation) ? normal : mirrored
        let orientation = cycle[((cycle.firstIndex(of: image.imageOrientation) ?? 0) + turns) % 4]
        if let cgImage = image.cgImage { return UIImage(cgImage: cgImage, scale: image.scale, orientation: orientation) }
        if let ciImage = image.ciImage { return UIImage(ciImage: ciImage, scale: image.scale, orientation: orientation) }
        return image
    }

    nonisolated static func rotate(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let sourceSize = image.size
        let rotatedSize = turns.isMultiple(of: 2)
            ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = image.cgImage != nil
        return UIGraphicsImageRenderer(size: rotatedSize, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            context.rotate(by: -.pi / 2 * CGFloat(turns))
            context.translateBy(x: -sourceSize.width / 2, y: -sourceSize.height / 2)
            image.draw(in: CGRect(origin: .zero, size: sourceSize))
        }
    }
}

@MainActor
final class PhotoEffectsDisplaySourceCache {
    private var source: UIImage?
    private var turns: Int?
    private var prepared: UIImage?
    func image(_ source: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        if self.source === source, self.turns == turns, let prepared { return prepared }
        let image = PhotoEffectsSourceRotation.displayImage(source, quarterTurns: turns)
        self.source = source; self.turns = turns; prepared = image
        return image
    }
}

/// Android PhotoEffectsPreviewCache: awaiter cancellation never owns shared rendering.
/// Closing a target cancels its worker permanently and releases every waiting caller.
actor PhotoEffectsPreviewCache<Value: Sendable> {
    private struct Superseded: Error {}
    private struct Running {
        let id: UUID
        let task: Task<Value, Error>
    }
    private let gate: CancellableSerialWorkGate
    private var closed = false
    private var completed: Value?
    private var running: Running?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    init(gate: CancellableSerialWorkGate = PhotoEffectsPreviewRenderGate.shared) { self.gate = gate }

    func getOrRender(isObsolete: @escaping @Sendable () -> Bool = { false },
                     serialize: Bool = true,
                     render: @escaping @Sendable (@escaping @Sendable () -> Bool) async throws -> Value) async throws -> Value {
        while true {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if let completed { return completed }
            let created = running == nil
            let work: Running
            if let running { work = running }
            else {
                let gate = gate, id = UUID()
                let task = Task.detached { () throws -> Value in
                    let operation: @Sendable () async throws -> Value = {
                        try Task.checkCancellation()
                        if isObsolete() { throw Superseded() }
                        let observed = PreviewObsoleteObservation()
                        do {
                            let result = try await render {
                                let obsolete = isObsolete()
                                if obsolete { observed.mark() }
                                return obsolete || Task.isCancelled
                            }
                            try Task.checkCancellation()
                            return result
                        } catch is CancellationError {
                            if observed.value && !Task.isCancelled { throw Superseded() }
                            throw CancellationError()
                        }
                    }
                    if serialize { return try await gate.withPermit(operation) }
                    return try await operation()
                }
                work = Running(id: id, task: task); running = work
                Task { [weak self] in
                    let result = await task.result
                    await self?.finished(id: id, result: result)
                }
            }
            let waiter = UUID()
            do {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { waiters[waiter] = continuation }
                    }
                } onCancel: { Task { await self.cancelWaiter(waiter) } }
            } catch {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                if (error is Superseded || (!created && error is CancellationError)) && !isObsolete() { continue }
                if error is Superseded { throw CancellationError() }
                throw error
            }
        }
    }
    private func finished(id: UUID, result: Result<Value, Error>) {
        guard running?.id == id else { return }
        running = nil
        if !closed, case .success(let value) = result { completed = value }
        let callbacks = waiters.values; waiters.removeAll()
        for continuation in callbacks { continuation.resume(with: closed ? .failure(CancellationError()) : result) }
    }
    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func close() {
        closed = true; running?.task.cancel(); running = nil; completed = nil
        let callbacks = waiters.values; waiters.removeAll()
        for continuation in callbacks { continuation.resume(throwing: CancellationError()) }
    }
}
private final class PreviewObsoleteObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    func mark() { lock.lock(); observed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return observed }
}

/// Android BoundedAccessCache uses three recent finished/active filter targets.
@MainActor
final class PhotoEffectsPreviewCachePool<Value: Sendable> {
    private var context = ""
    private var order: [String] = []
    private var caches: [String: PhotoEffectsPreviewCache<Value>] = [:]
    private let capacity: Int
    private let demand = PreviewCacheDemand()
    func request(_ keys: Set<String>) { demand.replace(keys) }
    init(capacity: Int = 3) { self.capacity = max(1, capacity) }
    func value(key: String, context: String,
               render: @escaping @Sendable (@escaping @Sendable () -> Bool) async throws -> Value) async throws -> Value {
        if self.context != context { close(); self.context = context }
        let cache: PhotoEffectsPreviewCache<Value>
        if let existing = caches[key] { cache = existing }
        else { cache = PhotoEffectsPreviewCache(); caches[key] = cache }
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity {
            if let old = caches.removeValue(forKey: order.removeFirst()) { Task { await old.close() } }
        }
        // The existing native stages already acquire the shared renderer gate.
        let demand = demand
        return try await cache.getOrRender(isObsolete: { !demand.includes(key) }, serialize: false, render: render)
    }
    func close() {
        let previous = Array(caches.values)
        caches.removeAll(); order.removeAll()
        Task { for cache in previous { await cache.close() } }
    }
}

private final class PreviewCacheDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: Set<String>?
    func replace(_ keys: Set<String>) { lock.lock(); requested = keys; lock.unlock() }
    func includes(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return requested?.contains(key) ?? true }
}
