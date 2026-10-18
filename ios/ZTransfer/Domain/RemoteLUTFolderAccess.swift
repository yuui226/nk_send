import Foundation
import Combine

enum RemoteLUTFolderAccessError: Error, Equatable { case missing, denied, read, tooMany }

/// Owns the security-scoped bookmark and exposes the same root + one-category scan
/// boundary as Android's LutFolderRepository. It returns metadata only; LUT bytes
/// are opened separately so a failed read cannot publish a partial folder snapshot.
final class RemoteLUTFolderAccess {
    enum Scope {
        case monitor, photo, pictureControl

        fileprivate var bookmarkKey: String {
            switch self {
            case .monitor: "remote_lut_folder_bookmark"
            case .photo: "photo_lut_folder_bookmark"
            case .pictureControl: "picture_control_folder_bookmark"
            }
        }
    }
    // Foundation exposes the security-scope bit only to macOS in some iOS SDKs;
    // the raw bookmark option is nevertheless supported by iOS document providers.
    private static let securityScope = URL.BookmarkCreationOptions(rawValue: 1 << 4)
    private static let resolveSecurityScope = URL.BookmarkResolutionOptions(rawValue: 1 << 4)
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private var scopedURL: URL?

    init(defaults: UserDefaults = .standard, scope: Scope = .monitor) {
        self.defaults = defaults
        bookmarkKey = scope.bookmarkKey
    }

    var bookmarkData: Data? { defaults.data(forKey: bookmarkKey) }

    func save(_ folder: URL) throws {
        let data = try folder.bookmarkData(options: Self.securityScope,
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
        _ = resolve()
    }

    struct PreparedFolder: Sendable {
        let bookmark: Data
        let files: [RemoteLUTFile]
        let root: URL?
        init(bookmark: Data, files: [RemoteLUTFile], root: URL? = nil) {
            self.bookmark = bookmark; self.files = files; self.root = root
        }
    }

    /// Prepare without replacing the live grant/bookmark. The caller publishes
    /// only after accepting the result (and, for async callers, its generation).
    static func prepareFolder(_ folder: URL, fileExtension: String = "cube",
                              operations: DirectoryAccessOperations = .system,
                              checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> PreparedFolder {
        guard operations.start(folder) else { throw RemoteLUTFolderAccessError.denied }
        defer { operations.stop(folder) }
        try checkCancelled()
        let bookmark: Data
        do {
            bookmark = try folder.bookmarkData(options: securityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch { throw folderFailure(error, isRoot: true) }
        let files = try scanContents(folder, fileExtension: fileExtension, checkCancelled: checkCancelled)
        try checkCancelled()
        return PreparedFolder(bookmark: bookmark, files: files, root: folder)
    }

    static func resolveBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: resolveSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func prepareBookmark(_ data: Data?, fileExtension: String = "cube", checkCancelled: () throws -> Void) throws -> PreparedFolder {
        try checkCancelled()
        guard let data else { throw RemoteLUTFolderAccessError.missing }
        var stale = false
        let folder: URL
        do {
            folder = try URL(resolvingBookmarkData: data, options: resolveSecurityScope,
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw RemoteLUTFolderAccessError.missing }
        return try prepareFolder(folder, fileExtension: fileExtension, checkCancelled: checkCancelled)
    }

    func commit(_ prepared: PreparedFolder) {
        defaults.set(prepared.bookmark, forKey: bookmarkKey)
    }

    struct ResolvedFolder: Sendable {
        let url: URL
        let bookmark: Data
    }

    static func prepareResolution(_ data: Data?) -> ResolvedFolder? {
        guard let data else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.resolveSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let refreshed = stale ? (try? url.bookmarkData(options: Self.securityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)) : nil
        return ResolvedFolder(url: url, bookmark: refreshed ?? data)
    }

    func commitResolution(_ resolved: ResolvedFolder) {
        if bookmarkData != resolved.bookmark { defaults.set(resolved.bookmark, forKey: bookmarkKey) }
    }

    func resolve() -> URL? {
        guard let resolved = Self.prepareResolution(bookmarkData) else { return nil }
        commitResolution(resolved)
        return resolved.url
    }

    func scan() throws -> [RemoteLUTFile] {
        guard let root = resolve() else { throw RemoteLUTFolderAccessError.missing }
        guard root.startAccessingSecurityScopedResource() else { throw RemoteLUTFolderAccessError.denied }
        scopedURL = root
        defer { root.stopAccessingSecurityScopedResource(); scopedURL = nil }
        return try Self.scanContents(root)
    }

    /// Enumerate incrementally; the budget counts every entry, not only LUTs.
    static func scanContents(_ root: URL, fileExtension: String = "cube", entryLimit: Int = 10_000,
                             checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> [RemoteLUTFile] {
        try checkCancelled()
        do {
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw RemoteLUTFolderAccessError.missing
            }
        } catch { throw folderFailure(error, isRoot: true) }
        var result: [RemoteLUTFile] = []
        var categories: [URL] = []
        var total = 0
        var seenFiles = Set<String>()
        var seenDirectories: Set<String> = [root.resolvingSymlinksInPath().path]
        func enumerate(_ directory: URL, category: String?) throws {
            try checkCancelled()
            var enumerationError: Error?
            guard let entries = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else { throw RemoteLUTFolderAccessError.read }
            while let item = entries.nextObject() as? URL {
                try checkCancelled()
                total += 1
                guard total <= entryLimit else { throw RemoteLUTFolderAccessError.tooMany }
                let values: URLResourceValues
                do { values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) }
                catch { throw RemoteLUTFolderAccessError.read }
                if values.isDirectory == true {
                    if category == nil && seenDirectories.insert(item.resolvingSymlinksInPath().path).inserted { categories.append(item) }
                    continue
                }
                let relative = category.map { $0 + "/" + item.lastPathComponent } ?? item.lastPathComponent
                guard item.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame,
                      seenFiles.insert(item.resolvingSymlinksInPath().path).inserted else { continue }
                append(item, relative: relative, size: values.fileSize, modified: values.contentModificationDate, into: &result)
            }
            try checkCancelled()
            if let enumerationError { throw folderFailure(enumerationError, isRoot: category == nil) }
        }
        try enumerate(root, category: nil)
        for category in categories { try enumerate(category, category: category.lastPathComponent) }
        return RemoteLUTCatalog.visibleFiles(result, fileExtension: fileExtension)
    }

    func read(_ file: RemoteLUTFile) throws -> Data {
        guard let root = resolve() else { throw RemoteLUTFolderAccessError.missing }
        guard root.startAccessingSecurityScopedResource() else { throw RemoteLUTFolderAccessError.denied }
        defer { root.stopAccessingSecurityScopedResource() }
        let url = root.appendingPathComponent(file.relativePath)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw RemoteLUTFolderAccessError.read }
        return try Self.readBounded(url)
    }

    static func readBookmark(_ bookmark: Data?, file: RemoteLUTFile,
                             checkCancelled: () throws -> Void) throws -> Data {
        try withScopedFile(bookmark, file: file, checkCancelled: checkCancelled) {
            try readBounded($0, checkCancelled: checkCancelled)
        }
    }

    static func parseBookmark(_ bookmark: Data?, file: RemoteLUTFile,
                              cache: ParsedLUTCache = .shared,
                              operations: DirectoryAccessOperations = .system,
                              checkCancelled: () throws -> Void) throws -> CubeLUT {
        do {
            return try withScopedFile(bookmark, file: file, operations: operations, checkCancelled: checkCancelled) {
                try parseFile($0, cache: cache, checkCancelled: checkCancelled)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Catalog identifiers are absolute file paths. Even a revoked grant
            // must invalidate a previously parsed table before a later retry.
            cache.remove(URL(fileURLWithPath: file.identifier).absoluteString)
            throw error
        }
    }

    static func withScopedFile<Value>(_ bookmark: Data?, file: RemoteLUTFile,
                                              operations: DirectoryAccessOperations = .system,
                                              checkCancelled: () throws -> Void,
                                              body: (URL) throws -> Value) throws -> Value {
        try checkCancelled()
        guard let bookmark else { throw RemoteLUTFolderAccessError.missing }
        var stale = false
        let root = try URL(resolvingBookmarkData: bookmark, options: resolveSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        guard operations.start(root) else { throw RemoteLUTFolderAccessError.denied }
        defer { operations.stop(root) }
        let url = root.appendingPathComponent(file.relativePath)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw RemoteLUTFolderAccessError.read
        }
        return try body(url)
    }

    static func parseFile(_ url: URL, cache: ParsedLUTCache = .shared,
                          checkCancelled: () throws -> Void,
                          read: ((URL) throws -> Data)? = nil) throws -> CubeLUT {
        let key = url.absoluteString
        func stamp() throws -> ParsedLUTCache.Stamp {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return .init(size: values.fileSize.map(Int64.init), modified: values.contentModificationDate)
        }
        try checkCancelled()
        let before: ParsedLUTCache.Stamp
        do { before = try stamp() }
        catch { cache.remove(key); throw error }
        try checkCancelled()
        guard (before.size ?? 0) <= CubeLUTParser.maxBytes else {
            cache.remove(key)
            throw CubeLUTFailure.tooLarge
        }
        if let table = cache.get(key, stamp: before) { try checkCancelled(); return table }
        let data = try read?(url) ?? readBounded(url, checkCancelled: checkCancelled)
        let table = try CubeLUTParser.parse(data, checkCancelled: checkCancelled)
        try checkCancelled()
        if before == (try stamp()) { cache.put(key, stamp: before, table: table) }
        return table
    }

    /// Check current metadata, then enforce the same limit on actual bytes:
    /// a provider may omit size or grow the file after the metadata query.
    static func readBounded(_ url: URL,
                            checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> Data {
        try checkCancelled()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, size > CubeLUTParser.maxBytes { throw CubeLUTFailure.tooLarge }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw RemoteLUTFolderAccessError.read }
        defer { try? handle.close() }
        var result = Data()
        while true {
            try checkCancelled()
            // Read at most one byte beyond the budget to detect unknown-size overflow.
            let count = min(64 * 1024, CubeLUTParser.maxBytes - result.count + 1)
            let block: Data
            do { block = try handle.read(upToCount: count) ?? Data() }
            catch { throw RemoteLUTFolderAccessError.read }
            try checkCancelled()
            if block.isEmpty { return result }
            guard block.count <= CubeLUTParser.maxBytes - result.count else {
                throw CubeLUTFailure.tooLarge
            }
            result.append(block)
        }
    }

    /// A failed child must preserve the root grant and current recipe.
    static func folderFailure(_ error: Error, isRoot: Bool) -> RemoteLUTFolderAccessError {
        guard isRoot else { return .read }
        if let failure = error as? RemoteLUTFolderAccessError { return failure }
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let failure = current else { break }
            if failure.domain == NSCocoaErrorDomain {
                if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return .missing }
                if failure.code == NSFileReadNoPermissionError { return .denied }
            }
            if failure.domain == NSPOSIXErrorDomain {
                if failure.code == Int(ENOENT) || failure.code == Int(ENOTDIR) { return .missing }
                if failure.code == Int(EACCES) || failure.code == Int(EPERM) { return .denied }
            }
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .read
    }

    private static func append(_ url: URL, relative: String, size: Int?, modified: Date?, into result: inout [RemoteLUTFile]) {
        result.append(RemoteLUTFile(identifier: url.path, name: url.lastPathComponent, relativePath: relative, size: size.map(Int64.init), modified: modified))
    }
}

/// Android SerialPresetQueue: one process-wide reader, independent request tickets.
/// Cancelling obsolete LUT work must not discard another feature's queued scan.
@MainActor
final class PresetIOQueue {
    static let shared = PresetIOQueue()

    final class Ticket: @unchecked Sendable {
        fileprivate let id = UUID()
        private let lock = NSLock()
        private var cancelled = false
        private let onCancel: @Sendable (UUID) -> Void
        init(onCancel: @escaping @Sendable (UUID) -> Void = { _ in }) { self.onCancel = onCancel }
        func cancel() {
            lock.lock()
            let changed = !cancelled
            cancelled = true
            lock.unlock()
            if changed { onCancel(id) }
        }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    }
    private struct Work: Sendable {
        let ticket: Ticket
        let run: @Sendable () async -> Void
    }
    private var active = false
    private var pending: [Work] = []
    private var cleanups: [@Sendable () throws -> Void] = []
    private let onCallbackFailure: @Sendable (Error) -> Void
    init(onCallbackFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.onCallbackFailure = onCallbackFailure
    }
    func cleanup(_ action: @escaping @Sendable () throws -> Void) { cleanups.append(action) }
    private func takeCleanups() -> [@Sendable () throws -> Void] {
        let result = cleanups; cleanups.removeAll(); return result
    }
    @discardableResult
    func submit<Value: Sendable>(
        action: @escaping @Sendable (Ticket) throws -> Value,
        discard: @escaping @Sendable (Result<Value, Error>) throws -> Void = { _ in },
        deliver: @escaping @MainActor (Result<Value, Error>) throws -> Void
    ) -> Ticket {
        let ticket = Ticket { [weak self] id in
            Task { @MainActor in self?.pending.removeAll { $0.ticket.id == id } }
        }
        let failure = onCallbackFailure
        let work = Work(ticket: ticket) { [weak self] in
            guard !ticket.isCancelled else { return }
            let result = Result { try action(ticket) }
            let delivered = await MainActor.run {
                guard !ticket.isCancelled else { return false }
                // A callback may commit before throwing; never discard afterward.
                do { try deliver(result) } catch { failure(error) }
                return true
            }
            if !delivered { do { try discard(result) } catch { failure(error) } }
            while let self {
                let cleanups = await self.takeCleanups()
                if cleanups.isEmpty { break }
                for cleanup in cleanups { do { try cleanup() } catch { failure(error) } }
            }
        }
        if active { pending.append(work) } else { start(work) }
        return ticket
    }
    private func start(_ work: Work) {
        active = true
        Task.detached(priority: .utility) {
            await work.run()
            await self.finished()
        }
    }
    private func finished() {
        active = false
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if !next.ticket.isCancelled { start(next); return }
        }
    }
}

// Preserve existing LUT call sites while sharing the same reader with NP3.
typealias LUTIOQueue = PresetIOQueue

/// UI request lifetime is independent of an uncooperative worker's lifetime.
@MainActor
final class LUTRequestController: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var pendingIdentifier: String?
    private var generation: UInt64 = 0
    private var ticket: LUTIOQueue.Ticket?
    private var timer: Task<Void, Never>?
    private let queue: LUTIOQueue
    init(queue: LUTIOQueue = .shared) { self.queue = queue }

    func cancel() {
        generation &+= 1
        ticket?.cancel()
        ticket = nil
        timer?.cancel()
        timer = nil
        if loading { loading = false }
        if pendingIdentifier != nil { pendingIdentifier = nil }
    }

    func submit<Value: Sendable>(
        timeout: Duration = .seconds(10),
        selectionIdentifier: String? = nil,
        action: @escaping @Sendable (LUTIOQueue.Ticket) throws -> Value,
        onTimeout: @escaping @MainActor () -> Void,
        deliver: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        cancel()
        if pendingIdentifier != selectionIdentifier { pendingIdentifier = selectionIdentifier }
        if !loading { loading = true }
        let id = generation
        ticket = queue.submit(action: action) { [weak self] result in
            guard let self, self.generation == id else { return }
            self.timer?.cancel()
            self.timer = nil
            self.ticket = nil
            if self.loading { self.loading = false }
            if self.pendingIdentifier != nil { self.pendingIdentifier = nil }
            deliver(result)
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == id else { return }
            self.cancel()
            onTimeout()
        }
    }

    deinit { ticket?.cancel(); timer?.cancel() }
}
