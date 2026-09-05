import Foundation
import CryptoKit
import Darwin
import ZTransferShared

enum SandboxTransferError: Error, LocalizedError {
    case unsafeName, invalidState, lengthMismatch, nameExhausted
    var errorDescription: String? {
        switch self {
        case .unsafeName: return "相机文件名不适合保存到本地目录。"
        case .invalidState: return "本地传输文件已关闭。"
        case .lengthMismatch: return "本地写入长度与接收长度不一致，文件未发布。"
        case .nameExhausted: return "同名文件过多，无法选择安全的保存名称。"
        }
    }
}

struct SavedCameraFile: Sendable {
    let url: URL
    let bytes: Int64
    let sha256: String
}

/// App-managed storage only (not a security-scoped Files provider). Each attempt owns one
/// unique hidden part. Existing files are never overwritten; only a verified, closed part moves
/// to a shared-policy final name. No process-resume claim: failed fresh attempts are discarded.
final class SandboxTransferFile: @unchecked Sendable {
    private enum State { case writing, sealed, published, discarded }
    private let lock = NSLock()
    private let directory: URL
    private let part: URL
    private let originalName: String
    private var handle: FileHandle?
    private var state = State.writing
    private var bytes: Int64 = 0
    private var hasher = SHA256()
    private var ownsPart = false

    init(directory: URL, name: String, declaredSize: Int64, captureDate: String?) throws {
        guard directory.isFileURL, Self.safeComponent(name) else { throw SandboxTransferError.unsafeName }
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let sharedName = PtpTransferBridge.shared.partName(name: name, size: declaredSize, captureDate: captureDate)
        // UUID prevents two concurrent attempts from writing the same partial file. Keep the
        // original metadata-derived identity in the name, but do not treat it as a resume token.
        // Bound the private part component independently of the real name (UTF-8 <= 255 bytes).
        // This is deliberately not a persistent resume filename.
        let hint = String(decoding: sharedName.utf8.prefix(80), as: UTF8.self)
        self.part = resolvedDirectory.appendingPathComponent(".\(UUID().uuidString)_\(hint)")
        self.directory = resolvedDirectory
        self.originalName = name
        try FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        try Data().write(to: part, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        ownsPart = true
        do {
            handle = try FileHandle(forWritingTo: part)
        } catch {
            discard()
            throw error
        }
    }

    deinit { discard() }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .writing, let handle else { throw SandboxTransferError.invalidState }
        guard Int64(data.count) <= Int64.max - bytes else { throw SandboxTransferError.lengthMismatch }
        try handle.write(contentsOf: data)
        bytes += Int64(data.count)
        hasher.update(data: data)
    }

    func commit(expectedBytes: Int64) throws -> SavedCameraFile {
        lock.lock()
        defer { lock.unlock() }
        guard state == .writing, let handle else { throw SandboxTransferError.invalidState }
        guard bytes == expectedBytes else { throw SandboxTransferError.lengthMismatch }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        state = .sealed
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        for number in 0...10_000 {
            let name = number == 0 ? originalName : PtpTransferBridge.shared.copyName(name: originalName, number: Int32(number))
            let destination = directory.appendingPathComponent(name)
            do {
                // Same-directory move; Foundation rejects an existing destination. Do not use
                // replaceItem or remove an existing file when another writer wins the name race.
                try FileManager.default.moveItem(at: part, to: destination)
                state = .published
                return SavedCameraFile(url: destination, bytes: bytes, sha256: digest)
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
        throw SandboxTransferError.nameExhausted
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard state != .published && state != .discarded else { return }
        try? handle?.close()
        handle = nil
        state = .discarded
        // Exactly the uniquely created part, never an existing final file or a whole directory.
        if ownsPart { try? FileManager.default.removeItem(at: part) }
        ownsPart = false
    }

    static func safeComponent(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    static func isPrivatePartName(_ name: String) -> Bool {
        if NativeOriginalIndexPolicy.shared.isPartName(name: name) { return true }
        guard name.first == "." else { return false }
        let suffix = name.dropFirst()
        guard suffix.count > 37 else { return false }
        let separator = suffix.index(suffix.startIndex, offsetBy: 36)
        guard UUID(uuidString: String(suffix[..<separator])) != nil, suffix[separator] == "_" else { return false }
        return NativeOriginalIndexPolicy.shared.isPartName(name: String(suffix[suffix.index(after: separator)...]))
    }
}

/// Filesystem orchestration stays off MainActor. Queue/entitlement/PhotoKit integration is separate.
actor CameraOriginalStore {
    private let root: URL
    private let originalIndex = OriginalFileIndexCache()

    init(root: URL) { self.root = root }

    func originals(since revision: Int64, rescan: Bool) throws -> OriginalIndexUpdate {
        if rescan || !originalIndex.ready { try originalIndex.scan(root: root) }
        try Task.checkCancellation()
        return originalIndex.update(since: revision)
    }

    /// Capture only a previously indexed entry; the same reader also serves coordinated providers.
    private func reader(locator: String, cancellation: PreviewExifReadCancellation = PreviewExifReadCancellation()) -> IndexedOriginalReader {
        let entry = URL(string: locator).flatMap { originalIndex.entry(at: $0) }
        return IndexedOriginalReader(root: root, entry: entry, cancellation: cancellation)
    }

    func originalData(locator: String) throws -> Data {
        try reader(locator: locator).originalData(locator: locator)
    }

    func originalRawPreviewData(locator: String) throws -> Data? {
        try reader(locator: locator).originalRawPreviewData(locator: locator)
    }

    func originalExif(locator: String) async throws -> PhotoExif? {
        let cancellation = PreviewExifReadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try self.reader(locator: locator, cancellation: cancellation).originalExif(locator: locator)
        }, onCancel: { cancellation.cancel() })
    }

    func copyOriginal(_ reference: ExistingOriginalReference, to output: SandboxTransferFile) throws -> Int64 {
        try reader(locator: reference.locator).copyOriginal(reference, to: output)
    }

    /// Sharing an existing original must not create another indexed/exported original or a date bucket.
    func makeShareFile(name: String, size: Int64) throws -> SandboxTransferFile {
        try SandboxTransferFile(directory: root.appendingPathComponent("Shared Originals", isDirectory: true),
                                name: name, declaredSize: size, captureDate: nil)
    }

    static func applicationStore() throws -> CameraOriginalStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return CameraOriginalStore(root: support.appendingPathComponent("ZTransfer/Originals", isDirectory: true))
    }

    func download(camera: CameraWiFiConnection, info: PtpObjectInfo, byDate: Bool, dayKey: Int32,
                  onProgress: ((CameraDownloadProgress) -> Void)? = nil) async throws -> SavedCameraFile {
        guard !info.isAssociation, info.identityComplete, let name = info.fileName else {
            throw SandboxTransferError.unsafeName
        }
        let folder = PtpTransferBridge.shared.destinationFolder(captureDate: info.captureDate, byDate: byDate, dayKey: dayKey)
        return try await downloadFile(camera: camera, handle: info.handle, size: info.size, name: name,
                                      date: info.captureDate, folder: folder, onProgress: onProgress)
    }

    func download(camera: CameraWiFiConnection, task: TransferTask,
                  onProgress: ((CameraDownloadProgress) -> Void)? = nil) async throws -> SavedCameraFile {
        try await downloadFile(camera: camera, handle: task.file.handle, size: task.file.size,
                               name: task.file.fileName, date: task.file.captureDate, folder: task.destinationFolderName, onProgress: onProgress)
    }

    private func downloadFile(camera: CameraWiFiConnection, handle: Int32, size: Int64, name: String,
                              date: String?, folder: String?, onProgress: ((CameraDownloadProgress) -> Void)?) async throws -> SavedCameraFile {
        if let folder, !SandboxTransferFile.safeComponent(folder) { throw SandboxTransferError.unsafeName }
        let directory = folder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        let output = try SandboxTransferFile(directory: directory, name: name, declaredSize: size, captureDate: date)
        do {
            let result = try await camera.download(handle: handle, declaredSize: size, onProgress: onProgress) { try output.write($0) }
            try Task.checkCancellation()
            let saved = try output.commit(expectedBytes: result.bytes)
            originalIndex.record(saved, folder: folder)
            return saved
        } catch {
            output.discard()
            throw error
        }
    }
}
