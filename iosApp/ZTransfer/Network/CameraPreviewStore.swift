import Foundation
import ZTransferShared

/// Borrowed transport only; EXIF result lifetime belongs to the workspace, not this connection.
protocol CameraExifSource: AnyObject {
    func exifHeader(handle: Int32, maximumBytes: Int32) async throws -> Data?
    func beginInteractivePreview() async throws -> UUID
    func endInteractivePreview(_ token: UUID) async
}
extension CameraWiFiConnection: CameraExifSource {}

protocol CameraPreviewSource: AnyObject {
    func thumbnail(handle: Int32) async throws -> Data?
    func backgroundThumbnail(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> Data?
    func fhdPicture(handle: Int32, retryDeviceBusy: Bool) async throws -> Data?
}
extension CameraPreviewSource {
    func backgroundThumbnail(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> Data? {
        guard await permitted() else { throw CameraStreamError.operationInProgress }
        return try await thumbnail(handle: handle)
    }
}
extension CameraWiFiConnection: CameraPreviewSource {}

private final class PreviewCacheEntry {
    let data: Data?
    var lastUsed: UInt64
    init(_ data: Data?, lastUsed: UInt64) { self.data = data; self.lastUsed = lastUsed }
}

/// Per-connection encoded cache. No handle or unknown-camera identity persists across reconnects.
/// Duplicate consumers share one bounded request; canceling one consumer does not abort another's
/// transaction. The connection owner closes outstanding IO when the camera session ends.
actor CameraPreviewStore {
    private let source: CameraPreviewSource
    private var cache: [String: PreviewCacheEntry] = [:]
    private var cacheBytes = 0
    private var access: UInt64 = 0
    private var pending: [String: Task<Data?, Error>] = [:]
    private var epoch: UInt64 = 0
    private let policy = NativePreviewPolicy()
    private var directObjectReads = false
    func configureDirectObjectReads(_ value: Bool) {
        guard !closed, directObjectReads != value else { return }
        directObjectReads = value
        epoch &+= 1; cache.removeAll(); cacheBytes = 0
    }
    private let connectionID: UUID?
    private var disk: CameraThumbnailDiskCache?
    private var diskConfigured = false
    private var allowedThumbnailKeys: Set<String>?
    private(set) var diskWritesBlocked = false
    private var closed = false
    private let fill = NativeThumbnailFillQueue()
    private var fillWorker: Task<Void, Never>?
    private var fillWake: UInt64 = 0
    private var fillEnabled = false
    private var connected = false
    private var transfersBusy = false
    private var foregroundUses = Set<UUID>()
    private var scanToken: UUID?
    private var scanAllowsFill = false
    private var scanHandles = Set<Int32>()
    private var lastCompleteSnapshot: CameraCatalogSnapshot?
    private var catalogReady = false
    private var catalogInfos: [Int32: PtpObjectInfo] = [:]
    private var catalogPublicationRevision: UInt64 = 0
    private var priorityRevision: UInt64 = 0

    func startBackgroundFill(startDay: Int32, endDay: Int32, revision: UInt64) {
        guard !closed else { return }
        fillEnabled = true
        connected = true // Called only after the real connection's ready handshake.
        setPriorityRange(startDay: startDay, endDay: endDay, revision: revision)
        wakeFill(retryFailures: true)
    }
    func setPriorityRange(startDay: Int32, endDay: Int32, revision: UInt64) {
        guard !closed, revision > priorityRevision else { return }
        priorityRevision = revision
        if fill.setPriorityRange(startDay: startDay, endDay: endDay) { wakeFill(retryFailures: false) }
    }
    func setTransfersBusy(_ busy: Bool) {
        guard !closed, transfersBusy != busy else { return }
        transfersBusy = busy
        wakeFill(retryFailures: !busy)
    }
    func setConnected(_ value: Bool) {
        guard !closed, connected != value else { return }
        connected = value
        wakeFill(retryFailures: value)
    }
    func beginForegroundUse() -> UUID {
        let token = UUID()
        if !closed { foregroundUses.insert(token); wakeFill(retryFailures: false) }
        return token
    }
    func allowsObjectResolution() -> Bool { !closed && foregroundUses.isEmpty }
    /// Idle catalog reconciliation must yield to transfers as well as foreground image requests.
    /// Do not test scanToken here: this admission also belongs to the active catalog scan itself.
    func allowsCatalogReconciliation() -> Bool { !closed && !transfersBusy && foregroundUses.isEmpty }
    func endForegroundUse(_ token: UUID) {
        if foregroundUses.remove(token) != nil { wakeFill(retryFailures: foregroundUses.isEmpty) }
    }
    func beginCatalogScan() -> UUID? {
        guard !closed else { return nil }
        let token = UUID()
        scanToken = token; catalogReady = false; scanAllowsFill = false; scanHandles.removeAll()
        _ = fill.replace(files: [])
        wakeFill(retryFailures: false)
        return token
    }
    @discardableResult
    func finishCatalogScan(_ token: UUID, snapshot: CameraCatalogSnapshot?) -> Bool {
        guard !closed, scanToken == token else { return false }
        scanToken = nil
        scanAllowsFill = false; scanHandles.removeAll()
        guard let snapshot, snapshot.metadataComplete, !snapshot.changedWhileScanning else {
            if let previous = lastCompleteSnapshot { _ = reconcile(previous) }
            else { fill.clear(); catalogInfos.removeAll(); catalogReady = false }
            return false
        }
        return reconcile(snapshot)
    }

    /// Add-only while scanning: never prune disk or infer missing handles as deleted.
    func appendCatalogBatch(_ token: UUID, snapshot: CameraCatalogSnapshot) -> Bool {
        guard !closed, scanToken == token, snapshot.connectionID == connectionID,
              !snapshot.changedWhileScanning else { return false }
        let newFiles = snapshot.files.filter { !scanHandles.contains($0.handle) }
        for file in newFiles {
            guard let info = snapshot.objectInfos[file.handle], info.identityComplete,
                  info.fileName == file.fileName, info.size == file.size else { return false }
        }
        guard fill.appendScanBatch(files: newFiles.filter { policy.prefetchThumbnail(direct: directObjectReads, file: $0) }) else { return false }
        for file in newFiles {
            scanHandles.insert(file.handle)
            if let info = snapshot.objectInfos[file.handle] {
                catalogInfos[file.handle] = info
                allowedThumbnailKeys?.insert(policy.thumbnailKey(info: info))
            }
        }
        catalogReady = true; scanAllowsFill = true; wakeFill(retryFailures: false)
        return true
    }
    func fillCounts() -> (pending: Int32, failed: Int32, running: Bool) {
        (fill.pendingCount, fill.failedCount, fillWorker != nil)
    }
    func suspendCatalogBatchFill() {
        if scanToken != nil { scanAllowsFill = false; wakeFill(retryFailures: false) }
    }

    private var mayFill: Bool {
        fillEnabled && !closed && connected && catalogReady && (scanToken == nil || scanAllowsFill) &&
            !transfersBusy && foregroundUses.isEmpty && disk != nil && !diskWritesBlocked
    }
    private func mayReadBackground(_ request: NativeThumbnailFillRequest) -> Bool { mayFill && fill.isCurrent(request: request) }
    private func wakeFill(retryFailures: Bool) {
        fillWake &+= 1
        if retryFailures { fill.retryFailed() }
        startFillIfPossible()
    }
    private func startFillIfPossible() {
        guard mayFill, fillWorker == nil, fill.pendingCount > 0 else { return }
        fillWorker = Task { [weak self] in
            var observed: UInt64 = 0
            while let step = await self?.fillOne() {
                observed = step.wake
                if !step.again { break }
            }
            await self?.fillFinished(observed: observed)
        }
    }
    private func fillOne() async -> (again: Bool, wake: UInt64) {
        let observed = fillWake
        guard mayFill, let request = fill.next() else { return (false, observed) }
        guard let info = catalogInfos[request.file.handle] else { _ = fill.failed(request: request); return (mayFill, observed) }
        do {
            let data = try await load(info: info, fhd: false, background: request)
            guard fill.isCurrent(request: request) else { return (mayFill, observed) }
            if let data {
                guard let disk, !diskWritesBlocked else { _ = fill.returnToFront(request: request); return (false, observed) }
                // A memory-only hit is not proof of persistence; this also repairs an OS-purged disk entry.
                let written: Bool
                do { written = try disk.write(data, key: policy.thumbnailKey(info: info)) }
                catch { diskWritesBlocked = true; _ = fill.returnToFront(request: request); return (false, observed) }
                guard written else {
                    diskWritesBlocked = true; _ = fill.returnToFront(request: request); return (false, observed)
                }
            }
            if data == nil && !policy.rememberThumbnailMiss(direct: directObjectReads, info: info) {
                _ = fill.failed(request: request)
            } else { _ = fill.settled(request: request) }
        } catch CameraStreamError.operationInProgress {
            _ = fill.returnToFront(request: request)
            return (false, observed) // A real foreground/scan/pending-slot state change wakes this; no polling timer.
        } catch CameraStreamError.closed {
            connected = false; _ = fill.returnToFront(request: request); return (false, observed)
        } catch CameraStreamError.notConnected {
            connected = false; _ = fill.returnToFront(request: request); return (false, observed)
        } catch {
            _ = fill.failed(request: request) // Retry only on a real state/range change, never in a hot idle loop.
        }
        return (mayFill, observed)
    }
    private func fillFinished(observed: UInt64) {
        fillWorker = nil
        if observed != fillWake { startFillIfPossible() } // Do not lose a wake that arrived while the last request drained.
    }

    init(source: CameraPreviewSource, connectionID: UUID? = nil) {
        self.source = source
        self.connectionID = connectionID
    }

    /// Runs filesystem work on this existing actor, not on the UI thread or another cache owner.
    func openDiskCache(root: URL, cameraIdentity: String) -> Bool {
        guard !closed else { return false }
        guard !diskConfigured else { return disk != nil }
        diskConfigured = true
        do {
            let cache = try CameraThumbnailDiskCache(root: root, cameraIdentity: cameraIdentity)
            disk = cache
            _ = try? cache.cleanupExpired()
            diskWritesBlocked = false
            wakeFill(retryFailures: true)
            return true
        } catch { diskWritesBlocked = true; return false }
    }

    /// Only the single catalog actor calls this after a complete non-raced scan.
    @discardableResult
    func reconcile(_ snapshot: CameraCatalogSnapshot) -> Bool {
        guard !closed, let connectionID, snapshot.connectionID == connectionID,
              snapshot.publicationRevision >= catalogPublicationRevision,
              snapshot.metadataComplete, !snapshot.changedWhileScanning else { return false }
        var keys = Set<String>()
        for file in snapshot.files {
            guard let info = snapshot.objectInfos[file.handle], info.identityComplete, !info.isAssociation,
                  info.fileName == file.fileName, info.size == file.size, info.captureDate == file.captureDate else { return false }
            keys.insert(policy.thumbnailKey(info: info))
        }
        guard fill.replace(files: snapshot.files.filter { policy.prefetchThumbnail(direct: directObjectReads, file: $0) }) else { return false }
        catalogPublicationRevision = snapshot.publicationRevision
        lastCompleteSnapshot = snapshot
        allowedThumbnailKeys = keys
        catalogInfos = snapshot.objectInfos
        catalogReady = true
        let validMemoryKeys = Set(keys.flatMap { ["thumb:" + $0, "fhd:" + $0] })
        for key in Array(cache.keys) where !validMemoryKeys.contains(key) {
            cacheBytes -= cache.removeValue(forKey: key)?.data?.count ?? 0
        }
        do {
            _ = try disk?.reconcile(validKeys: keys)
            diskWritesBlocked = disk == nil
            wakeFill(retryFailures: true)
            return true
        }
        catch { diskWritesBlocked = true; return false }
    }

    func clearForMemoryPressure() {
        epoch &+= 1; cache.removeAll(); cacheBytes = 0
        fillEnabled = false // Stop speculative refill; visible/explicit preview reads remain available.
    }

    /// Session teardown awaits this before a new connection can reuse this camera's directory.
    /// Do not cancel a shared request mid-frame here; the existing connection owner closes its sockets.
    func close() {
        closed = true
        clearForMemoryPressure()
        allowedThumbnailKeys = []
        disk = nil
        fill.clear(); catalogInfos.removeAll(); foregroundUses.removeAll(); scanToken = nil; catalogReady = false
        scanAllowsFill = false; scanHandles.removeAll(); lastCompleteSnapshot = nil
    }

    func thumbnail(info: PtpObjectInfo, allowRemote: Bool = true) async throws -> Data? {
        if !allowRemote { return try localThumbnail(info: info) }
        return try await load(info: info, fhd: false)
    }

    /// Memory then disk only; never waits for a pending remote frame or negative-caches a local miss.
    private func localThumbnail(info: PtpObjectInfo) throws -> Data? {
        try Task.checkCancellation()
        guard !closed, !info.isAssociation else { return nil }
        let identity = info.identityComplete ? policy.thumbnailKey(info: info) : "incomplete:\(info.handle):\(info.size)"
        guard allowedThumbnailKeys?.contains(identity) != false else { return nil }
        let key = "thumb:\(identity)"
        if let value = cache[key] { access &+= 1; value.lastUsed = access; return value.data }
        guard info.identityComplete, let data = try? disk?.read(key: identity) else { return nil }
        try Task.checkCancellation()
        store(data, key: key)
        return data
    }
    /// Product preview asks for FHD and EXIF before permitting thumbnail fallback. Do not call preview().
    func fhd(info: PtpObjectInfo) async throws -> Data? {
        let use = beginForegroundUse()
        defer { endForegroundUse(use) }
        return try await load(info: info, fhd: true)
    }

    /// Cache-only lookup: no disk read, actor child task or camera request for opening/flight frames.
    func cachedThumbnail(info: PtpObjectInfo) -> Data? {
        guard !closed else { return nil }
        let identity = info.identityComplete ? policy.thumbnailKey(info: info) : "incomplete:\(info.handle):\(info.size)"
        guard allowedThumbnailKeys?.contains(identity) != false, let value = cache["thumb:\(identity)"] else { return nil }
        access &+= 1; value.lastUsed = access
        return value.data
    }

    func preview(info: PtpObjectInfo) async throws -> Data? {
        let use = beginForegroundUse()
        defer { endForegroundUse(use) }
        if let fhd = try await load(info: info, fhd: true) { return fhd }
        return try await load(info: info, fhd: false)
    }

    private func load(info: PtpObjectInfo, fhd: Bool, background: NativeThumbnailFillRequest? = nil) async throws -> Data? {
        try Task.checkCancellation()
        guard !closed else { throw CameraStreamError.closed }
        guard !info.isAssociation else { return nil }
        // Incomplete identities are never confused with a real filename-based cache entry.
        let identity = info.identityComplete ? policy.thumbnailKey(info: info) : "incomplete:\(info.handle):\(info.size)"
        let key = "\(fhd ? "fhd" : "thumb"):\(identity)"
        access &+= 1
        if let value = cache[key] { value.lastUsed = access; return value.data }
        if let work = pending[key] {
            let result = try await work.value
            try Task.checkCancellation()
            guard !closed else { throw CameraStreamError.closed }
            return result
        }
        if !fhd, info.identityComplete, allowedThumbnailKeys?.contains(identity) != false,
           let data = try? disk?.read(key: identity) {
            store(data, key: key)
            return data
        }
        // Keep speculative callers from building an unbounded command backlog. Product visible-cell
        // scheduling retries this transient rejection; it must not be remembered as "no thumbnail".
        guard pending.count < 32 else { throw CameraStreamError.operationInProgress }
        let handle = info.handle
        let camera = source
        let startedEpoch = epoch
        let work = Task<Data?, Error> {
            if fhd { return try await camera.fhdPicture(handle: handle, retryDeviceBusy: true) }
            if let background {
                return try await camera.backgroundThumbnail(handle: handle, permitted: { [weak self] in
                    await self?.mayReadBackground(background) == true
                })
            }
            return try await camera.thumbnail(handle: handle)
        }
        pending[key] = work
        defer {
            pending[key] = nil
            if background == nil { wakeFill(retryFailures: false) } // A real visible-request completion frees a pending slot.
        }
        let result = try await work.value
        guard !closed else { throw CameraStreamError.closed }
        // FHD nil includes Busy, unsupported and per-object failures: never negative-cache it.
        // The thumbnail source returns nil only after a complete confirmed-miss/OK-empty response.
        let rememberMiss = !fhd && policy.rememberThumbnailMiss(direct: directObjectReads, info: info)
        if epoch == startedEpoch && allowedThumbnailKeys?.contains(identity) != false && (result != nil || rememberMiss) {
            store(result, key: key)
        }
        // Memory pressure does not discard a useful completed disk result. Reconciliation does reject stale identities.
        if !fhd, info.identityComplete, let result, let disk, allowedThumbnailKeys?.contains(identity) != false {
            do { let written = try disk.write(result, key: identity); if !written { diskWritesBlocked = true } }
            catch { diskWritesBlocked = true }
        }
        try Task.checkCancellation()
        return result
    }

    private func store(_ data: Data?, key: String) {
        let cost = data?.count ?? 0
        let budget = 32 * 1024 * 1024
        guard cost <= budget else { return }
        if let previous = cache.removeValue(forKey: key) { cacheBytes -= previous.data?.count ?? 0 }
        while cache.count >= 256 || cacheBytes + cost > budget {
            guard let oldest = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cacheBytes -= removed.data?.count ?? 0
        }
        access &+= 1
        cache[key] = PreviewCacheEntry(data, lastUsed: access)
        cacheBytes += cost
    }
}
