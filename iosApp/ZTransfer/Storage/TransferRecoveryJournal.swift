import Foundation

/// Explanatory checkpoint, NOT authority to reuse old camera handles or append to an old .part.
/// Android's process-local queue is not restored blindly either. Re-selection uses a fresh catalog.
actor TransferRecoveryJournal {
    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let size: Int64
        let captureDate: String?
        let storageIDs: [Int32]
        let status: String
        let downloaded: Int64
    }
    struct Document: Codable, Equatable, Sendable {
        let version: Int
        let connectionID: UUID
        let responderGUID: String?
        let sequence: UInt64
        let completed: Int
        let paused: Bool
        let truncated: Bool
        let pending: [Entry]
    }
    enum Failure: Error { case unavailable }
    private let file: URL
    private var activeConnection: UUID?
    private var lastSequence: UInt64?
    private var lastHistory: UInt64?
    init(file: URL) { self.file = file }

    static let application: TransferRecoveryJournal? = {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return TransferRecoveryJournal(file: support.appendingPathComponent("ZTransfer/recovery.json"))
    }()

    func activate(_ connectionID: UUID) {
        activeConnection = connectionID; lastSequence = nil; lastHistory = nil
    }
    func read() throws -> Document? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 512 * 1024 else { throw Failure.unavailable }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw Failure.unavailable }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let data = try input.read(upToCount: 512 * 1024 + 1) ?? Data()
        guard data.count <= 512 * 1024 else { throw Failure.unavailable }
        guard let value = try? JSONDecoder().decode(Document.self, from: data),
              value.version == 1, value.pending.count <= 500, value.completed >= 0,
              value.pending.allSatisfy({ SandboxTransferFile.safeComponent($0.name) && $0.size >= 0 &&
                  $0.downloaded >= 0 && $0.storageIDs.count <= 8 &&
                  ["WAITING", "TRANSFERING", "FAILED", "CANCELLED"].contains($0.status) }) else {
            throw Failure.unavailable // Preserve future/corrupt bytes; explicit reset backs them up.
        }
        return value
    }
    func record(_ snapshot: OriginalQueueSnapshot, responderGUID: String?) throws {
        guard snapshot.connectionID == activeConnection, snapshot.historyRevision > 0,
              lastHistory != snapshot.historyRevision, lastSequence.map({ snapshot.sequence > $0 }) ?? true else { return }
        _ = try read() // Never overwrite a document we cannot understand.
        let pending = snapshot.rows.filter { ["WAITING", "TRANSFERING", "FAILED", "CANCELLED"].contains($0.status) }
        let entries = pending.prefix(500).map {
            Entry(name: $0.name, size: $0.size, captureDate: $0.captureDate,
                storageIDs: Array($0.storageIDs.prefix(8)), status: $0.status, downloaded: $0.downloaded)
        }
        guard entries.allSatisfy({ SandboxTransferFile.safeComponent($0.name) }) else { throw Failure.unavailable }
        let value = Document(version: 1, connectionID: snapshot.connectionID, responderGUID: responderGUID,
            sequence: snapshot.sequence, completed: snapshot.rows.filter { $0.status == "COMPLETED" }.count,
            paused: snapshot.paused, truncated: pending.count > 500, pending: entries)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 512 * 1024 else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        lastSequence = snapshot.sequence; lastHistory = snapshot.historyRevision
    }
    /// Caller fences to an idle session and explicit confirmation. Only this metadata file is reset.
    func resetAfterConfirmation() throws {
        activeConnection = nil // A queued publication from the old connection cannot recreate this record.
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let backup = file.deletingPathExtension().appendingPathExtension("recoveryBackup-" + UUID().uuidString + ".json")
        try FileManager.default.moveItem(at: file, to: backup)
        lastSequence = nil; lastHistory = nil
    }
}
