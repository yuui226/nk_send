import Foundation

/// Android directoryLookupKey: connection modes may report different prefixes
/// for the same numbered original. Type, size and destination remain separate.
func transferDirectoryLookupKey(_ name: String) -> String {
    let base = exportedOriginalBaseName(name).lowercased()
    if let range = base.range(of: #"([0-9]+)\.([a-z0-9]+)$"#, options: .regularExpression) {
        return "number:" + base[range]
    }
    return "name:" + base
}


/// Like Android photoFrameSessionName, identify this process's in-flight
/// derivatives while preserving cleanup of older .nkframe_ names.
enum PhotoFrameTemporaryFiles {
    private static let sessionID = UUID()
    static var currentPrefix: String { ".nkframe_frame-\(sessionID.uuidString)_" }
    static func makeName() -> String { currentPrefix + UUID().uuidString + ".jpg" }
    static func isCurrent(_ name: String) -> Bool { name.hasPrefix(currentPrefix) }
}

struct IndexedTransferOriginal: Equatable, Sendable {
    var name: String
    var size: UInt64
    var url: URL
    fileprivate var revision: UInt64 = 0

    init(url: URL, size: UInt64, name: String? = nil) {
        self.url = url; self.size = size; self.name = name ?? url.lastPathComponent
    }
}

/// ExistingOriginalDocument: query fresh metadata and open for reading, without
/// consuming contents. Permission/provider errors are not evidence of deletion.
func readExistingTransferOriginal(_ cached: IndexedTransferOriginal) throws -> IndexedTransferOriginal? {
    do {
        var url = cached.url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .nameKey])
        if values.isDirectory == true { throw TransferOriginalReadError.directory }
        let handle = try FileHandle(forReadingFrom: url)
        try handle.close()
        var actual = cached
        if let name = values.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { actual.name = name }
        if let size = values.fileSize, size >= 0 { actual.size = UInt64(size) }
        return actual
    } catch {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) ||
            ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return nil }
        throw error
    }
}

private enum TransferOriginalReadError: LocalizedError {
    case directory
    var errorDescription: String? { "Indexed original is a directory" }
}

struct TransferDirectoryIndex: Sendable {
    let directory: URL
    private(set) var files: [String: [IndexedTransferOriginal]] = [:]
    private var exactNames: [String: IndexedTransferOriginal] = [:]
    private var revision: UInt64 = 0
    private(set) var partials: [String: URL] = [:]

    static func scan(directory: URL) -> TransferDirectoryIndex {
        (try? read(directory: directory)) ?? TransferDirectoryIndex(directory: directory)
    }

    static func read(directory: URL) throws -> TransferDirectoryIndex {
        var index = TransferDirectoryIndex(directory: directory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: []
        )
        for url in entries {
            try Task.checkCancellation()
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) }
            catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { continue }
                throw error
            }
            guard values.isDirectory != true,
                  values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            if LosslessCropTemporaryFiles.recognizes(name) { continue }
            if name.hasPrefix(".nkpart_") {
                index.partials[name] = url
                continue
            }
            let size = UInt64(max(0, values.fileSize ?? 0))
            index.addOriginal(url, size: size)
        }
        return index
    }

    /// Mirrors Android's `sweepAndIndexExisting(deleteParts = true)` at app
    /// startup. Current-process retries use `scan` directly and keep their
    /// partials; only stale transfer/frame files are removed here.
    @discardableResult
    static func removeStaleTemporaryFiles(in directory: URL) -> Int {
        let fileManager = FileManager.default
        let storageDirectories = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []).filter {
            (transferDatedFolderName($0.lastPathComponent) || $0.lastPathComponent.hasPrefix("ZT-")) &&
            $0.lastPathComponent.caseInsensitiveCompare(transferFrameOutputDirectoryName) != .orderedSame &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let originals = [directory] + storageDirectories
        let targets = originals + originals.map { $0.appendingPathComponent(transferFrameOutputDirectoryName, isDirectory: true) }
        var removed = 0
        for target in targets {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            ) else { continue }
            for url in entries {
                let name = url.lastPathComponent
                if LosslessCropTemporaryFiles.recognizes(name) {
                    guard !LosslessCropTemporaryFiles.isCurrent(name) else { continue }
                    if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
                    continue
                }
                guard name.hasPrefix(".nkpart_") || name.hasPrefix(".nkframe_") else { continue }
                guard !PhotoFrameTemporaryFiles.isCurrent(name) else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
                      values.isDirectory != true, values.isRegularFile == true else { continue }
                if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    func existingOriginal(for file: CameraFile) -> URL? {
        candidate(for: file)?.url
    }

    func candidate(for file: CameraFile) -> IndexedTransferOriginal? {
        if let exact = exactNames[file.fileName], file.size == UInt64(UInt32.max) || exact.size == file.size {
            return exact
        }
        return files[transferDirectoryLookupKey(file.fileName)]?
            .first(where: { file.size == UInt64(UInt32.max) || $0.size == file.size })
    }

    /// Recheck only candidates. Invalid originals fall through to surviving
    /// copies; edited/renamed documents retain their new name and size.
    mutating func findVerified(for file: CameraFile,
                              verify: (IndexedTransferOriginal) throws -> IndexedTransferOriginal? = readExistingTransferOriginal,
                              onInvalidated: (IndexedTransferOriginal) -> Void = { _ in }) throws -> IndexedTransferOriginal? {
        while let cached = candidate(for: file) {
            try Task.checkCancellation()
            let actual = try verify(cached)
            try Task.checkCancellation()
            // A reader may construct a fresh value. The index's replacement
            // revision is not filesystem metadata and must not cause a loop.
            if let actual, actual.name == cached.name, actual.size == cached.size,
               actual.url == cached.url { return cached }
            if remove(cached) {
                if let actual { addOriginal(actual) }
                onInvalidated(cached)
            }
        }
        return nil
    }

    @discardableResult mutating func remove(_ entry: IndexedTransferOriginal) -> Bool {
        guard exactNames[entry.name] == entry else { return false }
        exactNames[entry.name] = nil
        let key = transferDirectoryLookupKey(entry.name)
        files[key]?.removeAll { $0 == entry }
        if files[key]?.isEmpty == true { files[key] = nil }
        return true
    }

    func completePartial(for file: CameraFile) -> URL? {
        // Android discards still-image parts before its complete-part shortcut.
        // Matching byte counts do not prove that a failed photo was received
        // successfully, including parts left by an earlier app version.
        guard supportsVideoResume(fileName: file.fileName),
              file.size > 0, file.size != UInt64(UInt32.max) else { return nil }
        let name = transferPartialFileName(size: file.size, captureDate: file.captureDate, fileName: file.fileName)
        guard let url = partials[name],
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              UInt64(max(0, size)) == file.size else { return nil }
        return url
    }

    mutating func removePartial(_ url: URL) {
        if let key = partials.first(where: { $0.value == url })?.key {
            partials.removeValue(forKey: key)
        }
    }

    mutating func addOriginal(_ url: URL, size: UInt64) {
        addOriginal(IndexedTransferOriginal(url: url, size: size))
    }

    mutating func addOriginal(_ value: IndexedTransferOriginal) {
        var value = value
        revision &+= 1
        value.revision = revision
        let name = value.name
        let key = transferDirectoryLookupKey(name)
        // Android replaces the exact entry and removes its old size from the
        // normalized bucket. A rewritten local file cannot leave a stale hit.
        if exactNames.updateValue(value, forKey: name) != nil {
            files[key]?.removeAll { $0.name == name }
        }
        files[key, default: []].append(value)
    }
}

/// Android ExportedOriginalIndex: local-file identity is independent of queue
/// cards and camera handles. Removing a card must not make its original "new".
struct ExportedOriginalIndex: Sendable {
    private var destinations: [String: [String: [UInt64: URL]]] = [:]

    @discardableResult
    mutating func add(_ url: URL, size: UInt64, folderName: String?, name: String? = nil) -> Bool {
        let folder = folderName?.lowercased() ?? ""
        let name = transferDirectoryLookupKey(name ?? url.lastPathComponent)
        return add(url, size: size, folderKey: folder, lookupKey: name)
    }

    /// Directory scans already normalized their keys. Do not run a regular
    /// expression for every entry while holding the shared-store lock.
    @discardableResult
    mutating func add(_ url: URL, size: UInt64, folderKey: String, lookupKey: String) -> Bool {
        guard destinations[folderKey]?[lookupKey]?[size] != url else { return false }
        destinations[folderKey, default: [:]][lookupKey, default: [:]][size] = url
        return true
    }

    /// forgetExistingExport: only the observed URL/size/destination may leave.
    @discardableResult
    mutating func remove(_ entry: IndexedTransferOriginal, folderName: String?) -> Bool {
        let folder = folderName?.lowercased() ?? ""
        let name = transferDirectoryLookupKey(entry.name)
        guard destinations[folder]?[name]?[entry.size] == entry.url else { return false }
        destinations[folder]?[name]?[entry.size] = nil
        if destinations[folder]?[name]?.isEmpty == true { destinations[folder]?[name] = nil }
        if destinations[folder]?.isEmpty == true { destinations[folder] = nil }
        return true
    }

    mutating func merge(_ index: TransferDirectoryIndex, folderName: String?) {
        for entries in index.files.values {
            for entry in entries { add(entry.url, size: entry.size, folderName: folderName, name: entry.name) }
        }
    }

    func original(for file: CameraFile, folderName: String?) -> URL? {
        let name = transferDirectoryLookupKey(file.fileName)
        guard let sizes = destinations[folderName?.lowercased() ?? ""]?[name] else { return nil }
        return file.size == UInt64(UInt32.max) ? sizes.values.first : sizes[file.size]
    }
}

func transferDatedFolderName(_ name: String) -> Bool {
    name.range(of: #"^ZT\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
}

/// Android scans only the destination buckets selected by the current mode;
/// derived effects live in their own child and must never count as originals.
func transferStorageChildDirectory(_ name: String, mode: TransferStorageMode) -> Bool {
    guard name.caseInsensitiveCompare(transferFrameOutputDirectoryName) != .orderedSame else { return false }
    switch mode {
    case .unified:
        return false
    case .byDay:
        return transferDatedFolderName(name)
    case .byType:
        return isValidTransferFolderName(name)
    }
}
