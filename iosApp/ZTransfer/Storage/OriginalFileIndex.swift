import Foundation
import ZTransferShared

struct OriginalIndexEntry: Sendable, Equatable {
    let name: String
    let size: Int64
    let folder: String?
    let url: URL
}

struct OriginalIndexUpdate: Sendable {
    let revision: Int64
    let baseRevision: Int64
    let fullSnapshot: Bool
    let entries: [OriginalIndexEntry]
}

enum OriginalIndexError: Error, LocalizedError {
    case unsafeRoot, incompleteMetadata
    var errorDescription: String? { "无法完整读取本地原片目录；已保留上次索引。" }
}

/// Accessed only by CameraOriginalStore's actor. No second observer, worker or persistent database.
/// A bounded journal lets the visible page consume actual completed files without rescanning disk.
final class OriginalFileIndexCache {
    private var entries: [URL: OriginalIndexEntry] = [:]
    private var journal: [(Int64, OriginalIndexEntry)] = []
    private var revision: Int64 = 0
    private var fullRevision: Int64 = 0
    private(set) var ready = false

    /// Exact previously published locator only. Naming/copy-suffix matching stays in shared.
    func entry(at url: URL) -> OriginalIndexEntry? { entries[url] }

    func scan(root: URL) throws {
        try Task.checkCancellation()
        guard root.isFileURL else { throw OriginalIndexError.unsafeRoot }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootValues: URLResourceValues
        do {
            let symbolic = try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
            guard symbolic == false else { throw OriginalIndexError.unsafeRoot }
            rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain &&
                (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError) {
                publishFull([:]); return // A genuinely absent app-managed root is empty, not an I/O failure.
            }
            throw error
        }
        guard rootValues.isDirectory == true else { throw OriginalIndexError.unsafeRoot }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var candidate: [URL: OriginalIndexEntry] = [:]
        func scanFolder(_ directory: URL, folder: String?, allowDateDirectories: Bool) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            for child in children {
                try Task.checkCancellation()
                let name = child.lastPathComponent
                // Exclude only app-private parts, not legitimate original names that start with a dot.
                if SandboxTransferFile.isPrivatePartName(name) { continue }
                // Inspect the link itself before requesting target-like metadata, including broken links.
                guard let symbolic = try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink else {
                    throw OriginalIndexError.incompleteMetadata
                }
                if symbolic { continue }
                let values = try child.resourceValues(forKeys: keys)
                guard let isDirectory = values.isDirectory, let isRegularFile = values.isRegularFile else {
                    throw OriginalIndexError.incompleteMetadata
                }
                if isDirectory {
                    if allowDateDirectories && NativeOriginalIndexPolicy.shared.isDateFolder(name: name) {
                        try scanFolder(child, folder: name, allowDateDirectories: false)
                    }
                    continue
                }
                guard isRegularFile else { continue }
                guard let size = values.fileSize, size >= 0 else { throw OriginalIndexError.incompleteMetadata }
                let resolved = child.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(canonicalRoot.path + "/"),
                      resolved.deletingLastPathComponent() == directory.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw OriginalIndexError.unsafeRoot
                }
                candidate[resolved] = OriginalIndexEntry(name: name, size: Int64(size), folder: folder, url: resolved)
            }
        }
        try scanFolder(canonicalRoot, folder: nil, allowDateDirectories: true)
        try Task.checkCancellation()
        publishFull(candidate) // Only a complete scan may replace the previous filesystem snapshot.
    }

    func record(_ saved: SavedCameraFile, folder: String?) {
        let entry = OriginalIndexEntry(name: saved.url.lastPathComponent, size: saved.bytes, folder: folder,
                                      url: saved.url.standardizedFileURL.resolvingSymlinksInPath())
        guard entries[entry.url] != entry else { return }
        entries[entry.url] = entry
        revision += 1
        journal.append((revision, entry))
        if journal.count > 1024 { journal.removeFirst(journal.count - 1024) }
    }

    func update(since base: Int64) -> OriginalIndexUpdate {
        let oldestBase = journal.first.map { $0.0 - 1 } ?? revision
        let full = !ready || base < fullRevision || base < oldestBase || base > revision
        let rows = full ? entries.values.sorted { $0.url.path < $1.url.path } : journal.filter { $0.0 > base }.map { $0.1 }
        return OriginalIndexUpdate(revision: revision, baseRevision: base, fullSnapshot: full, entries: rows)
    }

    private func publishFull(_ candidate: [URL: OriginalIndexEntry]) {
        guard !ready || candidate != entries else { return }
        entries = candidate
        ready = true
        revision += 1
        fullRevision = revision
        journal.removeAll(keepingCapacity: true)
    }
}
