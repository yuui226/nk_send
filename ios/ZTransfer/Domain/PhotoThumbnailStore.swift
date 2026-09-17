import Foundation

/// Session-owned thumbnail lookup pipeline. The order and negative-cache rules
/// mirror Android `CameraViewModel.loadThumbnail`.
actor PhotoThumbnailStore {
    private struct PrefetchCacheWriteError: Error {}
    private let disk: PhotoThumbnailDiskCache
    private var cameraStore: PhotoThumbnailDiskCache.CameraStore?
    private var cameraIdentity: String?
    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0
    private let memoryBudget: Int
    private var negative = Set<String>()
    private final class Flight: @unchecked Sendable {
        let task: Task<Data, Error>
        var waiters: Int
        init(task: Task<Data, Error>, waiters: Int = 1) { self.task = task; self.waiters = waiters }
    }
    private final class WaiterToken: @unchecked Sendable {
        let key: String
        let flight: Flight
        private let lock = NSLock()
        private var released = false
        init(key: String, flight: Flight) { self.key = key; self.flight = flight }
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !released else { return false }
            released = true
            return true
        }
    }
    private var inFlight: [String: Flight] = [:]
    private let remoteGate = ThumbnailRemoteGate()

    init(disk: PhotoThumbnailDiskCache = PhotoThumbnailDiskCache()) {
        self.disk = disk
        // Android reserves about one eighth of the process heap for bitmap LRU.
        // Data is compressed thumbnail bytes on iOS, so retain the same ratio
        // with a small floor and no arbitrary entry-count eviction.
        self.memoryBudget = max(4 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 8))
    }

    func beginSession(identity: String) {
        guard cameraIdentity != identity else { return }
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        memory.removeAll(keepingCapacity: true)
        memoryOrder.removeAll(keepingCapacity: true)
        memoryBytes = 0
        negative.removeAll(keepingCapacity: true)
        cameraIdentity = identity
        cameraStore = disk.openCamera(identity: identity)
        _ = disk.cleanupExpired()
    }

    /// Android clears the in-memory bitmap and negative sets at the beginning
    /// of a fresh scan while retaining the per-camera disk cache.
    func resetForScan(identity: String) {
        beginSession(identity: identity)
        memory.removeAll(keepingCapacity: true)
        memoryOrder.removeAll(keepingCapacity: true)
        memoryBytes = 0
        negative.removeAll(keepingCapacity: true)
    }

    func load(
        file: CameraFile,
        identity: String,
        directSTA: Bool = false,
        allowRemote: Bool,
        transform: @escaping @Sendable (Data) -> Data = { $0 },
        validate: @escaping @Sendable (Data) -> Bool = { !$0.isEmpty },
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Data? {
        beginSession(identity: identity)
        guard let expectedIdentity = cameraIdentity else { return nil }
        let (key, standardKey) = cacheKeys(for: file, directSTA: directSTA)
        if let value = memory[key] { touch(key); return value }
        if negative.contains(key) { return nil }
        if let store = cameraStore,
           let url = store.find(key, legacyName: PhotoThumbnailDiskCache.legacyCacheFileName(
               fileName: file.fileName, size: file.size, captureDate: file.captureDate
           ), alternateName: directSTA ? standardKey : nil),
           let raw = try? Data(contentsOf: url), !raw.isEmpty {
            let value = transform(raw)
            if validate(value) {
                insert(value, key: key)
                return value
            }
            // A malformed disk entry is not an authoritative no-thumbnail
            // result. Delete it and fall through to a fresh camera read.
            cameraStore?.remove(key, url: url)
        }
        guard allowRemote else { return nil }
        if let flight = inFlight[key] {
            flight.waiters += 1
            let raw = try await awaitFlight(WaiterToken(key: key, flight: flight))
            guard cameraIdentity == expectedIdentity else { throw CancellationError() }
            guard !raw.isEmpty else { negative.insert(key); return nil }
            let processed = transform(raw)
            guard validate(processed) else {
                cameraStore?.remove(key)
                if !(directSTA && file.fileExtension != ".jpg") { negative.insert(key) }
                return nil
            }
            insert(processed, key: key)
            _ = cameraStore?.write(raw, as: key)
            return processed
        }
        // Flights carry raw camera bytes. Android's background lane writes
        // those bytes directly to disk; decoding/cropping belongs only to the
        // visible lane when it reads the cache.
        let task = Task<Data, Error> {
            try await self.remoteGate.withPermit { try await fetch() }
        }
        let flight = Flight(task: task)
        inFlight[key] = flight
        do {
            let value = try await awaitFlight(WaiterToken(key: key, flight: flight))
            guard cameraIdentity == expectedIdentity else { throw CancellationError() }
            guard !value.isEmpty else { negative.insert(key); return nil }
            let processed = transform(value)
            guard validate(processed) else {
                cameraStore?.remove(key)
                if !(directSTA && file.fileExtension != ".jpg") { negative.insert(key) }
                return nil
            }
            insert(processed, key: key)
            _ = cameraStore?.write(value, as: key)
            return processed
        } catch { throw error }
    }

    /// Scan-pipeline variant: same lookup order, but a successful fetch is
    /// written to disk only and does not populate the decoded-memory cache.
    /// Android uses this path after each accepted metadata batch.
    func prefetch(
        file: CameraFile,
        identity: String,
        directSTA: Bool = false,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Bool {
        beginSession(identity: identity)
        guard let expectedIdentity = cameraIdentity else { return false }
        let (key, standardKey) = cacheKeys(for: file, directSTA: directSTA)
        // Android's no-thumbnail set is a settled result, not a transient
        // failure. A disk-fill pass must not keep retrying the same handle.
        if negative.contains(key) { return true }
        if let store = cameraStore,
           let url = store.find(key, legacyName: PhotoThumbnailDiskCache.legacyCacheFileName(
               fileName: file.fileName, size: file.size, captureDate: file.captureDate
           ), alternateName: directSTA ? standardKey : nil),
           let value = try? Data(contentsOf: url), !value.isEmpty { return true }
        if let flight = inFlight[key] {
            flight.waiters += 1
            let value = try await awaitFlight(WaiterToken(key: key, flight: flight))
            guard cameraIdentity == expectedIdentity else { throw CancellationError() }
            guard !value.isEmpty else { return true }
            guard cameraStore?.write(value, as: key) == true else { return false }
            return true
        }
        // Keep the completion behind the disk write. A visible request that
        // waits for this flight must observe the same cache state as Android
        // and must not start a duplicate GetThumb in the write window.
        let task = Task<Data, Error> {
            let raw = try await self.remoteGate.withPermit { try await fetch() }
            try self.persistPrefetch(raw, key: key, expectedIdentity: expectedIdentity)
            return raw
        }
        let flight = Flight(task: task)
        inFlight[key] = flight
        do {
            _ = try await awaitFlight(WaiterToken(key: key, flight: flight))
            guard cameraIdentity == expectedIdentity else { throw CancellationError() }
            // An empty GetThumb response is authoritative and has already
            // been entered in the negative cache by persistPrefetch.
            return true
        } catch is PrefetchCacheWriteError {
            // Android stops the background fill when disk writes fail, while a
            // visible request may still retry through its own lane.
            return false
        } catch { throw error }
    }

    private func persistPrefetch(_ raw: Data, key: String, expectedIdentity: String) throws {
        guard cameraIdentity == expectedIdentity else { throw CancellationError() }
        guard !raw.isEmpty else { negative.insert(key); return }
        guard cameraStore?.write(raw, as: key) == true else { throw PrefetchCacheWriteError() }
    }

    func clear() {
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        memory.removeAll()
        memoryOrder.removeAll()
        memoryBytes = 0
        negative.removeAll()
        cameraStore = nil
        cameraIdentity = nil
    }

    func reconcile(files: [CameraFile], identity: String, directSTA: Bool) {
        beginSession(identity: identity)
        let names = Set(files.map { cacheKeys(for: $0, directSTA: directSTA).primary })
        pruneSessionState(validKeys: names)
        _ = cameraStore?.reconcile(validNames: names)
    }

    /// Android drops handle-scoped memory, negative and in-flight state as
    /// soon as an authoritative handle catalog removes an object. Disk files
    /// remain until the complete metadata scan can reconcile stable keys.
    func invalidate(files: [CameraFile], identity: String, directSTA: Bool) {
        guard !files.isEmpty else { return }
        beginSession(identity: identity)
        let keys = Set(files.map { cacheKeys(for: $0, directSTA: directSTA).primary })
        for key in keys {
            if let value = memory.removeValue(forKey: key) { memoryBytes -= value.count }
            memoryOrder.removeAll { $0 == key }
            negative.remove(key)
            if let flight = inFlight.removeValue(forKey: key) { flight.task.cancel() }
        }
    }

    private func pruneSessionState(validKeys: Set<String>) {
        for key in memory.keys where !validKeys.contains(key) {
            if let value = memory.removeValue(forKey: key) { memoryBytes -= value.count }
        }
        memoryOrder.removeAll { !validKeys.contains($0) }
        negative.formIntersection(validKeys)
        for key in Array(inFlight.keys) where !validKeys.contains(key) {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func cacheKeys(for file: CameraFile, directSTA: Bool) -> (primary: String, standard: String) {
        let standard = PhotoThumbnailDiskCache.cacheFileName(
            fileName: file.fileName,
            size: file.size,
            captureDate: file.captureDate
        )
        let primary = directSTA
            ? PhotoThumbnailDiskCache.staCacheFileName(handle: file.id, size: file.size)
            : standard
        return (primary, standard)
    }

    private func insert(_ value: Data, key: String) {
        if let old = memory.updateValue(value, forKey: key) { memoryBytes -= old.count }
        memoryBytes += value.count
        touch(key)
        while memoryBytes > memoryBudget, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            guard let removed = memory.removeValue(forKey: oldest) else { continue }
            memoryBytes -= removed.count
        }
    }

    private func awaitFlight(_ token: WaiterToken) async throws -> Data {
        defer {
            Task { self.release(token, cancelUnderlying: Task.isCancelled) }
        }
        return try await withTaskCancellationHandler {
            try await token.flight.task.value
        } onCancel: {
            Task { await self.release(token, cancelUnderlying: true) }
        }
    }

    private func release(_ token: WaiterToken, cancelUnderlying: Bool) {
        guard token.claim() else { return }
        guard let current = inFlight[token.key], current === token.flight else { return }
        current.waiters -= 1
        if cancelUnderlying && current.waiters == 0 {
            current.task.cancel()
            inFlight.removeValue(forKey: token.key)
        } else if current.waiters == 0 {
            inFlight.removeValue(forKey: token.key)
        }
    }

    private func touch(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }
}

/// Android serializes background thumbnail reads with a one-permit gate so a
/// scan cannot flood the same PTP/IP transaction channel.
private actor ThumbnailRemoteGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withPermit<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if available {
            available = false
        } else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
            do { try Task.checkCancellation() }
            catch {
                releasePermit()
                throw error
            }
        }
        defer { releasePermit() }
        return try await operation()
    }

    private func releasePermit() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available = true
        }
    }
}
