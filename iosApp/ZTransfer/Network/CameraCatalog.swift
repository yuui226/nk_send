import Foundation
import ZTransferShared

protocol CameraCatalogSource: AnyObject {
    var connectionID: UUID { get }
    func storageIDs() async throws -> [Int32]
    func objectHandles(storageID: Int32) async throws -> [Int32]
    func objectInfo(handle: Int32) async throws -> PtpObjectInfo
    func snapshot() async -> CameraConnectionSnapshot
    func newObjectInfo(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> PtpObjectInfo
}

extension CameraCatalogSource {
    func newObjectInfo(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> PtpObjectInfo {
        guard await permitted() else { throw CameraStreamError.operationInProgress }
        return try await objectInfo(handle: handle)
    }
}

struct CameraCatalogAddition {
    let snapshot: CameraCatalogSnapshot
    let info: PtpObjectInfo
    let newMedia: CameraFileInfo?
}

extension CameraWiFiConnection: CameraCatalogSource {}

struct CameraCatalogSnapshot {
    let connectionID: UUID
    let revision: UInt64
    let storageIDs: [Int32]
    let files: [CameraFileInfo]
    let objectInfos: [Int32: PtpObjectInfo]
    /// All metadata aliases, not just visible rows. Order is explicit, never Dictionary iteration.
    let indexedObjectInfos: [PtpObjectInfo]
    let totalHandles: Int
    let metadataComplete: Bool
    let changedWhileScanning: Bool
    /// Raw successful enumeration delta, not a list of publishable/auto-transferable rows.
    let handleDelta: CameraHandleDelta?
    let publicationRevision: UInt64

    init(connectionID: UUID, revision: UInt64, storageIDs: [Int32], files: [CameraFileInfo],
         objectInfos: [Int32: PtpObjectInfo], totalHandles: Int, metadataComplete: Bool,
         changedWhileScanning: Bool, handleDelta: CameraHandleDelta? = nil, publicationRevision: UInt64 = 0,
         indexedObjectInfos: [PtpObjectInfo]? = nil) {
        self.connectionID = connectionID; self.revision = revision; self.storageIDs = storageIDs
        self.files = files; self.objectInfos = objectInfos; self.totalHandles = totalHandles
        // Old/manual fixtures keep a deterministic fallback; real producers always supply read order.
        self.indexedObjectInfos = indexedObjectInfos ?? objectInfos.keys.sorted().compactMap { objectInfos[$0] }
        self.metadataComplete = metadataComplete; self.changedWhileScanning = changedWhileScanning
        self.handleDelta = handleDelta
        self.publicationRevision = publicationRevision
    }
}

/// Normal AP/STA catalog only. One immutable camera generation; failed enumeration never replaces
/// the last good snapshot with an empty list. Shared code owns handle order and backup merging.
/// Event revisions are invalidations, not lossless events; callers must schedule another scan when
/// changedWhileScanning is true. Automatic transfer/event reconciliation is a separate coordinator.
actor CameraCatalog {
    private let source: CameraCatalogSource
    private let stationMode: Bool
    private let previews: CameraPreviewStore?
    private var scanning = false
    private var latest: CameraCatalogSnapshot?
    private let handleBaseline = NativeCameraHandleBaseline()
    private struct PendingObject: Sendable { let token = UUID(); var attempts: Int32 = 0; var next: Int64 }
    private var pendingObjects: [Int32: PendingObject] = [:]
    private var pendingOrder: [Int32] = []
    private var resolver: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var publicationRevision: UInt64 = 0
    private var receivedEventRevision: UInt64?
    private var closed = false
    private var resolverFailed = false
    private(set) var needsEventRescan = false
    private let onAddition: (@Sendable (CameraCatalogAddition) async -> Void)?

    init(source: CameraCatalogSource, stationMode: Bool, previews: CameraPreviewStore? = nil,
         onAddition: (@Sendable (CameraCatalogAddition) async -> Void)? = nil) {
        self.source = source; self.stationMode = stationMode; self.previews = previews
        self.onAddition = onAddition
    }
    deinit { resolver?.cancel() }
    func snapshot() -> CameraCatalogSnapshot? { latest }

    func refresh(detectNewHandles: Bool = false) async throws -> CameraCatalogSnapshot {
        guard !closed else { throw CameraStreamError.closed }
        guard !scanning else { throw CameraStreamError.operationInProgress }
        try Task.checkCancellation()
        scanning = true
        scanGeneration &+= 1
        publicationRevision &+= 1
        defer { scanning = false; wakeResolver() }
        let fillScan = await previews?.beginCatalogScan()
        do {
            let before = await source.snapshot()
            guard before.phase == .ready else { throw CameraStreamError.notConnected }
            guard before.connectionID == source.connectionID else { throw CameraStreamError.closed }
            let stores = try await source.storageIDs()
            let scan = NativeCameraCatalogScan(rawStorageIds: Self.native(stores), stationMode: stationMode)
            var enumeratedHandles: [Int32] = []
            for index in 0..<Int(scan.storageCount) {
                try Task.checkCancellation()
                let handles = try await source.objectHandles(storageID: scan.queryStorageId(index: Int32(index)))
                guard scan.addHandles(index: Int32(index), handles: Self.native(handles)) else { throw CameraStreamError.invalidArgument }
                enumeratedHandles.append(contentsOf: handles)
            }
            guard scan.begin() else { throw CameraStreamError.invalidArgument }
            let enumerated = await source.snapshot()
            try Task.checkCancellation()
            guard !closed, enumerated.phase == .ready, enumerated.connectionID == before.connectionID else { throw CameraStreamError.closed }
            // The raw handle list is already authoritative, even if later ObjectInfo is partial.
            // Like Android, disabled detection still advances the baseline; no first-scan catch-up.
            let handleDelta = handleBaseline.acceptEnumeration(handles: Self.native(enumeratedHandles), detectNewHandles: detectNewHandles)
            while true {
                try Task.checkCancellation()
                if let handle = scan.nextReadHandle()?.int32Value {
                    let info: PtpObjectInfo?
                    do { info = try await source.objectInfo(handle: handle) }
                    catch is CameraOperationError {
                        // A fully consumed object-level rejection/incomplete dataset is a partial scan,
                        // never evidence that the file was deleted. Transport errors abort publication.
                        info = nil
                    }
                    guard scan.accept(handle: handle, info: info) else { throw CameraStreamError.invalidArgument }
                } else if !scan.publishNext() { break }
            }
            let after = await source.snapshot()
            try Task.checkCancellation()
            guard !closed, after.phase == .ready, after.connectionID == before.connectionID else { throw CameraStreamError.closed }
            var files: [CameraFileInfo] = []
            var infos: [Int32: PtpObjectInfo] = [:]
            var indexedInfos: [PtpObjectInfo] = []
            for index in 0..<Int(scan.indexedObjectCount) {
                guard let info = scan.indexedObjectInfoAt(index: Int32(index)) else { throw CameraStreamError.invalidArgument }
                infos[info.handle] = info; indexedInfos.append(info)
            }
            for index in 0..<Int(scan.rowCount) {
                guard let file = scan.fileAt(index: Int32(index)) else { throw CameraStreamError.invalidArgument }
                files.append(file)
            }
            let result = CameraCatalogSnapshot(connectionID: source.connectionID, revision: before.eventRevision,
                storageIDs: (0..<Int(scan.storageCount)).map { scan.storageId(index: Int32($0)) },
                files: files, objectInfos: infos, totalHandles: Int(scan.totalHandles),
                metadataComplete: scan.metadataComplete, changedWhileScanning: before.eventRevision != after.eventRevision,
                handleDelta: handleDelta, publicationRevision: publicationRevision, indexedObjectInfos: indexedInfos)
            // Keep old complete rows on partial metadata failure; return the partial attempt explicitly
            // for diagnostics. A future incremental reconciler may merge it, never infer missing=deleted.
            if result.metadataComplete { latest = result }
            resolverFailed = false
            if result.metadataComplete && !result.changedWhileScanning && result.revision >= (receivedEventRevision ?? 0) {
                needsEventRescan = false
            }
            if let fillScan { _ = await previews?.finishCatalogScan(fillScan, snapshot: result) }
            return result
        } catch {
            if let fillScan { _ = await previews?.finishCatalogScan(fillScan, snapshot: nil) }
            throw error
        }
    }

    private static func native(_ values: [Int32]) -> KotlinIntArray {
        let array = KotlinIntArray(size: Int32(values.count))
        for (index, value) in values.enumerated() { array.set(index: Int32(index), value: value) }
        return array
    }

    /// Connection's existing observer forwards batches; never read a second copy of its AsyncStream.
    func receiveEvents(_ batch: CameraEventBatch) {
        guard !closed, batch.cursor.connectionID == source.connectionID else { return }
        if let receivedEventRevision, batch.cursor.revision <= receivedEventRevision { return }
        receivedEventRevision = batch.cursor.revision
        if batch.requiresRescan { needsEventRescan = true; return }
        for event in batch.events {
            let handle = Int32(truncatingIfNeeded: event.firstParameter)
            if event.code == Lab.shared.EVT_OBJECT_REMOVED {
                pendingObjects.removeValue(forKey: handle) // Withdraw even an in-flight metadata read.
                pendingOrder.removeAll { $0 == handle }
                needsEventRescan = true // Actual removed-row reconciliation belongs to W03/W04.
            } else if event.code == Lab.shared.EVT_OBJECT_ADDED,
                      handleBaseline.shouldResolve(handle: handle, visibleFiles: latest?.files ?? []), pendingObjects[handle] == nil {
                pendingObjects[handle] = PendingObject(next: Self.nowMs() + NewCameraObjectPolicy.shared.COALESCE_MS)
                pendingOrder.append(handle)
            }
        }
        wakeResolver()
    }

    func close() {
        closed = true; scanGeneration &+= 1; resolver?.cancel()
        pendingObjects.removeAll(); pendingOrder.removeAll()
    }

    private static func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    private func wakeResolver() {
        guard !closed, !resolverFailed, !needsEventRescan, resolver == nil, !scanning, handleBaseline.hasSnapshot,
              latest != nil, !pendingObjects.isEmpty else { return }
        resolver = Task { [weak self] in
            while !Task.isCancelled, let delay = await self?.resolveBatch() {
                do { try await Task.sleep(nanoseconds: UInt64(max(1, delay)) * 1_000_000) }
                catch { break }
            }
            await self?.resolverFinished()
        }
    }
    private func resolverFinished() { resolver = nil; wakeResolver() }

    private func mayResolve(_ handle: Int32, token: UUID, generation: UInt64) async -> Bool {
        guard !closed, !needsEventRescan, !scanning, scanGeneration == generation, pendingObjects[handle]?.token == token else { return false }
        if let previews, !(await previews.allowsObjectResolution()) { return false }
        return !closed && !needsEventRescan && !scanning && scanGeneration == generation && pendingObjects[handle]?.token == token
            && handleBaseline.shouldResolve(handle: handle, visibleFiles: latest?.files ?? [])
    }

    private func resolveBatch() async -> Int64? {
        guard !closed, !resolverFailed, !needsEventRescan, !Task.isCancelled, let current = latest else { return nil }
        for handle in pendingOrder where !handleBaseline.shouldResolve(handle: handle, visibleFiles: current.files) {
            pendingObjects.removeValue(forKey: handle)
        }
        pendingOrder.removeAll { pendingObjects[$0] == nil }
        guard !pendingOrder.isEmpty else { return nil }
        if scanning { return NewCameraObjectPolicy.shared.COALESCE_MS }
        let now = Self.nowMs()
        let ready = pendingOrder.filter { (pendingObjects[$0]?.next ?? Int64.max) <= now }
            .prefix(Int(NewCameraObjectPolicy.shared.RESOLVE_BATCH_SIZE))
        var attempted = false
        for handle in ready {
            guard let pending = pendingObjects[handle] else { continue }
            let generation = scanGeneration
            guard await mayResolve(handle, token: pending.token, generation: generation) else { continue }
            let info: PtpObjectInfo?
            do {
                info = try await source.newObjectInfo(handle: handle, permitted: { [weak self] in
                    await self?.mayResolve(handle, token: pending.token, generation: generation) ?? false
                })
            } catch CameraStreamError.operationInProgress { continue }
            catch is CameraOperationError { info = nil }
            catch {
                if !closed { resolverFailed = true; needsEventRescan = true }
                return nil // Transport/cancellation is not five repeated reads on a poisoned connection.
            }
            let state = await source.snapshot()
            guard !Task.isCancelled, state.phase == .ready, state.connectionID == source.connectionID else {
                resolverFailed = true; return nil
            }
            // A removal may be received by the socket before the observer has forwarded its batch.
            if state.eventRevision > (receivedEventRevision ?? 0) { continue }
            guard await mayResolve(handle, token: pending.token, generation: generation), let base = latest else { continue }
            attempted = true
            if let info, info.handle == handle, let file = NewCameraObjectPolicy.shared.publicationFile(info: info) {
                let isNew = NewCameraObjectPolicy.shared.isNew(files: base.files, handle: handle, info: file)
                let files = NewCameraObjectPolicy.shared.publish(files: base.files, handle: handle, info: file)
                var infos = base.objectInfos; infos[handle] = info
                publicationRevision &+= 1
                let updated = CameraCatalogSnapshot(connectionID: base.connectionID, revision: base.revision,
                    storageIDs: base.storageIDs, files: files, objectInfos: infos, totalHandles: base.totalHandles + 1,
                    metadataComplete: base.metadataComplete, changedWhileScanning: base.changedWhileScanning,
                    publicationRevision: publicationRevision, indexedObjectInfos: base.indexedObjectInfos + [info])
                latest = updated; handleBaseline.recordPublished(handle: handle)
                pendingObjects.removeValue(forKey: handle); pendingOrder.removeAll { $0 == handle }
                let media = isNew && NewCameraObjectPolicy.shared.automaticMedia(file: file) ? file : nil
                _ = await previews?.reconcile(updated)
                guard !closed, !Task.isCancelled else { return nil }
                if let onAddition { await onAddition(CameraCatalogAddition(snapshot: updated, info: info, newMedia: media)) }
            } else if var retry = pendingObjects[handle], retry.token == pending.token {
                retry.attempts += 1
                if retry.attempts >= NewCameraObjectPolicy.shared.RESOLVE_MAX_ATTEMPTS {
                    pendingObjects.removeValue(forKey: handle); pendingOrder.removeAll { $0 == handle }
                } else {
                    retry.next = Self.nowMs() + NewCameraObjectPolicy.shared.retryDelayMs(attempts: retry.attempts)
                    pendingObjects[handle] = retry
                }
            }
        }
        guard !pendingObjects.isEmpty else { return nil }
        // Blocked preview/scan retries are admission checks only; they send no command or TID.
        let untilNext = (pendingObjects.values.map(\.next).min() ?? now) - Self.nowMs()
        return untilNext > 0 ? min(NewCameraObjectPolicy.shared.COALESCE_MS, untilNext)
            : (attempted ? 1 : NewCameraObjectPolicy.shared.COALESCE_MS)
    }
}
