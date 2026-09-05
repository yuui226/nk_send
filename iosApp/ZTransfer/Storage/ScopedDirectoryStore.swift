import Foundation

struct ResolvedExportDirectory {
    let url: URL
    let stale: Bool
}

/// Opaque bytes, not a path or an active security scope. Never log or export the bookmark.
struct ExportDirectorySelection: Sendable, Equatable {
    fileprivate let bookmark: Data
}

protocol ExportDirectoryAccess {
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
    func isDirectory(_ url: URL) throws -> Bool
    func bookmark(_ url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> ResolvedExportDirectory
}

private final class AppleExportDirectoryAccess: ExportDirectoryAccess {
    func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    func isDirectory(_ url: URL) throws -> Bool { try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve(_ bookmark: Data) throws -> ResolvedExportDirectory {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedExportDirectory(url: url, stale: stale)
    }
}

enum ExportDirectoryError: Error, LocalizedError {
    case missing, invalidBookmark, permissionLost, notDirectory, selectionChanged
    var errorDescription: String? {
        switch self {
        case .missing: return "请先通过系统文件选择器选择导出目录。"
        case .invalidBookmark: return "保存的目录授权无法读取，请重新选择目录；原文件未删除。"
        case .permissionLost: return "目录访问权限已不可用，请重新选择；原文件仍保留。"
        case .notDirectory: return "所选位置不是可访问的文件目录。"
        case .selectionChanged: return "保存目录授权已变化，请重新打开当前目录；不会改写到另一个位置。"
        }
    }
}

/// Persists only the user's explicit directory grant. Never treats a remembered path as permission.
/// Access is lexical and balanced on every return/throw. Provider IO must additionally coordinate
/// reads/writes; this grant store is not the full external-directory download executor.
actor ScopedDirectoryStore {
    private let bookmarkFile: URL
    private let access: ExportDirectoryAccess

    init(bookmarkFile: URL, access: ExportDirectoryAccess? = nil) {
        self.bookmarkFile = bookmarkFile
        self.access = access ?? AppleExportDirectoryAccess()
    }

    static func applicationStore() throws -> ScopedDirectoryStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return ScopedDirectoryStore(bookmarkFile: support.appendingPathComponent("ZTransfer/export-directory.bookmark"))
    }

    func select(_ url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL, access.start(url) else { throw ExportDirectoryError.permissionLost }
        defer { access.stop(url) }
        guard try access.isDirectory(url) else { throw ExportDirectoryError.notDirectory }
        let data = try access.bookmark(url)
        try persist(data)
    }

    /// Operation cannot escape the URL and assume continued access. A future async provider executor
    /// must own its own grant lifetime rather than retaining this URL after the closure returns.
    func withDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: bookmarkFile.path) else { throw ExportDirectoryError.missing }
        let size = try bookmarkFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...1_048_576).contains(size) else { throw ExportDirectoryError.invalidBookmark }
        let resolved = try access.resolve(Data(contentsOf: bookmarkFile))
        guard resolved.url.isFileURL, access.start(resolved.url) else { throw ExportDirectoryError.permissionLost }
        defer { access.stop(resolved.url) }
        guard try access.isDirectory(resolved.url) else { throw ExportDirectoryError.notDirectory }
        if resolved.stale { try persist(access.bookmark(resolved.url)) }
        try Task.checkCancellation()
        return try operation(resolved.url)
    }

    /// Freeze the selected grant. Later operations must reject a new/forgotten grant rather than redirect.
    func selection() throws -> ExportDirectorySelection {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: bookmarkFile.path) else { throw ExportDirectoryError.missing }
        let size = try bookmarkFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...1_048_576).contains(size) else { throw ExportDirectoryError.invalidBookmark }
        let data = try Data(contentsOf: bookmarkFile)
        guard (1...1_048_576).contains(data.count) else { throw ExportDirectoryError.invalidBookmark }
        return ExportDirectorySelection(bookmark: data)
    }

    func withDirectory<T>(selection expected: ExportDirectorySelection, _ operation: (URL) throws -> T) throws -> T {
        guard try selection() == expected else { throw ExportDirectoryError.selectionChanged }
        let resolved = try access.resolve(expected.bookmark)
        guard resolved.url.isFileURL, access.start(resolved.url) else { throw ExportDirectoryError.permissionLost }
        defer { access.stop(resolved.url) }
        guard try access.isDirectory(resolved.url) else { throw ExportDirectoryError.notDirectory }
        // A pinned operation must not rewrite a newer grant. The ordinary owner can refresh stale data.
        try Task.checkCancellation()
        return try operation(resolved.url)
    }

    func displayName() throws -> String { try withDirectory { $0.lastPathComponent } }

    /// Forget only the app's one known bookmark, never the selected directory or its contents.
    func forget() throws {
        if FileManager.default.fileExists(atPath: bookmarkFile.path) { try FileManager.default.removeItem(at: bookmarkFile) }
    }

    private func persist(_ data: Data) throws {
        guard bookmarkFile.isFileURL, (1...1_048_576).contains(data.count) else { throw ExportDirectoryError.invalidBookmark }
        try FileManager.default.createDirectory(at: bookmarkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: bookmarkFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
