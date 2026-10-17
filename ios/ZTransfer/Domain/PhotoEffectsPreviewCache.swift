import Foundation

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
