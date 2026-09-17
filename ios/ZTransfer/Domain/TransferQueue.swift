import Foundation
import UIKit

func exportedOriginalBaseName(_ name: String) -> String {
    name.replacingOccurrences(of: " \\(\\d+\\)(?=\\.[^.]*$|$)", with: "", options: .regularExpression)
}

/// Android's PTP capture date is `yyyyMMdd'T'HHmmss`; malformed or missing
/// dates fall back to the day the task is queued.
func transferDateFolderName(_ captureDate: String?, fallback: Date = Date()) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let fallbackParts = calendar.dateComponents([.year, .month, .day], from: fallback)
    var year = fallbackParts.year ?? 1970
    var month = fallbackParts.month ?? 1
    var day = fallbackParts.day ?? 1
    if let raw = captureDate?.prefix(8), raw.count == 8,
       let y = Int(raw.prefix(4)), let m = Int(raw.dropFirst(4).prefix(2)),
       let d = Int(raw.suffix(2)),
       (1...12).contains(m), (1...31).contains(d), y >= 1,
       let parsed = calendar.date(from: DateComponents(year: y, month: m, day: d)),
       calendar.component(.year, from: parsed) == y,
       calendar.component(.month, from: parsed) == m,
       calendar.component(.day, from: parsed) == d {
        year = y; month = m; day = d
    }
    return String(format: "ZT%04d-%02d-%02d", year, month, day)
}

/// Android's SAF providers are not assumed to have one filesystem's case
/// rules. Derived output names therefore compare case-insensitively and use
/// the first free ` (n)` suffix from the visible directory snapshot.
func uniquePhotoFrameName(_ preferred: String, occupied: Set<String>, fallbackMillis: Int64? = nil) -> String {
    let normalized = Set(occupied.map { $0.lowercased() })
    guard normalized.contains(preferred.lowercased()) else { return preferred }
    let url = URL(fileURLWithPath: preferred)
    let ext = url.pathExtension
    let stem = url.deletingPathExtension().lastPathComponent
    for index in 1...999 {
        let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
        if !normalized.contains(candidate.lowercased()) { return candidate }
    }
    let millis = fallbackMillis ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    return ext.isEmpty ? "\(stem)_\(millis)" : "\(stem)_\(millis).\(ext)"
}

enum TransferStatus: String, Codable, Sendable { case waiting, transferring, completed, failed, cancelled }

struct TransferQueueItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let file: CameraFile
    var status: TransferStatus = .waiting
    var progress: Double = 0
    var bytesPerSecond: Int64 = 0
    /// Android stores the end-to-end average for a completed real download
    /// (MB/s). Local existing-file hits intentionally keep this at zero.
    var downloadMBps: Double = 0
    /// Android records the active file transfer duration on completion.
    /// A skipped existing file has no transfer duration.
    var elapsedMs: Int64?
    var error: String?
    var skipped = false
    var outputURL: URL?
    /// Android locks the destination folder when the task is created. Keeping
    /// it on the item prevents a later settings change from moving a queued
    /// task between the root and a dated folder.
    var destinationFolderName: String?
    /// Android snapshots the complete effects editor at enqueue time.
    /// A later editor change must never alter an already queued export.
    var effects: PhotoEffectsSettings?
    var isGeneratingFrame = false
    var frameGenerationStartedAt: Date?
    var frameGenerationElapsedMs: Int64?
    var frameURL: URL?
    var frameError: String?


}

struct TransferQueueSnapshot: Equatable, Sendable {
    let items: [TransferQueueItem]
    let isTransferring: Bool
    let pauseAfterCurrent: Bool
    var invalidatedDirectory: URL? = nil
}

/// High-frequency progress is kept separate from the low-frequency queue
/// snapshot, matching Android's activeTransferProgress StateFlow. This keeps
/// inactive cards and list layout out of the 200 ms progress loop.
struct TransferActiveProgress: Equatable, Sendable {
    let taskID: UUID
    let fraction: Double
    let bytesPerSecond: Int64
    /// Last non-zero sample retained across the short preparation gap between
    /// files so the queue capsule does not flash to zero.
    let retainedBytesPerSecond: Int64
}

/// Android's endToEndBytesPerSecond: use only bytes transferred in this
/// attempt and a monotonic elapsed duration; invalid samples are zero.
internal func endToEndBytesPerSecond(transferredBytes: UInt64, elapsedMs: Int64) -> Int64 {
    guard transferredBytes > 0, elapsedMs > 0 else { return 0 }
    let value = Double(transferredBytes) * 1_000.0 / Double(elapsedMs)
    guard value < Double(Int64.max) else { return .max }
    return Int64(value)
}

internal func retainLastValidTransferSpeed(previous: Int64, sample: Int64) -> Int64 {
    sample > 0 ? sample : max(0, previous)
}

struct TransferDownloadProgress: Equatable, Sendable {
    let fraction: Double
    let downloaded: UInt64
    let total: UInt64
    var bytesPerSecond: Int64 = 0
}

/// The queue only needs the existing camera download operation. Keeping this
/// boundary explicit also lets state-transition tests hold a real task in flight.
protocol TransferDownloading: Sendable {
    func download(file: CameraFile, to directory: URL,
                  progress: (@Sendable (Double) -> Void)?) async throws -> URL

    func downloadWithMetrics(file: CameraFile, to directory: URL,
                             progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> URL
    func downloadResult(file: CameraFile, to directory: URL, captureHeader: Bool,
                        progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> CameraDownloadResult
    func frameMetadataHeader(file: CameraFile) async throws -> Data?
}

extension CameraSession: TransferDownloading {}

extension TransferDownloading {
    func frameMetadataHeader(file: CameraFile) async throws -> Data? { nil }

    func downloadResult(file: CameraFile, to directory: URL, captureHeader: Bool,
                        progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> CameraDownloadResult {
        let started = ContinuousClock.now
        let output = try await downloadWithMetrics(file: file, to: directory, progress: progress)
        let bytes = UInt64(max(0, (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        return CameraDownloadResult(url: output, bytes: bytes, transferredBytes: bytes,
                                    startedAt: started, headerPrefix: nil)
    }
    /// Compatibility path for deterministic test cameras and platform
    /// transports that only expose a fraction. Production CameraSession
    /// supplies actual bytes from the PTP transaction.
    func downloadWithMetrics(file: CameraFile, to directory: URL,
                             progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> URL {
        try await download(file: file, to: directory) { fraction in
            let total = file.size == UInt64(UInt32.max) ? 0 : file.size
            let downloaded = total > 0 ? UInt64((Double(total) * fraction).rounded()) : 0
            progress?(TransferDownloadProgress(fraction: fraction, downloaded: downloaded, total: total))
        }
    }
}

/// Android keeps execution order separate from the visible task history.
/// Retrying a card replaces it in place, but appends its attempt to this FIFO.
struct PendingTransferQueue {
    private var order: [UUID] = []
    private var head = 0
    private var pending: Set<UUID> = []

    mutating func append(_ id: UUID) {
        if pending.insert(id).inserted { order.append(id) }
    }

    mutating func withdraw(_ id: UUID) { pending.remove(id) }

    mutating func takeFirst() -> UUID? {
        while head < order.count {
            let id = order[head]
            head += 1
            if pending.remove(id) != nil {
                if head >= 256 && head * 2 >= order.count {
                    order.removeFirst(head)
                    head = 0
                }
                return id
            }
        }
        order.removeAll(keepingCapacity: true)
        head = 0
        return nil
    }

    mutating func clear() { self = PendingTransferQueue() }
}

/// Android treats an already exported original as a completed, skipped task.
/// Keeping this check separate makes the rule deterministic and unit-testable.
func existingTransferDestination(for file: CameraFile, in directory: URL) -> URL? {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
    ) else { return nil }
    let expectedName = exportedOriginalBaseName(file.fileName).lowercased()
    return entries.first { candidate in
        let values = try? candidate.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              exportedOriginalBaseName(candidate.lastPathComponent).lowercased() == expectedName else { return false }
        guard file.size == UInt64(UInt32.max) else { return values?.fileSize.map { UInt64($0) } == Optional(file.size) }
        return true
    }
}

/// Resolves the exact Android destination: root when the option is off, or a
/// `ZTyyyy-MM-dd` child when it is on. Existing files are only considered in
/// that selected directory, never in an unrelated dated folder.
func transferDestinationDirectory(root: URL, folderName: String?) -> URL {
    guard let folderName, !folderName.isEmpty else { return root }
    return root.appendingPathComponent(folderName, isDirectory: true)
}

/// Serial transfer queue. Android permits repeated manual exports of one camera
/// handle; only the automatic-new-media path uses an identity de-duplication key.
/// The active file is never user-cancelled and pause takes effect at its boundary.
actor TransferQueue {
    typealias FrameRenderer = @Sendable (URL, PhotoEffectsSettings, URL, PhotoFrameMetadata?) async throws -> URL
    private struct FrameJob: Sendable {
        let id: UUID
        let source: URL
        let settings: PhotoEffectsSettings
        let directory: URL
        let metadata: PhotoFrameMetadata?
        let failTaskOnError: Bool
        let started: ContinuousClock.Instant
    }
    private(set) var items: [TransferQueueItem] = []
    private(set) var isTransferring = false
    private(set) var pauseAfterCurrent = false
    private var worker: Task<Void, Never>?
    /// iOS has no Android-style foreground service. Keep a bounded system
    /// background assertion while the queue is active so short background
    /// transitions can finish the current file and flush its part file.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskToken: UUID?
    private var pending = PendingTransferQueue()
    private var frameWorkers: [UUID: Task<Void, Never>] = [:]
    private var frameJobs: [UUID: FrameJob] = [:]
    private var pendingFrames = PendingTransferQueue()
    private let renderFrame: FrameRenderer
    private static let frameParallelism = 2 // PHOTO_FRAME_EXPORT_PARALLELISM
    private var session: (any TransferDownloading)?
    private var directory: URL?
    private var invalidatedDirectory: URL?
    private var frameMetadataCache: [UInt32: PhotoFrameMetadata] = [:]
    private var continuations: [UUID: AsyncStream<TransferQueueSnapshot>.Continuation] = [:]
    private var progressContinuations: [UUID: AsyncStream<TransferActiveProgress?>.Continuation] = [:]
    private var activeProgress: TransferActiveProgress?
    private var lastValidTransferSpeed: Int64 = 0
    init(defaults: UserDefaults = .standard, renderFrame: @escaping FrameRenderer = TransferQueue.renderFrameFile) {
        self.renderFrame = renderFrame
        // Android TransferState.tasks is in-memory only. Discard the earlier
        // iOS-only snapshot once; settings and on-disk partials have their own
        // existing stores and are unaffected by this queue lifecycle.
        defaults.removeObject(forKey: "transferQueue.items.v1")
    }

    deinit {
        worker?.cancel()
        frameWorkers.values.forEach { $0.cancel() }
    }

    func snapshots() -> AsyncStream<TransferQueueSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { continuations[id] = nil }

    func progressSnapshots() -> AsyncStream<TransferActiveProgress?> {
        AsyncStream { continuation in
            let id = UUID()
            progressContinuations[id] = continuation
            continuation.yield(activeProgress)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeProgressObserver(id) }
            }
        }
    }

    private func removeProgressObserver(_ id: UUID) { progressContinuations[id] = nil }

    @discardableResult
    func enqueue(_ file: CameraFile, organizeByDate: Bool = false,
                 effects: PhotoEffectsSettings? = nil) -> UUID? {
        let item = TransferQueueItem(
            id: UUID(), file: file,
            destinationFolderName: organizeByDate ? transferDateFolderName(file.captureDate) : nil,
            effects: effects
        )
        items.append(item); pending.append(item.id); publish(); return item.id
    }

    @discardableResult
    func enqueue(_ files: [CameraFile], organizeByDate: Bool = false,
                 effects: PhotoEffectsSettings? = nil) -> [UUID] {
        var seen: Set<UInt32> = []
        let queuedAt = Date()
        let additions = files.filter { seen.insert($0.id).inserted }.map { file in
            TransferQueueItem(id: UUID(), file: file,
                              destinationFolderName: organizeByDate
                                ? transferDateFolderName(file.captureDate, fallback: queuedAt) : nil,
                              effects: effects)
        }
        guard !additions.isEmpty else { return [] }
        items.append(contentsOf: additions)
        additions.forEach { pending.append($0.id) }
        publish()
        return additions.map(\.id)
    }

    @discardableResult
    func enqueueAutomatic(_ file: CameraFile, organizeByDate: Bool = false,
                          effects: PhotoEffectsSettings? = nil) -> UUID? {
        enqueueAutomatic([file], organizeByDate: organizeByDate, effects: effects).first
    }

    @discardableResult
    func enqueueAutomatic(_ files: [CameraFile], organizeByDate: Bool = false,
                          effects: PhotoEffectsSettings? = nil) -> [UUID] {
        var identities = Set(items.map { automaticIdentity(for: $0.file) })
        let candidates = files.filter { identities.insert(automaticIdentity(for: $0)).inserted }
        return enqueue(candidates, organizeByDate: organizeByDate, effects: effects)
    }

    func start(session: (any TransferDownloading)?, directory: URL) {
        self.session = session; self.directory = directory
        invalidatedDirectory = nil
        startWorkerIfAllowed()
    }

    private func startWorkerIfAllowed() {
        guard worker == nil, !pauseAfterCurrent else { return }
        // Publish before scheduling, as Android's lazy worker does. An enqueue
        // must not flash a paused state while its worker waits to run.
        isTransferring = true
        publish()
        worker = Task { [weak self] in await self?.run() }
    }

    private func beginBackgroundTransferActivity() async {
        guard backgroundTaskID == .invalid else { return }
        let token = UUID()
        backgroundTaskToken = token
        let id = await MainActor.run { [weak self] in
            UIApplication.shared.beginBackgroundTask(withName: "ZTransfer transfer") {
                Task { await self?.backgroundTransferExpired(token: token) }
            }
        }
        backgroundTaskID = id
        if id == .invalid { backgroundTaskToken = nil }
    }

    private func endBackgroundTransferActivity() {
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        backgroundTaskToken = nil
        guard id != .invalid else { return }
        Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
    }

    private func backgroundTransferExpired(token: UUID) {
        guard backgroundTaskToken == token else { return }
        // Cancellation preserves the current .nkpart_ file. The worker's
        // normal cancellation path returns the item to WAITING so a later
        // foreground reconnect can resume it from the next chunk boundary.
        worker?.cancel()
    }

    /// Explicitly starting the pending queue is the Android
    /// `startPendingTransfers` path: it clears a previously requested
    /// boundary pause before creating the worker. Automatic enqueue uses
    /// `start` directly so a deferred queue remains deferred.
    func startPendingTransfers(session: (any TransferDownloading)?, directory: URL) {
        guard worker == nil, items.contains(where: { $0.status == .waiting }) else { return }
        pauseAfterCurrent = false
        start(session: session, directory: directory)
    }

    /// Refreshes the transport used by later retries without changing the
    /// deferred-start decision or interrupting an active transfer.
    func attach(session: (any TransferDownloading)?, directory: URL?) {
        self.session = session
        // A nil bookmark is meaningful: Android clears the destination after
        // an invalid directory and must not let a reconnect resurrect the
        // stale URL for an automatically started task.
        self.directory = directory
        if directory != nil, invalidatedDirectory != nil {
            invalidatedDirectory = nil
            publish()
        }
    }

    /// Clears the live camera reference when the root connection disappears.
    /// The queue remains in memory and its active transfer is allowed to
    /// unwind; the next task then observes the same nil-provider state as
    /// Android and is marked camera-not-connected instead of using a stale
    /// session object.
    func detach() {
        session = nil
    }

    /// A delayed loss callback from a previous CameraSession must not clear
    /// the provider installed by a faster reconnect.
    func detach(ifCurrentSessionIs failedSession: CameraSession) {
        guard let current = session as? CameraSession, current === failedSession else { return }
        session = nil
    }

    /// Android only records this request while a transfer worker is active.
    /// An idle queue must remain startable; setting the flag before the first
    /// task would incorrectly suppress the next explicit start.
    func pauseAfterCurrentFile() {
        guard isTransferring else { return }
        pauseAfterCurrent = true
        publish()
    }
    func resume() {
        guard let directory else { return }
        startPendingTransfers(session: session, directory: directory)
    }

    /// Withdraw one waiting task from the queue. Android has no user action
    /// that cancels an active file transfer, so transferring tasks are left
    /// untouched here and finish normally.
    func withdraw(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .waiting else { return }
        pending.withdraw(id)
        items[index].status = .cancelled
        items[index].bytesPerSecond = 0
        publish()
    }

    /// Android's clear flow first withdraws every waiting item so the worker
    /// cannot claim another file during the removal animation.  The active item
    /// is intentionally left untouched.
    func withdrawPending() {
        var changed = false
        for index in items.indices where items[index].status == .waiting {
            pending.withdraw(items[index].id)
            items[index].status = .cancelled
            items[index].bytesPerSecond = 0
            changed = true
        }
        if changed { publish() }
    }

    /// Retry keeps the queue entry in place, but clears the terminal result so the
    /// serial worker can claim it again. The Android queue exposes retry on the
    /// failed card and does not duplicate the visible card.
    @discardableResult
    func retry(id: UUID) -> UUID? {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .failed || items[index].status == .cancelled,
              directory != nil else { return nil }
        let old = items[index]
        // A failed derived-frame task already has its original on disk. Keep
        // that source so retry can regenerate the frame offline, matching
        // Android's existing-original short circuit.
        let replacement = TransferQueueItem(
            id: UUID(), file: old.file,
            outputURL: old.outputURL,
            destinationFolderName: old.destinationFolderName,
            effects: old.effects
        )
        items[index] = replacement
        pending.append(replacement.id)
        publish()
        startWorkerIfAllowed()
        return replacement.id
    }

    /// Removes only terminal cards. Active downloads are deliberately left alone,
    /// matching Android's clear action which never interrupts the current file.
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !items[index].isGeneratingFrame,
              items[index].status == .completed || items[index].status == .failed || items[index].status == .cancelled else { return false }
        items.remove(at: index)
        publish()
        return true
    }

    func clearFinished() {
        removeCleared()
    }

    /// RemoveCleared in Android is deliberately limited to terminal items; a
    /// waiting item can only disappear after withdrawPending has run.
    func removeCleared() {
        let before = items.count
        items.removeAll { !$0.isGeneratingFrame &&
            ($0.status == .completed || $0.status == .failed || $0.status == .cancelled) }
        if items.count != before { publish() }
    }

    /// Retry every failed/cancelled item with a fresh attempt identity, then
    /// restart the worker if a live session and directory are available.
    func retryFailed(excluding excludedIDs: Set<UUID> = []) {
        guard directory != nil else { return }
        var replacements = false
        for index in items.indices where !excludedIDs.contains(items[index].id) &&
            (items[index].status == .failed || items[index].status == .cancelled) {
            let old = items[index]
            items[index] = TransferQueueItem(
                id: UUID(), file: old.file,
                outputURL: old.outputURL,
                destinationFolderName: old.destinationFolderName,
                effects: old.effects
            )
            pending.append(items[index].id)
            replacements = true
        }
        if replacements {
            publish()
            startWorkerIfAllowed()
        }
    }

    private func run() async {
        await beginBackgroundTransferActivity()
        frameMetadataCache.removeAll(keepingCapacity: true)
        var stoppedAfterCurrent = false
        defer {
            endBackgroundTransferActivity()
            activeProgress = nil
            lastValidTransferSpeed = 0
            publishProgress()
            isTransferring = false
            worker = nil
            pauseAfterCurrent = stoppedAfterCurrent
            publish()
        }
        guard let directory else { invalidateDirectory(); return }
        let directoryValid = await Task.detached(priority: .utility) {
            (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) != nil
        }.value
        guard directoryValid else { invalidateDirectory(); return }

        // SAF indexing is off the UI/scheduler thread on Android. Each await
        // below is also a withdrawal point; identify tasks by ID after it.
        var directoryIndexes: [URL: TransferDirectoryIndex] = [:]
        directoryIndexes[directory] = await Task.detached(priority: .utility) {
            TransferDirectoryIndex.scan(directory: directory)
        }.value
        while !Task.isCancelled {
            if pauseAfterCurrent { stoppedAfterCurrent = true; break }
            guard let itemID = pending.takeFirst() else { break }
            guard let task = items.first(where: { $0.id == itemID && $0.status == .waiting }) else { continue }
            let destinationDirectory = transferDestinationDirectory(root: directory, folderName: task.destinationFolderName)
            do {
                if directoryIndexes[destinationDirectory] == nil {
                    directoryIndexes[destinationDirectory] = try await Task.detached(priority: .utility) {
                        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                        return TransferDirectoryIndex.scan(directory: destinationDirectory)
                    }.value
                }
                guard isWaiting(itemID) else { continue }
                try Task.checkCancellation()
                if let destination = directoryIndexes[destinationDirectory]?.existingOriginal(for: task.file) {
                    let effects = task.effects.flatMap { $0.hasEffect && Self.supportsRenderedOutput(task.file.fileExtension) ? $0 : nil }
                    let existingFrame: URL?
                    if let effects {
                        existingFrame = await Task.detached(priority: .utility) {
                            Self.existingFrameURL(source: destination, settings: effects, in: destinationDirectory)
                        }.value
                    } else { existingFrame = nil }
                    guard isWaiting(itemID) else { continue }
                    try Task.checkCancellation()
                    guard let index = items.firstIndex(where: { $0.id == itemID }) else { continue }
                    items[index].status = .completed
                    items[index].progress = 1
                    items[index].bytesPerSecond = 0
                    items[index].downloadMBps = 0
                    items[index].elapsedMs = nil
                    items[index].skipped = effects == nil || existingFrame != nil
                    items[index].outputURL = destination
                    items[index].frameURL = existingFrame
                    if let effects, existingFrame == nil {
                        await startFrameGeneration(for: itemID, source: destination, file: task.file, settings: effects,
                                                   in: destinationDirectory, failTaskOnError: true)
                    }
                    publish()
                    continue
                }

                // Android's DL_RESUME_COMPLETE shortcut: a complete,
                // identity-matching .nkpart_ means the previous download
                // finished before its final rename. Finalize it while the
                // card is still WAITING, then run the same local-original
                // effect check without touching the camera session.
                if let partial = directoryIndexes[destinationDirectory]?.completePartial(for: task.file) {
                    do {
                        let output = try finalizeTransferTemporary(
                            temporary: partial, directory: destinationDirectory, fileName: task.file.fileName, allowCopy: false
                        )
                        directoryIndexes[destinationDirectory]?.removePartial(partial)
                        directoryIndexes[destinationDirectory]?.addOriginal(output, size: task.file.size)
                        guard isWaiting(itemID) else { continue }
                        let effects = task.effects.flatMap { $0.hasEffect && Self.supportsRenderedOutput(task.file.fileExtension) ? $0 : nil }
                        guard let index = items.firstIndex(where: { $0.id == itemID }) else { continue }
                        items[index].status = .completed
                        items[index].progress = 1
                        items[index].bytesPerSecond = 0
                        items[index].downloadMBps = 0
                        items[index].elapsedMs = nil
                        items[index].skipped = effects == nil
                        items[index].outputURL = output
                        if let effects {
                            await startFrameGenerationIfNeeded(
                                for: itemID, source: output, file: task.file, settings: effects,
                                in: destinationDirectory, failTaskOnError: true
                            )
                        }
                        publish()
                        continue
                    } catch {
                        // A provider may reject both rename and copy. Android
                        // deletes that unusable part and falls through to a
                        // fresh download, preserving the task's FIFO slot.
                        try? FileManager.default.removeItem(at: partial)
                        directoryIndexes[destinationDirectory]?.removePartial(partial)
                    }
                }
                // No TRANSFERING state for a local hit or disconnected task.
                // Resolve the current session only after local-file preflight.
                guard let session else {
                    fail(itemID, message: AppLocalized.resource("camera_not_connected"))
                    continue
                }
                guard let index = items.firstIndex(where: { $0.id == itemID && $0.status == .waiting }) else { continue }
                items[index].status = .transferring
                items[index].error = nil
                items[index].elapsedMs = nil
                activeProgress = TransferActiveProgress(taskID: itemID, fraction: 0, bytesPerSecond: 0,
                                                        retainedBytesPerSecond: lastValidTransferSpeed)
                publishProgress()
                publish()
                let result = try await session.downloadResult(file: task.file, to: destinationDirectory,
                                                              captureHeader: Self.needsCameraMetadata(task.effects, file: task.file)) { [weak self] progress in
                    Task { await self?.updateProgress(id: itemID, progress: progress) }
                }
                let output = result.url
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].status = .completed
                    items[index].progress = 1
                    items[index].bytesPerSecond = 0
                    let elapsed = Self.milliseconds(since: result.startedAt)
                    items[index].downloadMBps = Double(endToEndBytesPerSecond(
                        transferredBytes: result.transferredBytes, elapsedMs: elapsed
                    )) / (1024 * 1024)
                    items[index].elapsedMs = elapsed
                    items[index].outputURL = output
                    if let effects = task.effects, effects.hasEffect, Self.supportsRenderedOutput(task.file.fileExtension) {
                        await startFrameGeneration(
                            for: itemID, source: output, file: task.file, settings: effects, in: destinationDirectory,
                            metadata: result.headerPrefix.flatMap(PhotoFrameMetadata.cameraSnapshot),
                            allowCameraMetadataRead: result.bytes > result.transferredBytes
                        )
                    }
                    publish()
                }
                directoryIndexes[destinationDirectory]?.addOriginal(output, size: result.bytes)
            } catch is CancellationError {
                if let index = items.firstIndex(where: { $0.id == itemID }),
                   items[index].status == .waiting || items[index].status == .transferring {
                    items[index].status = .waiting
                    items[index].progress = 0
                    items[index].bytesPerSecond = 0
                    items[index].error = nil
                    pending.append(itemID)
                    if activeProgress?.taskID == itemID {
                        activeProgress = nil
                        publishProgress()
                    }
                    publish()
                }
                if activeProgress?.taskID == itemID {
                    activeProgress = nil
                    publishProgress()
                }
                // A cancelled session must not be retried in a tight loop.
                break
            } catch CameraRepositoryError.resumeUnavailable {
                // Android deletes the identity-matching part when a resumed
                // stream cannot use partial-object reads. Keeping it would
                // make every retry fail at the same preflight boundary.
                let partial = destinationDirectory.appendingPathComponent(
                    transferPartialFileName(size: task.file.size,
                                            captureDate: task.file.captureDate,
                                            fileName: task.file.fileName),
                    isDirectory: false
                )
                try? FileManager.default.removeItem(at: partial)
                directoryIndexes[destinationDirectory] = TransferDirectoryIndex.scan(directory: destinationDirectory)
                if activeProgress?.taskID == itemID {
                    activeProgress = nil
                    publishProgress()
                }
                fail(itemID, message: AppLocalized.resource("transfer_failed"))
            } catch {
                // Android refreshes only the failed task's part index so a
                // retry queued on the same worker can see a newly preserved
                // .nkpart_ without rescanning unrelated destinations.
                directoryIndexes[destinationDirectory] = await Task.detached(priority: .utility) {
                    TransferDirectoryIndex.scan(directory: destinationDirectory)
                }.value
                if activeProgress?.taskID == itemID {
                    activeProgress = nil
                    publishProgress()
                }
                if items.contains(where: { $0.id == itemID && ($0.status == .waiting || $0.status == .transferring) }) {
                    fail(itemID, message: transferErrorMessage(error))
                }
            }
        }
    }

    private func isWaiting(_ id: UUID) -> Bool {
        items.contains { $0.id == id && $0.status == .waiting }
    }

    private func fail(_ id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .failed
        items[index].error = message
        items[index].bytesPerSecond = 0
        publish()
    }

    private func invalidateDirectory() {
        invalidatedDirectory = directory
        directory = nil
        pending.clear()
        let message = AppLocalized.resource("error_dir_invalid")
        for index in items.indices where items[index].status == .waiting {
            items[index].status = .failed
            items[index].bytesPerSecond = 0
            items[index].error = message
        }
        publish()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: .now).components
        return max(0, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    private static func supportsRenderedOutput(_ ext: String) -> Bool {
        // Android's PhotoFrameExporter deliberately limits transfer effects
        // to JPG/JPEG/PNG; RAW, TIFF, HEIC and video remain original-only.
        [".jpg", ".jpeg", ".png"].contains(ext.lowercased())
    }

    /// Mark generation before publishing COMPLETED, including time waiting for
    /// Android's bounded two-worker pool. Clear/remove must protect both active
    /// and queued renders, without delaying subsequent original downloads.
    private func startFrameGeneration(for id: UUID, source: URL, file: CameraFile, settings: PhotoEffectsSettings,
                                      in directory: URL, failTaskOnError: Bool = false,
                                      metadata: PhotoFrameMetadata? = nil, allowCameraMetadataRead: Bool = true) async {
        guard frameJobs[id] == nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let started = ContinuousClock.now
        items[index].isGeneratingFrame = true
        items[index].frameGenerationStartedAt = Date()
        items[index].frameGenerationElapsedMs = nil
        items[index].frameError = nil
        publish()
        var cameraMetadata = frameMetadataCache[file.id] ?? metadata
        if cameraMetadata == nil && allowCameraMetadataRead && Self.needsCameraMetadata(settings, file: file) {
            do {
                if let header = try await session?.frameMetadataHeader(file: file) {
                    cameraMetadata = await Task.detached(priority: .utility) {
                        PhotoFrameMetadata.cameraSnapshot(header)
                    }.value
                }
            } catch is CancellationError {
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].isGeneratingFrame = false
                    items[index].frameGenerationStartedAt = nil
                }
                return
            } catch { /* Android: header failure only affects the derivative. */ }
        }
        guard items.contains(where: { $0.id == id && $0.isGeneratingFrame }) else { return }
        if let cameraMetadata { frameMetadataCache[file.id] = cameraMetadata }
        frameJobs[id] = FrameJob(id: id, source: source, settings: settings, directory: directory,
                                 metadata: cameraMetadata, failTaskOnError: failTaskOnError, started: started)
        pendingFrames.append(id)
        startWaitingFrames()
    }

    /// Android's launchPhotoFrameExport(skipIfExisting = true) checks the
    /// deterministic frame path before publishing GENERATING. Keep that
    /// preflight off the actor so a repeated export never flashes a fake
    /// generation state or consumes a frame worker.
    private func startFrameGenerationIfNeeded(
        for id: UUID,
        source: URL,
        file: CameraFile,
        settings: PhotoEffectsSettings,
        in directory: URL,
        failTaskOnError: Bool = false,
        metadata: PhotoFrameMetadata? = nil,
        allowCameraMetadataRead: Bool = true,
    ) async {
        let existing = await Task.detached(priority: .utility) {
            Self.existingFrameURL(source: source, settings: settings, in: directory)
        }.value
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let existing {
            items[index].frameURL = existing
            items[index].skipped = true
            items[index].frameError = nil
            return
        }
        await startFrameGeneration(for: id, source: source, file: file, settings: settings,
                                   in: directory, failTaskOnError: failTaskOnError,
                                   metadata: metadata, allowCameraMetadataRead: allowCameraMetadataRead)
    }

    private func startWaitingFrames() {
        while frameWorkers.count < Self.frameParallelism, let id = pendingFrames.takeFirst() {
            guard let job = frameJobs[id] else { continue }
            frameWorkers[id] = Task { [weak self] in await self?.generateFrame(job) }
        }
    }

    private func generateFrame(_ job: FrameJob) async {
        defer {
            if let index = items.firstIndex(where: { $0.id == job.id }) {
                items[index].isGeneratingFrame = false
                items[index].frameGenerationStartedAt = nil
                items[index].frameGenerationElapsedMs = Self.milliseconds(since: job.started)
            }
            frameJobs[job.id] = nil
            frameWorkers[job.id] = nil
            publish()
            startWaitingFrames()
        }
        do {
            // Recheck when a worker becomes available: an earlier identical
            // export may have completed while this job was waiting.
            let existing = await Task.detached(priority: .utility) {
                Self.existingFrameURL(source: job.source, settings: job.settings, in: job.directory)
            }.value
            try Task.checkCancellation()
            if let existing {
                if let index = items.firstIndex(where: { $0.id == job.id }) {
                    items[index].frameURL = existing
                    items[index].skipped = true
                    items[index].error = nil
                }
                return
            }
            if Self.needsCameraMetadata(job.settings, name: job.source.lastPathComponent),
               job.settings.metadata.hasVisibleMetadata, job.metadata == nil {
                throw CameraRepositoryError.invalidDataset
            }
            let output = try await renderFrame(job.source, job.settings, job.directory, job.metadata)
            try Task.checkCancellation()
            if let index = items.firstIndex(where: { $0.id == job.id }) { items[index].frameURL = output }
        } catch is CancellationError {
            // Completion cleanup above runs even when the renderer is cancelled.
        } catch {
            if let index = items.firstIndex(where: { $0.id == job.id }) {
                items[index].frameError = transferErrorMessage(error)
                // Android only fails the card on the existing-original path.
                // A newly downloaded original remains successfully transferred.
                if job.failTaskOnError {
                    items[index].status = .failed
                    items[index].error = transferErrorMessage(error)
                    items[index].bytesPerSecond = 0
                }
            }
        }
    }

    private nonisolated static func renderFrameFile(source: URL, settings: PhotoEffectsSettings, directory: URL, metadata: PhotoFrameMetadata?) async throws -> URL {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try autoreleasepool {
                // TransferViewModel passes the immutable camera metadata snapshot
                // with allowLocalMetadataRead=false. Decode the saved image without
                // allocating another full Data buffer or rereading local EXIF.
                guard let image = UIImage(contentsOfFile: source.path) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let rendered = try PhotoEffectsRenderer.render(image, settings: settings, metadata: metadata)
                try Task.checkCancellation()
                guard let encoded = PhotoEffectsJPEGEncoder.encode(
                    rendered, copyingMetadataFrom: source, cameraMetadata: metadata
                ) else { throw CocoaError(.fileWriteUnknown) }
                let framesDirectory = directory.appendingPathComponent("ZTFrames", isDirectory: true)
                try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
                let destination = uniqueFrameURL(frameURL(source: source, settings: settings, framesDirectory: framesDirectory))
                try encoded.write(to: destination, options: .atomic)
                return destination
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private nonisolated static func needsCameraMetadata(_ settings: PhotoEffectsSettings?, file: CameraFile) -> Bool {
        needsCameraMetadata(settings, name: file.fileName)
    }

    private nonisolated static func needsCameraMetadata(_ settings: PhotoEffectsSettings?, name: String) -> Bool {
        guard let settings, settings.photoFrameEnabled, settings.photoFrameBorderEnabled else { return false }
        return ["jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased())
    }

    private nonisolated static func existingFrameURL(source: URL, settings: PhotoEffectsSettings, in directory: URL) -> URL? {
        let framesDirectory = directory.appendingPathComponent("ZTFrames", isDirectory: true)
        let preferred = frameURL(source: source, settings: settings, framesDirectory: framesDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: framesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let stem = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        let pattern = #"^\#(NSRegularExpression.escapedPattern(for: stem))(?: \(\d+\)|_\d+)?\.\#(NSRegularExpression.escapedPattern(for: ext))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return entries.first { candidate in
            guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            let range = NSRange(candidate.lastPathComponent.startIndex..., in: candidate.lastPathComponent)
            return regex.firstMatch(in: candidate.lastPathComponent, options: [], range: range) != nil
        }
    }

    private nonisolated static func frameURL(source: URL, settings: PhotoEffectsSettings, framesDirectory: URL) -> URL {
        framesDirectory.appendingPathComponent(
            androidPhotoFrameOutputName(sourceName: source.lastPathComponent, settings: settings)
        )
    }

    private nonisolated static func uniqueFrameURL(_ preferred: URL) -> URL {
        let directory = preferred.deletingLastPathComponent()
        let occupied = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return directory.appendingPathComponent(
            uniquePhotoFrameName(preferred.lastPathComponent, occupied: occupied)
        )
    }

    private func updateProgress(id: UUID, progress: TransferDownloadProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .transferring else { return }
        items[index].bytesPerSecond = progress.bytesPerSecond
        let retained = retainLastValidTransferSpeed(previous: lastValidTransferSpeed,
                                                     sample: progress.bytesPerSecond)
        lastValidTransferSpeed = retained
        items[index].progress = min(max(progress.fraction, 0), 1)
        activeProgress = TransferActiveProgress(taskID: id, fraction: items[index].progress,
                                                bytesPerSecond: items[index].bytesPerSecond,
                                                retainedBytesPerSecond: retained)
        publishProgress()
    }

    func snapshot() -> TransferQueueSnapshot {
        TransferQueueSnapshot(items: items, isTransferring: isTransferring,
                              pauseAfterCurrent: pauseAfterCurrent, invalidatedDirectory: invalidatedDirectory)
    }
    private func publish() {
        let value = snapshot()
        continuations.values.forEach { $0.yield(value) }
    }

    private func publishProgress() {
        let value = activeProgress
        progressContinuations.values.forEach { $0.yield(value) }
    }

    private func automaticIdentity(for file: CameraFile) -> String {
        "\(file.fileName)|\(file.size)|\(file.captureDate ?? "")"
    }

    private func transferErrorMessage(_ error: Error) -> String {
        switch error {
        case CameraTransportError.disconnected:
            return AppLocalized.resource("error_camera_connection_lost")
        case CameraTransportError.timeout:
            // Android normalizes socket timeouts to the same reconnect/resume guidance.
            return AppLocalized.resource("error_camera_connection_lost")
        case PTPSessionError.timeout, PTPSessionError.invalidated:
            // PTP session loss has the same retry/resume meaning as the
            // transport-level disconnect reported by Android.
            return AppLocalized.resource("error_camera_connection_lost")
        case CameraRepositoryError.invalidDataset:
            return AppLocalized.resource("error_camera_metadata_unavailable")
        case CameraRepositoryError.resumeUnavailable:
            return AppLocalized.resource("transfer_failed")
        default:
            // Android's friendlyError normalizes transport failures even when
            // ImageCaptureCore/PTP wraps them in an NSError with only a text
            // description. Preserve that user-facing classification here.
            let message = error.localizedDescription
            let lower = message.lowercased()
            if ["connection abort", "connection reset", "broken pipe", "network is unreachable",
                "timed out", "timeout", "socket", "econn", "etimedout"].contains(where: { lower.contains($0) }) {
                return AppLocalized.resource("error_camera_connection_lost")
            }
            if error is CocoaError, (error as NSError).code == CocoaError.fileNoSuchFile.rawValue {
                return AppLocalized.resource("error_dir_invalid")
            }
            return message
        }
    }
}
