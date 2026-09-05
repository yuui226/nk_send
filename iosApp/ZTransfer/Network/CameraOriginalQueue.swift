import Foundation
import ZTransferShared

struct OriginalQueueRow: Sendable {
    let id: Int64
    let name: String
    let handle: Int32
    let size: Int64
    let captureDate: String?
    let isProtected: Bool
    let storageIDs: [Int32]
    let destinationFolderName: String?
    let status: String
    let skipped: Bool
    let downloaded: Int64
    let fraction: Float
    let bytesPerSecond: Int64
    let error: String?
    let elapsedMs: Int64?
    let downloadMBps: Float
}

struct OriginalQueueSnapshot: Sendable {
    let connectionID: UUID
    let sequence: UInt64
    /// Changes only with queue/history/execution updates, not 200 ms byte samples.
    let historyRevision: UInt64
    let completedOriginalRevision: UInt64
    let rows: [OriginalQueueRow]
    let running: Bool
    let paused: Bool
}

/// Original-file executor bound to one camera generation. Shared owns FIFO/history transitions;
/// this actor owns the asynchronous task, disk operations and cancellation. No camera rebinding:
/// reusing old object handles after reconnect requires the later identity/checkpoint validation.
actor CameraOriginalQueue {
    nonisolated let updates: AsyncStream<OriginalQueueSnapshot>
    private let notifications: AsyncStream<OriginalQueueSnapshot>.Continuation
    private let core = NativeOriginalTransferQueue()
    private let camera: CameraWiFiConnection
    private let store: CameraOriginalStore
    private var destination: OriginalFilesDestination?
    private var destinationRevision: UInt64 = 0
    private var changingDestination = false
    private var startAfterDestinationChange = false
    private var stagedFiles: [Int64: SavedCameraFile] = [:]
    private var originalLookup = NativeOriginalFileIndex()
    private var reusedFiles: [Int64: (source: OriginalFilesReusing, reference: ExistingOriginalReference)] = [:]
    private var worker: Task<Void, Never>?
    private var savedFiles: [Int64: SavedCameraFile] = [:]
    private var historyRevision: UInt64 = 0
    private var completedOriginalRevision: UInt64 = 0
    private var sequence: UInt64 = 0

    init(camera: CameraWiFiConnection, store: CameraOriginalStore, destination: OriginalFilesDestination? = nil) {
        self.camera = camera
        self.store = store
        self.destination = destination // Restored before admission; runNext still validates before any IO.
        var continuation: AsyncStream<OriginalQueueSnapshot>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        notifications = continuation
    }

    deinit { worker?.cancel(); notifications.finish() }

    /// No live run rebinding. An idle/waiting queue uses the explicitly selected root on its next run,
    /// just as Android snapshots the root at processQueue start. Folder/name stay in shared tasks.
    @discardableResult
    func configureDestination(_ value: OriginalFilesDestination?) async throws -> Bool {
        guard worker == nil, !core.running, !changingDestination else { return false }
        let revision = destinationRevision
        if let value { try await value.validateSelection() }
        try Task.checkCancellation()
        guard worker == nil, !core.running, !changingDestination, revision == destinationRevision else { return false }
        destination = value
        destinationRevision &+= 1
        return true
    }

    /// Fence only execution, not admission. A queued start resumes once with the committed target
    /// (or the unchanged old target on failure). A later pause/stop withdraws that queued start.
    @discardableResult
    func configureDestination(_ change: OriginalDestinationChange) async throws -> Bool {
        guard worker == nil, !core.running, !changingDestination else { return false }
        changingDestination = true
        defer {
            changingDestination = false
            let shouldStart = startAfterDestinationChange
            startAfterDestinationChange = false
            if shouldStart { start() }
        }
        try Task.checkCancellation()
        try await change.commit()
        destination = change.destination // No await, validation or cancellation check after commit.
        destinationRevision &+= 1
        return true
    }

    @discardableResult
    func enqueue(_ info: PtpObjectInfo, byDate: Bool, dayKey: Int32, deferred: Bool) -> Int64? {
        guard let task = core.enqueue(info: info, byDate: byDate, dayKey: dayKey) else { return nil }
        publish()
        if core.shouldAutoStart(deferred: deferred) { start() }
        return task.taskId
    }

    /// One actor turn admits the selected catalog batch in its supplied order, then starts once.
    func enqueueCatalog(_ infos: [PtpObjectInfo], files: [CameraFileInfo], byDate: Bool, dayKey: Int32, deferred: Bool) -> Int {
        guard !Task.isCancelled, infos.count == files.count else { return 0 }
        var accepted = 0
        for (info, file) in zip(infos, files) {
            guard core.enqueueCatalog(info: info, file: file, byDate: byDate, dayKey: dayKey) != nil else { break }
            accepted += 1
        }
        if accepted > 0 {
            publish()
            if core.shouldAutoStart(deferred: deferred) { start() }
        }
        return accepted
    }

    func start() {
        if changingDestination { startAfterDestinationChange = true; return }
        guard worker == nil, core.start() else { return }
        originalLookup = NativeOriginalFileIndex() // Rescan once per run, then consume the owner's bounded deltas.
        publish()
        worker = Task { [weak self] in
            // Retain the owner only during one bounded file operation, not while idle.
            while !Task.isCancelled, await self?.runNext() == true {}
            await self?.finished()
        }
    }

    func pauseAfterCurrent() { startAfterDestinationChange = false; core.pauseAfterCurrent(); publish() }
    func withdraw(_ taskID: Int64) { core.withdraw(taskId: taskID); publish() }
    func withdrawPending() { core.withdrawPending(); publish() }
    @discardableResult
    func removeTask(_ taskID: Int64) -> Bool {
        let removed = core.removeTask(taskId: taskID)
        if removed {
            // Only release the queue's lookup; never delete the user's completed original.
            savedFiles.removeValue(forKey: taskID)
            stagedFiles.removeValue(forKey: taskID)
            reusedFiles.removeValue(forKey: taskID)
            publish()
        }
        return removed
    }
    func clearTerminal() {
        core.clearTerminal()
        let retained = Set((0..<Int(core.count)).compactMap { core.taskAt(index: Int32($0))?.taskId })
        savedFiles = savedFiles.filter { retained.contains($0.key) }
        stagedFiles = stagedFiles.filter { retained.contains($0.key) }
        reusedFiles = reusedFiles.filter { retained.contains($0.key) }
        publish()
    }
    func retry(_ taskID: Int64) {
        if let attempt = core.retry(taskId: taskID), let staged = stagedFiles.removeValue(forKey: taskID) {
            stagedFiles[attempt.taskId] = staged
        }
        publish()
        if !core.paused { start() }
    }
    @discardableResult
    func retryFailed(excluding taskIDs: Set<Int64>) -> Int32 {
        let before = (0..<Int(core.count)).compactMap { core.taskAt(index: Int32($0)) }
        let count = core.retryFailed(excludedTaskIds: Set(taskIDs.map { KotlinLong(value: $0) }))
        if count > 0 {
            // The shared reducer replaces retries in-place; only carry IO context to its new IDs.
            // Do not reproduce its eligibility, exclusions, FIFO ordering or task creation in Swift.
            for (index, previous) in before.enumerated() {
                if let attempt = core.taskAt(index: Int32(index)), attempt.taskId != previous.taskId,
                   attempt.file == previous.file, attempt.destinationFolderName == previous.destinationFolderName,
                   let staged = stagedFiles.removeValue(forKey: previous.taskId) {
                    stagedFiles[attempt.taskId] = staged
                }
            }
            publish()
            if !core.paused { start() }
        }
        return count
    }
    func savedFile(_ taskID: Int64) -> SavedCameraFile? { savedFiles[taskID] ?? stagedFiles[taskID] }

    /// Existing provider originals are copied on demand; never hand a scoped URL to ShareLink.
    func prepareSavedFile(_ taskID: Int64) async throws -> SavedCameraFile? {
        if let saved = savedFile(taskID) { return saved }
        guard let reused = reusedFiles[taskID] else { return nil }
        let output = try await store.makeShareFile(name: reused.reference.name, size: reused.reference.size)
        do {
            let bytes = try await reused.source.copyOriginal(reused.reference, to: output)
            guard bytes == reused.reference.size else { throw OriginalIndexError.incompleteMetadata }
            try Task.checkCancellation()
            let saved = try output.commit(expectedBytes: bytes)
            // Removal/clear may run while a provider is materializing bytes. Do not resurrect history.
            if reusedFiles[taskID]?.reference == reused.reference { savedFiles[taskID] = saved }
            return saved
        } catch {
            output.discard() // Only this private part. Never delete the original or a committed share.
            throw error
        }
    }

    private func existingOriginal(for task: TransferTask, source: OriginalFilesReusing) async throws -> ExistingOriginalReference? {
        let value = try await source.originals(since: originalLookup.revision, rescan: !originalLookup.hasSnapshot)
        try Task.checkCancellation()
        let update = NativeOriginalIndexUpdate(revision: value.revision, baseRevision: value.baseRevision, fullSnapshot: value.fullSnapshot)
        for entry in value.entries {
            guard update.add(name: entry.name, size: entry.size, folder: entry.folder, locator: entry.url.absoluteString) else {
                throw OriginalIndexError.incompleteMetadata
            }
        }
        guard originalLookup.apply(update: update) else { throw OriginalIndexError.incompleteMetadata }
        guard let match = originalLookup.find(file: task.file, folder: task.destinationFolderName) else { return nil }
        return ExistingOriginalReference(name: match.name, size: match.size, locator: match.locator)
    }

    func originals(since revision: Int64, rescan: Bool) async throws -> OriginalIndexUpdate {
        try await store.originals(since: revision, rescan: rescan)
    }

    func originalData(locator: String) async throws -> Data {
        try await store.originalData(locator: locator)
    }

    func originalRawPreviewData(locator: String) async throws -> Data? {
        try await store.originalRawPreviewData(locator: locator)
    }

    func originalExif(locator: String) async throws -> PhotoExif? {
        try await store.originalExif(locator: locator)
    }

    /// Cancels the current network operation; pending tasks stay waiting for an explicit start.
    func stop() async {
        startAfterDestinationChange = false
        core.pauseAfterCurrent()
        let active = worker
        active?.cancel()
        await active?.value
    }

    func snapshot() -> OriginalQueueSnapshot {
        let rows = (0..<Int(core.count)).compactMap { index -> OriginalQueueRow? in
            guard let task = core.taskAt(index: Int32(index)) else { return nil }
            return OriginalQueueRow(id: task.taskId, name: task.file.fileName,
                                    handle: task.file.handle, size: task.file.size,
                                    captureDate: task.file.captureDate, isProtected: task.file.isProtected,
                                    storageIDs: task.file.storageIds.map { $0.int32Value },
                                    destinationFolderName: task.destinationFolderName, status: task.status.name, skipped: task.skipped,
                                    downloaded: task.downloaded, fraction: task.progress, bytesPerSecond: task.speed,
                                    error: task.error, elapsedMs: task.elapsedMs?.int64Value, downloadMBps: task.downloadMBps)
        }
        return OriginalQueueSnapshot(connectionID: camera.connectionID, sequence: sequence, historyRevision: historyRevision,
                                     completedOriginalRevision: completedOriginalRevision,
                                     rows: rows, running: core.running, paused: core.paused)
    }

    private func runNext() async -> Bool {
        guard let task = core.takeNext() else { return false }
        publish()
        let began = ProcessInfo.processInfo.systemUptime
        do {
            try Task.checkCancellation()
            let id = task.taskId
            let target = destination // configureDestination cannot change this while the worker exists.
            if let target { try await target.validateSelection() }
            let source: OriginalFilesReusing
            if let target { source = target } else { source = store }
            if let existing = try await existingOriginal(for: task, source: source) {
                try Task.checkCancellation()
                reusedFiles[id] = (source, existing)
                stagedFiles.removeValue(forKey: id) // Full original stays on disk, but sharing follows the matched target.
                core.completedExisting(taskId: id, bytes: existing.size)
                completedOriginalRevision &+= 1
                publish()
                return !Task.isCancelled
            }
            let saved: SavedCameraFile
            if target != nil, let retained = stagedFiles[id] {
                saved = retained // Only a completed app original; the publisher rechecks size and SHA256.
            } else {
                saved = try await store.download(camera: camera, task: task) { [weak self] progress in
                    Task { await self?.receivedProgress(taskID: id, progress: progress) }
                }
            }
            if let target {
                stagedFiles[id] = saved // Retain before awaiting the provider; failure is retryable without another download.
                _ = try await target.publish(saved, originalName: task.file.fileName, folder: task.destinationFolderName)
            }
            // No cancellation check after a successful final publication. Sharing still uses the app-owned
            // original, never an external URL after its security scope has ended.
            savedFiles[task.taskId] = saved
            stagedFiles.removeValue(forKey: task.taskId)
            completedOriginalRevision &+= 1
            core.completed(taskId: task.taskId, bytes: saved.bytes,
                           elapsedMs: Int64((ProcessInfo.processInfo.systemUptime - began) * 1000))
        } catch {
            core.failed(taskId: task.taskId, message: error.localizedDescription, cancelled: Task.isCancelled)
            let state = await camera.snapshot()
            if Task.isCancelled || state.phase != .ready { core.pauseAfterCurrent() }
        }
        publish()
        return !Task.isCancelled
    }

    private func finished() {
        core.finishRun()
        worker = nil
        publish()
        // Enqueue may interleave after takeNext returned nil but before this cleanup. A running
        // queue accepts new work even with deferred-start enabled; do not strand that last item.
        if !core.paused { start() }
    }

    private func receivedProgress(taskID: Int64, progress: CameraDownloadProgress) {
        core.progress(taskId: taskID, downloaded: progress.downloaded, total: progress.total,
                      bytesPerSecond: progress.bytesPerSecond)
        publish(historyChanged: false)
    }

    private func publish(historyChanged: Bool = true) {
        sequence &+= 1
        if historyChanged { historyRevision &+= 1 }
        notifications.yield(snapshot())
    }
}
