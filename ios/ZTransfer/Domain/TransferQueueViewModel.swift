import Combine
import Foundation

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published private(set) var snapshot = TransferQueueSnapshot(items: [], isTransferring: false, pauseAfterCurrent: false)
    private let queue: TransferQueue
    private var observation: Task<Void, Never>?

    init(queue: TransferQueue) {
        self.queue = queue
        observation = Task { [weak self] in
            guard let self else { return }
            let stream = await queue.snapshots()
            for await value in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.snapshot = value }
            }
        }
    }

    deinit { observation?.cancel() }

    func enqueue(_ file: CameraFile, organizeByDate: Bool = false, effects: PhotoEffectsSettings? = nil) { Task { _ = await queue.enqueue(file, organizeByDate: organizeByDate, effects: effects) } }
    /// Batch entry point used by Android's collapsed burst preview. Tasks are
    /// appended in source order and the worker is started once, so a burst
    /// cannot interleave with another enqueue between members.
    func enqueue(_ files: [CameraFile], autoStart session: CameraSession?, directory: URL?, organizeByDate: Bool = false, effects: PhotoEffectsSettings? = nil) {
        guard !files.isEmpty else { return }
        Task {
            for file in files { _ = await queue.enqueue(file, organizeByDate: organizeByDate, effects: effects) }
            if let session, let directory { await queue.start(session: session, directory: directory) }
        }
    }
    func enqueue(_ files: [CameraFile], organizeByDate: Bool = false, effects: PhotoEffectsSettings? = nil) {
        guard !files.isEmpty else { return }
        Task {
            for file in files { _ = await queue.enqueue(file, organizeByDate: organizeByDate, effects: effects) }
        }
    }
    /// Android's automatic-new-media entry point deduplicates by logical
    /// identity before adding and starts the worker only when the user has not
    /// deferred transfer start.
    func enqueueAutomatic(_ files: [CameraFile], session: CameraSession?, directory: URL?, autoStart: Bool, organizeByDate: Bool = false, effects: PhotoEffectsSettings? = nil) {
        guard !files.isEmpty else { return }
        Task {
            var accepted = false
            for file in files {
                if await queue.enqueueAutomatic(file, organizeByDate: organizeByDate, effects: effects) != nil { accepted = true }
            }
            if accepted, autoStart, let session, let directory {
                await queue.start(session: session, directory: directory)
            }
        }
    }
    func enqueue(_ file: CameraFile, autoStart session: CameraSession?, directory: URL?, organizeByDate: Bool = false, effects: PhotoEffectsSettings? = nil) {
        Task {
            _ = await queue.enqueue(file, organizeByDate: organizeByDate, effects: effects)
            if let session, let directory { await queue.start(session: session, directory: directory) }
        }
    }
    func attach(session: CameraSession, directory: URL?) { Task { await queue.attach(session: session, directory: directory) } }
    func detach() { Task { await queue.detach() } }
    func start(session: CameraSession, directory: URL) { Task { await queue.startPendingTransfers(session: session, directory: directory) } }
    func pause() { Task { await queue.pauseAfterCurrentFile() } }
    func resume() { Task { await queue.resume() } }
    func cancel(id: UUID) { Task { await queue.cancel(id: id) } }
    func withdrawPending() { Task { await queue.withdrawPending() } }
    func removeCleared() { Task { await queue.removeCleared() } }
    func retryFailed() { Task { await queue.retryFailed() } }
    func retry(id: UUID) { Task { await queue.retry(id: id) } }
    func remove(id: UUID) { Task { await queue.remove(id: id) } }
    func clearFinished() { Task { await queue.clearFinished() } }
}
