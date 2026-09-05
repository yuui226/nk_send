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
    private var worker: Task<Void, Never>?
    private var savedFiles: [Int64: SavedCameraFile] = [:]
    private var historyRevision: UInt64 = 0
    private var completedOriginalRevision: UInt64 = 0
    private var sequence: UInt64 = 0

    init(camera: CameraWiFiConnection, store: CameraOriginalStore) {
        self.camera = camera
        self.store = store
        var continuation: AsyncStream<OriginalQueueSnapshot>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        notifications = continuation
    }

    deinit { worker?.cancel(); notifications.finish() }

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
        guard worker == nil, core.start() else { return }
        publish()
        worker = Task { [weak self] in
            // Retain the owner only during one bounded file operation, not while idle.
            while !Task.isCancelled, await self?.runNext() == true {}
            await self?.finished()
        }
    }

    func pauseAfterCurrent() { core.pauseAfterCurrent(); publish() }
    func withdraw(_ taskID: Int64) { core.withdraw(taskId: taskID); publish() }
    func withdrawPending() { core.withdrawPending(); publish() }
    @discardableResult
    func removeTask(_ taskID: Int64) -> Bool {
        let removed = core.removeTask(taskId: taskID)
        if removed {
            // Only release the queue's lookup; never delete the user's completed original.
            savedFiles.removeValue(forKey: taskID)
            publish()
        }
        return removed
    }
    func clearTerminal() {
        core.clearTerminal()
        let retained = Set((0..<Int(core.count)).compactMap { core.taskAt(index: Int32($0))?.taskId })
        savedFiles = savedFiles.filter { retained.contains($0.key) }
        publish()
    }
    func retry(_ taskID: Int64) {
        _ = core.retry(taskId: taskID)
        publish()
        if !core.paused { start() }
    }
    @discardableResult
    func retryFailed(excluding taskIDs: Set<Int64>) -> Int32 {
        let count = core.retryFailed(excludedTaskIds: Set(taskIDs.map { KotlinLong(value: $0) }))
        if count > 0 {
            publish()
            if !core.paused { start() }
        }
        return count
    }
    func savedFile(_ taskID: Int64) -> SavedCameraFile? { savedFiles[taskID] }

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
                                    destinationFolderName: task.destinationFolderName, status: task.status.name,
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
            let saved = try await store.download(camera: camera, task: task) { [weak self] progress in
                Task { await self?.receivedProgress(taskID: id, progress: progress) }
            }
            savedFiles[task.taskId] = saved
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
