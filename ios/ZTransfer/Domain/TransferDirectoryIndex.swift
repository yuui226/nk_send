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

    mutating func addOriginal(_ url: URL, size: UInt64) {
        let key = exportedOriginalBaseName(url.lastPathComponent).lowercased()
        files[key, default: []].append((size: size, url: url))
    }
}

func transferDatedFolderName(_ name: String) -> Bool {
    name.range(of: #"^ZT\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
}
