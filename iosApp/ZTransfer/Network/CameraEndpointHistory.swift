import Foundation
import ZTransferShared

enum CameraEndpointError: Error, LocalizedError {
    case invalidAddress, invalidIdentity, corruptHistory, confirmationRequired
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入有效的相机 IPv4、IPv6 或主机名；不要包含网址、路径或端口。"
        case .invalidIdentity: return "缺少已核对的相机身份，不能保存或选择历史地址。"
        case .corruptHistory: return "相机地址历史损坏或版本较新；原文件未被覆盖，可确认后备份并重置地址历史。"
        case .confirmationRequired: return "此操作需要明确确认；尚未删除或重置任何记录。"
        }
    }
}

struct CameraEndpointAddress: Codable, Equatable, Hashable {
    let host: String
    var port: UInt16 { UInt16(PtpConstants.shared.PTP_PORT) }
    private init(host: String) { self.host = host }
    static func parse(_ raw: String) throws -> CameraEndpointAddress {
        guard let host = NativeCameraEndpointAddress.shared.normalize(raw: raw) else { throw CameraEndpointError.invalidAddress }
        return CameraEndpointAddress(host: host)
    }
}

struct CameraEndpointRecord: Codable, Equatable, Identifiable {
    let responderGUID: String
    let displayName: String
    let address: CameraEndpointAddress
    let lastSuccessfulAtMs: Int64
    var id: String { responderGUID }
}

/// Non-secret endpoint metadata only. Never stores the installation initiator identity or pairing
/// credentials. Addresses are hints; an explicit selection must still verify the responder GUID.
final class CameraEndpointHistory: @unchecked Sendable {
    private struct Document: Codable { var version = 1; var entries: [CameraEndpointRecord] = [] }
    private static let diskLock = NSLock()
    private let file: URL
    private let now: () -> Int64
    init(file: URL, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) throws {
        guard file.isFileURL else { throw CameraEndpointError.corruptHistory }
        self.file = file; self.now = now
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        _ = try Self.read(file)
    }
    static func applicationStore() throws -> CameraEndpointHistory { try CameraEndpointHistory(file: applicationFile()) }
    private static func applicationFile() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("ZTransfer/camera-endpoint-history.json")
    }
    func entries() throws -> [CameraEndpointRecord] {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        return try Self.read(file).entries.sorted {
            $0.lastSuccessfulAtMs == $1.lastSuccessfulAtMs ? $0.responderGUID < $1.responderGUID : $0.lastSuccessfulAtMs > $1.lastSuccessfulAtMs
        }
    }
    func select(responderGUID: String) throws -> CameraEndpointRecord? {
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responderGUID) else { throw CameraEndpointError.invalidIdentity }
        return try entries().first { $0.responderGUID == normalized }
    }
    /// Call only after the selected address completed the real camera handshake, never on typing,
    /// Bonjour advertisement, an attempted connection, or a failed/mismatched responder response.
    func recordSuccessful(responderGUID: String, displayName: String, address: CameraEndpointAddress) throws {
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responderGUID) else { throw CameraEndpointError.invalidIdentity }
        let validated = try CameraEndpointAddress.parse(address.host)
        guard validated == address else { throw CameraEndpointError.invalidAddress }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CameraEndpointError.invalidIdentity
        }
        let stamp = now()
        guard stamp > 0 else { throw CameraEndpointError.corruptHistory }
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        var document = try Self.read(file)
        document.entries.removeAll { $0.responderGUID == normalized }
        document.entries.append(CameraEndpointRecord(responderGUID: normalized, displayName: name, address: validated, lastSuccessfulAtMs: stamp))
        guard document.entries.count <= 256 else { throw CameraEndpointError.corruptHistory }
        try Self.write(document, to: file)
    }
    func forget(responderGUID: String) throws {
        guard let normalized = NikonStaBridge.shared.normalizeGuid(value: responderGUID) else { throw CameraEndpointError.invalidIdentity }
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        var document = try Self.read(file)
        guard document.entries.contains(where: { $0.responderGUID == normalized }) else { return }
        document.entries.removeAll { $0.responderGUID == normalized }
        try Self.write(document, to: file)
    }
    @discardableResult func reset(confirmed: Bool) throws -> URL? { try Self.reset(file: file, confirmed: confirmed) }
    /// An unknown future document is never migrated by guessing. Explicit reset archives the exact
    /// bytes first and replaces only this metadata file; installation/pairing identity is untouched.
    @discardableResult static func reset(file: URL, confirmed: Bool) throws -> URL? {
        guard confirmed else { throw CameraEndpointError.confirmationRequired }
        guard file.isFileURL else { throw CameraEndpointError.corruptHistory }
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        var archive: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            try validateRegularFile(file)
            let destination = file.deletingLastPathComponent().appendingPathComponent("camera-endpoint-history-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: destination)
            archive = destination
        }
        try Self.write(Document(), to: file)
        return archive
    }
    @discardableResult static func resetApplicationHistory(confirmed: Bool) throws -> URL? {
        try reset(file: applicationFile(), confirmed: confirmed)
    }
    private static func validateRegularFile(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CameraEndpointError.corruptHistory
        }
    }
    private static func read(_ file: URL) throws -> Document {
        guard FileManager.default.fileExists(atPath: file.path) else { return Document() }
        do {
            try validateRegularFile(file)
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024 else {
                throw CameraEndpointError.corruptHistory
            }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1, document.entries.count <= 256,
                  Set(document.entries.map(\.responderGUID)).count == document.entries.count else { throw CameraEndpointError.corruptHistory }
            for entry in document.entries {
                guard NikonStaBridge.shared.normalizeGuid(value: entry.responderGUID) == entry.responderGUID,
                      try CameraEndpointAddress.parse(entry.address.host) == entry.address, entry.lastSuccessfulAtMs > 0,
                      !entry.displayName.isEmpty, entry.displayName.utf8.count <= 256,
                      !entry.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw CameraEndpointError.corruptHistory
                }
            }
            return document
        } catch { throw CameraEndpointError.corruptHistory }
    }
    private static func write(_ document: Document, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) { try validateRegularFile(file) }
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }
}
