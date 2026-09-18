import Foundation
import CryptoKit

/// Camera-scoped thumbnail disk cache.  The rules intentionally mirror
/// Android's `ThumbnailDiskCache`: no size based eviction, atomic writes, and
/// reconciliation only after a complete authoritative handle scan.
final class PhotoThumbnailDiskCache: @unchecked Sendable {
    static let maxIdleInterval: TimeInterval = 90 * 24 * 60 * 60

    final class CameraStore: @unchecked Sendable {
        fileprivate let root: URL
        fileprivate let directory: URL
        fileprivate let lock: NSLock
        fileprivate var index: Set<String>

        fileprivate init(root: URL, directory: URL) {
            self.root = root
            self.directory = directory
            self.lock = NSLock()
            self.index = []
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )) ?? []
            var names = Set<String>()
            for url in files {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if url.pathExtension.lowercased() == "jpg", size > 0 {
                    names.insert(url.lastPathComponent)
                } else if url.pathExtension.lowercased() == "tmp" || size == 0 {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            index = names
        }

        /// The OS may clear cache contents while the process remains alive.
        /// Android resets an existing CameraCache index when its directory is
        /// recreated; do the same before serving the next lookup.
        fileprivate func resetIndexAfterDirectoryRecreated() {
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            index = Set((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ))?.compactMap { url in
                guard url.pathExtension.lowercased() == "jpg",
                      ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { return nil }
                return url.lastPathComponent
            } ?? [])
        }

        func target(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: false) }

        func find(_ name: String, legacyName: String? = nil, alternateName: String? = nil) -> URL? {
            lock.lock(); defer { lock.unlock() }
            let fm = FileManager.default
            ensureDirectoryLocked()
            let targetURL = target(name)
            if index.contains(name), ((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
                return targetURL
            }
            index.remove(name)
            try? fm.removeItem(at: targetURL)
            for candidate in [alternateName, legacyName].compactMap({ $0 }).filter({ $0 != name }) {
                let source = candidate == alternateName ? target(candidate) : root.appendingPathComponent(candidate)
                guard ((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { continue }
                do {
                    try fm.moveItem(at: source, to: targetURL)
                    index.insert(name)
                    return targetURL
                } catch {
                    // A failed migration still leaves the old valid file usable.
                    if source.pathExtension.lowercased() == "jpg" { return source }
                }
            }
            return nil
        }

        private func ensureDirectoryLocked() {
            guard !fmDirectoryExists() else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            index.removeAll()
        }

        private func fmDirectoryExists() -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        @discardableResult
        func write(_ data: Data, as name: String) -> Bool {
            guard !data.isEmpty else { return false }
            lock.lock(); defer { lock.unlock() }
            let fm = FileManager.default
            ensureDirectoryLocked()
            let targetURL = target(name)
            if ((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
                index.insert(name); return true
            }
            let tempURL = directory.appendingPathComponent(name + ".tmp")
            do {
                try? fm.removeItem(at: tempURL)
                // The explicit .tmp + move is already the same atomic publish
                // boundary Android uses. Data.write(.atomic) created and
                // renamed a second hidden temporary file for every thumbnail.
                try data.write(to: tempURL)
                guard ((try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == data.count else {
                    try? fm.removeItem(at: tempURL); return false
                }
                try? fm.removeItem(at: targetURL)
                try fm.moveItem(at: tempURL, to: targetURL)
                guard ((try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == data.count else {
                    try? fm.removeItem(at: targetURL); return false
                }
                index.insert(name); return true
            } catch {
                try? fm.removeItem(at: tempURL)
                index.remove(name)
                return false
            }
        }

        func remove(_ name: String, url: URL? = nil) {
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.removeItem(at: url ?? target(name))
            index.remove(name)
        }

        fileprivate func cleanupTemporaryFiles() {
            lock.lock(); defer { lock.unlock() }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if file.pathExtension.lowercased() == "tmp" || size == 0 {
                    try? FileManager.default.removeItem(at: file)
                    index.remove(file.lastPathComponent)
                }
            }
        }

        /// Call only after a complete successful handle + metadata scan.
        @discardableResult
        func reconcile(validNames: Set<String>) -> Int {
            lock.lock(); defer { lock.unlock() }
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            var removed = 0
            for url in urls where url.pathExtension.lowercased() == "jpg" && !validNames.contains(url.lastPathComponent) {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
                index.remove(url.lastPathComponent)
            }
            return removed
        }
    }

    private let root: URL
    private let lock = NSLock()
    private var stores: [String: CameraStore] = [:]
    private var cleanupClaimed = false

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// Android owns one ThumbnailDiskCache for the ViewModel lifetime and
    /// launches its expiration sweep once. Shared iOS stores use this claim to
    /// preserve the same rule across camera reconnects.
    func claimCleanup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cleanupClaimed else { return false }
        cleanupClaimed = true
        return true
    }

    func openCamera(identity: String, now: Date = Date()) -> CameraStore {
        lock.lock(); defer { lock.unlock() }
        let directory = root.appendingPathComponent("camera_\(Self.sha256(identity))", isDirectory: true)
        let directoryAlreadyExisted = FileManager.default.fileExists(atPath: directory.path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(".last_connected")
        try? Data(String(now.timeIntervalSince1970).utf8).write(to: marker, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: directory.path)
        if let existing = stores[directory.lastPathComponent] {
            if !directoryAlreadyExisted { existing.resetIndexAfterDirectoryRecreated() }
            return existing
        }
        let store = CameraStore(root: root, directory: directory)
        stores[directory.lastPathComponent] = store
        return store
    }

    @discardableResult
    func cleanupExpired(now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.timeIntervalSince1970 - Self.maxIdleInterval
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var removed = 0
        for dir in dirs where dir.lastPathComponent.hasPrefix("camera_") && dir.hasDirectoryPath {
            let marker = dir.appendingPathComponent(".last_connected")
            let value = Double((try? String(contentsOf: marker, encoding: .utf8)) ?? "") ?? 0
            let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
            if max(value, mtime) < cutoff { try? fm.removeItem(at: dir); removed += 1 }
            else if let store = stores[dir.lastPathComponent] {
                // The background sweep may overlap an active scan. Android
                // takes the CameraCache lock here so it cannot delete the
                // explicit .tmp file while a thumbnail write is in progress.
                store.cleanupTemporaryFiles()
            }
            else {
                let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                for child in children where child.pathExtension.lowercased() == "tmp" || (((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0) {
                    try? fm.removeItem(at: child)
                }
            }
        }
        for file in dirs where file.pathExtension.lowercased() == "tmp" {
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        // Keep recent legacy flat files so a later camera lookup can migrate
        // them lazily, matching Android's 90-day cleanup window.
        for file in dirs where file.pathExtension.lowercased() == "jpg" {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
            if mtime < cutoff, (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    static func cacheFileName(fileName: String, size: UInt64, captureDate: String?) -> String {
        sha256("\(fileName)\u{0}\(size)\u{0}\(captureDate ?? "")") + ".jpg"
    }

    static func staCacheFileName(handle: UInt32, size: UInt64) -> String {
        sha256("sta\u{0}\(UInt64(handle))\u{0}\(size)") + ".jpg"
    }

    static func legacyCacheFileName(fileName: String, size: UInt64, captureDate: String?) -> String {
        let safe = fileName.map { $0.isLetter || $0.isNumber || ".-_".contains($0) ? $0 : "_" }
        return "\(String(safe))_\(size)_\(captureDate ?? "0").jpg"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
