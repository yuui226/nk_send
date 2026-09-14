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
    /// Mirrors Android's `isLoadingFiles`/`hasCompletedFileScan` pair.  The
    /// view may receive several published batches before the scan completes.
    @Published private(set) var isLoadingFiles = false
    @Published private(set) var hasCompletedFileScan = false
    private var allFiles: [CameraFile] = []
    private var transferredIDs: Set<UInt32> = []
    var availableFiles: [CameraFile] { allFiles }
    var transferredFileIDs: Set<UInt32> { transferredIDs }
    private let scanCatalog: @Sendable (Bool, PhotoScanSnapshot?, Bool, @escaping @Sendable ([CameraFile]) async throws -> Void) async throws -> PhotoScanResult
    private let resumeSnapshotProvider: @Sendable () async -> PhotoScanSnapshot?
    private let prefetchBatch: @Sendable ([CameraFile]) async -> Set<UInt32>
    private let canFill: @Sendable () async -> Bool
    private let reconcileCache: @Sendable ([CameraFile], Bool) async -> Void
    private let thumbnailFillQueue = PhotoThumbnailFillQueue()
    private var catalogUpdatesTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var fillTask: Task<Void, Never>?
    private var fillWorkerActive = false
    private var previewPausedScan = false
    private var transferBusy = false
    private var newMediaHandler: (([CameraFile]) -> Void)?
    private var transferIndexGeneration = 0
    private var transferIndexDirectory: URL?
    private var transferIndexOrganizeByDate = false
    private var diskOriginals = ExportedOriginalIndex()
    private var queueOriginals = ExportedOriginalIndex()
    /// A cancelled/old scan must never publish over a newer camera session.
    private var loadGeneration = 0

    /// Matches Android's latestEffectPreviewFile: videos are never used as an
    /// effect demo, and ties are resolved by the camera handle.
    static func latestEffectPreviewFile(in files: [CameraFile]) -> CameraFile? {
        files
            .filter { $0.fileExtension != ".mov" && $0.fileExtension != ".mp4" }
            .max { lhs, rhs in
                let leftDate = lhs.captureDate ?? ""
                let rightDate = rhs.captureDate ?? ""
                if leftDate != rightDate { return leftDate < rightDate }
                return lhs.id < rhs.id
            }
    }

    var latestEffectPreviewFile: CameraFile? {
        Self.latestEffectPreviewFile(in: allFiles)
    }

    init(repository: CameraRepository) {
        self.scanCatalog = { preserve, snapshot, detect, handler in
            try await repository.scanCatalog(preserveExisting: preserve,
                                              resumeSnapshot: snapshot,
                                              detectNewHandles: detect,
                                              onBatch: handler)
        }
        self.resumeSnapshotProvider = { nil }
        self.prefetchBatch = { _ in [] }
        self.canFill = { true }
        self.reconcileCache = { _, _ in }
        observeCatalog(repository)
    }
    init(session: CameraSession) {
        self.scanCatalog = { preserve, snapshot, detect, handler in
            try await session.scanCatalog(preserveExisting: preserve,
                                          resumeSnapshot: snapshot,
                                          detectNewHandles: detect,
                                          onBatch: handler)
        }
        self.resumeSnapshotProvider = { await session.scanSnapshotForResume() }
        self.prefetchBatch = { files in
            var settled = Set<UInt32>()
            for file in files {
                guard !Task.isCancelled, await session.backgroundThumbnailFillAllowed() else { return settled }
                if (try? await session.prefetchThumbnail(file: file)) == true { settled.insert(file.id) }
            }
            return settled
        }
        self.canFill = { await session.backgroundThumbnailFillAllowed() }
        self.reconcileCache = { files, authoritative in
            await session.reconcileThumbnailCache(files: files, authoritative: authoritative)
        }
        catalogUpdatesTask = Task { [weak self] in
            let repository = session.repository
            for await files in await repository.catalogUpdates() {
                guard !Task.isCancelled else { return }
                self?.applyCatalogUpdate(files)
            }
        }
    }
    private func observeCatalog(_ repository: CameraRepository) {
        catalogUpdatesTask = Task { [weak self] in
            for await files in await repository.catalogUpdates() {
                guard !Task.isCancelled else { return }
                self?.applyCatalogUpdate(files)
            }
        }
    }
    private func applyCatalogUpdate(_ files: [CameraFile]) {
        guard loadState == .loaded else { return }
        let oldIDs = Set(allFiles.map(\.id))
        allFiles = files
        publishSections()
        let additions = files.filter { !oldIDs.contains($0.id) }
        if !additions.isEmpty {
            newMediaHandler?(additions.filter(Self.isAutoTransferMedia))
            Task { [weak self] in
                guard let self else { return }
                await thumbnailFillQueue.enqueueNew(additions)
                startThumbnailFillWorker()
            }
        }
    }

    /// Installs the host-level automatic transfer sink. The handler is kept
    /// outside the scanner so queue policy remains identical to Android's
    /// TransferViewModel and does not affect catalog ordering/backpressure.
    func setNewMediaHandler(_ handler: @escaping ([CameraFile]) -> Void) {
        newMediaHandler = handler
    }

    private static func isAutoTransferMedia(_ file: CameraFile) -> Bool {
        [".jpg", ".tif", ".png", ".bmp", ".gif", ".ico",
         ".mov", ".avi", ".mp4", ".nef", ".crw", ".cr2", ".cr3",
         ".arw"].contains(file.fileExtension)
    }

    deinit { loadTask?.cancel(); fillTask?.cancel(); catalogUpdatesTask?.cancel() }

    func load() {
        loadTask?.cancel()
        fillTask?.cancel()
        fillTask = nil
        fillWorkerActive = false
        loadGeneration &+= 1
        let generation = loadGeneration
        allFiles.removeAll(keepingCapacity: true)
        sections.removeAll()
        hasCompletedFileScan = false
        isLoadingFiles = true
        loadState = .loading
        loadTask = Task { [weak self] in
            await self?.reload(generation: generation, resumeSnapshot: nil)
        }
    }

    /// Awaitable refresh used by SwiftUI's pull-to-refresh.  A cancelled scan
    /// never replaces the current catalog, matching Android's refresh reducer.
    func reload() async {
        loadGeneration &+= 1
        // CameraViewModel.loadFiles cancels the previous fileLoadJob before
        // starting a refresh. Without this, the old scan could keep issuing
        // metadata commands until its next generation check, competing with
        // the new scan for the same PTP session.
        loadTask?.cancel()
        loadTask = nil
        await reload(generation: loadGeneration, resumeSnapshot: nil)
    }

    private func reload(generation: Int, resumeSnapshot: PhotoScanSnapshot?) async {
        guard generation == loadGeneration else { return }
        // Android's fill collector is gated by hasCompletedFileScan. Cancel
        // the existing worker for refreshes too, otherwise an old worker can
        // issue GetThumb while this generation is enumerating handles.
        fillTask?.cancel()
        fillTask = nil
        fillWorkerActive = false
        await thumbnailFillQueue.beginScan()
        loadState = .loading
        isLoadingFiles = true
        hasCompletedFileScan = false
        do {
            // Pull-to-refresh keeps the published snapshot while Android
            // re-queries handles and removes only confirmed missing objects.
            // Android's FHD resume is keyed by the explicit handle snapshot,
            // not by whether a metadata row happened to reach the UI yet.
            let preserveExisting = !allFiles.isEmpty || resumeSnapshot != nil
            if !preserveExisting {
                allFiles.removeAll(keepingCapacity: true)
                sections.removeAll()
            }
            let accumulator = ScanAccumulator()
            let result = try await scanCatalog(preserveExisting, resumeSnapshot, preserveExisting) { [weak self] batch in
                guard let self else { throw CancellationError() }
                try await self.acceptBatch(batch, generation: generation, accumulator: accumulator)
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            // Repository returns the merged logical rows in stable display
            // order, including dual-card membership replacements.
            allFiles = result.files
            if !result.removedHandles.isEmpty { await thumbnailFillQueue.remove(result.removedHandles) }
            await thumbnailFillQueue.seed(allFiles, priorityRange: filter.dateRange)
            await reconcileCache(allFiles, result.handleQueriesSucceeded && result.metadataComplete)
            publishSections()
            loadState = .loaded
            isLoadingFiles = false
            hasCompletedFileScan = true
            if !result.addedHandles.isEmpty {
                let added = result.files.filter { result.addedHandles.contains($0.id) && Self.isAutoTransferMedia($0) }
                if !added.isEmpty { newMediaHandler?(added) }
            }
            startThumbnailFillWorker()
        } catch is CancellationError {
            return
        } catch CameraRepositoryError.foregroundPreempted {
            // Remote monitor owns the command channel. Keep the rows already
            // shown and let the monitor dismissal trigger a fresh handle scan.
            guard generation == loadGeneration else { return }
            isLoadingFiles = false
            loadState = allFiles.isEmpty ? .idle : .loaded
            hasCompletedFileScan = false
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            // Preserve any already published files. A failed/incomplete scan
            // must not be treated as authoritative empty storage and must not
            // trigger disk-cache reconciliation.
            isLoadingFiles = false
            loadState = .failed(error.localizedDescription)
        }
    }

    private func publishSections() {
        // A refreshed catalog may reuse a handle for another file. Resolve
        // current file identity against the indexes, never a stale handle set.
        transferredIDs = indexedTransferredIDs
        sections = PhotoCatalogGrouping.byCaptureDay(
            PhotoFilter.apply(allFiles, state: filter, transferredIDs: transferredIDs),
        )
    }

    private func acceptBatch(
        _ batch: [CameraFile],
        generation: Int,
        accumulator: ScanAccumulator
    ) async throws {
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        var additions: [CameraFile] = []
        for file in batch where accumulator.publishedIDs.insert(file.id).inserted {
            allFiles.append(file)
            additions.append(file)
        }
        publishSections()
        // The repository awaits this callback: scanning cannot request the
        // next metadata batch until this batch's per-file prefetch has finished,
        // matching Android's accepted-batch/backpressure order.
        // Unlike ObjectAdded events, an accepted scan batch is not inserted into
        // the background queue here. Android prefetches this batch directly and
        // leaves misses out of the queue until the completed scan calls seed().
        // Enqueuing first would make a transient miss remain pending forever and
        // would change the order of the post-scan fill pass.
        // Android abandons this batch's background prefetch when a foreground
        // owner has the camera channel. The items stay pending for the normal
        // fill worker; they are not failures and must not require an unrelated
        // filter change to be retried.
        let channelAllowed = await canFill()
        let fillAllowed = !transferBusy && channelAllowed
        let settled = fillAllowed ? await prefetchBatch(additions) : Set<UInt32>()
        for id in settled { await thumbnailFillQueue.markSettled(id) }
        // Misses and transient errors are intentionally not marked failed here.
        // They are discovered by the post-scan seed and handled by the same
        // background worker as every other unsettled file, matching Android's
        // prefetchPublishedFileBatch behavior.
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        await Task.yield()
    }

    private final class ScanAccumulator: @unchecked Sendable {
        var publishedIDs = Set<UInt32>()
    }

    func cancelLoading() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoadingFiles = false
    }

    /// Android pauses the metadata pipeline while an interactive FHD preview
    /// owns the camera channel, retaining the published rows for resumption.
    func pauseForPreview() {
        guard isLoadingFiles else { return }
        previewPausedScan = true
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoadingFiles = false
    }

    func resumeAfterPreview() {
        guard previewPausedScan else { return }
        previewPausedScan = false
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading
        isLoadingFiles = true
        hasCompletedFileScan = false
        loadTask = Task { [weak self] in
            let snapshot = await self?.resumeSnapshotProvider()
            guard !Task.isCancelled else { return }
            await self?.reload(generation: generation, resumeSnapshot: snapshot)
        }
    }

    func setFilter(_ filter: PhotoFilterState) {
        self.filter = filter
        publishSections()
        Task { [weak self] in
            guard let self else { return }
            await thumbnailFillQueue.updatePriorityRange(allFiles, range: filter.dateRange)
            await thumbnailFillQueue.retryFailed()
            startThumbnailFillWorker()
        }
    }

    /// TransferViewModel exposes the same foreground gate Android feeds into
    /// CameraViewModel. A running transfer owns the PTP channel, so the list
    /// fill worker must stop and wake only after the transfer becomes idle.
    func setTransferBusy(_ busy: Bool) {
        guard transferBusy != busy else { return }
        transferBusy = busy
        if !busy { startThumbnailFillWorker() }
    }

    /// Reawaken background filling after a remote/FHD full-screen owner closes.
    func wakeThumbnailFill() { startThumbnailFillWorker() }

    /// Remote monitor can capture new media, therefore its return path starts
    /// a fresh handle enumeration rather than resuming the old scan snapshot.
    func resumeAfterRemote() {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading
        isLoadingFiles = true
        hasCompletedFileScan = false
        loadTask = Task { [weak self] in
            await self?.reload(generation: generation, resumeSnapshot: nil)
        }
    }

    private func updateTransferredIDs(_ ids: Set<UInt32>) {
        guard ids != transferredIDs else { return }
        transferredIDs = ids
        guard loadState == .loaded else { return }
        publishSections()
    }

    /// recordExistingExport is an index insertion, never a replacement with
    /// the queue's currently completed IDs. Keep originals after clear, retry
    /// and derived-image failure, and reject late results from an old folder.
    func recordTransferredOriginals(_ items: [TransferQueueItem]) {
        guard let root = transferIndexDirectory else { return }
        if queueOriginals.record(items, root: root) { publishTransferredOriginals() }
    }

    private func publishTransferredOriginals() {
        updateTransferredIDs(indexedTransferredIDs)
    }

    private var indexedTransferredIDs: Set<UInt32> {
        Set(allFiles.compactMap { file -> UInt32? in
            let folder = transferIndexOrganizeByDate ? transferDateFolderName(file.captureDate) : nil
            return diskOriginals.original(for: file, folderName: folder) != nil ||
                queueOriginals.original(for: file, folderName: folder) != nil ? file.id : nil
        })
    }

    /// Android refreshes the exported-original index independently of the
    /// queue. This keeps the list's "untransferred" filter correct even when
    /// the app is reopened with an empty in-memory queue.
    func refreshTransferredIDs(directory: URL?, organizeByDate: Bool) {
        transferIndexGeneration &+= 1
        let generation = transferIndexGeneration
        if transferIndexDirectory != directory {
            diskOriginals = ExportedOriginalIndex()
            queueOriginals = ExportedOriginalIndex()
        }
        transferIndexDirectory = directory
        transferIndexOrganizeByDate = organizeByDate
        publishTransferredOriginals()
        guard let directory else {
            return
        }
        let indexTask = Task.detached(priority: .utility) {
            var result = ExportedOriginalIndex()
            guard FileManager.default.fileExists(atPath: directory.path) else { return result }
            result.merge(TransferDirectoryIndex.scan(directory: directory), folderName: nil)
            if let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                for child in children where transferDatedFolderName(child.lastPathComponent) {
                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    result.merge(TransferDirectoryIndex.scan(directory: child), folderName: child.lastPathComponent)
                }
            }
            return result
        }
        Task { [weak self] in
            let index = await indexTask.value
            guard let self, generation == self.transferIndexGeneration else { return }
            self.diskOriginals = index
            self.publishTransferredOriginals()
        }
    }

    func clearFilter() { setFilter(PhotoFilterState()) }

    private func startThumbnailFillWorker() {
        if fillWorkerActive {
            Task { await thumbnailFillQueue.wake() }
            return
        }
        fillWorkerActive = true
        fillTask = Task { [weak self] in
            guard let self else { return }
            defer { self.fillWorkerActive = false }
            while !Task.isCancelled {
                guard let polled = await thumbnailFillQueue.poll() else {
                    await thumbnailFillQueue.waitForWake()
                    // Android promotes transient failures only after an external
                    // wake-up (network/session/foreground state), never in a
                    // hot loop. Keep the same retry boundary here.
                    await thumbnailFillQueue.retryFailed()
                    continue
                }
                let id = polled.id
                // Android's queue resolves the current file when a task is
                // consumed. Do not capture a one-time catalog snapshot here:
                // ObjectAdded can enqueue a file after the worker starts.
                guard let file = self.allFiles.first(where: { $0.id == id }) else {
                    continue
                }
                guard !self.transferBusy, await canFill() else {
                    await thumbnailFillQueue.returnToFront(id, expectedRevision: polled.revision)
                    return
                }
                let settled = await prefetchBatch([file])
                // The Android worker treats a foreground owner taking the
                // channel as a pause, not as a thumbnail failure. The session
                // prefetch closure can return an empty set when that gate
                // closes during the request, so check it before classifying
                // the result and put the item back on the same scan revision.
                guard !self.transferBusy, await canFill() else {
                    await thumbnailFillQueue.returnToFront(id, expectedRevision: polled.revision)
                    return
                }
                if settled.contains(id) { await thumbnailFillQueue.markSettled(id) }
                else { await thumbnailFillQueue.markFailed(id) }
            }
        }
    }
}
