import Foundation

struct IOSPhotoEffectsBatchProgress: Equatable, Sendable {
    let total: Int
    let completed: Int
    let saved: Int

    var failed: Int { completed - saved }
    var isFinished: Bool { completed == total }
}

/// Each invocation owns its cursor and counters. Only two operations are in flight, even for a
/// large selection; awaiting progress keeps its final publication ahead of the completion state.
actor PhotoEffectsBatchCoordinator {
    func process<Item: Sendable>(
        _ items: [Item],
        onProgress: @escaping @Sendable (IOSPhotoEffectsBatchProgress) async -> Void,
        generateAndSave: @escaping @Sendable (Item) async throws -> Bool
    ) async throws -> IOSPhotoEffectsBatchProgress {
        let snapshot = items
        var progress = IOSPhotoEffectsBatchProgress(total: snapshot.count, completed: 0, saved: 0)
        try Task.checkCancellation()
        await onProgress(progress)

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            var nextIndex = 0
            for _ in 0..<min(2, snapshot.count) {
                let item = snapshot[nextIndex]
                nextIndex += 1
                group.addTask { try await Self.generate(item, operation: generateAndSave) }
            }

            while let saved = try await group.next() {
                try Task.checkCancellation()
                progress = IOSPhotoEffectsBatchProgress(total: snapshot.count,
                    completed: progress.completed + 1, saved: progress.saved + (saved ? 1 : 0))
                await onProgress(progress)
                try Task.checkCancellation()
                if nextIndex < snapshot.count {
                    let item = snapshot[nextIndex]
                    nextIndex += 1
                    group.addTask { try await Self.generate(item, operation: generateAndSave) }
                }
            }
            return progress
        }
    }

    nonisolated private static func generate<Item: Sendable>(
        _ item: Item, operation: @Sendable (Item) async throws -> Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        do { return try await operation(item) }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
    }
}
