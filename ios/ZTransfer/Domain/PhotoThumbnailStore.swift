import Foundation

/// Actor-owned, byte-bounded access order, matching Android's LruCache policy.
/// Value links avoid both linear array moves on a hit and reference cycles on clear.
struct PhotoThumbnailMemoryCache: Sendable {
    private struct Entry: Sendable {
        let data: Data
        var previous: String?
        var next: String?
    }
    private var entries: [String: Entry] = [:]
    private var oldest: String?
    private var newest: String?
    private let budget: Int
    private(set) var byteCount = 0
    var count: Int { entries.count }

    init(budget: Int) {
        precondition(budget >= 0)
        self.budget = budget
    }

    mutating func value(for key: String) -> Data? {
        guard let entry = entries[key] else { return nil }
        if newest != key {
            unlink(entry)
            append(key, data: entry.data)
        }
        return entry.data
    }

    mutating func insert(_ data: Data, for key: String) {
        remove(key)
        append(key, data: data)
        byteCount += data.count
        // Preserve the existing rule: an oversized entry evicts older entries
        // and then itself, rather than changing which thumbnails stay resident.
        while byteCount > budget, let key = oldest { remove(key) }
    }

    mutating func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        unlink(entry)
        byteCount -= entry.data.count
    }

    mutating func retainOnly(_ keys: Set<String>) {
        var key = oldest
        while let current = key {
            key = entries[current]?.next
            if !keys.contains(current) { remove(current) }
        }
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        oldest = nil
        newest = nil
        byteCount = 0
    }

    private mutating func unlink(_ entry: Entry) {
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { newest = entry.previous }
    }

    private mutating func append(_ key: String, data: Data) {
        entries[key] = Entry(data: data, previous: newest, next: nil)
        if let newest { entries[newest]?.next = key }
        else { oldest = key }
        newest = key
    }
}

/// Session-owned thumbnail lookup pipeline. The order and negative-cache rules
/// mirror Android `CameraViewModel.loadThumbnail`.
actor PhotoThumbnailStore {
    private static let sharedDisk = PhotoThumbnailDiskCache()
    private struct PrefetchCacheWriteError: Error {}
    private struct InvalidPrefetchBytes: Error {}
    private(set) var diskWritesBlocked = false
    private let disk: PhotoThumbnailDiskCache
    private var cameraStore: PhotoThumbnailDiskCache.CameraStore?
    private var cameraIdentity: String?
    private var memory: PhotoThumbnailMemoryCache
    private var negative = Set<String>()
    private final class Flight: @unchecked Sendable {
        enum VisibleResult { case image(Data), unavailable }
        let task: Task<Data, Error>
        var waiters: Int
        // Only accessed on PhotoThumbnailStore. Prefetch never populates this.
        // Like Android's InflightThumb, visible waiters share decoding as well
        // as the remote read, even when the result exceeds the memory budget.
        var visibleResult: VisibleResult?
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
    var activeWaiterCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters } }
    private var observers: [UInt32: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private let remoteGate = ThumbnailRemoteGate()

    init(disk: PhotoThumbnailDiskCache? = nil, memoryBudget: Int? = nil) {
        self.disk = disk ?? Self.sharedDisk
        // Android reserves about one eighth of the process heap for bitmap LRU.
        // Data is compressed thumbnail bytes on iOS, so retain the same ratio
        // with a small floor and no arbitrary entry-count eviction.
        self.memory = PhotoThumbnailMemoryCache(budget: memoryBudget ??
            max(4 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 8)))
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
        negative.removeAll(keepingCapacity: true)
        cameraIdentity = identity
        diskWritesBlocked = false
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
        let keys = cacheKeys(for: file, directSTA: directSTA)
        let key = keys.primary
        if let value = memory.value(for: key) { return value }
        if negative.contains(key) { return nil }
        if let store = cameraStore,
           let url = store.find(key, legacyName: keys.legacy, alternateName: keys.alternate),
           let raw = try? Data(contentsOf: url), !raw.isEmpty {
            let value = transform(raw)
            if validate(value) {
                memory.insert(value, for: key)
                return value
            }
            // A malformed disk entry is not an authoritative no-thumbnail
            // result. Delete it and fall through to a fresh camera read.
            cameraStore?.remove(key, url: url)
        }
        guard allowRemote else { return nil }
        // Flights carry raw camera bytes. Android's background lane writes
        // those bytes directly to disk; decoding/cropping belongs only to the
        // visible lane when it reads the cache.
        let flight: Flight
        if let existing = inFlight[key] {
            existing.waiters += 1
            flight = existing
        } else {
            let task = Task<Data, Error> {
                try await self.remoteGate.withPermit { try await fetch() }
            }
            flight = Flight(task: task)
            inFlight[key] = flight
        }
        let raw = try await awaitFlight(WaiterToken(key: key, flight: flight))
        guard cameraIdentity == expectedIdentity else { throw CancellationError() }
        if let result = flight.visibleResult {
            switch result {
            case .image(let data): return data
            case .unavailable: return nil
            }
        }
        // No suspension between decode and publication: other waiters see
        // the same result, including invalid bytes, without processing again.
        flight.visibleResult = .unavailable
        guard !raw.isEmpty else {
            // Direct-STA RAW/video probe misses stay retryable; ordinary
            // GetThumb's empty response remains authoritative.
            if !(directSTA && file.fileExtension != ".jpg") { negative.insert(key) }
            return nil
        }
        let processed = transform(raw)
        guard validate(processed) else {
            cameraStore?.remove(key)
            if !(directSTA && file.fileExtension != ".jpg") { negative.insert(key) }
            return nil
        }
        flight.visibleResult = .image(processed)
        memory.insert(processed, for: key)
        _ = writeCache(raw, key: key)
        return processed
    }

    /// Scan-pipeline variant: same lookup order, but a successful fetch is
    /// written to disk only and does not populate the decoded-memory cache.
    /// Android uses this path after each accepted metadata batch.
    func prefetch(
        file: CameraFile, identity: String, directSTA: Bool = false,
        validate: (@Sendable (Data) -> Bool)? = nil,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Bool {
        try await prefetchOutcome(file: file, identity: identity, directSTA: directSTA,
                                  validate: validate, fetch: fetch).isSettled
    }

    func prefetchOutcome(
        file: CameraFile,
        identity: String,
        directSTA: Bool = false,
        validate: (@Sendable (Data) -> Bool)? = nil,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> ThumbnailPrefetchOutcome {
        beginSession(identity: identity)
        guard let expectedIdentity = cameraIdentity else { return .unsettled }
        let keys = cacheKeys(for: file, directSTA: directSTA)
        let key = keys.primary
        // Android's no-thumbnail set is a settled result, not a transient
        // failure. A disk-fill pass must not keep retrying the same handle.
        if negative.contains(key), !directSTA || validate == nil { return .settled }
        if validate != nil { negative.remove(key) }
        if let store = cameraStore,
           let url = store.find(key, legacyName: keys.legacy, alternateName: keys.alternate) {
            // Ordinary Android-compatible fill uses indexed file length.
            // Sequential STA also validates old entries, so an in-place app
            // update cannot keep treating rejected bytes as completed work.
            if let validate {
                if let raw = try? Data(contentsOf: url), validate(raw) { return .cached }
                store.remove(key, url: url)
            } else { return .cached }
        }
        // All formats participate in the ordered fill, including direct-STA
        // RAW/video. Visibility is never a prerequisite for camera reads.
        guard !diskWritesBlocked else { return .unsettled }
        if let flight = inFlight[key] {
            flight.waiters += 1
            let value: Data
            do {
                value = try await awaitFlight(WaiterToken(key: key, flight: flight))
            } catch is PrefetchCacheWriteError { return .unsettled }
            catch is InvalidPrefetchBytes { return .unsettled }
            guard cameraIdentity == expectedIdentity else { throw CancellationError() }
            if value.isEmpty && !directSTA { negative.insert(key); return .settled }
            if let validate, !validate(value) { cameraStore?.remove(key); return .unsettled }
            guard !value.isEmpty else { return .settled }
            guard writeCache(value, key: key) else { return .unsettled }
            return .settled
        }
        // Keep the completion behind the disk write. A visible request that
        // waits for this flight must observe the same cache state as Android
        // and must not start a duplicate GetThumb in the write window.
        let task = Task<Data, Error> {
            let raw = try await self.remoteGate.withPermit {
                guard await !self.diskWritesBlocked else { throw PrefetchCacheWriteError() }
                return try await fetch()
            }
            if !(raw.isEmpty && !directSTA), let validate, !validate(raw) { throw InvalidPrefetchBytes() }
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
            return .settled
        } catch is InvalidPrefetchBytes {
            return .unsettled
        } catch is PrefetchCacheWriteError {
            // A disk failure never settles the item; the connection latch
            // blocks subsequent remote fill while preserving cache reads.
            return .unsettled
        } catch { throw error }
    }

    private func persistPrefetch(_ raw: Data, key: String, expectedIdentity: String) throws {
        guard cameraIdentity == expectedIdentity else { throw CancellationError() }
        guard !raw.isEmpty else { negative.insert(key); return }
        guard writeCache(raw, key: key) else { throw PrefetchCacheWriteError() }
    }

    private func writeCache(_ raw: Data, key: String) -> Bool {
        guard !diskWritesBlocked else { return false }
        guard cameraStore?.write(raw, as: key) == true else {
            diskWritesBlocked = true
            return false
        }
        return true
    }

    func clear() {
        for subscriptions in observers.values {
            for continuation in subscriptions.values { continuation.finish() }
        }
        observers.removeAll()
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        memory.removeAll()
        negative.removeAll()
        cameraStore = nil
        cameraIdentity = nil
        diskWritesBlocked = false
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
            memory.remove(key)
            negative.remove(key)
            if let flight = inFlight.removeValue(forKey: key) { flight.task.cancel() }
        }
    }

    private func pruneSessionState(validKeys: Set<String>) {
        memory.retainOnly(validKeys)
        negative.formIntersection(validKeys)
        for key in Array(inFlight.keys) where !validKeys.contains(key) {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func cacheKeys(for file: CameraFile, directSTA: Bool) -> (primary: String, legacy: String?, alternate: String?) {
        let standard = PhotoThumbnailDiskCache.cacheFileName(
            fileName: file.fileName,
            size: file.size,
            captureDate: file.captureDate
        )
        if directSTA && file.fileExtension == ".jpg" {
            return (PhotoThumbnailDiskCache.staJpegCacheFileName(handle: file.id, size: file.size), nil, nil)
        }
        let primary = directSTA
            ? PhotoThumbnailDiskCache.staCacheFileName(handle: file.id, size: file.size)
            : standard
        return (primary, PhotoThumbnailDiskCache.legacyCacheFileName(
            fileName: file.fileName, size: file.size, captureDate: file.captureDate),
            directSTA ? standard : nil)
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

/// A completed/no-thumbnail result does not imply a pre-existing disk hit.
/// Android CachedThumbnailBatchPolicy accelerates only `.cached` outcomes.
enum ThumbnailPrefetchOutcome: Sendable {
    case cached, settled, unsettled
    var isSettled: Bool { self != .unsettled }
}

struct ThumbnailBatchResult: Sendable {
    var settled = Set<UInt32>()
    var cached = Set<UInt32>()
    var interrupted = false
    var diskWritesBlocked = false
}
