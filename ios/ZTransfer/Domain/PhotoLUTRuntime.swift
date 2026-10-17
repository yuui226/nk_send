import Foundation

/// Immutable tables are retained by active callers or this bounded LRU.
final class PhotoLUTResourceCache: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: Int
    private let maximumEntries: Int
    private var tables: [String: CubeLUT] = [:]
    private var order: [String] = []
    private var bytes = 0
    private var loading: [String: Load] = [:]

    init(budget: Int = 8 * 1024 * 1024, maximumEntries: Int = 16) {
        self.budget = max(0, budget)
        self.maximumEntries = max(0, maximumEntries)
    }

    var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var count: Int { lock.lock(); defer { lock.unlock() }; return tables.count }

    func table(_ key: String) -> CubeLUT? {
        lock.lock()
        defer { lock.unlock() }
        guard let table = tables[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return table
    }

    /// Android PhotoCubeResourceCache.acquire: one reader per key, no I/O or
    /// waiting under the LRU lock. Failed reads are shared but never cached.
    func acquire(_ key: String, read: () -> CubeLUT?) -> CubeLUT? {
        lock.lock()
        if let table = tables[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lock.unlock()
            return table
        }
        if let existing = loading[key] {
            lock.unlock()
            return existing.wait()
        }
        let load = Load()
        loading[key] = load
        lock.unlock()

        let result = read().map { remember($0) }
        load.finish(result)
        lock.lock()
        loading.removeValue(forKey: key)
        lock.unlock()
        return result
    }

    private final class Load: @unchecked Sendable {
        private let condition = NSCondition()
        private var finished = false
        private var result: CubeLUT?

        func wait() -> CubeLUT? {
            condition.lock()
            defer { condition.unlock() }
            while !finished { condition.wait() }
            return result
        }

        func finish(_ result: CubeLUT?) {
            condition.lock()
            self.result = result
            finished = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func contains(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tables[key] != nil
    }

    func seed(_ table: CubeLUT) { _ = remember(table) }

    private func remember(_ table: CubeLUT) -> CubeLUT {
        lock.lock()
        defer { lock.unlock() }
        let key = table.digest
        if let existing = tables[key] { return existing }
        // iOS samples directly from the Float array; it has no Android mapper copy.
        let cost = table.rgb.count * MemoryLayout<Float>.stride
        guard cost <= budget, maximumEntries > 0 else { return table }
        while bytes + cost > budget || tables.count >= maximumEntries {
            guard let oldest = order.first, let removed = tables.removeValue(forKey: oldest) else { break }
            order.removeFirst()
            bytes -= removed.rgb.count * MemoryLayout<Float>.stride
        }
        tables[key] = table
        order.append(key)
        bytes += cost
        return table
    }

    func removeAll() {
        lock.lock()
        tables.removeAll()
        order.removeAll()
        bytes = 0
        lock.unlock()
    }
}

/// A recipe owns its private file identity, never a decoded Float table.
/// Android PhotoLutStore tracks these owners weakly so queued recipes survive
/// editor changes without keeping every previously selected table alive.
final class PhotoLUTSnapshotOwner: Sendable, Equatable {
    let digest: String
    let url: URL
    let legacyURL: URL?
    init(digest: String, url: URL, legacyURL: URL? = nil) {
        self.digest = digest; self.url = url; self.legacyURL = legacyURL
    }
    static func == (lhs: PhotoLUTSnapshotOwner, rhs: PhotoLUTSnapshotOwner) -> Bool {
        lhs.digest == rhs.digest && lhs.url == rhs.url
    }
}

enum PhotoLUTRuntime {
    private static let storage = Storage()
    static func register(_ lut: CubeLUT, snapshot: URL? = nil) {
        if let snapshot { registerSnapshot(digest: lut.digest, url: snapshot) }
        storage.cache.seed(lut)
    }

    /// Restored recipes retain only snapshot metadata until a render requests it.
    static func registerSnapshot(digest: String, url: URL, legacyURL: URL? = nil) {
        storage.lock.lock()
        storage.snapshots[digest] = url
        if let legacyURL { storage.legacySnapshots[url] = legacyURL }
        storage.lock.unlock()
    }

    static func snapshotOwner(digest: String) -> PhotoLUTSnapshotOwner? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard let url = storage.snapshots[digest] else { return nil }
        return ownerLocked(digest: digest, url: url)
    }

    static func snapshotOwner(digest: String, url: URL) -> PhotoLUTSnapshotOwner {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return ownerLocked(digest: digest, url: url)
    }

    private static func ownerLocked(digest: String, url: URL) -> PhotoLUTSnapshotOwner {
        storage.owners = storage.owners.filter { $0.value.value != nil }
        if let owner = storage.owners[url]?.value { return owner }
        let owner = PhotoLUTSnapshotOwner(digest: digest, url: url, legacyURL: storage.legacySnapshots[url])
        storage.owners[url] = WeakOwner(owner)
        return owner
    }

    static func table(owner: PhotoLUTSnapshotOwner) -> CubeLUT? {
        if let legacy = owner.legacyURL, !FileManager.default.fileExists(atPath: owner.url.path) {
            // Legacy recovery runs only on the caller's render worker. Even a
            // warm digest table must not hide a failed durable migration.
            guard let table = storage.migrations.acquire(owner.url.path, read: {
                PhotoLUTStore.migrateSnapshot(from: legacy, to: owner.url, digest: owner.digest)
            }) else { return nil }
            storage.cache.seed(table)
            return table
        }
        return storage.cache.acquire(owner.digest) {
            PhotoLUTStore.readSnapshot(at: owner.url, digest: owner.digest)
        }
    }

    /// Metadata-only validation must not reload a table on the editor thread.
    static func contains(digest: String) -> Bool {
        if storage.cache.contains(digest) { return true }
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.snapshots[digest] != nil
    }

    static func table(digest: String) -> CubeLUT? {
        if let owner = snapshotOwner(digest: digest) { return table(owner: owner) }
        return storage.cache.table(digest)
    }

    /// Enumerate outside the owner lock; recheck current roles and owners for
    /// each deletion under the same lock used to acquire a write/recipe owner.
    static func pruneSnapshots(in directory: URL, retained: () -> Set<URL>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for file in files where file.pathExtension == "bin" {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            storage.lock.lock()
            if storage.owners[file]?.value == nil && !retained().contains(file) {
                if (try? FileManager.default.removeItem(at: file)) != nil {
                    storage.snapshots = storage.snapshots.filter { $0.value != file }
                    storage.owners.removeValue(forKey: file)
                    storage.legacySnapshots.removeValue(forKey: file)
                }
            }
            storage.lock.unlock()
        }
    }

    static func purgeMemoryCache() { storage.cache.removeAll() }

    private final class WeakOwner {
        weak var value: PhotoLUTSnapshotOwner?
        init(_ value: PhotoLUTSnapshotOwner) { self.value = value }
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        let cache = PhotoLUTResourceCache()
        let migrations = PhotoLUTResourceCache(budget: 0)
        var snapshots: [String: URL] = [:]
        var legacySnapshots: [URL: URL] = [:]
        var owners: [URL: WeakOwner] = [:]
    }
}
