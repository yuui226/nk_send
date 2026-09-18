import Foundation

/// Session-owned thumbnail lookup pipeline. The order and negative-cache rules
/// mirror Android `CameraViewModel.loadThumbnail`.
actor PhotoThumbnailStore {
    private static let sharedDisk = PhotoThumbnailDiskCache()
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
    private var observers: [UInt32: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private let remoteGate = ThumbnailRemoteGate()

    init(disk: PhotoThumbnailDiskCache? = nil) {
        self.disk = disk ?? Self.sharedDisk
        // Android reserves about one eighth of the process heap for bitmap LRU.
        // Data is compressed thumbnail bytes on iOS, so retain the same ratio
        // with a small floor and no arbitrary entry-count eviction.
        self.memoryBudget = max(4 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 8))
    }

    /// Cancelling a cell removes only its subscription, never camera work.
    /// The initial event closes the subscribe/cache-read race on reappearance.
    func updates(handle: UInt32) -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[handle, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(handle: handle, id: id) }
        }
        continuation.yield(())
        return stream
    }

    private func removeObserver(handle: UInt32, id: UUID) {
        observers[handle]?[id] = nil
        if observers[handle]?.isEmpty == true { observers[handle] = nil }
    }

    func publish(handle: UInt32) {
        guard let continuations = observers[handle]?.values else { return }
        for continuation in continuations { continuation.yield(()) }
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
        if disk.claimCleanup() {
            let disk = self.disk
            // Android performs the 90-day sweep on a background IO coroutine
            // at ViewModel startup. It is not part of the STA catalog critical
            // path. Start it only after the active camera directory is opened
            // and marked current, then let scanning proceed immediately.
            Task.detached(priority: .utility) { _ = disk.cleanupExpired() }
        }
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
            guard !raw.isEmpty else {
                // Android keeps a direct-STA RAW/video bounded-probe miss
                // retryable. It is not the camera's authoritative NoThumbnail
                // response and may succeed when the cell becomes visible again.
                if !(directSTA && file.fileExtension != ".jpg") { negative.insert(key) }
                return nil
            }
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
            guard !value.isEmpty else {
                if !(directSTA && file.fileExtension != ".jpg") { negative.insert(key) }
                return nil
            }
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
        validate: (@Sendable (Data) -> Bool)? = nil,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Bool {
        beginSession(identity: identity)
        guard let expectedIdentity = cameraIdentity else { return false }
        let (key, standardKey) = cacheKeys(for: file, directSTA: directSTA)
        // Android's no-thumbnail set is a settled result, not a transient
        // failure. A disk-fill pass must not keep retrying the same handle.
        if let value = memory[key], validate?(value) != false { touch(key); return true }
        if negative.contains(key), validate == nil { return true }
        if validate != nil { negative.remove(key) }
        if let store = cameraStore,
           let url = store.find(key, legacyName: PhotoThumbnailDiskCache.legacyCacheFileName(
               fileName: file.fileName, size: file.size, captureDate: file.captureDate
           ), alternateName: directSTA ? standardKey : nil) {
            // Ordinary Android-compatible fill uses indexed file length.
            // Sequential STA also validates old entries, so an in-place app
            // update cannot keep treating rejected bytes as completed work.
            if let validate {
                if let raw = try? Data(contentsOf: url), validate(raw) { return true }
                store.remove(key, url: url)
            } else { return true }
        }
        // All formats participate in the ordered fill, including direct-STA
        // RAW/video. Visibility is never a prerequisite for camera reads.
        if let flight = inFlight[key] {
            flight.waiters += 1
            let value = try await awaitFlight(WaiterToken(key: key, flight: flight))
            guard cameraIdentity == expectedIdentity else { throw CancellationError() }
            if let validate, !validate(value) { cameraStore?.remove(key); return false }
            guard !value.isEmpty else { return true }
            guard cameraStore?.write(value, as: key) == true else { return false }
            return true
        }
        // Keep the completion behind the disk write. A visible request that
        // waits for this flight must observe the same cache state as Android
        // and must not start a duplicate GetThumb in the write window.
        let task = Task<Data, Error> {
            let raw = try await self.remoteGate.withPermit { try await fetch() }
            if let validate, !validate(raw) { throw PrefetchCacheWriteError() }
            try self.persistPrefetch(raw, key: key, expectedIdentity: expectedIdentity)
            return raw
        }
        let flight = Flight(task: task)
        inFlight[key] = flight
        do {
            _ = try await awaitFlight(WaiterToken(key: key, flight: flight))
            guard cameraIdentity == expectedIdentity else { throw CancellationError() }
            // With a validator only usable bytes reach persistence. Ordinary
            // GetThumb also retains its authoritative empty-response handling.
            return true
        } catch is PrefetchCacheWriteError {
            // Neither invalid image bytes nor a failed write settles the item.
            // The sequential owner can retry without relying on cell visibility.
            return false
        } catch { throw error }
    }

    private func persistPrefetch(_ raw: Data, key: String, expectedIdentity: String) throws {
        guard cameraIdentity == expectedIdentity else { throw CancellationError() }
        guard !raw.isEmpty else { negative.insert(key); return }
        guard cameraStore?.write(raw, as: key) == true else { throw PrefetchCacheWriteError() }
    }

    func clear() {
        for subscriptions in observers.values {
            for continuation in subscriptions.values { continuation.finish() }
        }
        observers.removeAll()
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
            // We are already back on this actor. Release before returning the
            // miss so an immediate visible retry cannot join a completed failed
            // flight. A new Task also reads its own cancellation flag, not the
            // cancelled caller's flag (unlike Android's finally block).
            release(token, cancelUnderlying: Task.isCancelled)
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
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var available = true
    private var waiters: [Waiter] = []

    func withPermit<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { releasePermit() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if available {
            available = false
            return
        }
        let id = UUID()
        let ownsPermit = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            // Swift continuations do not leave a queue automatically when the
            // cell's .task is cancelled. Android's Semaphore does; remove the
            // stale waiter so newly visible thumbnails do not sit behind a
            // long chain of off-screen requests.
            Task { await self.cancelWaiter(id) }
        }
        guard ownsPermit else { throw CancellationError() }
        do { try Task.checkCancellation() }
        catch {
            // The waiter may have received the permit concurrently with its
            // cancellation. In that race it owns the permit and must pass it on.
            releasePermit()
            throw error
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releasePermit() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            available = true
        }
    }
}
