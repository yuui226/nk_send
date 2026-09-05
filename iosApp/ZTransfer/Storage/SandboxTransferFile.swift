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

    /// Read only an indexed app-owned original. Never accepts arbitrary file/provider URLs.
    /// No network access or index rescan on a preview request; deletion/size change fails locally.
    func originalData(locator: String) throws -> Data {
        try withOriginalInput(locator: locator, maximumFileBytes: Int64(Int32.max)) { input, size in
            var data = Data()
            var remaining = size
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
                guard !chunk.isEmpty else { throw OriginalIndexError.incompleteMetadata }
                data.append(chunk); remaining -= Int64(chunk.count)
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw OriginalIndexError.incompleteMetadata }
            try Task.checkCancellation()
            return data
        }
    }

    /// Same indexed owner/descriptor checks, but only bounded slices of a potentially large RAW.
    func originalRawPreviewData(locator: String) throws -> Data? {
        try withOriginalInput(locator: locator, maximumFileBytes: Int64.max) { input, size in
            let prefixCount = Int(min(size, Int64(LocalRawPreviewPolicy.shared.indexPrefixBytes)))
            let prefix = try readOriginalRange(input, offset: 0, count: prefixCount, size: size)
            let references = NativeRawPreviewBridge.shared.candidates(data: prefix as NSData)
            var bestBytes: Data?
            var bestPixels: Int64 = -1
            for reference in references {
                try Task.checkCancellation()
                let offset = reference.offset, length = Int64(reference.length)
                // Invalid/out-of-file candidates are misses, not permission to read another file.
                guard offset >= 0, length > 0, offset <= size, length <= size - offset else { continue }
                let bytes: Data
                if offset + length <= Int64(prefix.count) {
                    bytes = prefix.subdata(in: Int(offset)..<Int(offset + length))
                } else {
                    bytes = try readOriginalRange(input, offset: offset, count: Int(length), size: size)
                }
                let pixels = try PreviewImageDecoder.rawPreviewPixels(bytes)
                if LocalRawPreviewPolicy.shared.isBetter(pixelCount: pixels, previous: bestPixels) {
                    bestPixels = pixels; bestBytes = bytes
                }
            }
            var finalState = stat()
            guard fstat(input.fileDescriptor, &finalState) == 0, finalState.st_size == size else {
                throw OriginalIndexError.incompleteMetadata
            }
            try Task.checkCancellation()
            return bestBytes
        }
    }

    private func readOriginalRange(_ input: FileHandle, offset: Int64, count: Int, size: Int64) throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
            throw OriginalIndexError.incompleteMetadata
        }
        try input.seek(toOffset: UInt64(offset))
        var data = Data(), remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
            guard !chunk.isEmpty else { throw OriginalIndexError.incompleteMetadata }
            data.append(chunk); remaining -= chunk.count
        }
        try Task.checkCancellation()
        return data
    }

    /// Opens once without following directory/leaf links, and closes on every return/throw.
    private func withOriginalInput<T>(locator: String, maximumFileBytes: Int64,
                                      body: (FileHandle, Int64) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard let url = URL(string: locator), url.isFileURL,
              url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
              let entry = originalIndex.entry(at: url), entry.url.absoluteString == locator,
              entry.size > 0, entry.size <= maximumFileBytes,
              SandboxTransferFile.safeComponent(entry.name),
              !SandboxTransferFile.isPrivatePartName(entry.name) else { throw OriginalIndexError.unsafeRoot }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
            throw OriginalIndexError.unsafeRoot
        }
        let parent = entry.folder.map { canonicalRoot.appendingPathComponent($0, isDirectory: true) } ?? canonicalRoot
        guard (entry.folder == nil || NativeOriginalIndexPolicy.shared.isDateFolder(name: entry.folder!)),
              try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
              parent.standardizedFileURL.resolvingSymlinksInPath() == parent,
              url.deletingLastPathComponent() == parent,
              url.standardizedFileURL.resolvingSymlinksInPath() == url else { throw OriginalIndexError.unsafeRoot }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink == false, values.isRegularFile == true,
              values.fileSize.map(Int64.init) == entry.size else { throw OriginalIndexError.incompleteMetadata }
        // Hold each directory descriptor and open the next component without following symlinks.
        // Replacing a date folder or leaf between the URL checks and open cannot redirect this read.
        let rootFD = canonicalRoot.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw OriginalIndexError.unsafeRoot }
        defer { _ = Darwin.close(rootFD) }
        let folderFD: Int32
        if let folder = entry.folder {
            folderFD = folder.withCString { Darwin.openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0) }
            guard folderFD >= 0 else { throw OriginalIndexError.unsafeRoot }
        } else { folderFD = rootFD }
        defer { if folderFD != rootFD { _ = Darwin.close(folderFD) } }
        let fileFD = entry.name.withCString { Darwin.openat(folderFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0) }
        guard fileFD >= 0 else { throw OriginalIndexError.unsafeRoot }
        let input = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        defer { try? input.close() }
        var opened = stat()
        guard fstat(fileFD, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_size == entry.size else { throw OriginalIndexError.incompleteMetadata }
        return try body(input, entry.size)
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
