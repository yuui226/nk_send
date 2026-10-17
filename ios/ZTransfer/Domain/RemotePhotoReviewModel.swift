import Combine
import Foundation

/// RemotePhotoReview.kt: a frozen catalog per opening, one compatibility stop,
/// and a generation boundary that prevents late reads entering a new opening.
@MainActor
final class RemotePhotoReviewModel: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published private(set) var photos: [RemoteReviewPhoto] = []
    @Published private(set) var hasMore = false
    private let frames: RemoteReviewFrameGate
    private let openCatalog: () async throws -> RemoteReviewCatalog
    private let endLiveView: () async -> Void
    private let restartLiveView: () -> Void
    private let isConnected: () -> Bool
    private let onActiveChanged: (Bool) -> Void
    private var generation = UUID()
    private var catalog: RemoteReviewCatalog?
    private var loadTask: Task<Void, Never>?
    private var compatibilityTask: Task<Void, Never>?
    private var restartRequired = false
    private var closing = false

    init(frames: RemoteReviewFrameGate,
         openCatalog: @escaping () async throws -> RemoteReviewCatalog,
         endLiveView: @escaping () async -> Void,
         restartLiveView: @escaping () -> Void,
         isConnected: @escaping () -> Bool,
         onActiveChanged: @escaping (Bool) -> Void = { _ in }) {
        self.frames = frames
        self.openCatalog = openCatalog
        self.endLiveView = endLiveView
        self.restartLiveView = restartLiveView
        self.isConnected = isConnected
        self.onActiveChanged = onActiveChanged
    }

    func open() {
        guard !active, !closing else { return }
        generation = UUID()
        active = true
        onActiveChanged(true)
        photos = []
        catalog = nil
        hasMore = false
        frames.pause()
        retry()
    }

    private func current(_ id: UUID) -> Bool {
        active && !closing && generation == id && isConnected()
    }

    func retry() {
        guard active, !closing, !loading else { return }
        if !photos.isEmpty { loadMore(); return }
        loading = true
        failed = false
        let id = generation
        loadTask = Task { [self] in
            defer { if generation == id { loading = false; loadTask = nil } }
            do {
                try await frames.awaitIdle()
                try await Task.sleep(for: .milliseconds(200))
                do { try await readFirst(id) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    guard await stopForCompatibility(id) else { throw error }
                    try await Task.sleep(for: .milliseconds(200))
                    try await readFirst(id)
                }
                if photos.isEmpty, await stopForCompatibility(id) {
                    try await Task.sleep(for: .milliseconds(200))
                    try await readFirst(id)
                }
            } catch is CancellationError { }
            catch { if current(id) { failed = true } }
        }
    }

    private func readFirst(_ id: UUID) async throws {
        guard current(id) else { throw CancellationError() }
        let snapshot = try await openCatalog()
        let result = try await snapshot.loadNextPage()
        let more = await snapshot.hasMore
        try Task.checkCancellation()
        guard current(id) else { throw CancellationError() }
        catalog = snapshot
        photos = result
        hasMore = more
    }

    func loadMore() {
        guard let catalog, active, !closing, !loading, hasMore else { return }
        loading = true
        failed = false
        let id = generation
        loadTask = Task { [self] in
            defer { if generation == id { loading = false; loadTask = nil } }
            do {
                let result = try await catalog.loadNextPage()
                let more = await catalog.hasMore
                try Task.checkCancellation()
                guard current(id) else { return }
                photos = result
                hasMore = more
            } catch is CancellationError { }
            catch { if current(id) { failed = true } }
        }
    }

    /// Shared by enumeration and preview fallback; ambiguous EndLiveView also
    /// requires a fresh session when closing. The command survives caller cancel.
    private func stopForCompatibility(_ id: UUID) async -> Bool {
        guard current(id), !restartRequired else { return false }
        restartRequired = true
        let task = Task { [endLiveView] in await endLiveView() }
        compatibilityTask = task
        await task.value
        compatibilityTask = nil
        return current(id)
    }

    func preview<T>(_ operation: () async -> T?) async throws -> T? {
        let id = generation
        guard current(id) else { throw CancellationError() }
        var result = await operation()
        try Task.checkCancellation()
        if result == nil, await stopForCompatibility(id) {
            try await Task.sleep(for: .milliseconds(200))
            guard current(id) else { throw CancellationError() }
            result = await operation()
        }
        try Task.checkCancellation()
        guard current(id) else { throw CancellationError() }
        return result
    }

    func close() async {
        guard active, !closing else { return }
        closing = true
        loadTask?.cancel()
        await loadTask?.value
        await compatibilityTask?.value
        if restartRequired && isConnected() { restartLiveView() }
        restartRequired = false
        catalog = nil
        active = false
        onActiveChanged(false)
        loading = false
        frames.resume()
        closing = false
    }
}
