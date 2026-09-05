import Foundation
import CryptoKit
import ImageIO
import ZTransferShared

enum ThumbnailDiskError: Error { case unsafePath, incompleteFile }

/// Only CameraPreviewStore's actor accesses this instance. Derived thumbnails only, never originals.
/// No capacity eviction: shared 90-day camera expiry and authoritative catalog reconciliation apply.
final class CameraThumbnailDiskCache {
    private let root: URL
    let directory: URL
    private let now: () -> Int64
    private let policy = NativePreviewPolicy()
    private static let maximumBytes = 4 * 1024 * 1024

    init(root: URL, cameraIdentity: String, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard root.isFileURL, !cameraIdentity.isEmpty else { throw ThumbnailDiskError.unsafePath }
        try Self.ensureDirectory(root)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = canonicalRoot
        self.directory = canonicalRoot.appendingPathComponent("camera_" + Self.digest(cameraIdentity), isDirectory: true)
        self.now = now
        try ensureOpen()
        try touch()
    }

    func read(key: String) throws -> Data? {
        try ensureOpen()
        let file = target(key)
        guard let size = try Self.regularSize(file, parent: directory) else { return nil }
        guard size > 0, size <= Self.maximumBytes else { try remove(file); return nil }
        let data = try Self.readBounded(file, maximum: Self.maximumBytes)
        guard data.count == size, Self.validImage(data) else { try remove(file); return nil }
        return data
    }

    @discardableResult
    func write(_ data: Data, key: String) throws -> Bool {
        guard !data.isEmpty, data.count <= Self.maximumBytes, Self.validImage(data) else { return false }
        try ensureOpen()
        if try read(key: key) != nil { return true }
        let file = target(key)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? remove(temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard try Self.regularSize(temporary, parent: directory) == data.count else { throw ThumbnailDiskError.incompleteFile }
        // Refuse unexpected files/links; never follow an existing target or replace a complete cache hit.
        guard try Self.regularSize(file, parent: directory) == nil else { throw ThumbnailDiskError.unsafePath }
        try FileManager.default.moveItem(at: temporary, to: file)
        guard try Self.regularSize(file, parent: directory) == data.count else { throw ThumbnailDiskError.incompleteFile }
        return true
    }

    /// Caller must first prove complete metadata and no camera-event race. No legacy flat-cache import on iOS.
    @discardableResult
    func reconcile(validKeys: Set<String>) throws -> Int {
        try ensureOpen()
        let validNames = Set(validKeys.map { Self.digest($0) + ".jpg" })
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var removed = 0
        for file in entries where Self.isImageName(file.lastPathComponent) && !validNames.contains(file.lastPathComponent) {
            if (try? Self.regularSize(file, parent: directory)) != nil { try remove(file); removed += 1 }
        }
        return removed
    }

    /// Deletes only recognized regular cache files in validated direct child directories. Unknown/link entries are retained.
    @discardableResult
    func cleanupExpired() throws -> Int {
        try ensureOpen()
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var removed = 0
        for child in entries where child.standardizedFileURL.path != directory.path && Self.isCameraName(child.lastPathComponent) {
            do {
                try Self.validateDirectory(child)
                guard child.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == root else { continue }
                let marker = child.appendingPathComponent(".last_connected")
                let directoryDate = try child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                var last = Int64((directoryDate?.timeIntervalSince1970 ?? 0) * 1000)
                if let size = try Self.regularSize(marker, parent: child) {
                    guard size <= 128 else { continue }
                    let text = String(data: try Self.readBounded(marker, maximum: 128), encoding: .utf8)
                    let recorded = text.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                    let date = try marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    last = max(recorded, Int64((date?.timeIntervalSince1970 ?? 0) * 1000))
                }
                guard policy.cameraCacheExpired(lastConnectedMs: last, nowMs: now()) else { continue }
                let files = try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
                // Do not recursively remove an unknown subtree or even a symlink in a cache-looking directory.
                guard try files.allSatisfy({ file in
                    let name = file.lastPathComponent
                    guard name == ".last_connected" || Self.isImageName(name) || Self.isTemporaryName(name) else { return false }
                    return try Self.regularSize(file, parent: child) != nil
                }) else { continue }
                for file in files { try Self.removeRegular(file, parent: child) }
                try Self.validateDirectory(child)
                if try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty {
                    try FileManager.default.removeItem(at: child); removed += 1
                }
            } catch { continue } // A failed/unknown directory is not evidence that it is disposable.
        }
        return removed
    }

    private func target(_ key: String) -> URL { directory.appendingPathComponent(Self.digest(key) + ".jpg") }

    private func ensureOpen() throws {
        try Self.ensureDirectory(root)
        guard root.standardizedFileURL.resolvingSymlinksInPath() == root else { throw ThumbnailDiskError.unsafePath }
        try Self.ensureDirectory(directory)
        guard directory.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == root else {
            throw ThumbnailDiskError.unsafePath
        }
        // The OS may purge caches while the connection remains alive. Recreate without an old in-memory file index.
        if try Self.regularSize(directory.appendingPathComponent(".last_connected"), parent: directory) == nil { try touch() }
    }

    private func touch() throws {
        let marker = directory.appendingPathComponent(".last_connected")
        _ = try Self.regularSize(marker, parent: directory)
        try Data(String(now()).utf8).write(to: marker, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(now()) / 1000)], ofItemAtPath: marker.path)
    }

    private func remove(_ file: URL) throws { try Self.removeRegular(file, parent: directory) }
    private static func removeRegular(_ file: URL, parent: URL) throws {
        if try regularSize(file, parent: parent) != nil { try FileManager.default.removeItem(at: file) }
    }
    private static func ensureDirectory(_ url: URL) throws {
        do { try validateDirectory(url) }
        catch {
            guard isMissing(error) else { throw error }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try validateDirectory(url)
        }
    }
    private static func validateDirectory(_ url: URL) throws {
        // Inspect link metadata before directory metadata, including for a broken symbolic link.
        var fresh = url
        fresh.removeAllCachedResourceValues() // Long-lived directory URLs must observe OS cache purges/replacements.
        guard try fresh.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
              try fresh.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ThumbnailDiskError.unsafePath }
    }
    private static func regularSize(_ file: URL, parent: URL) throws -> Int? {
        try validateDirectory(parent)
        guard file.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL else { throw ThumbnailDiskError.unsafePath }
        do {
            var fresh = file
            fresh.removeAllCachedResourceValues()
            guard try fresh.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw ThumbnailDiskError.unsafePath }
            let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  file.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == parent.standardizedFileURL.resolvingSymlinksInPath() else {
                throw ThumbnailDiskError.unsafePath
            }
            return size
        } catch { if isMissing(error) { return nil }; throw error }
    }
    private static func isMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSCocoaErrorDomain && (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError)
    }
    private static func readBounded(_ file: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: maximum + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw ThumbnailDiskError.incompleteFile }
        }
        return data
    }
    private static func validImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: Substring) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    private static func isImageName(_ name: String) -> Bool { name.hasSuffix(".jpg") && isDigest(name.dropLast(4)) }
    private static func isCameraName(_ name: String) -> Bool { name.hasPrefix("camera_") && isDigest(name.dropFirst(7)) }
    private static func isTemporaryName(_ name: String) -> Bool { name.hasSuffix(".tmp") && UUID(uuidString: String(name.dropLast(4))) != nil }
}
