import Foundation

/// Android PhotoEffectsBatch.kt: completed includes failed outputs; total is
/// the original selection size and never changes while a batch is running.
struct PhotoEffectsBatchProgress: Equatable, Sendable {
    let total: Int
    var completed = 0
    var saved = 0
    var failed: Int { completed - saved }
}

enum LocalPhotoBatchPhase: Int, Equatable, Sendable {
    case ready, generating, complete, partial, failed
}

struct LocalPhotoBatchState<Source: Hashable & Sendable>: Equatable, Sendable {
    private(set) var photos: [Source] = []
    private(set) var phase: LocalPhotoBatchPhase = .ready
    private(set) var progress = PhotoEffectsBatchProgress(total: 0)
    private(set) var generation: UInt64 = 0

    var generating: Bool { phase == .generating }

    /// A cancelled picker does not erase the previous selection. Replacing a
    /// selection preserves picker order and removes duplicates, like Android.
    @discardableResult
    mutating func select(_ sources: [Source]) -> Bool {
        guard !generating, !sources.isEmpty else { return false }
        var seen = Set<Source>()
        photos = sources.filter { seen.insert($0).inserted }
        phase = .ready
        progress = PhotoEffectsBatchProgress(total: photos.count)
        generation &+= 1
        return true
    }

    @discardableResult
    mutating func begin() -> UInt64? {
        guard phase == .ready, !photos.isEmpty else { return nil }
        generation &+= 1
        phase = .generating
        progress = PhotoEffectsBatchProgress(total: photos.count)
        return generation
    }

    mutating func update(_ value: PhotoEffectsBatchProgress, generation: UInt64) {
        guard self.generation == generation, generating, value.total == photos.count else { return }
        progress = value
    }

    mutating func finish(_ value: PhotoEffectsBatchProgress, generation: UInt64) {
        guard self.generation == generation, generating, value.total == photos.count else { return }
        progress = value
        phase = value.saved == value.total ? .complete : value.saved == 0 ? .failed : .partial
    }

    mutating func returnToReady(ifUnchanged snapshot: Self) {
        guard self == snapshot else { return }
        phase = .ready
    }

    /// Only lifecycle disposal cancels Android's batch; there is no stop button.
    mutating func cancel() {
        generation &+= 1
        phase = .ready
    }
}

enum PhotoEffectsBatchRunner {
    /// At most two sources are decoded/generated at once. Tasks are replenished
    /// only as results settle; a large selection never queues decoded bitmaps.
    static func generate<Source: Sendable>(
        photos: [Source],
        onProgress: @Sendable (PhotoEffectsBatchProgress) async -> Void,
        generate: @escaping @Sendable (Source) async throws -> Bool
    ) async throws -> PhotoEffectsBatchProgress {
        var progress = PhotoEffectsBatchProgress(total: photos.count)
        try Task.checkCancellation()
        await onProgress(progress)
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            var next = 0
            func enqueue(_ source: Source) {
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let saved = try await generate(source)
                        try Task.checkCancellation()
                        return saved
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        return false
                    }
                }
            }
            for _ in 0..<min(2, photos.count) {
                enqueue(photos[next])
                next += 1
            }
            while let saved = try await group.next() {
                try Task.checkCancellation()
                progress.completed += 1
                if saved { progress.saved += 1 }
                await onProgress(progress)
                if next < photos.count {
                    enqueue(photos[next])
                    next += 1
                }
            }
            return progress
        }
    }
}
