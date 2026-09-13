import Foundation
import Combine

enum PhotoListLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class PhotoListViewModel: ObservableObject {
    @Published private(set) var loadState: PhotoListLoadState = .idle
    @Published private(set) var sections: [PhotoDaySection] = []
    @Published private(set) var filter = PhotoFilterState()
    private var allFiles: [CameraFile] = []
    private var transferredIDs: Set<UInt32> = []
    var availableFiles: [CameraFile] { allFiles }
    private let loadCatalog: @Sendable () async throws -> [CameraFile]
    private var loadTask: Task<Void, Never>?

    init(repository: CameraRepository) { self.loadCatalog = { try await repository.loadCatalog() } }
    init(session: CameraSession) { self.loadCatalog = { try await session.catalog() } }

    deinit { loadTask?.cancel() }

    func load() {
        loadTask?.cancel()
        loadState = .loading
        loadTask = Task { [weak self] in
            await self?.reload()
        }
    }

    /// Awaitable refresh used by SwiftUI's pull-to-refresh.  A cancelled scan
    /// never replaces the current catalog, matching Android's refresh reducer.
    func reload() async {
        do {
            let files = try await loadCatalog()
            guard !Task.isCancelled else { return }
            allFiles = files
            sections = PhotoCatalogGrouping.byCaptureDay(
                PhotoFilter.apply(files, state: filter, transferredIDs: transferredIDs),
            )
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    func setFilter(_ filter: PhotoFilterState) {
        self.filter = filter
        sections = PhotoCatalogGrouping.byCaptureDay(PhotoFilter.apply(allFiles, state: filter, transferredIDs: transferredIDs))
    }

    func updateTransferredIDs(_ ids: Set<UInt32>) {
        guard ids != transferredIDs else { return }
        transferredIDs = ids
        guard loadState == .loaded else { return }
        sections = PhotoCatalogGrouping.byCaptureDay(PhotoFilter.apply(allFiles, state: filter, transferredIDs: ids))
    }

    func clearFilter() { setFilter(PhotoFilterState()) }
}
