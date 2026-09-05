import Foundation
import CryptoKit
import Darwin
import ZTransferShared

enum ProviderPublicationError: Error, LocalizedError {
    case unsafePath, sourceChanged, verificationFailed, coordinationFailed
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "原片或导出目录路径不安全；未覆盖已有文件。"
        case .sourceChanged: return "应用内原片已变化或不完整；未发布导出文件。"
        case .verificationFailed: return "导出副本校验未通过；应用内原片仍保留。"
        case .coordinationFailed: return "文件服务未授予本次读写访问；请检查目录授权后重试。"
        }
    }
}

/// A fresh coordinator per operation; cancel is the only method allowed from another thread.
protocol ProviderFileCoordinating: AnyObject, Sendable {
    func copy(source: URL, directory: URL, accessor: (URL, URL) throws -> SavedCameraFile) throws -> SavedCameraFile
    func cancel()
}

private final class AppleProviderFileCoordinator: ProviderFileCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var active: NSFileCoordinator?
    private var cancelled = false
    func copy(source: URL, directory: URL, accessor: (URL, URL) throws -> SavedCameraFile) throws -> SavedCameraFile {
        // Actors may resume on another thread. Create/use on this synchronous operation's thread.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        active = coordinator
        lock.unlock()
        defer { lock.lock(); active = nil; lock.unlock() }
        var result: Result<SavedCameraFile, Error>?
        var failure: NSError?
        coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: directory, options: [], error: &failure) { input, output in
            result = Result { try accessor(input, output) } // Use the URLs supplied by coordination, not the old paths.
        }
        if let result { return try result.get() }
        if let failure { throw failure }
        throw ProviderPublicationError.coordinationFailed
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = active; lock.unlock()
        current?.cancel() // The only NSFileCoordinator method Apple allows from any thread.
    }
}

/// NSFileCoordinator.cancel alone cannot interrupt an accessor already copying bytes.
/// The same flag therefore gates every chunk and the final publication boundary.
private final class ProviderPublicationControl: @unchecked Sendable {
    let coordinator: ProviderFileCoordinating
    private let lock = NSLock()
    private var cancelled = false
    init(coordinator: ProviderFileCoordinating) { self.coordinator = coordinator }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        coordinator.cancel()
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Publish only an already completed app-managed original. No network transaction is held while
/// a provider materializes content or grants coordination. No ongoing permission/cloud-sync claim.
actor ProviderOriginalPublisher {
    private let directory: ScopedDirectoryStore
    private let coordinatorFactory: () -> ProviderFileCoordinating
    init(directory: ScopedDirectoryStore, coordinatorFactory: (() -> ProviderFileCoordinating)? = nil) {
        self.directory = directory; self.coordinatorFactory = coordinatorFactory ?? { AppleProviderFileCoordinator() }
    }

    func publish(_ saved: SavedCameraFile, folder: String? = nil) async throws -> SavedCameraFile {
        try Task.checkCancellation()
        let control = ProviderPublicationControl(coordinator: coordinatorFactory())
        return try await withTaskCancellationHandler(operation: {
            try await directory.withDirectory { granted in
                try control.check()
                return try control.coordinator.copy(source: saved.url, directory: granted) { input, output in
                    try Self.copyVerified(saved, coordinatedSource: input, coordinatedDirectory: output,
                        folder: folder, checkCancellation: control.check)
                }
            }
        }, onCancel: { control.cancel() })
    }

    /// All filesystem operations here run inside BOTH the grant and coordinated accessor.
    /// Internal seam supports real filesystem tests without granting access to a user's provider.
    static func copyVerified(_ saved: SavedCameraFile, coordinatedSource source: URL, coordinatedDirectory root: URL,
                             folder: String?, checkCancellation: () throws -> Void) throws -> SavedCameraFile {
        try checkCancellation()
        let name = saved.url.lastPathComponent
        guard source.isFileURL, root.isFileURL, saved.bytes >= 0, SandboxTransferFile.safeComponent(name),
              !SandboxTransferFile.isPrivatePartName(name) else {
            throw ProviderPublicationError.unsafePath
        }
        if let folder, !SandboxTransferFile.safeComponent(folder) || !NativeOriginalIndexPolicy.shared.isDateFolder(name: folder) {
            throw ProviderPublicationError.unsafePath
        }
        try requireDirectory(root)
        let target: URL
        if let folder {
            target = root.appendingPathComponent(folder, isDirectory: true)
            // No intermediate path creation and no following an existing symlink/date-file collision.
            do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            catch {
                let value = error as NSError
                guard value.domain == NSCocoaErrorDomain && value.code == NSFileWriteFileExistsError else { throw error }
            }
            try requireDirectory(target)
        } else { target = root }
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink == false else { throw ProviderPublicationError.unsafePath }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProviderPublicationError.sourceChanged }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size == saved.bytes else {
            throw ProviderPublicationError.sourceChanged
        }
        let hint = String(decoding: PtpTransferBridge.shared.partName(name: name, size: saved.bytes, captureDate: nil).utf8.prefix(80), as: UTF8.self)
        let part = target.appendingPathComponent(".\(UUID().uuidString)_\(hint)")
        var ownsPart = false, published = false
        var output: FileHandle?
        defer {
            try? output?.close()
            // Only our one unique part; never remove a final file, the source, or a directory.
            if ownsPart && !published { try? FileManager.default.removeItem(at: part) }
        }
        try checkCancellation()
        try Data().write(to: part, options: [.withoutOverwriting]) // Provider, not app sandbox protection attributes.
        ownsPart = true
        let writer = try FileHandle(forWritingTo: part)
        output = writer
        let sourceDigest = try digest(input, bytes: saved.bytes, checkCancellation: checkCancellation) { try writer.write(contentsOf: $0) }
        guard sourceDigest == saved.sha256 else { throw ProviderPublicationError.sourceChanged }
        try writer.synchronize(); try writer.close(); output = nil

        // Read back the provider's closed part. Bounded memory for RAW/video, not whole-file Data.
        let verification = try FileHandle(forReadingFrom: part)
        let copyDigest: String
        do {
            copyDigest = try digest(verification, bytes: saved.bytes, mismatch: .verificationFailed, checkCancellation: checkCancellation) { _ in }
            try verification.close()
        } catch { try? verification.close(); throw error }
        guard copyDigest == saved.sha256 else { throw ProviderPublicationError.verificationFailed }
        for number in 0...10_000 {
            try checkCancellation()
            let finalName = number == 0 ? name : PtpTransferBridge.shared.copyName(name: name, number: Int32(number))
            guard SandboxTransferFile.safeComponent(finalName) else { throw ProviderPublicationError.unsafePath }
            let destination = target.appendingPathComponent(finalName)
            do {
                try FileManager.default.moveItem(at: part, to: destination) // Existing names are never replaced.
                published = true
                // Do not turn a completed publication into an error if cancellation arrives after the move.
                return SavedCameraFile(url: destination, bytes: saved.bytes, sha256: copyDigest)
            } catch {
                let value = error as NSError
                if value.domain == NSCocoaErrorDomain && value.code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
        throw SandboxTransferError.nameExhausted
    }

    private static func requireDirectory(_ url: URL) throws {
        let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard value.isDirectory == true, value.isSymbolicLink == false else { throw ProviderPublicationError.unsafePath }
    }

    private static func digest(_ input: FileHandle, bytes: Int64, mismatch: ProviderPublicationError = .sourceChanged, checkCancellation: () throws -> Void,
                               consume: (Data) throws -> Void) throws -> String {
        var remaining = bytes, hash = SHA256()
        while remaining > 0 {
            try checkCancellation()
            let chunk = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !chunk.isEmpty else { throw mismatch }
            try consume(chunk); hash.update(data: chunk); remaining -= Int64(chunk.count)
        }
        try checkCancellation()
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw mismatch }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
