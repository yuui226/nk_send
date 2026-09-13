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

    func enqueue(_ file: CameraFile) { Task { _ = await queue.enqueue(file) } }
    func enqueue(_ file: CameraFile, autoStart session: CameraSession?, directory: URL?) {
        Task {
            _ = await queue.enqueue(file)
            if let session, let directory { await queue.start(session: session, directory: directory) }
        }
    }
    func start(session: CameraSession, directory: URL) { Task { await queue.start(session: session, directory: directory) } }
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
