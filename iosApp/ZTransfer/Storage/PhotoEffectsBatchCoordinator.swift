import Foundation

struct IOSPhotoEffectsBatchProgress: Equatable, Sendable {
    let total: Int
    let completed: Int
    let saved: Int

    var failed: Int { completed - saved }
    var isFinished: Bool { completed == total }
}

/// Owns the bounded batch schedule used by the iOS photo-effects UI. Rendering and persistence
/// stay injected so the coordinator can use the shared filter kernel and PhotoKit independently.
actor PhotoEffectsBatchCoordinator {
    private var nextIndex = 0
    private var progress = IOSPhotoEffectsBatchProgress(total: 0, completed: 0, saved: 0)

    func process<Item: Sendable>(
        _ items: [Item],
        onProgress: @escaping @Sendable (IOSPhotoEffectsBatchProgress) -> Void,
        generateAndSave: @escaping @Sendable (Item) async throws -> Bool,
    ) async throws -> IOSPhotoEffectsBatchProgress {
        let snapshot = items
        nextIndex = 0
        progress = IOSPhotoEffectsBatchProgress(total: snapshot.count, completed: 0, saved: 0)
        onProgress(progress)
        guard !snapshot.isEmpty else { return progress }

        let workerCount = min(2, snapshot.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [weak self] in
                    guard let self else { return }
                    while let index = await self.takeNext(count: snapshot.count) {
                        try Task.checkCancellation()
                        let saved: Bool
                        do {
                            saved = try await generateAndSave(snapshot[index])
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            saved = false
                        }
                        await self.settle(saved: saved, onProgress: onProgress)
                    }
                }
            }
            try await group.waitForAll()
        }
        return progress
    }

    private func takeNext(count: Int) -> Int? {
        guard nextIndex < count else { return nil }
        defer { nextIndex += 1 }
        return nextIndex
    }

    private func settle(
        saved: Bool,
        onProgress: @escaping @Sendable (IOSPhotoEffectsBatchProgress) -> Void,
    ) {
        progress = IOSPhotoEffectsBatchProgress(total: progress.total, completed: progress.completed + 1,
                                                saved: progress.saved + (saved ? 1 : 0))
        onProgress(progress)
    }
}
