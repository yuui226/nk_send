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

enum TransferStatus: String, Codable, Sendable { case waiting, transferring, completed, failed, cancelled }

struct TransferQueueItem: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let file: CameraFile
    var status: TransferStatus = .waiting
    var progress: Double = 0
    var bytesPerSecond: Int64 = 0
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

    private enum CodingKeys: String, CodingKey {
        case id, file, status, progress, bytesPerSecond, error, skipped, outputURL, destinationFolderName,
             elapsedMs, effects, isGeneratingFrame, frameGenerationStartedAt, frameGenerationElapsedMs, frameURL, frameError
    }

    init(id: UUID, file: CameraFile, status: TransferStatus = .waiting,
         progress: Double = 0, bytesPerSecond: Int64 = 0, elapsedMs: Int64? = nil, error: String? = nil,
         skipped: Bool = false, outputURL: URL? = nil,
         destinationFolderName: String? = nil, effects: PhotoEffectsSettings? = nil,
         isGeneratingFrame: Bool = false, frameGenerationStartedAt: Date? = nil,
         frameGenerationElapsedMs: Int64? = nil, frameURL: URL? = nil, frameError: String? = nil) {
        self.id = id; self.file = file; self.status = status; self.progress = progress
        self.bytesPerSecond = bytesPerSecond; self.elapsedMs = elapsedMs; self.error = error; self.skipped = skipped
        self.outputURL = outputURL; self.destinationFolderName = destinationFolderName
        self.effects = effects; self.isGeneratingFrame = isGeneratingFrame
        self.frameGenerationStartedAt = frameGenerationStartedAt
        self.frameGenerationElapsedMs = frameGenerationElapsedMs
        self.frameURL = frameURL; self.frameError = frameError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        file = try values.decode(CameraFile.self, forKey: .file)
        status = try values.decodeIfPresent(TransferStatus.self, forKey: .status) ?? .waiting
        progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        bytesPerSecond = try values.decodeIfPresent(Int64.self, forKey: .bytesPerSecond) ?? 0
        elapsedMs = try values.decodeIfPresent(Int64.self, forKey: .elapsedMs)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        skipped = try values.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
        outputURL = try values.decodeIfPresent(URL.self, forKey: .outputURL)
        destinationFolderName = try values.decodeIfPresent(String.self, forKey: .destinationFolderName)
        effects = try values.decodeIfPresent(PhotoEffectsSettings.self, forKey: .effects)
        isGeneratingFrame = try values.decodeIfPresent(Bool.self, forKey: .isGeneratingFrame) ?? false
        frameGenerationStartedAt = try values.decodeIfPresent(Date.self, forKey: .frameGenerationStartedAt)
        frameGenerationElapsedMs = try values.decodeIfPresent(Int64.self, forKey: .frameGenerationElapsedMs)
        frameURL = try values.decodeIfPresent(URL.self, forKey: .frameURL)
        frameError = try values.decodeIfPresent(String.self, forKey: .frameError)
    }
}

struct TransferQueueSnapshot: Equatable, Sendable {
    let items: [TransferQueueItem]
    let isTransferring: Bool
    let pauseAfterCurrent: Bool
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
    private(set) var items: [TransferQueueItem] = []
    private(set) var isTransferring = false
    private(set) var pauseAfterCurrent = false
    private var worker: Task<Void, Never>?
    private var frameWorkers: [UUID: Task<Void, Never>] = [:]
    private var session: CameraSession?
    private var directory: URL?
    private var progressSamples: [UUID: (time: Date, value: Double)] = [:]
    private var continuations: [AsyncStream<TransferQueueSnapshot>.Continuation] = []
    private let defaults: UserDefaults
    private let persistenceKey = "transferQueue.items.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: persistenceKey),
           let stored = try? JSONDecoder().decode([TransferQueueItem].self, from: data) {
            // A process can disappear while a file is transferring. Android
            // requeues that item on the next session instead of persisting a
            // permanent in-flight state.
            items = stored.map { item in
                guard item.status == .transferring || item.isGeneratingFrame else { return item }
                var recovered = item
                recovered.status = .waiting
                recovered.progress = 0
                recovered.bytesPerSecond = 0
                recovered.elapsedMs = nil
                recovered.error = nil
                recovered.isGeneratingFrame = false
                recovered.frameGenerationStartedAt = nil
                recovered.frameGenerationElapsedMs = nil
                recovered.frameError = nil
                return recovered
            }
        }
    }

    deinit {
        worker?.cancel()
        frameWorkers.values.forEach { $0.cancel() }
    }

    func snapshots() -> AsyncStream<TransferQueueSnapshot> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(snapshot())
            continuation.onTermination = { _ in }
        }
    }

    @discardableResult
    func enqueue(_ file: CameraFile, organizeByDate: Bool = false,
                 effects: PhotoEffectsSettings? = nil) -> UUID? {
        let item = TransferQueueItem(
            id: UUID(), file: file,
            destinationFolderName: organizeByDate ? transferDateFolderName(file.captureDate) : nil,
            effects: effects
        )
        items.append(item); publish(); return item.id
    }

    @discardableResult
    func enqueueAutomatic(_ file: CameraFile, organizeByDate: Bool = false,
                          effects: PhotoEffectsSettings? = nil) -> UUID? {
        let identity = automaticIdentity(for: file)
        guard !items.contains(where: { automaticIdentity(for: $0.file) == identity }) else { return nil }
        return enqueue(file, organizeByDate: organizeByDate, effects: effects)
    }

    func start(session: CameraSession, directory: URL) {
        self.session = session; self.directory = directory
        guard worker == nil, !pauseAfterCurrent else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    /// Explicitly starting the pending queue is the Android
    /// `startPendingTransfers` path: it clears a previously requested
    /// boundary pause before creating the worker. Automatic enqueue uses
    /// `start` directly so a deferred queue remains deferred.
    func startPendingTransfers(session: CameraSession, directory: URL) {
        pauseAfterCurrent = false
        start(session: session, directory: directory)
    }

    /// Refreshes the transport used by later retries without changing the
    /// deferred-start decision or interrupting an active transfer.
    func attach(session: CameraSession, directory: URL?) {
        self.session = session
        // A nil bookmark is meaningful: Android clears the destination after
        // an invalid directory and must not let a reconnect resurrect the
        // stale URL for an automatically started task.
        self.directory = directory
    }

    /// Clears the live camera reference when the root connection disappears.
    /// The queue remains persisted and its active transfer is allowed to
    /// unwind; the next task then observes the same nil-provider state as
    /// Android and is marked camera-not-connected instead of using a stale
    /// session object.
    func detach() {
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
        pauseAfterCurrent = false
        if worker == nil, let session, let directory { start(session: session, directory: directory) }
        publish()
    }

    func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .waiting else { return }
        items[index].status = .cancelled; publish()
    }

    /// Android's clear flow first withdraws every waiting item so the worker
    /// cannot claim another file during the removal animation.  The active item
    /// is intentionally left untouched.
    func withdrawPending() {
        var changed = false
        for index in items.indices where items[index].status == .waiting {
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
        let replacement = TransferQueueItem(
            id: UUID(), file: old.file,
            destinationFolderName: old.destinationFolderName,
            effects: old.effects
        )
        items[index] = replacement
        publish()
        if worker == nil, let session, let directory, !pauseAfterCurrent {
            start(session: session, directory: directory)
        }
        return replacement.id
    }

    /// Removes only terminal cards. Active downloads are deliberately left alone,
    /// matching Android's clear action which never interrupts the current file.
    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .completed || items[index].status == .failed || items[index].status == .cancelled else { return }
        items.remove(at: index)
        publish()
    }

    func clearFinished() {
        items.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
        publish()
    }

    /// RemoveCleared in Android is deliberately limited to terminal items; a
    /// waiting item can only disappear after withdrawPending has run.
    func removeCleared() {
        let before = items.count
        items.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
        if items.count != before { publish() }
    }

    /// Retry every failed/cancelled item with a fresh attempt identity, then
    /// restart the worker if a live session and directory are available.
    func retryFailed() {
        guard directory != nil else { return }
        var replacements = false
        for index in items.indices where items[index].status == .failed || items[index].status == .cancelled {
            let old = items[index]
            items[index] = TransferQueueItem(
                id: UUID(), file: old.file,
                destinationFolderName: old.destinationFolderName,
                effects: old.effects
            )
            replacements = true
        }
        if replacements {
            publish()
            if worker == nil, let session, let directory, !pauseAfterCurrent { start(session: session, directory: directory) }
        }
    }

    private func run() async {
        isTransferring = true; publish()
        defer { isTransferring = false; worker = nil; publish() }
        // Match Android's queue-start guard: a stale/deleted destination fails waiting
        // tasks with a user-facing recovery message before any camera transfer begins.
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else {
            let message = AppLocalized.resource("error_dir_invalid")
            var changed = false
            for index in items.indices where items[index].status == .waiting {
                items[index].status = .failed
                items[index].error = message
                changed = true
            }
            if changed { publish() }
            return
        }
        // Build one snapshot for the root and any Android-style dated folders;
        // each task then reuses it instead of enumerating the directory again.
        var directoryIndexes: [URL: TransferDirectoryIndex] = [:]
        let rootIndex = TransferDirectoryIndex.scan(directory: directory)
        directoryIndexes[directory] = rootIndex
        if let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for child in children where transferDatedFolderName(child.lastPathComponent) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                directoryIndexes[child] = TransferDirectoryIndex.scan(directory: child)
            }
        }
        while !Task.isCancelled, !pauseAfterCurrentFileRequested {
            guard let index = items.firstIndex(where: { $0.status == .waiting }) else { break }
            // Android asks the provider for a live camera immediately before
            // claiming each task. If the session disappeared between files,
            // it settles that task as "camera not connected" and advances to
            // the next queued task, preserving the same per-card publication
            // order and retry affordance.
            guard let session else {
                let message = AppLocalized.resource("camera_not_connected")
                items[index].status = .failed
                items[index].error = message
                items[index].bytesPerSecond = 0
                publish()
                continue
            }
            let itemID = items[index].id
            let originalSize = items[index].file.size
            items[index].status = .transferring; items[index].error = nil; publish()
            let transferStartedAt = Date()
            items[index].elapsedMs = nil
            progressSamples[itemID] = (Date(), 0)
            do {
                let destinationDirectory = transferDestinationDirectory(
                    root: directory, folderName: items[index].destinationFolderName
                )
                if items[index].destinationFolderName != nil {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                }
                if directoryIndexes[destinationDirectory] == nil {
                    directoryIndexes[destinationDirectory] = TransferDirectoryIndex.scan(directory: destinationDirectory)
                }
                if let destination = directoryIndexes[destinationDirectory]?.existingOriginal(for: items[index].file) {
                    let effects = items[index].effects
                    if let index = items.firstIndex(where: { $0.id == itemID }) {
                        items[index].status = .completed
                        items[index].progress = 1
                        items[index].skipped = true
                        items[index].outputURL = destination
                        progressSamples[itemID] = nil
                        publish()
                    }
                    if let effects, effects.hasEffect,
                       Self.supportsRenderedOutput(items.first(where: { $0.id == itemID })?.file.fileExtension ?? "") {
                        if let frame = existingFrameURL(source: destination, settings: effects, in: destinationDirectory) {
                            if let index = items.firstIndex(where: { $0.id == itemID }) {
                                items[index].frameURL = frame; publish()
                            }
                        } else {
                            startFrameGeneration(for: itemID, source: destination, settings: effects, in: destinationDirectory)
                        }
                    }
                    continue
                }
                let output = try await session.download(file: items[index].file, to: destinationDirectory) { [weak self] progress in
                    Task { await self?.updateProgress(id: itemID, value: progress) }
                }
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].status = .completed
                    items[index].progress = 1
                    items[index].elapsedMs = Int64(max(0, Date().timeIntervalSince(transferStartedAt) * 1000).rounded())
                    items[index].outputURL = output
                    publish()
                }
                directoryIndexes[destinationDirectory, default: TransferDirectoryIndex.scan(directory: destinationDirectory)]
                    .addOriginal(output, size: originalSize)
                progressSamples[itemID] = nil
                // Android keeps the original as completed, then renders the
                // immutable effect snapshot into the sibling ZTFrames folder.
                // A frame failure never rolls back a successful original.
                if let effects = items.first(where: { $0.id == itemID })?.effects,
                   effects.hasEffect,
                   Self.supportsRenderedOutput(items.first(where: { $0.id == itemID })?.file.fileExtension ?? "") {
                    startFrameGeneration(for: itemID, source: output, settings: effects, in: destinationDirectory)
                }
            } catch is CancellationError {
                // The active transfer has no user-cancel action in Android;
                // cancellation here is lifecycle/session teardown. Keep it
                // waiting so the persisted queue can resume from .nkpart_ on
                // the next live session instead of losing the task.
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].status = .waiting
                    items[index].progress = 0
                    items[index].bytesPerSecond = 0
                    items[index].error = nil
                    publish()
                }
                progressSamples[itemID] = nil
            } catch {
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].status = .failed
                    items[index].error = transferErrorMessage(error)
                    publish()
                }
                progressSamples[itemID] = nil
            }
        }
    }

    private var pauseAfterCurrentFileRequested: Bool { pauseAfterCurrent }

    private static func supportsRenderedOutput(_ ext: String) -> Bool {
        // Android's PhotoFrameExporter deliberately limits transfer effects
        // to JPG/JPEG/PNG; RAW, TIFF, HEIC and video remain original-only.
        [".jpg", ".jpeg", ".png"].contains(ext.lowercased())
    }

    /// Android hands derivative rendering to a separate worker immediately after the original
    /// reaches COMPLETED; the FIFO download loop must continue with the next camera object.
    private func startFrameGeneration(for id: UUID, source: URL, settings: PhotoEffectsSettings, in directory: URL) {
        guard frameWorkers[id] == nil else { return }
        frameWorkers[id] = Task { [weak self] in
            await self?.generateFrame(for: id, source: source, settings: settings, in: directory)
            await self?.finishFrameWorker(id)
        }
    }

    private func finishFrameWorker(_ id: UUID) {
        frameWorkers[id] = nil
    }

    private func generateFrame(for id: UUID, source: URL, settings: PhotoEffectsSettings, in directory: URL) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let startedAt = Date()
        items[index].isGeneratingFrame = true
        items[index].frameGenerationStartedAt = startedAt
        items[index].frameGenerationElapsedMs = nil
        items[index].frameError = nil
        publish()
        do {
            let data = try Data(contentsOf: source)
            guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            let metadata = PhotoExifParser.parse(data).map(PhotoFrameMetadata.init)
            let rendered = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try autoreleasepool {
                    try PhotoEffectsRenderer.render(image, settings: settings, metadata: metadata)
                }
            }.value
            try Task.checkCancellation()
            guard let encoded = rendered.jpegData(compressionQuality: 1) else { throw CocoaError(.fileWriteUnknown) }
            let framesDirectory = directory.appendingPathComponent("ZTFrames", isDirectory: true)
            try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            let preferred = frameURL(source: source, settings: settings, framesDirectory: framesDirectory)
            let destination = uniqueFrameURL(preferred)
            try encoded.write(to: destination, options: .atomic)
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].isGeneratingFrame = false
                items[index].frameGenerationStartedAt = nil
                items[index].frameGenerationElapsedMs = Int64(max(0, Date().timeIntervalSince(startedAt) * 1000).rounded())
                items[index].frameURL = destination
                publish()
            }
        } catch is CancellationError {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].isGeneratingFrame = false
                items[index].frameGenerationStartedAt = nil
                publish()
            }
        } catch {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].isGeneratingFrame = false
                items[index].frameGenerationStartedAt = nil
                items[index].frameGenerationElapsedMs = Int64(max(0, Date().timeIntervalSince(startedAt) * 1000).rounded())
                items[index].frameError = error.localizedDescription
                publish()
            }
        }
    }

    private func existingFrameURL(source: URL, settings: PhotoEffectsSettings, in directory: URL) -> URL? {
        let framesDirectory = directory.appendingPathComponent("ZTFrames", isDirectory: true)
        let preferred = frameURL(source: source, settings: settings, framesDirectory: framesDirectory)
        return FileManager.default.fileExists(atPath: preferred.path) ? preferred : nil
    }

    private func frameURL(source: URL, settings: PhotoEffectsSettings, framesDirectory: URL) -> URL {
        framesDirectory.appendingPathComponent(
            androidPhotoFrameOutputName(sourceName: source.lastPathComponent, settings: settings)
        )
    }

    private func uniqueFrameURL(_ preferred: URL) -> URL {
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        let stem = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        for i in 1...999 {
            let candidate = preferred.deletingLastPathComponent().appendingPathComponent("\(stem) (\(i)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return preferred.deletingLastPathComponent().appendingPathComponent("\(stem)_\(Date().timeIntervalSince1970).\(ext)")
    }

    private func updateProgress(id: UUID, value: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .transferring else { return }
        let now = Date()
        if let previous = progressSamples[id], now.timeIntervalSince(previous.time) > 0.08 {
            let delta = max(0, value - previous.value)
            items[index].bytesPerSecond = Int64(Double(items[index].file.size) * delta / now.timeIntervalSince(previous.time))
            progressSamples[id] = (now, value)
        }
        items[index].progress = value; publish()
    }

    private func snapshot() -> TransferQueueSnapshot { TransferQueueSnapshot(items: items, isTransferring: isTransferring, pauseAfterCurrent: pauseAfterCurrent) }
    private func publish() {
        persist()
        let value = snapshot()
        continuations.forEach { $0.yield(value) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: persistenceKey)
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
