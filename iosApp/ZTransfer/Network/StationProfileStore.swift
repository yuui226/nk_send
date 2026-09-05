import Foundation
import ZTransferShared

struct StationConnectionOptions {
    var expectedResponderGUID: String? = nil
    var allowPairing = false
    var forceProfilePairing = false
}

enum CameraStationError: Error, LocalizedError {
    case unexpectedResponder, pairingRequired, albumUnavailable, missingIdentity, corruptIdentityStore
    case pairingCompleted(String)
    var errorDescription: String? {
        switch self {
        case .unexpectedResponder: return "响应相机与选中的机身身份不符，已停止连接。"
        case .pairingRequired: return "相机需要完成电脑模式配对，请先启用配对诊断并在相机端确认。"
        case .albumUnavailable: return "STA 标准流程尚未取得可用相册；专用兼容/直接读取路径还未接入。"
        case .missingIdentity: return "相机未返回可持久保存的机身身份，不能确认配对。"
        case .corruptIdentityStore: return "本地相机身份文件无效；未重置身份或覆盖原文件。"
        case .pairingCompleted: return "相机已确认配对并保存标记，请完成相机端提示后重新连接。"
        }
    }
}

/// Only this installation's stable PC identity and authoritative pairing acknowledgements.
/// Full profile history/selection/Bonjour remain separate. Atomic local writes precede pacing.
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
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return try StationProfileStore(file: support.appendingPathComponent("ZTransfer/station-identity.json"))
    }

    func isPaired(_ responder: String) throws -> Bool {
        Self.diskLock.lock()
        defer { Self.diskLock.unlock() }
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responder) else { return false }
        return try Self.read(file).pairedResponders.contains(normalized)
    }

    func markPaired(_ responder: String) throws {
        Self.diskLock.lock()
        defer { Self.diskLock.unlock() }
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responder) else { throw CameraStationError.missingIdentity }
        var document = try Self.read(file)
        if document.pairedResponders.contains(normalized) { return }
        document.pairedResponders.append(normalized)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }

    private static func read(_ file: URL) throws -> Document {
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
}
