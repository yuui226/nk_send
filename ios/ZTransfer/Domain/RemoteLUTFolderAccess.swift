import Foundation

enum RemoteLUTFolderAccessError: Error, Equatable { case missing, denied, read, tooMany }

/// Owns the security-scoped bookmark and exposes the same root + one-category scan
/// boundary as Android's LutFolderRepository. It returns metadata only; LUT bytes
/// are opened separately so a failed read cannot publish a partial folder snapshot.
final class RemoteLUTFolderAccess {
    // Foundation exposes the security-scope bit only to macOS in some iOS SDKs;
    // the raw bookmark option is nevertheless supported by iOS document providers.
    private static let securityScope = URL.BookmarkCreationOptions(rawValue: 1 << 4)
    private static let resolveSecurityScope = URL.BookmarkResolutionOptions(rawValue: 1 << 4)
    private let defaults: UserDefaults
    private let bookmarkKey = "remote_lut_folder_bookmark"
    private var scopedURL: URL?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func save(_ folder: URL) throws {
        let data = try folder.bookmarkData(options: Self.securityScope,
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
        _ = resolve()
    }

    func resolve() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.resolveSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let refreshed = try? url.bookmarkData(options: Self.securityScope,
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil) { defaults.set(refreshed, forKey: bookmarkKey) }
        return url
    }

    func scan() throws -> [RemoteLUTFile] {
        guard let root = resolve() else { throw RemoteLUTFolderAccessError.missing }
        guard root.startAccessingSecurityScopedResource() else { throw RemoteLUTFolderAccessError.denied }
        scopedURL = root
        defer { root.stopAccessingSecurityScopedResource(); scopedURL = nil }
        let manager = FileManager.default
        guard let rootItems = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw RemoteLUTFolderAccessError.read }
        var result: [RemoteLUTFile] = []
        var categories: [URL] = []
        for item in rootItems {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true { categories.append(item); continue }
            append(item, relative: item.lastPathComponent, size: values.fileSize, into: &result)
        }
        for category in categories {
            guard let children = try? manager.contentsOfDirectory(at: category, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw RemoteLUTFolderAccessError.read }
            for item in children {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values.isDirectory == true { continue }
                append(item, relative: category.lastPathComponent + "/" + item.lastPathComponent, size: values.fileSize, into: &result)
            }
        }
        guard result.count <= 10_000 else { throw RemoteLUTFolderAccessError.tooMany }
        return RemoteLUTCatalog.visibleFiles(result)
    }

    func read(_ file: RemoteLUTFile) throws -> Data {
        guard let root = resolve() else { throw RemoteLUTFolderAccessError.missing }
        guard root.startAccessingSecurityScopedResource() else { throw RemoteLUTFolderAccessError.denied }
        defer { root.stopAccessingSecurityScopedResource() }
        let url = root.appendingPathComponent(file.relativePath)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw RemoteLUTFolderAccessError.read }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { throw RemoteLUTFolderAccessError.read }
        return data
    }

    private func append(_ url: URL, relative: String, size: Int?, into result: inout [RemoteLUTFile]) {
        guard url.pathExtension.caseInsensitiveCompare("cube") == .orderedSame else { return }
        result.append(RemoteLUTFile(identifier: url.path, name: url.lastPathComponent, relativePath: relative, size: size.map(Int64.init)))
    }
}
