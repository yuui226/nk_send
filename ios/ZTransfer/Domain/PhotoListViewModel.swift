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
    // The workspace swaps between the photo list, transfer queue and monitor.
    // Keep one model per camera session so those routes never discard the
    // already enumerated files or their in-memory thumbnail work state.
    private static var sessionModels: [ObjectIdentifier: PhotoListViewModel] = [:]

    static func cached(session: CameraSession, onTransportLost: (() -> Void)? = nil) -> PhotoListViewModel {
        let key = ObjectIdentifier(session)
        if let existing = sessionModels[key] { return existing }
        let model = PhotoListViewModel(session: session, onTransportLost: onTransportLost)
        sessionModels[key] = model
        return model
    }

    /// A model survives route changes only while its CameraSession is the
    /// workspace owner. Once reconnect or camera switching replaces that
    /// session, release every task and the strong cache entry together.
    static func evict(session: CameraSession) {
        sessionModels.removeValue(forKey: ObjectIdentifier(session))?.retire()
    }
    @Published private(set) var loadState: PhotoListLoadState = .idle
    @Published private(set) var sections: [PhotoDaySection] = []
    /// The complete session catalog is retained for transfer and event
    /// bookkeeping; this is the range-scoped catalog presented in the grid.
    @Published private(set) var displayedFiles: [CameraFile] = []
    @Published private(set) var availableDayKeys: Set<String> = []
    @Published private(set) var burstGroups: [BurstPhotoGroup] = []
    @Published private(set) var burstIDByFile: [UInt32: String] = [:]
    @Published private(set) var exitingTransferredFileIDs: Set<UInt32> = []
    @Published private(set) var filter = PhotoFilterState()
    @Published private(set) var photoLoadingRange = PhotoFilterPersistence.loadPhotoLoadingRange()
    @Published private(set) var availableStorageSlots: [UInt32] = []
    /// Android derives these with `remember(presentedCameraFiles)`. Keep the
    /// same catalog-scoped cache here so opening Filter is a constant-time
    /// state change instead of a fresh walk over every camera file.
    private(set) var availableFilterExtensions: [String] = []
    private(set) var latestKnownCaptureDay: String?
    /// Mirrors Android's `isLoadingFiles`/`hasCompletedFileScan` pair.  The
    /// view may receive several published batches before the scan completes.
    @Published private(set) var isLoadingFiles = false
    @Published private(set) var hasCompletedFileScan = false
    /// Rating filter consumers observe the lifecycle state separately from
    /// the grid, so toggling the loader never replays list animations.
    @Published private(set) var ratingScan = PhotoRatingScan()
    private var allFiles: [CameraFile] = []
    private var transferredIDs: Set<UInt32> = []
    private var storageIDsBySlot: [UInt32: Set<UInt32>] = [:]
    var availableFiles: [CameraFile] { allFiles }
    var transferredFileIDs: Set<UInt32> { transferredIDs }
    private let scanCatalog: (@Sendable (Bool, PhotoScanSnapshot?, Bool, @escaping @Sendable () async -> Int, @escaping @Sendable ([CameraFile]) async throws -> Void) async throws -> PhotoScanResult)?
    private let resumeSnapshotProvider: @Sendable () async -> PhotoScanSnapshot?
    private let prefetchBatch: @Sendable ([CameraFile]) async -> ThumbnailBatchResult
    private let canFill: @Sendable () async -> Bool
    private let reconcileCache: @Sendable ([CameraFile], Bool) async -> Void
    private let invalidateThumbnailState: @Sendable ([CameraFile]) async -> Void
    private let setRemoteGate: @Sendable (Bool) async -> Void
    private let onTransportLost: (() -> Void)?
    private let thumbnailFillQueue: PhotoThumbnailFillQueue
    private let sequentialLoading: Bool
    private let ratingScanController: PhotoRatingScanController
    private var ratingScanObservation: AnyCancellable?
    private var catalogUpdatesTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var fillTask: Task<Void, Never>?
    private var fillResumeTask: Task<Void, Never>?
    private var fillWorkerActive = false
    private var previewPausedScan = false
    private var previewActive = false
    private var remoteActive = false
    private var remoteRefreshPending = false
    private var transferBusy = false
    private var newMediaHandler: (([CameraFile]) -> Void)?
    private var transferIndexGeneration = 0
    private var transferIndexDirectory: URL?
    private var transferIndexOrganizeByDate = false
    private var diskOriginals = ExportedOriginalIndex()
    private var queueOriginals = ExportedOriginalIndex()
    /// A cancelled/old scan must never publish over a newer camera session.
    private var loadGeneration = 0
    private var loadingRangeScanStopped = false

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

    init(session: CameraSession, onTransportLost: (() -> Void)? = nil) {
        sequentialLoading = session.wirelessMode == .sta
        thumbnailFillQueue = PhotoThumbnailFillQueue(sequential: session.wirelessMode == .sta)
        ratingScanController = PhotoRatingScanController(io: PhotoRatingScanIO(session: session))
        self._filter = Published(initialValue: PhotoFilterPersistence.load())
        self.onTransportLost = onTransportLost
        self.setRemoteGate = { await session.setRemoteActive($0) }
        self.scanCatalog = { preserve, snapshot, detect, nextBatchSize, handler in
            let loadingRange = PhotoFilterPersistence.loadPhotoLoadingRange()
            return try await session.scanCatalog(preserveExisting: preserve,
                                                 resumeSnapshot: snapshot,
                                                 detectNewHandles: detect,
                                                 loadingRange: loadingRange,
                                                 nextBatchSize: nextBatchSize,
                                                 onBatch: handler)
        }
        self.resumeSnapshotProvider = { await session.scanSnapshotForResume() }
        self.prefetchBatch = { files in
            var result = ThumbnailBatchResult()
            for file in files {
                if session.wirelessMode == .sta {
                    while !Task.isCancelled, !(await session.backgroundThumbnailFillAllowed()) {
                        result.interrupted = true
                        do { try await Task.sleep(for: .milliseconds(50)) }
                        catch { return result }
                    }
                }
                guard !Task.isCancelled, await session.backgroundThumbnailFillAllowed() else {
                    result.interrupted = true
                    return result
                }
                if let outcome = try? await session.prefetchThumbnailOutcome(file: file) {
                    if outcome.isSettled { result.settled.insert(file.id) }
                    if outcome == .cached { result.cached.insert(file.id) }
                }
            }
            return result
        }
        self.canFill = { await session.backgroundThumbnailFillAllowed() }
        self.reconcileCache = { files, authoritative in
            await session.reconcileThumbnailCache(files: files, authoritative: authoritative)
        }
        self.invalidateThumbnailState = { files in
            await session.invalidateThumbnailState(files: files)
        }
        catalogUpdatesTask = Task { [weak self] in
            let repository = session.repository
            for await files in await repository.catalogUpdates() {
                guard !Task.isCancelled else { return }
                self?.applyCatalogUpdate(files)
            }
        }
        ratingScanObservation = ratingScanController.$state.sink { [weak self] value in
            self?.ratingScan = value
        }
    }

    /// A restored workspace has presentation state but no catalog transport.
    /// It cannot start a scan, manufacture files or claim a completed scan.
    convenience init(disconnected: CameraPresentationMode) {
        self.init(scanCatalog: nil, setRemoteGate: { _ in },
                  sequentialLoading: disconnected == .sta)
        self.filter = PhotoFilterPersistence.load()
    }

    /// Dependency seam for lifecycle tests. Production sessions use the
    /// initializer above; keeping the scan and gate closures injectable lets
    /// the remote/FHD preemption contract be verified without a synthetic PTP
    /// transport obscuring the ordering under test.
    init(
        scanCatalog: (@Sendable (Bool, PhotoScanSnapshot?, Bool, @escaping @Sendable () async -> Int, @escaping @Sendable ([CameraFile]) async throws -> Void) async throws -> PhotoScanResult)?,
        resumeSnapshotProvider: @escaping @Sendable () async -> PhotoScanSnapshot? = { nil },
        prefetchBatch: @escaping @Sendable ([CameraFile]) async -> ThumbnailBatchResult = { _ in ThumbnailBatchResult() },
        canFill: @escaping @Sendable () async -> Bool = { false },
        reconcileCache: @escaping @Sendable ([CameraFile], Bool) async -> Void = { _, _ in },
        invalidateThumbnailState: @escaping @Sendable ([CameraFile]) async -> Void = { _ in },
        setRemoteGate: @escaping @Sendable (Bool) async -> Void,
        sequentialLoading: Bool = false,
        onTransportLost: (() -> Void)? = nil
    ) {
        self.sequentialLoading = sequentialLoading
        self.thumbnailFillQueue = PhotoThumbnailFillQueue(sequential: sequentialLoading)
        self.ratingScanController = PhotoRatingScanController(io: .noop)
        self.scanCatalog = scanCatalog
        self.resumeSnapshotProvider = resumeSnapshotProvider
        self.prefetchBatch = prefetchBatch
        self.canFill = canFill
        self.reconcileCache = reconcileCache
        self.invalidateThumbnailState = invalidateThumbnailState
        self.setRemoteGate = setRemoteGate
        self.onTransportLost = onTransportLost
        ratingScanObservation = ratingScanController.$state.sink { [weak self] value in
            self?.ratingScan = value
        }
    }
    private func applyCatalogUpdate(_ files: [CameraFile]) {
        guard loadState == .loaded else { return }
        let oldByID = Dictionary(uniqueKeysWithValues: allFiles.map { ($0.id, $0) })
        let oldIDs = Set(oldByID.keys)
        let oldLogicalIDs = Set(allFiles.map(PublishedPhotoIdentity.init))
        let currentIDs = Set(files.map(\.id))
        allFiles = files
        publishSections()
        // A dual-card backup alias can replace a deleted primary handle
        // without representing new media. Android compares the published
        // logical identity here, so that replacement must not auto-transfer.
        let additions = files.filter { !oldLogicalIDs.contains(PublishedPhotoIdentity($0)) }
        let removals = oldIDs.subtracting(currentIDs).compactMap { oldByID[$0] }
        if !additions.isEmpty || !removals.isEmpty {
            newMediaHandler?(additions.filter(Self.isAutoTransferMedia))
            Task { [weak self] in
                guard let self else { return }
                await invalidateThumbnailState(removals)
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
        [".jpg", ".jpeg", ".tif", ".png", ".bmp", ".gif", ".ico",
         ".mov", ".avi", ".mp4", ".nef", ".crw", ".cr2", ".cr3",
         ".arw"].contains(file.fileExtension)
    }

    deinit {
        loadTask?.cancel()
        fillTask?.cancel()
        fillResumeTask?.cancel()
        catalogUpdatesTask?.cancel()
    }

    private func retire() {
        loadGeneration &+= 1
        transferIndexGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        fillTask?.cancel()
        fillTask = nil
        ratingScanController.cancel()
        fillResumeTask?.cancel()
        fillResumeTask = nil
        fillWorkerActive = false
        catalogUpdatesTask?.cancel()
        catalogUpdatesTask = nil
        newMediaHandler = nil
        isLoadingFiles = false
        displayedFiles.removeAll()
    }

    func load() {
        guard scanCatalog != nil else { return }
        guard case .idle = loadState else {
            // Returning from another workspace must not start a second scan.
            return
        }
        loadTask?.cancel()
        fillTask?.cancel()
        fillTask = nil
        fillResumeTask?.cancel()
        fillResumeTask = nil
        fillWorkerActive = false
        loadGeneration &+= 1
        let generation = loadGeneration
        allFiles.removeAll(keepingCapacity: true)
        displayedFiles.removeAll(keepingCapacity: true)
        sections.removeAll()
        hasCompletedFileScan = false
        isLoadingFiles = true
        loadState = .loading
        loadTask = Task { [weak self] in
            await self?.reload(generation: generation, resumeSnapshot: nil)
        }
    }

    /// Explicit refresh for non-STA owners. The list has no pull-to-refresh;
    /// repeated STA entry requests cannot replace the session's scan.
    func reload() async {
        guard scanCatalog != nil else { return }
        // STA has one session-owned scan. UI refreshes cannot replace its cursor.
        guard !sequentialLoading else { load(); return }
        loadGeneration &+= 1
        let generation = loadGeneration
        // CameraViewModel.loadFiles cancels the previous fileLoadJob before
        // starting a refresh. Without this, the old scan could keep issuing
        // metadata commands until its next generation check, competing with
        // the new scan for the same PTP session.
        let previous = loadTask
        previous?.cancel()
        await previous?.value
        guard !Task.isCancelled, generation == loadGeneration else { return }
        loadTask = nil
        await reload(generation: generation, resumeSnapshot: nil)
    }

    private func reload(generation: Int, resumeSnapshot: PhotoScanSnapshot?, preserve: Bool? = nil) async {
        guard generation == loadGeneration, let scanCatalog else { return }
        // Android's fill collector is gated by hasCompletedFileScan. Cancel
        // the existing worker for refreshes too, otherwise an old worker can
        // issue GetThumb while this generation is enumerating handles.
        fillTask?.cancel()
        fillTask = nil
        fillResumeTask?.cancel()
        fillResumeTask = nil
        fillWorkerActive = false
        await thumbnailFillQueue.beginScan()
        loadingRangeScanStopped = false
        loadState = .loading
        isLoadingFiles = true
        hasCompletedFileScan = false
        do {
            // Pull-to-refresh keeps the published snapshot while Android
            // re-queries handles and removes only confirmed missing objects.
            // Android's FHD resume is keyed by the explicit handle snapshot,
            // not by whether a metadata row happened to reach the UI yet.
            let preserveExisting = preserve ?? (!allFiles.isEmpty || resumeSnapshot != nil)
            if !preserveExisting {
                allFiles.removeAll(keepingCapacity: true)
                sections.removeAll()
            }
            let accumulator = ScanAccumulator()
            accumulator.publishedIDs = Set(allFiles.map(\.id))
            accumulator.initialLogicalIDs = Set(allFiles.map(PublishedPhotoIdentity.init))
            let result = try await scanCatalog(preserveExisting, resumeSnapshot, preserveExisting, { [weak self] in
                guard let self else { return 12 }
                return await self.nextScanBatchSize(generation: generation, accumulator: accumulator)
            }) { [weak self] batch in
                guard let self else { throw CancellationError() }
                try await self.acceptBatch(batch, generation: generation, accumulator: accumulator)
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            // Repository returns the merged logical rows in stable display
            // order, including dual-card membership replacements.
            allFiles = result.files
            loadingRangeScanStopped = result.stoppedAtLoadingRange
            if result.handleQueriesSucceeded {
                storageIDsBySlot = photoStorageIDsBySlot(result.filterStorageIDs)
                availableStorageSlots = storageIDsBySlot.keys.sorted()
                let normalizedSlot = normalizedPhotoStorageSlot(filter.storageSlot,
                                                                available: availableStorageSlots,
                                                                scanComplete: true)
                if normalizedSlot != filter.storageSlot { filter.storageSlot = normalizedSlot }
            }
            if !result.removedHandles.isEmpty { await thumbnailFillQueue.remove(result.removedHandles) }
            await thumbnailFillQueue.seed(
                allFiles,
                priorityRange: filter.dateRange,
                loadingRange: newestCaptureDaysRange(allFiles, days: photoLoadingRange.days)
            )
            await reconcileCache(allFiles, result.handleQueriesSucceeded && result.metadataComplete)
            publishSections()
            loadState = .loaded
            isLoadingFiles = false
            hasCompletedFileScan = true
            if !result.addedHandles.isEmpty {
                let added = result.files.filter {
                    result.addedHandles.contains($0.id) &&
                        !accumulator.initialLogicalIDs.contains(PublishedPhotoIdentity($0)) &&
                        Self.isAutoTransferMedia($0)
                }
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
        } catch CameraRepositoryError.transportLost {
            guard generation == loadGeneration else { return }
            isLoadingFiles = false
            hasCompletedFileScan = false
            loadState = allFiles.isEmpty ? .failed(AppLocalized.resource("connection_failed_short")) : .loaded
            onTransportLost?()
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
        let loadingRange = newestCaptureDaysRange(allFiles, days: photoLoadingRange.days)
        let scopedFiles = loadingRange == nil
            ? allFiles
            : allFiles.filter { file in
                file.captureDate == nil || loadingRange?.contains(file.captureDate) == true
            }
        displayedFiles = scopedFiles

        var extensions = Set<String>()
        var latestDay: String?
        for file in scopedFiles {
            extensions.insert(file.fileExtension.lowercased())
            if let day = validPhotoCaptureDay(file.captureDate) {
                if let current = latestDay {
                    if day > current { latestDay = day }
                } else {
                    latestDay = day
                }
            }
        }
        availableFilterExtensions = extensions.sorted()
        latestKnownCaptureDay = latestDay
        transferredIDs = indexedTransferredIDs
        availableDayKeys = Set(scopedFiles.map { file in
            guard let value = file.captureDate, value.count >= 8 else { return PhotoCatalogGrouping.unknownDay }
            return String(value.prefix(8))
        })
        burstGroups = PhotoCatalogGrouping.bursts(in: scopedFiles)
        burstIDByFile = burstGroups.reduce(into: [:]) { result, group in
            for file in group.files { result[file.id] = group.id }
        }
        sections = PhotoCatalogGrouping.byCaptureDay(
            PhotoFilter.apply(scopedFiles, state: filter,
                              transferredIDs: transferredIDs.subtracting(exitingTransferredFileIDs),
                              storageIDsBySlot: storageIDsBySlot),
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
        var allCached = !additions.isEmpty
        for file in additions {
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            if sequentialLoading {
                let allowed = await canFill()
                if transferBusy || previewActive || remoteActive || !allowed { allCached = false }
                try await waitForSequentialChannel()
            } else {
                let allowed = await canFill()
                guard !transferBusy, !previewActive, !remoteActive, allowed else {
                    allCached = false
                    break
                }
            }
            let result = await prefetchBatch([file])
            for id in result.settled { await thumbnailFillQueue.markSettled(id) }
            allCached = allCached && result.cached.contains(file.id) && !result.interrupted
        }
        accumulator.batchPolicy.complete(count: additions.count, allCached: allCached)
        // Misses and transient errors are intentionally not marked failed here.
        // They are discovered by the post-scan seed and handled by the same
        // background worker as every other unsettled file, matching Android's
        // prefetchPublishedFileBatch behavior.
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        await Task.yield()
    }

    private func nextScanBatchSize(generation: Int, accumulator: ScanAccumulator) async -> Int {
        guard generation == loadGeneration else { return 12 }
        let allowed = await canFill()
        if transferBusy || previewActive || remoteActive || !allowed {
            accumulator.batchPolicy.complete(count: 0, allCached: false)
        }
        return accumulator.batchPolicy.size
    }

    private final class ScanAccumulator: @unchecked Sendable {
        var batchPolicy = CachedThumbnailBatchPolicy()
        var publishedIDs = Set<UInt32>()
        var initialLogicalIDs = Set<PublishedPhotoIdentity>()
    }

    func cancelLoading() {
        guard !sequentialLoading else { return }
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoadingFiles = false
    }

    /// Android pauses the metadata pipeline while an interactive FHD preview
    /// owns the camera channel, retaining the published rows for resumption.
    func pauseForPreview() {
        previewActive = true
        guard !sequentialLoading else { return }
        guard isLoadingFiles else { return }
        previewPausedScan = true
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoadingFiles = false
    }

    func resumeAfterPreview() {
        previewActive = false
        if sequentialLoading { wakeThumbnailFill(); return }
        guard !remoteActive else { return }
        if remoteRefreshPending {
            remoteRefreshPending = false
            refreshAfterRemote()
            return
        }
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
        if !filter.untransferredOnly { exitingTransferredFileIDs.removeAll() }
        PhotoFilterPersistence.save(filter)
        publishSections()
        guard !sequentialLoading else { return }
        Task { [weak self] in
            guard let self else { return }
            await thumbnailFillQueue.updatePriorityRange(allFiles, range: filter.dateRange)
            await thumbnailFillQueue.retryFailed()
            startThumbnailFillWorker()
        }
    }

    /// Persists the Android-compatible newest-shooting-day scope. Shrinking
    /// only changes the presented set and queue admission. If an earlier
    /// bounded scan retained a handle snapshot, widening resumes that same
    /// snapshot instead of starting a second enumeration from the camera.
    func setPhotoLoadingRange(_ range: PhotoLoadingRange) {
        let previous = photoLoadingRange
        guard previous != range else { return }
        PhotoFilterPersistence.savePhotoLoadingRange(range)
        photoLoadingRange = range
        publishSections()
        let allowed = newestCaptureDaysRange(allFiles, days: range.days)
        Task { [weak self] in
            guard let self else { return }
            await thumbnailFillQueue.updateLoadingRange(allFiles, range: allowed)
            await thumbnailFillQueue.wake()
            let widened = previous.days > 0 && (range.days == 0 || range.days > previous.days)
            guard widened, loadingRangeScanStopped, hasCompletedFileScan,
                  self.scanCatalog != nil else { return }
            loadTask?.cancel()
            loadGeneration &+= 1
            let generation = loadGeneration
            let snapshot = await resumeSnapshotProvider()
            guard !Task.isCancelled else { return }
            loadState = .loading
            isLoadingFiles = true
            hasCompletedFileScan = false
            loadTask = Task { [weak self] in
                await self?.reload(generation: generation, resumeSnapshot: snapshot, preserve: true)
            }
        }
    }

    /// Feeds the Android-equivalent rating lifecycle. The UI owns the switch,
    /// pause boundary and selected rating days; the controller owns snapshot,
    /// cache, progress and cancellation semantics.
    func updateRatingScan(enabled: Bool, paused: Bool = false,
                          recentThumbnailReadyDays: Int = 0,
                          ratingDays: Int = 3,
                          files: [CameraFile]? = nil) {
        let input = PhotoRatingScanInput(
            files: files ?? allFiles,
            paused: paused,
            useObjectRating: !sequentialLoading,
            staConnection: sequentialLoading,
            listLoading: isLoadingFiles,
            recentThumbnailReadyDays: recentThumbnailReadyDays,
            ratingDays: ratingDays,
            photoLoadingDays: photoLoadingRange.days
        )
        ratingScanController.update(input, enabled: enabled)
    }

    func cancelRatingScan() {
        ratingScanController.cancel()
    }

    /// TransferViewModel exposes the same foreground gate Android feeds into
    /// CameraViewModel. A running transfer owns the PTP channel, so the list
    /// fill worker must stop and wake only after the transfer becomes idle.
    func setTransferBusy(_ busy: Bool) {
        guard transferBusy != busy else { return }
        transferBusy = busy
        if sequentialLoading {
            if !busy { wakeThumbnailFill() }
            return
        }
        fillResumeTask?.cancel()
        fillResumeTask = nil
        if busy {
            // Android's collectLatest cancels the active background-fill
            // coroutine as soon as a transfer takes ownership. Cancelling the
            // waiter also cancels its sole thumbnail flight, so the first file
            // chunk is not left waiting behind a full GetThumb transaction.
            fillTask?.cancel()
        } else {
            // A cancelled worker clears fillWorkerActive in its defer. Wait
            // for that cleanup before restarting or startThumbnailFillWorker
            // would observe the old worker and lose this resume edge.
            let stoppingWorker = fillTask
            fillResumeTask = Task { [weak self] in
                await stoppingWorker?.value
                guard let self, !Task.isCancelled, !self.transferBusy else { return }
                self.startThumbnailFillWorker()
            }
        }
    }

    /// Reawaken background filling after a remote/FHD full-screen owner closes.
    func wakeThumbnailFill() {
        guard !sequentialLoading || hasCompletedFileScan else { return }
        startThumbnailFillWorker()
    }

    /// Remote monitor can capture new media, therefore its return path starts
    /// a fresh handle enumeration rather than resuming the old scan snapshot.
    /// Android RemoteScreen sets its page gate before loading any parameters.
    /// Drain the current command, then stop before the next metadata request;
    /// cancelling a live iOS PTP transaction would invalidate the connection.
    func pauseForRemote() async {
        guard !remoteActive else { return }
        remoteActive = true
        await setRemoteGate(true)
        guard !sequentialLoading else { return }
        await loadTask?.value
        isLoadingFiles = false
    }

    func resumeAfterRemote(isConnected: Bool) async {
        guard remoteActive else { return }
        remoteActive = false
        // Balance pauseForRemote's ownership here instead of relying on the
        // monitor model to release the same repository flag as a side effect.
        // The fresh handle scan must not be queued until the foreground gate
        // is visibly open, matching Android setRemoteActive(false).
        await setRemoteGate(false)
        guard isConnected else { return }
        if sequentialLoading { wakeThumbnailFill(); return }
        if previewActive { remoteRefreshPending = true; return }
        refreshAfterRemote()
    }

    private func refreshAfterRemote() {
        guard scanCatalog != nil else { return }
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading
        isLoadingFiles = true
        hasCompletedFileScan = false
        loadTask = Task { [weak self] in
            await self?.reload(generation: generation, resumeSnapshot: nil, preserve: true)
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
        let previous = indexedTransferredIDs
        if queueOriginals.record(items, root: root) {
            let current = indexedTransferredIDs
            exitingTransferredFileIDs.formUnion(newlyExitingTransferredFileIDs(
                previous: previous,
                current: current,
                queueItems: items,
                untransferredOnly: filter.untransferredOnly
            ))
            publishTransferredOriginals()
        }
    }

    func finishTransferredExit(_ fileID: UInt32) {
        guard exitingTransferredFileIDs.remove(fileID) != nil else { return }
        publishSections()
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

    private func waitForSequentialChannel() async throws {
        while true {
            try Task.checkCancellation()
            if !transferBusy && !previewActive && !remoteActive, await canFill() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

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
                if sequentialLoading {
                    do { try await waitForSequentialChannel() }
                    catch { return }
                    let settled = await prefetchBatch([file]).settled
                    if settled.contains(id) { await thumbnailFillQueue.markSettled(id) }
                    else { await thumbnailFillQueue.markFailed(id) }
                    continue
                }
                guard !self.transferBusy, await canFill() else {
                    await thumbnailFillQueue.returnToFront(id, expectedRevision: polled.revision)
                    return
                }
                let settled = await prefetchBatch([file]).settled
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
