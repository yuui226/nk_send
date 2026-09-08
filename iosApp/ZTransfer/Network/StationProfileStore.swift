import Foundation
import ZTransferShared

struct StationConnectionOptions {
    var expectedResponderGUID: String? = nil
    var allowPairing = false
    var forceProfilePairing = false
    /// Explicit compatibility path. The baseline/diagnostic route remains unchanged by default.
    var exploreAlbumAccess = false
}

enum CameraStationError: Error, LocalizedError {
    case unexpectedResponder, pairingRequired, albumUnavailable, missingIdentity, corruptIdentityStore
    case pairingCompleted(String)
    var errorDescription: String? {
        switch self {
        case .unexpectedResponder: return "响应相机与选中的机身身份不符，已停止连接。"
        case .pairingRequired: return "相机需要完成电脑模式配对，请勾选“允许首次电脑模式配对”，重试并在相机端确认。"
        case .albumUnavailable: return "STA 相册读取验证未通过。请确认相机有可读取的照片、电脑连接模式已开启，再重试。"
        case .missingIdentity: return "相机未返回可持久保存的机身身份，不能确认配对。"
        case .corruptIdentityStore: return "本地相机身份文件无效；未重置身份或覆盖原文件。"
        case .pairingCompleted: return "相机已确认配对并保存标记，请完成相机端提示后重新连接。"
        }
    }
}

/// Only this installation's stable PC identity and authoritative pairing acknowledgements.
/// Address metadata stays in CameraEndpointHistory; this existing identity format is preserved.
/// Atomic local writes precede pacing. Forgetting one responder never regenerates the initiator.
final class StationProfileStore: @unchecked Sendable {
    private struct Document: Codable {
        var version: Int = 1
        var initiator: String
        var pairedResponders: [String] = []
    }
    private static let diskLock = NSLock()
    private let file: URL
    let identity: Data

    init(file: URL) throws {
        guard file.isFileURL else { throw CameraStationError.corruptIdentityStore }
        Self.diskLock.lock()
        defer { Self.diskLock.unlock() }
        self.file = file
        let document: Document
        if FileManager.default.fileExists(atPath: file.path) {
            document = try Self.read(file)
        } else {
            let random = (0..<8).map { _ in UInt8.random(in: 0...255) }
            let candidate = Document(initiator: random.map { String(format: "%02x", $0) }.joined())
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try JSONEncoder().encode(candidate).write(to: file, options: .withoutOverwriting)
                document = candidate
            } catch {
                let failure = error as NSError
                guard failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteFileExistsError else { throw error }
                document = try Self.read(file)
            }
        }
        identity = Data(document.initiator.utf8)
    }

    static func applicationStore() throws -> StationProfileStore {
        try StationProfileStore(file: applicationFile())
    }

    private static func applicationFile() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return support.appendingPathComponent("ZTransfer/station-identity.json")
    }

    @discardableResult static func recoverApplicationIdentity(confirmed: Bool) throws -> URL? {
        try recoverCorruptStore(file: applicationFile(), confirmed: confirmed)
    }

    func isPaired(_ responder: String) throws -> Bool {
        Self.diskLock.lock()
        defer { Self.diskLock.unlock() }
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responder) else { return false }
        return try currentDocument().pairedResponders.contains(normalized)
    }

    func markPaired(_ responder: String) throws {
        Self.diskLock.lock()
        defer { Self.diskLock.unlock() }
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responder) else { throw CameraStationError.missingIdentity }
        var document = try currentDocument()
        if document.pairedResponders.contains(normalized) { return }
        document.pairedResponders.append(normalized)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    func pairedResponderGUIDs() throws -> [String] {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        return Array(Set(try currentDocument().pairedResponders)).sorted()
    }

    func forgetResponder(_ responder: String) throws {
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responder) else { throw CameraStationError.missingIdentity }
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        var document = try currentDocument()
        guard document.pairedResponders.contains(normalized) else { return }
        document.pairedResponders.removeAll { $0 == normalized }
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    /// Only an explicitly confirmed recovery may archive an unreadable/unsupported document.
    /// A valid identity store is never reset here; use forgetResponder for one-camera re-pairing.
    @discardableResult static func recoverCorruptStore(file: URL, confirmed: Bool) throws -> URL? {
        guard confirmed else { throw CameraEndpointError.confirmationRequired }
        guard file.isFileURL else { throw CameraStationError.corruptIdentityStore }
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        if (try? Self.read(file)) != nil { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CameraStationError.corruptIdentityStore }
        let archive = file.deletingLastPathComponent().appendingPathComponent("station-identity-backup-\(UUID().uuidString).json")
        // Move only this exact regular file. Its complete bytes survive; next explicit open creates
        // a fresh installation identity and requires pairing again (never pretend old markers apply).
        try FileManager.default.moveItem(at: file, to: archive)
        return archive
    }

    private static func read(_ file: URL) throws -> Document {
        let type = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard type.isRegularFile == true, type.isSymbolicLink != true else { throw CameraStationError.corruptIdentityStore }
        let length = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard length <= 1024 * 1024 else { throw CameraStationError.corruptIdentityStore }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.version == 1, document.initiator.utf8.count == 16,
              document.initiator.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              document.pairedResponders.allSatisfy({ NikonStaBridge.shared.normalizeGuid(value: $0) == $0 }) else {
            throw CameraStationError.corruptIdentityStore
        }
        return document
    }

    private func currentDocument() throws -> Document {
        let document = try Self.read(file)
        guard Data(document.initiator.utf8) == identity else { throw CameraStationError.corruptIdentityStore }
        return document
    }
}
