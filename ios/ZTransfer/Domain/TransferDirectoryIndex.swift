import Foundation

struct TransferDirectoryIndex: Sendable {
    let directory: URL
    private(set) var files: [String: [(size: UInt64, url: URL)]] = [:]
    private(set) var partials: [String: URL] = [:]

    static func scan(directory: URL) -> TransferDirectoryIndex {
        var index = TransferDirectoryIndex(directory: directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return index }
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]),
                  values.isDirectory != true,
                  values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".nkpart_") {
                index.partials[name] = url
                continue
            }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let key = exportedOriginalBaseName(name).lowercased()
            index.files[key, default: []].append((size: size, url: url))
        }
        return index
    }

    /// Mirrors Android's `sweepAndIndexExisting(deleteParts = true)` at app
    /// startup. Current-process retries use `scan` directly and keep their
    /// partials; only stale transfer/frame files are removed here.
    @discardableResult
    static func removeStaleTemporaryFiles(in directory: URL) -> Int {
        let fileManager = FileManager.default
        let datedDirectories = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []).filter {
            transferDatedFolderName($0.lastPathComponent) &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        var removed = 0
        for target in [directory] + datedDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            ) else { continue }
            for url in entries {
                let name = url.lastPathComponent
                guard name.hasPrefix(".nkpart_") || name.hasPrefix(".nkframe_") else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
                      values.isDirectory != true, values.isRegularFile == true else { continue }
                if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    func existingOriginal(for file: CameraFile) -> URL? {
        let key = exportedOriginalBaseName(file.fileName).lowercased()
        return files[key]?.first(where: { file.size == UInt64(UInt32.max) || $0.size == file.size })?.url
    }

    func completePartial(for file: CameraFile) -> URL? {
        guard file.size > 0, file.size != UInt64(UInt32.max) else { return nil }
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
        let key = exportedOriginalBaseName(url.lastPathComponent).lowercased()
        files[key, default: []].append((size: size, url: url))
    }
}

/// Android ExportedOriginalIndex: local-file identity is independent of queue
/// cards and camera handles. Removing a card must not make its original "new".
struct ExportedOriginalIndex: Sendable {
    private var destinations: [String: [String: [UInt64: URL]]] = [:]

    @discardableResult
    mutating func add(_ url: URL, size: UInt64, folderName: String?) -> Bool {
        let folder = folderName?.lowercased() ?? ""
        let name = exportedOriginalBaseName(url.lastPathComponent).lowercased()
        guard destinations[folder]?[name]?[size] != url else { return false }
        destinations[folder, default: [:]][name, default: [:]][size] = url
        return true
    }

    mutating func merge(_ index: TransferDirectoryIndex, folderName: String?) {
        for entries in index.files.values {
            for entry in entries { add(entry.url, size: entry.size, folderName: folderName) }
        }
    }

    @discardableResult
    mutating func record(_ items: [TransferQueueItem], root: URL) -> Bool {
        var changed = false
        for item in items {
            guard let output = item.outputURL,
                  output.deletingLastPathComponent() == transferDestinationDirectory(root: root, folderName: item.destinationFolderName)
            else { continue }
            if add(output, size: item.file.size, folderName: item.destinationFolderName) { changed = true }
        }
        return changed
    }

    func original(for file: CameraFile, folderName: String?) -> URL? {
        let name = exportedOriginalBaseName(file.fileName).lowercased()
        guard let sizes = destinations[folderName?.lowercased() ?? ""]?[name] else { return nil }
        return file.size == UInt64(UInt32.max) ? sizes.values.first : sizes[file.size]
    }
}

func transferDatedFolderName(_ name: String) -> Bool {
    name.range(of: #"^ZT\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
}
