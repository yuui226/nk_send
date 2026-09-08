import Foundation
import ZTransferShared

protocol CameraCatalogSource: AnyObject {
    var connectionID: UUID { get }
    func storageIDs() async throws -> [Int32]
    func objectHandles(storageID: Int32) async throws -> [Int32]
    func objectInfo(handle: Int32) async throws -> PtpObjectInfo
    func snapshot() async -> CameraConnectionSnapshot
    func newObjectInfo(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> PtpObjectInfo
    func catalogStorageIDs(permitted: @escaping @Sendable () async -> Bool) async throws -> [Int32]
    func catalogObjectHandles(storageID: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> [Int32]
    func catalogObjectInfo(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> PtpObjectInfo
}

extension CameraCatalogSource {
    func catalogStorageIDs(permitted: @escaping @Sendable () async -> Bool) async throws -> [Int32] {
        guard await permitted() else { throw CameraStreamError.operationInProgress }
        return try await storageIDs()
    }
    func catalogObjectHandles(storageID: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> [Int32] {
        guard await permitted() else { throw CameraStreamError.operationInProgress }
        return try await objectHandles(storageID: storageID)
    }
    func catalogObjectInfo(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> PtpObjectInfo {
        guard await permitted() else { throw CameraStreamError.operationInProgress }
        return try await objectInfo(handle: handle)
    }
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
/// One connection-owned worker coalesces event invalidations. Only authoritative, complete,
/// same-generation results replace rows; automatic admission remains a separate coordinator.
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
    private let onChange: (@Sendable (CameraCatalogSnapshot) async -> Void)?
    private struct ChangeRequest: Sendable { let token: UInt64; let full: Bool }
    private var changeSerial: UInt64 = 0
    private var pendingChange: ChangeRequest?
    private var changeWorker: Task<Void, Never>?
    // Full manual enumeration commits its baseline before metadata, just like Android. Keep these
    // candidates across a failed/raced scan so that this early commit cannot swallow event catch-up.
    private var scanCatchupHandles = Set<Int32>()
    private var scanCatchupMedia: [Int32: CameraFileInfo] = [:]
    private var activeScanNewHandles = Set<Int32>()

    init(source: CameraCatalogSource, stationMode: Bool, previews: CameraPreviewStore? = nil,
         onAddition: (@Sendable (CameraCatalogAddition) async -> Void)? = nil,
         onChange: (@Sendable (CameraCatalogSnapshot) async -> Void)? = nil) {
        self.source = source; self.stationMode = stationMode; self.previews = previews
        self.onAddition = onAddition
        self.onChange = onChange
    }
    deinit { resolver?.cancel(); changeWorker?.cancel() }
    func snapshot() -> CameraCatalogSnapshot? { latest }

    func refresh(detectNewHandles: Bool = false) async throws -> CameraCatalogSnapshot {
        try await scanCatalog(detectNewHandles: detectNewHandles, change: nil)
    }

    private func scanCatalog(detectNewHandles: Bool, change: ChangeRequest?) async throws -> CameraCatalogSnapshot {
        guard !closed else { throw CameraStreamError.closed }
        guard !scanning else { throw CameraStreamError.operationInProgress }
        try Task.checkCancellation()
        scanning = true
        scanGeneration &+= 1
        let generation = scanGeneration
        publicationRevision &+= 1
        activeScanNewHandles.removeAll()
        defer { scanning = false; activeScanNewHandles.removeAll(); wakeChanges(); wakeResolver() }
        let fillScan = await previews?.beginCatalogScan()
        do {
            let before = await source.snapshot()
            guard before.phase == .ready else { throw CameraStreamError.notConnected }
            guard before.connectionID == source.connectionID else { throw CameraStreamError.closed }
            let admission: @Sendable () async -> Bool = { [weak self] in
                guard let change else { return true }
                return await self?.mayChange(change, generation: generation, duringScan: true) ?? false
            }
            let stores: [Int32]
            if change != nil { stores = try await source.catalogStorageIDs(permitted: admission) }
            else { stores = try await source.storageIDs() }
            let scan = NativeCameraCatalogScan(rawStorageIds: Self.native(stores), stationMode: stationMode)
            var enumeratedHandles: [Int32] = []
            for index in 0..<Int(scan.storageCount) {
                try Task.checkCancellation()
                let handles: [Int32]
                if change != nil {
                    handles = try await source.catalogObjectHandles(storageID: scan.queryStorageId(index: Int32(index)), permitted: admission)
                } else { handles = try await source.objectHandles(storageID: scan.queryStorageId(index: Int32(index))) }
                guard scan.addHandles(index: Int32(index), handles: Self.native(handles)) else { throw CameraStreamError.invalidArgument }
                enumeratedHandles.append(contentsOf: handles)
            }
            guard scan.begin() else { throw CameraStreamError.invalidArgument }
            let enumerated = await source.snapshot()
            try Task.checkCancellation()
            guard !closed, enumerated.phase == .ready, enumerated.connectionID == before.connectionID else { throw CameraStreamError.closed }
            // The raw handle list is already authoritative, even if later ObjectInfo is partial.
            // Like Android, disabled detection still advances the baseline; no first-scan catch-up.
            if handleBaseline.hasSnapshot {
                activeScanNewHandles = Set(enumeratedHandles.filter {
                    handleBaseline.shouldResolve(handle: $0, visibleFiles: latest?.files ?? [])
                })
                scanCatchupHandles.formUnion(activeScanNewHandles.filter {
                    change != nil || detectNewHandles || pendingObjects[$0] != nil
                })
            }
            // An event-driven scan is speculative until every metadata read and revision fence pass.
            // Manual scan keeps Android's early-enumeration semantics and explicit partial result.
            var handleDelta: CameraHandleDelta?
            if change == nil {
                handleDelta = handleBaseline.acceptEnumeration(handles: Self.native(enumeratedHandles), detectNewHandles: detectNewHandles)
            }
            while true {
                try Task.checkCancellation()
                if let handle = scan.nextReadHandle()?.int32Value {
                    let info: PtpObjectInfo?
                    do {
                        if change != nil { info = try await source.catalogObjectInfo(handle: handle, permitted: admission) }
                        else { info = try await source.objectInfo(handle: handle) }
                    }
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
            if let change {
                guard await mayChange(change, generation: generation, duringScan: true),
                      before.eventRevision == after.eventRevision,
                      after.eventRevision <= (receivedEventRevision ?? 0) else {
                    throw CameraStreamError.operationInProgress
                }
                guard scan.metadataComplete else {
                    throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.GET_OBJECT_INFO)
                }
                handleDelta = handleBaseline.acceptEnumeration(handles: Self.native(enumeratedHandles), detectNewHandles: true)
            }
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
            let previousFiles = latest?.files ?? []
            if result.metadataComplete && !result.changedWhileScanning { latest = result }
            resolverFailed = false
            if result.metadataComplete && !result.changedWhileScanning && result.revision >= (receivedEventRevision ?? 0) {
                needsEventRescan = false
                if change == nil || pendingChange?.token == change?.token { pendingChange = nil }
            }
            if result.changedWhileScanning { requestChange(full: true) }
            if let fillScan { _ = await previews?.finishCatalogScan(fillScan, snapshot: result) }
            if result.metadataComplete && !result.changedWhileScanning {
                if change != nil, !closed, let onChange { await onChange(result) }
                await publishScanAdditions(result, previousFiles: previousFiles)
            }
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
        if batch.requiresRescan { requestChange(full: true); return }
        for event in batch.events {
            let handle = Int32(truncatingIfNeeded: event.firstParameter)
            if event.code == Lab.shared.EVT_OBJECT_ADDED, scanning, activeScanNewHandles.contains(handle) {
                // This scan may already have committed its raw baseline. Preserve the actual event,
                // without turning a manual detectNewHandles=false enumeration into auto discovery.
                scanCatchupHandles.insert(handle)
            }
            if event.code == Lab.shared.EVT_OBJECT_REMOVED {
                pendingObjects.removeValue(forKey: handle) // Withdraw even an in-flight metadata read.
                pendingOrder.removeAll { $0 == handle }
                scanCatchupHandles.remove(handle)
                scanCatchupMedia.removeValue(forKey: handle)
                // An unknown removed handle may still invalidate an in-progress first scan.
                if scanning || !handleBaseline.hasSnapshot || handle == 0 || handle == -1 ||
                    !handleBaseline.shouldResolve(handle: handle, visibleFiles: latest?.files ?? []) {
                    requestChange(full: false)
                }
            } else if [Int32(0x4004), 0x4005, 0x4007, 0x400C].contains(event.code) {
                // Standard StoreAdded/Removed, ObjectInfoChanged, StorageInfoChanged. NOT
                // DevicePropChanged (0x4006): exposure changes must not churn the photo catalog.
                requestChange(full: true)
            } else if event.code == Lab.shared.EVT_OBJECT_ADDED,
                      handleBaseline.shouldResolve(handle: handle, visibleFiles: latest?.files ?? []), pendingObjects[handle] == nil {
                pendingObjects[handle] = PendingObject(next: Self.nowMs() + NewCameraObjectPolicy.shared.COALESCE_MS)
                pendingOrder.append(handle)
            }
        }
        wakeResolver()
    }

    func close() {
        closed = true; scanGeneration &+= 1; resolver?.cancel(); changeWorker?.cancel()
        pendingChange = nil; scanCatchupHandles.removeAll()
        scanCatchupMedia.removeAll()
        pendingObjects.removeAll(); pendingOrder.removeAll()
    }

    private static func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    private func requestChange(full: Bool) {
        changeSerial &+= 1
        pendingChange = ChangeRequest(token: changeSerial, full: full || pendingChange?.full == true)
        needsEventRescan = true
        wakeChanges()
    }

    private func wakeChanges() {
        guard !closed, !resolverFailed, !scanning, pendingChange != nil, changeWorker == nil else { return }
        changeWorker = Task { [weak self] in
            // Coalesce Event + GetEventEx duplicates, without blocking the connection observer.
            do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return }
            while !Task.isCancelled, let delay = await self?.reconcileChange() {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) } catch { break }
            }
            await self?.changesFinished()
        }
    }
    private func changesFinished() { changeWorker = nil; wakeChanges(); wakeResolver() }

    private func mayChange(_ request: ChangeRequest, generation: UInt64, duringScan: Bool) async -> Bool {
        guard !closed, !Task.isCancelled, !resolverFailed, scanGeneration == generation,
              scanning == duringScan, pendingChange?.token == request.token else { return false }
        if let previews, !(await previews.allowsCatalogReconciliation()) { return false }
        return !closed && !Task.isCancelled && !resolverFailed && scanGeneration == generation &&
            scanning == duringScan && pendingChange?.token == request.token
    }

    /// Like Android syncCameraHandleCatalog: all required GetObjectHandles must succeed before
    /// removing anything; no ObjectInfo/thumbnail/EXIF read on this lightweight deletion path.
    private func reconcileChange() async -> Int64? {
        guard !closed, !resolverFailed, !Task.isCancelled, let request = pendingChange else { return nil }
        guard !scanning else { return 90 }
        let generation = scanGeneration
        guard await mayChange(request, generation: generation, duringScan: false) else { return 90 }
        do {
            if request.full || latest == nil || !handleBaseline.hasSnapshot {
                _ = try await scanCatalog(detectNewHandles: true, change: request)
            } else if let base = latest {
                let admission: @Sendable () async -> Bool = { [weak self] in
                    await self?.mayChange(request, generation: generation, duringScan: false) ?? false
                }
                let before = await source.snapshot()
                guard before.phase == .ready, before.connectionID == source.connectionID else { throw CameraStreamError.closed }
                let plan = NativeCameraCatalogScan(rawStorageIds: Self.native(base.storageIDs), stationMode: stationMode)
                var queries = Set<Int32>()
                var handles = Set<Int32>()
                var handleOrder: [Int32] = []
                for index in 0..<Int(plan.storageCount) {
                    let storage = plan.queryStorageId(index: Int32(index))
                    if queries.insert(storage).inserted {
                        for handle in try await source.catalogObjectHandles(storageID: storage, permitted: admission) {
                            if handles.insert(handle).inserted { handleOrder.append(handle) }
                        }
                    }
                }
                let after = await source.snapshot()
                guard await mayChange(request, generation: generation, duringScan: false),
                      after.phase == .ready, after.connectionID == before.connectionID,
                      before.eventRevision == after.eventRevision,
                      after.eventRevision <= (receivedEventRevision ?? 0) else { return 90 }
                let nativeHandles = Self.native(handleOrder)
                guard let files = NativeCameraCatalogReconciliation.shared.reconcile(publishedFiles: base.files,
                    currentHandles: nativeHandles, indexedInfos: base.indexedObjectInfos),
                    let delta = handleBaseline.acceptIdleEnumeration(handles: nativeHandles) else { return 2_000 }
                let indexed = base.indexedObjectInfos.filter { handles.contains($0.handle) }
                let infos = base.objectInfos.filter { handles.contains($0.key) }
                pendingOrder.removeAll { !handles.contains($0) }
                pendingObjects = pendingObjects.filter { handles.contains($0.key) }
                scanCatchupHandles.formIntersection(handles)
                scanCatchupMedia = scanCatchupMedia.filter { handles.contains($0.key) }
                for handle in handleOrder where handleBaseline.shouldResolve(handle: handle, visibleFiles: files) {
                    if pendingObjects[handle] == nil {
                        pendingObjects[handle] = PendingObject(next: Self.nowMs() + NewCameraObjectPolicy.shared.COALESCE_MS)
                        pendingOrder.append(handle)
                    }
                }
                publicationRevision &+= 1
                let updated = CameraCatalogSnapshot(connectionID: base.connectionID, revision: after.eventRevision,
                    storageIDs: base.storageIDs, files: files, objectInfos: infos, totalHandles: handles.count,
                    metadataComplete: true, changedWhileScanning: false, handleDelta: delta,
                    publicationRevision: publicationRevision, indexedObjectInfos: indexed)
                latest = updated
                // Consume THIS request before awaiting publication. A later event owns a new token.
                pendingChange = nil; needsEventRescan = false
                _ = await previews?.reconcile(updated)
                if !closed, !Task.isCancelled, let onChange { await onChange(updated) }
            }
        } catch CameraStreamError.operationInProgress { return 90 }
        catch is CameraOperationError { return 2_000 } // Busy/malformed/partial is never deletion.
        catch is CancellationError {
            if !closed { resolverFailed = true; needsEventRescan = true }
            return nil
        }
        catch {
            // A transport failure is not a reason to keep sending on a poisoned connection.
            if !closed { resolverFailed = true; needsEventRescan = true }
            return nil
        }
        return pendingChange == nil ? nil : 90
    }

    private func publishScanAdditions(_ result: CameraCatalogSnapshot, previousFiles: [CameraFileInfo]) async {
        var compared = previousFiles
        var additions: [CameraCatalogAddition] = []
        for info in result.indexedObjectInfos where scanCatchupHandles.contains(info.handle) {
            guard let file = NewCameraObjectPolicy.shared.publicationFile(info: info) else { continue }
            let isNew = NewCameraObjectPolicy.shared.isNew(files: compared, handle: info.handle, info: file)
            compared = NewCameraObjectPolicy.shared.publish(files: compared, handle: info.handle, info: file)
            let saved = scanCatchupMedia[info.handle]
            let sameSavedIdentity = saved?.fileName == file.fileName && saved?.size == file.size && saved?.captureDate == file.captureDate
            let media = (isNew || sameSavedIdentity) && NewCameraObjectPolicy.shared.automaticMedia(file: file) ? file : nil
            if let media { scanCatchupMedia[info.handle] = media }
            additions.append(CameraCatalogAddition(snapshot: result, info: info, newMedia: media))
        }
        // A complete scan accounts for every raw handle, including non-media/folders. Only failed
        // or raced scans retain candidates; repeating a successful scan must not enqueue them again.
        scanCatchupHandles = scanCatchupHandles.intersection(Set(result.objectInfos.keys))
        scanCatchupMedia = scanCatchupMedia.filter { scanCatchupHandles.contains($0.key) }
        for addition in additions {
            guard !closed, !Task.isCancelled, !needsEventRescan,
                  latest?.publicationRevision == result.publicationRevision else { return }
            scanCatchupHandles.remove(addition.info.handle)
            scanCatchupMedia.removeValue(forKey: addition.info.handle)
            if let onAddition { await onAddition(addition) }
        }
    }

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
