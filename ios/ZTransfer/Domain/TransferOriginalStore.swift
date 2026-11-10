import Foundation

/// Android's exported-original index is independent of queue history. All
/// mutable state below is lock-protected; filesystem work never holds the lock.
final class TransferOriginalStore: @unchecked Sendable {
    struct Bucket: Sendable {
        let folder: String?
        let index: TransferDirectoryIndex
    }
    struct Membership: Sendable {
        let revision: UInt64
        let ids: Set<UInt32>
        let publishedIDs: Set<UInt32>
    }
    typealias Scanner = @Sendable (URL, TransferStorageMode) async throws -> [Bucket]
    private struct Key: Hashable {
        let folder: String
        let name: String
        let size: UInt64
        init(_ entry: IndexedTransferOriginal, folder: String?) {
            self.folder = folder?.lowercased() ?? ""
            name = transferDirectoryLookupKey(entry.name); size = entry.size
        }
        init(folderKey: String, lookupKey: String, size: UInt64) {
            folder = folderKey; name = lookupKey; self.size = size
        }
    }
    private let lock = NSLock()
    private var directory: URL?
    private var index = ExportedOriginalIndex()
    private var revision: UInt64 = 0
    private var mutations: [Key: UInt64] = [:]
    private var publications: [Key: (revision: UInt64, id: UInt32)] = [:]
    private var completedModes: Set<String> = []
    private var scanID: UUID?
    private var scanMode: String?
    private var scanTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let scan: Scanner
    private let accessOperations: DirectoryAccessOperations

    init(accessOperations: DirectoryAccessOperations = .system, scan: Scanner? = nil) {
        self.accessOperations = accessOperations
        self.scan = scan ?? { root, mode in
            var buckets = [Bucket(folder: nil, index: try TransferDirectoryIndex.read(directory: root))]
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            for child in children where transferStorageChildDirectory(child.lastPathComponent, mode: mode) {
                try Task.checkCancellation()
                guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                buckets.append(Bucket(folder: child.lastPathComponent, index: try TransferDirectoryIndex.read(directory: child)))
            }
            return buckets
        }
    }

    deinit {
        scanTask?.cancel()
        observers.values.forEach { $0.finish() }
    }

    func select(_ root: URL?, reset: Bool = false) {
        let old: (Bool, Task<Void, Never>?) = lock.withLock {
            guard reset || directory != root else { return (false, nil) }
            let previous = scanTask
            directory = root; index = ExportedOriginalIndex(); revision &+= 1
            mutations.removeAll(); publications.removeAll(); completedModes.removeAll()
            scanID = nil; scanMode = nil; scanTask = nil
            return (true, previous)
        }
        old.1?.cancel()
        if old.0 { notify() }
    }

    /// Share scans across catalog batches/routes. A mode adds its destination
    /// buckets; changing the root invalidates every old scan and publication.
    func refresh(directory root: URL?, mode: TransferStorageMode, reset: Bool = false) {
        select(root, reset: reset)
        guard let root else { return }
        let old: Task<Void, Never>? = lock.withLock {
            guard directory == root, !completedModes.contains(mode.rawValue),
                  scanID == nil || scanMode != mode.rawValue else { return nil }
            let old = scanTask, id = UUID(), started = revision
            scanID = id; scanMode = mode.rawValue
            let scan = scan, accessOperations = accessOperations
            scanTask = Task.detached(priority: .utility) { [weak self] in
                let access = DirectoryAccessLease(url: root, operations: accessOperations)
                defer { withExtendedLifetime(access) {} }
                do {
                    try Task.checkCancellation()
                    let buckets = try await scan(root, mode)
                    try Task.checkCancellation()
                    self?.finishScan(id: id, root: root, mode: mode, started: started, buckets: buckets)
                } catch { self?.finishScan(id: id, root: root, mode: mode, started: started, buckets: nil) }
            }
            return old
        }
        old?.cancel()
    }

    private func finishScan(id: UUID, root: URL, mode: TransferStorageMode, started: UInt64, buckets: [Bucket]?) {
        let changed = lock.withLock {
            guard scanID == id, directory == root else { return false }
            scanTask = nil; scanID = nil; scanMode = nil
            defer { mutations.removeAll(keepingCapacity: true) }
            guard let buckets else { return false } // Preserve successful concurrent publications on IO failure.
            for bucket in buckets {
                let folderKey = bucket.folder?.lowercased() ?? ""
                for (lookupKey, entries) in bucket.index.files {
                    for entry in entries where mutations[Key(folderKey: folderKey, lookupKey: lookupKey, size: entry.size), default: 0] <= started {
                        _ = index.add(entry.url, size: entry.size, folderKey: folderKey, lookupKey: lookupKey)
                    }
                }
            }
            completedModes.insert(mode.rawValue); revision &+= 1
            return true
        }
        if changed { notify() }
    }

    @discardableResult
    func record(_ entry: IndexedTransferOriginal, root: URL, folder: String?, fileID: UInt32? = nil) -> Bool {
        let changed = lock.withLock {
            guard directory == root else { return false }
            revision &+= 1
            let key = Key(entry, folder: folder)
            if scanID != nil { mutations[key] = revision }
            let changed = index.add(entry.url, size: entry.size, folderKey: key.folder, lookupKey: key.name)
            if changed { publications[key] = fileID.map { (revision, $0) } }
            return changed
        }
        if changed { notify() }
        return changed
    }

    @discardableResult
    func forget(_ entry: IndexedTransferOriginal, root: URL, folder: String?) -> Bool {
        let changed = lock.withLock {
            guard directory == root else { return false }
            revision &+= 1
            let key = Key(entry, folder: folder)
            // Mark even if a scan has not populated the slot yet; its older
            // result must not resurrect the just-verified missing original.
            if scanID != nil { mutations[key] = revision }
            let changed = index.remove(entry, folderName: folder)
            if changed { publications[key] = nil }
            return changed
        }
        if changed { notify() }
        return changed
    }

    func original(for file: CameraFile, folder: String?, root: URL?) -> URL? {
        lock.withLock {
            guard let root, directory == root else { return nil }
            return index.original(for: file, folderName: folder)
        }
    }

    func membership(_ files: [CameraFile], root: URL?, mode: TransferStorageMode, since: UInt64) -> Membership {
        lock.withLock {
            guard let root, directory == root else { return Membership(revision: revision, ids: [], publishedIDs: []) }
            let ids = Set(files.compactMap { file -> UInt32? in
                index.original(for: file, folderName: transferStorageFolderName(file: file, mode: mode)) != nil ? file.id : nil
            })
            return Membership(revision: revision, ids: ids,
                publishedIDs: revision == since ? [] : Set(publications.values.filter { $0.revision > since }.map(\.id)))
        }
    }

    var isScanning: Bool { lock.withLock { scanID != nil } }

    func updates() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { observers[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
            continuation.yield(())
        }
    }
    private func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    private func notify() {
        let values = lock.withLock { Array(observers.values) }
        // Signals carry no stale snapshot: subscribers read the latest state.
        values.forEach { $0.yield(()) }
    }
}
