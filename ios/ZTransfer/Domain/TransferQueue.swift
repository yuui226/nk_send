import Foundation

func exportedOriginalBaseName(_ name: String) -> String {
    name.replacingOccurrences(of: " \\(\\d+\\)(?=\\.[^.]*$|$)", with: "", options: .regularExpression)
}

enum TransferStatus: String, Codable, Sendable { case waiting, transferring, completed, failed, cancelled }

struct TransferQueueItem: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let file: CameraFile
    var status: TransferStatus = .waiting
    var progress: Double = 0
    var bytesPerSecond: Int64 = 0
    var error: String?
    var skipped = false
    var outputURL: URL?
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

/// Serial transfer queue. Android permits repeated manual exports of one camera
/// handle; only the automatic-new-media path uses an identity de-duplication key.
/// The active file is never user-cancelled and pause takes effect at its boundary.
actor TransferQueue {
    private(set) var items: [TransferQueueItem] = []
    private(set) var isTransferring = false
    private(set) var pauseAfterCurrent = false
    private var worker: Task<Void, Never>?
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
                guard item.status == .transferring else { return item }
                var recovered = item
                recovered.status = .waiting
                recovered.progress = 0
                recovered.bytesPerSecond = 0
                recovered.error = nil
                return recovered
            }
        }
    }

    deinit { worker?.cancel() }

    func snapshots() -> AsyncStream<TransferQueueSnapshot> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(snapshot())
            continuation.onTermination = { _ in }
        }
    }

    @discardableResult
    func enqueue(_ file: CameraFile) -> UUID? {
        let item = TransferQueueItem(id: UUID(), file: file)
        items.append(item); publish(); return item.id
    }

    @discardableResult
    func enqueueAutomatic(_ file: CameraFile) -> UUID? {
        let identity = automaticIdentity(for: file)
        guard !items.contains(where: { automaticIdentity(for: $0.file) == identity }) else { return nil }
        return enqueue(file)
    }

    func start(session: CameraSession, directory: URL) {
        self.session = session; self.directory = directory
        guard worker == nil, !pauseAfterCurrent else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    func pauseAfterCurrentFile() { pauseAfterCurrent = true; publish() }
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
        let replacement = TransferQueueItem(id: UUID(), file: old.file)
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
            items[index] = TransferQueueItem(id: UUID(), file: old.file)
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
            let message = "传输目录已失效，请重新选择"
            var changed = false
            for index in items.indices where items[index].status == .waiting {
                items[index].status = .failed
                items[index].error = message
                changed = true
            }
            if changed { publish() }
            return
        }
        while !Task.isCancelled, !pauseAfterCurrentFileRequested {
            guard let index = items.firstIndex(where: { $0.status == .waiting }), let session else { break }
            let itemID = items[index].id
            items[index].status = .transferring; items[index].error = nil; publish()
            progressSamples[itemID] = (Date(), 0)
            do {
                if let destination = existingTransferDestination(for: items[index].file, in: directory) {
                    if let index = items.firstIndex(where: { $0.id == itemID }) {
                        items[index].status = .completed
                        items[index].progress = 1
                        items[index].skipped = true
                        items[index].outputURL = destination
                        progressSamples[itemID] = nil
                        publish()
                    }
                    continue
                }
                let output = try await session.download(file: items[index].file, to: directory) { [weak self] progress in
                    Task { await self?.updateProgress(id: itemID, value: progress) }
                }
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].status = .completed; items[index].progress = 1; items[index].outputURL = output; publish()
                }
                progressSamples[itemID] = nil
            } catch is CancellationError {
                if let index = items.firstIndex(where: { $0.id == itemID }) { items[index].status = .cancelled; publish() }
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
            return "相机连接中断，重连后重试可续传"
        case CameraTransportError.timeout:
            // Android normalizes socket timeouts to the same reconnect/resume guidance.
            return "相机连接中断，重连后重试可续传"
        default:
            return error.localizedDescription
        }
    }
}
