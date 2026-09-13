import Foundation

enum CameraRepositoryError: Error, Equatable, Sendable {
    case invalidDataset
    /// Remote monitor owns the channel; the list must abandon its old handle
    /// snapshot and enumerate again after monitor dismissal.
    case foregroundPreempted
}

/// Resumable handle enumeration state. Android keeps this snapshot when a
/// foreground preview interrupts metadata reads; only handles already
/// accepted by the list are marked processed.
struct PhotoScanSnapshot: Sendable {
    let storageIDs: [UInt32]
    let handleOrders: [(storageID: UInt32, handles: [UInt32])]
    var processedHandles: Set<UInt32>
    let handleQueriesSucceeded: Bool

    var remainingHandles: [(storageID: UInt32, handles: [UInt32])] {
        handleOrders.map { ($0.storageID, $0.handles.filter { !processedHandles.contains($0) }) }
    }
}

struct PhotoScanResult: Sendable {
    let files: [CameraFile]
    let removedHandles: Set<UInt32>
    let addedHandles: Set<UInt32>
    let handleQueriesSucceeded: Bool
    let metadataComplete: Bool
}

/// Protocol-level camera catalog. It deliberately exposes only operations already used by
/// the Android NikonCamera path; UI state and transfer policy stay in higher layers.
actor CameraRepository {
    private let session: PTPSession
    private var subjectTrackingActive = false
    private let staAlbum: STAAlbumAccess?
    private let directReader: STAObjectReader?
    private var prefetchedStorageIDs: [UInt32]?
    private var prefetchedHandles: (storageID: UInt32, handles: [UInt32])?
    private var activeForegroundReads = 0
    private var remoteActive = false
    private var fhdActive = false
    private var transfersBusy = false
    private var activeCatalogScans = 0
    private var catalogLoading: Bool { activeCatalogScans > 0 }
    private var catalogFiles: [UInt32: CameraFile] = [:]
    private var indexedCatalogFiles: [UInt32: CameraFile] = [:]
    private var catalogOrder: [UInt32] = []
    private var catalogStorageIDs: [UInt32] = []
    private var knownHandles = Set<UInt32>()
    private var catalogReady = false
    private var lastCatalogCheck = ContinuousClock.now
    private var catalogSyncRequested = false
    private var scanSnapshot: PhotoScanSnapshot?
    private var pendingObjects: [UInt32: (attempts: Int, ready: ContinuousClock.Instant)] = [:]
    private var eventResolveTask: Task<Void, Never>?
    private var catalogContinuations: [UUID: AsyncStream<[CameraFile]>.Continuation] = [:]

    init(session: PTPSession, staAlbum: STAAlbumAccess? = nil) {
        self.session = session; self.staAlbum = staAlbum
        self.prefetchedStorageIDs = staAlbum?.storageIDs
        self.prefetchedHandles = staAlbum?.prefetchedHandles
        self.directReader = staAlbum?.directObjectRead == true ? STAObjectReader(session: session, operations: staAlbum?.deviceInfo?.operations ?? []) : nil
    }

    deinit { eventResolveTask?.cancel() }

    func keepalive() async -> Bool {
        if activeForegroundReads > 0 { return true }
        return await session.keepaliveIfIdle()
    }

    /// Executes Android's tap-focus transaction. Nikon cameras that support
    /// StartTracking receive the tracking coordinates and then one AfDrive;
    /// unsupported bodies fall back to ChangeAfArea followed by AfDrive.
    func focusAt(trackingX: UInt32, trackingY: UInt32,
                 focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        if subjectTrackingActive {
            _ = try? await session.execute(operation: PTPConstants.endTracking)
            subjectTrackingActive = false
        }
        do {
            _ = try await session.execute(operation: PTPConstants.startTracking,
                                          parameters: [trackingX, trackingY])
            subjectTrackingActive = true
            try await Task.sleep(nanoseconds: 80_000_000)
            let af = try await afDriveAndWait()
            return RemoteFocusResult(trackingStarted: true, polls: af.polls,
                                     timedOut: af.timedOut)
        } catch PTPSessionError.responseCode(PTPConstants.operationNotSupported) {
            _ = try await session.execute(operation: PTPConstants.changeAFArea,
                                          parameters: [focusX, focusY])
            try await Task.sleep(nanoseconds: 80_000_000)
            let af = try await afDriveAndWait()
            return RemoteFocusResult(trackingStarted: false, polls: af.polls,
                                     timedOut: af.timedOut)
        }
    }

    func endSubjectTracking() async throws {
        guard subjectTrackingActive else { return }
        do { _ = try await session.execute(operation: PTPConstants.endTracking) }
        catch PTPSessionError.responseCode(PTPConstants.operationNotSupported) {}
        catch PTPSessionError.responseCode(0xA002) {}
        subjectTrackingActive = false
    }

    private func afDriveAndWait() async throws -> (polls: Int, timedOut: Bool) {
        _ = try await session.execute(operation: PTPConstants.afDrive)
        let deadline = ContinuousClock.now + .seconds(6)
        var polls = 0
        while ContinuousClock.now < deadline {
            do {
                _ = try await session.execute(operation: PTPConstants.deviceReady,
                                              timeoutNanoseconds: 1_000_000_000)
                return (polls, false)
            } catch PTPSessionError.responseCode(PTPConstants.deviceBusy) {
                polls += 1
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        return (polls, true)
    }

    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? {
        let response = try await session.execute(operation: PTPConstants.getDevicePropDesc,
                                                 parameters: [property.rawValue])
        guard let parsed = RemotePropertyCodec.parseDescription(response.data) else { return nil }
        return RemotePropertyDescriptor(property: property, dataType: parsed.dataType,
                                        writable: parsed.writable,
                                        current: UInt64(bitPattern: parsed.current),
                                        values: parsed.values.map { UInt64(bitPattern: $0) })
    }

    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws {
        guard let encoded = RemotePropertyCodec.encode(Int64(bitPattern: value), dataType: descriptor.dataType) else {
            throw CameraRepositoryError.invalidDataset
        }
        _ = try await session.execute(operation: PTPConstants.setDevicePropValue,
                                      parameters: [descriptor.property.rawValue], data: encoded)
    }

    /// Starts Nikon Live View using the same bounded busy retry and DeviceReady
    /// poll as Android RemoteLab. A successful call means the camera is ready
    /// to accept frame requests; callers still wait for the first frame.
    func startLiveView() async throws {
        remoteActive = true
        var started = false
        defer { if !started { remoteActive = false; scheduleObjectResolver() } }
        var attempts = 0
        while true {
            do {
                _ = try await session.execute(operation: PTPConstants.startLiveView)
                break
            } catch PTPSessionError.responseCode(let code)
                where (code == PTPConstants.deviceBusy || code == 0xA004) && attempts < 5 {
                attempts += 1
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            do {
                _ = try await session.execute(operation: PTPConstants.deviceReady,
                                              timeoutNanoseconds: 1_000_000_000)
                started = true
                return
            } catch PTPSessionError.responseCode(let code) where code == PTPConstants.deviceBusy {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw PTPSessionError.timeout
    }

    func endLiveView() async {
        defer { remoteActive = false; scheduleObjectResolver() }
        _ = try? await session.execute(operation: PTPConstants.endLiveView)
    }

    /// Requests one JPEG frame. Enhanced metadata frames are preferred and
    /// fall back to the standard Nikon operation when unsupported.
    func liveViewFrame(preferEnhanced: Bool = true) async throws -> Data {
        if preferEnhanced {
            do {
                let data = try await session.execute(operation: PTPConstants.getLiveViewImageEx).data
                if !data.isEmpty { return data }
            } catch PTPSessionError.responseCode(let code)
                where code == PTPConstants.operationNotSupported || code == 0xA00B {
                // Fall through to the standard frame operation.
            }
        }
        return try await session.execute(operation: PTPConstants.getLiveViewImage).data
    }

    func capturePhoto() async throws {
        _ = try await session.execute(operation: PTPConstants.captureInMedia)
    }

    func startMovieRecording() async throws -> RemoteMovieStartResult {
        let response = try await movieCommandWithBusyRetry(PTPConstants.startMovieRecording)
        var prohibitCondition: UInt32?
        if response != PTPConstants.responseOK {
            do {
                // RemoteLab.PROP_NK_MOV_PROHIBIT: read only after a failed start,
                // including bit 10 when the camera is already recording.
                let data = try await session.execute(operation: PTPConstants.getDevicePropValue,
                                                     parameters: [0xD0A4]).data
                if data.count >= 4 {
                    prohibitCondition = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
                }
            } catch PTPSessionError.responseCode(_) {
                // Android keeps the start response when the optional property
                // returns a negative response. Transport errors still propagate.
            }
        }
        try Task.checkCancellation()
        return RemoteMovieStartResult(responseCode: response, prohibitCondition: prohibitCondition)
    }

    func endMovieRecording() async throws -> UInt16 {
        try await movieCommandWithBusyRetry(PTPConstants.endMovieRecording)
    }

    private func movieCommandWithBusyRetry(_ operation: UInt16) async throws -> UInt16 {
        let session = self.session
        return try await RemoteMovieCommandRetry.execute {
            do { return try await session.execute(operation: operation).code }
            catch PTPSessionError.responseCode(let response) { return response }
        }
    }

    func loadDeviceInfo() async throws -> PTPDeviceInfo {
        if let info = staAlbum?.deviceInfo { return info }
        let result = try await session.execute(operation: PTPConstants.getDeviceInfo)
        guard let info = PTPDatasetParser.parseDeviceInfo(result.data) else { throw CameraRepositoryError.invalidDataset }
        return info
    }

    /// Stable per-body cache identity. A network session without an announced
    /// serial deliberately returns nil rather than mixing thumbnails between
    /// cameras, matching Android's camera-scoped cache invariant.
    func thumbnailCacheIdentity() -> String? {
        guard let info = staAlbum?.deviceInfo,
              !info.serialNumber.isEmpty else { return nil }
        return "\(info.manufacturer)\u{0}\(info.model)\u{0}\(info.serialNumber)"
    }

    func usesDirectThumbnailRead() -> Bool { directReader != nil }
    func backgroundThumbnailFillAllowed() -> Bool {
        activeForegroundReads == 0 && !remoteActive && !fhdActive && !transfersBusy
    }

    func setTransfersBusy(_ busy: Bool) { transfersBusy = busy }

    /// Foreground FHD preview has priority over catalog metadata reads.  The
    /// scan keeps its handle snapshot and resumes at the same cursor when the
    /// preview releases the channel.
    func setFHDActive(_ active: Bool) { fhdActive = active }

    private func waitForForegroundPreview() async throws {
        // Android cancels a list scan when remote monitor takes ownership. The
        // monitor may capture new media, so its next list load must enumerate
        // fresh handles instead of resuming the old snapshot.
        if remoteActive {
            scanSnapshot = nil
            throw CameraRepositoryError.foregroundPreempted
        }
        // Interactive FHD is a short same-session pause and resumes at the
        // existing cursor after the preview releases the channel.
        while fhdActive {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func loadStorageIDs() async throws -> [UInt32] {
        if let ids = prefetchedStorageIDs { prefetchedStorageIDs = nil; return ids }
        let result = try await catalogCommand(PTPConstants.getStorageIDs)
        guard let ids = PTPDatasetParser.readStorageIDs(result.data) else { throw CameraRepositoryError.invalidDataset }
        return ids
    }

    func loadObjectHandles(storageID: UInt32 = 0xFFFFFFFF) async throws -> [UInt32] {
        if let prefetch = prefetchedHandles, prefetch.storageID == storageID {
            prefetchedHandles = nil; return prefetch.handles
        }
        let result = try await catalogCommand(PTPConstants.getObjectHandles, [storageID, .max, 0])
        guard let handles = PTPDatasetParser.readObjectHandles(result.data) else { throw CameraRepositoryError.invalidDataset }
        return handles
    }

    private struct ObjectHandlesStatus: Sendable {
        let handles: [UInt32]
        let successful: Bool
        let responseCode: UInt16?
    }

    /// Status-preserving query used by the list scan. Android treats a
    /// non-STA response-level failure as an incomplete scan (retaining rows),
    /// while STA retries DeviceBusy and reconnects after the third failure.
    private func loadObjectHandlesWithStatus(storageID: UInt32) async throws -> ObjectHandlesStatus {
        if let prefetch = prefetchedHandles, prefetch.storageID == storageID {
            prefetchedHandles = nil
            return ObjectHandlesStatus(handles: prefetch.handles, successful: true,
                                       responseCode: PTPConstants.responseOK)
        }
        do {
            let response = try await session.executeResponse(
                operation: PTPConstants.getObjectHandles,
                parameters: [storageID, .max, 0],
                timeoutNanoseconds: 60_000_000_000
            )
            guard response.code == PTPConstants.responseOK,
                  let handles = PTPDatasetParser.readObjectHandles(response.data) else {
                return ObjectHandlesStatus(handles: [], successful: false, responseCode: response.code)
            }
            return ObjectHandlesStatus(handles: handles, successful: true, responseCode: response.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ObjectHandlesStatus(handles: [], successful: false, responseCode: nil)
        }
    }

    func loadObjectInfo(handle: UInt32) async throws -> CameraFile {
        let result = try await session.execute(operation: PTPConstants.getObjectInfo, parameters: [handle])
        guard let file = PTPDatasetParser.parseObjectInfo(handle: handle, result.data) else { throw CameraRepositoryError.invalidDataset }
        return file
    }

    func thumbnail(handle: UInt32) async throws -> Data {
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        if let directReader { return try await directReader.thumbnail(handle: handle) }
        return try await session.execute(operation: PTPConstants.getThumb, parameters: [handle]).data
    }

    /// Android's preview order: FHD picture first, then Nikon large thumb, then
    /// the standard thumbnail when the camera reports the operation unsupported.
    func preview(handle: UInt32) async throws -> Data {
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        if let directReader { return try await directReader.preview(handle: handle) }
        var lastError: Error?
        for operation in [PTPConstants.getFHDPicture, PTPConstants.getLargeThumb, PTPConstants.getThumb] {
            do {
                let data = try await session.execute(operation: operation, parameters: [handle]).data
                if !data.isEmpty { return data }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CameraRepositoryError.invalidDataset
    }

    func readPrefix(handle: UInt32, length: Int64) async throws -> Data {
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        let count = max(0, min(length, Int64(UInt32.max)))
        if let directReader {
            return try await directReader.exifHeader(handle: handle, length: Int(count))
        }
        let result = try await session.execute(
            operation: PTPConstants.getPartialObjectEx,
            parameters: [handle, 0, 0, UInt32(count & 0xFFFF_FFFF), UInt32(count >> 32)]
        )
        return result.data
    }

    /// PTP/IP and USB share the same serialized operation path. A temporary
    /// file is written first, then atomically moved into the destination so a
    /// cancellation or disconnect never leaves a valid-looking partial file.
    func download(handle: UInt32, size: UInt64, fileName: String, to directory: URL,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        activeForegroundReads += 1; defer { activeForegroundReads -= 1; scheduleObjectResolver() }
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let destination = directory.appendingPathComponent(safeName, isDirectory: false)
        let temporary = destination.appendingPathExtension("ztransfer-partial")
        try? FileManager.default.removeItem(at: temporary)
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        do {
            let total: UInt64
            if size == UInt64(UInt32.max) || size == 0 {
                let sizeData = try await session.execute(operation: PTPConstants.getObjectSize, parameters: [handle]).data
                guard sizeData.count >= 8 else { throw CameraRepositoryError.invalidDataset }
                total = sizeData.readUInt64LE(at: 0)
            } else {
                total = size
            }
            guard total > 0 else { throw CameraRepositoryError.invalidDataset }
            let chunk: UInt64 = 4 * 1024 * 1024
            var offset: UInt64 = 0
            let handleForWriting = try FileHandle(forWritingTo: temporary)
            defer { try? handleForWriting.close() }
            while offset < total {
                try Task.checkCancellation()
                let request = min(chunk, total - offset)
                let result = try await session.execute(
                    operation: PTPConstants.getPartialObjectEx,
                    parameters: [handle, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(request), UInt32(request >> 32)],
                    timeoutNanoseconds: staAlbum == nil ? 45_000_000_000 : 60_000_000_000
                )
                try handleForWriting.write(contentsOf: result.data)
                offset += UInt64(result.data.count)
                guard !result.data.isEmpty else { throw CameraRepositoryError.invalidDataset }
                progress?(min(1, Double(offset) / Double(total)))
            }
            try handleForWriting.close()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            progress?(1)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func scanCatalog(
        preserveExisting: Bool = false,
        resumeSnapshot: PhotoScanSnapshot? = nil,
        detectNewHandles: Bool = false,
        onBatch: (@Sendable ([CameraFile]) async throws -> Void)? = nil
    ) async throws -> PhotoScanResult {
        activeCatalogScans += 1
        defer { activeCatalogScans -= 1; scheduleObjectResolver() }

        // A resume snapshot is valid only for this repository/session.  A fresh
        // scan invalidates old rows and cache state exactly like Android.
        let reusable = resumeSnapshot ?? (preserveExisting ? scanSnapshot : nil)
        if !preserveExisting && reusable == nil {
            catalogFiles.removeAll(keepingCapacity: true)
            indexedCatalogFiles.removeAll(keepingCapacity: true)
            catalogOrder.removeAll(keepingCapacity: true)
            knownHandles.removeAll(keepingCapacity: true)
            catalogStorageIDs.removeAll(keepingCapacity: true)
            scanSnapshot = nil
        }
        var existingFiles = preserveExisting
            ? catalogOrder.compactMap { catalogFiles[$0] }
            : []
        var existingHandles = Set(existingFiles.map(\.id))
        var addedHandles = Set<UInt32>()
        var removedHandles = Set<UInt32>()

        let storageIDs: [UInt32]
        var groups: [(storage: UInt32, handles: [UInt32])]
        var handleQueriesSucceeded = true
        if let reusable {
            storageIDs = reusable.storageIDs
            groups = reusable.remainingHandles.map { ($0.storageID, $0.handles) }
            handleQueriesSucceeded = reusable.handleQueriesSucceeded
            scanSnapshot = reusable
        } else {
            let raw: [UInt32]
            do {
                raw = try await loadStorageIDs()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Android's non-STA getStorageIds() maps a command/transport
                // failure to an empty result; the no-usable-storage branch
                // completes the scan without authorizing cache reconciliation.
                if staAlbum != nil { throw error }
                raw = []
            }
            // Android ignores sentinel/invalid stores and, for non-STA
            // transports, stores whose low 16 bits are zero. STA also drops
            // only the sentinel values because its wildcard mapping is
            // handled by queryStorageID below.
            storageIDs = Array(Set(raw.filter { id in
                guard id != 0 && id != .max else { return false }
                return staAlbum != nil || (id & 0xFFFF) != 0
            })).sorted()
            if storageIDs.isEmpty {
                // An empty/failed storage response is not authoritative. The
                // Android path removes only handles from an established
                // baseline; a first scan keeps any rows already published by
                // an earlier partial result.
                removedHandles = knownHandles.isEmpty ? [] : knownHandles.intersection(existingHandles)
                for handle in removedHandles {
                    catalogFiles.removeValue(forKey: handle)
                    indexedCatalogFiles.removeValue(forKey: handle)
                }
                catalogOrder.removeAll { removedHandles.contains($0) }
                existingFiles.removeAll()
                existingHandles.removeAll()
                knownHandles.removeAll()
                catalogStorageIDs.removeAll()
                scanSnapshot = nil
                catalogReady = true
                lastCatalogCheck = .now
                publishCatalog()
                return PhotoScanResult(files: [], removedHandles: removedHandles,
                                       addedHandles: [], handleQueriesSucceeded: false,
                                       metadataComplete: true)
            }
            let queries = storageIDs
            groups = []
            var seen = Set<UInt32>()
            for storage in queries {
                let query = queryStorageID(storage)
                var attempts = 1
                var result = try await loadObjectHandlesWithStatus(storageID: query)
                while staAlbum != nil && !result.successful,
                      result.responseCode == PTPConstants.deviceBusy && attempts < 3 {
                    try await Task.sleep(nanoseconds: 750_000_000)
                    attempts += 1
                    result = try await loadObjectHandlesWithStatus(storageID: query)
                }
                guard result.successful else {
                    handleQueriesSucceeded = false
                    if staAlbum != nil {
                        throw PTPSessionError.responseCode(result.responseCode ?? PTPConstants.deviceBusy)
                    }
                    // Android keeps the partial list for a non-STA response
                    // failure and skips authoritative cache reconciliation.
                    groups.append((storage, []))
                    continue
                }
                // Nikon returns handles old→new; Android reverses every
                // storage (USB, STA and aggregate queries) to read newest first.
                let ordered = Array(result.handles.reversed())
                groups.append((storage, ordered.filter { seen.insert($0).inserted }))
            }
            let currentHandles = Set(groups.flatMap(\.handles))
            if handleQueriesSucceeded {
                if preserveExisting { removedHandles = knownHandles.subtracting(currentHandles) }
                if detectNewHandles { addedHandles = currentHandles.subtracting(knownHandles) }
                for handle in removedHandles { catalogFiles.removeValue(forKey: handle) }
                for handle in removedHandles { indexedCatalogFiles.removeValue(forKey: handle) }
                catalogOrder.removeAll { removedHandles.contains($0) }
                existingFiles.removeAll { removedHandles.contains($0.id) }
                existingHandles.subtract(removedHandles)
                knownHandles = currentHandles
                catalogStorageIDs = storageIDs
            }
            scanSnapshot = PhotoScanSnapshot(
                storageIDs: storageIDs,
                handleOrders: groups.map { ($0.storage, $0.handles) },
                processedHandles: Set(existingHandles),
                handleQueriesSucceeded: handleQueriesSucceeded
            )
            // Preserve the Android refresh contract: metadata is requested only
            // for handles not already published in this camera session.
            if preserveExisting {
                groups = groups.map { ($0.storage, $0.handles.filter { !existingHandles.contains($0) }) }
            }
        }
        if let directReader { try await directReader.prepare(groups: groups) }

        var files = existingFiles
        var byIdentity = Dictionary(uniqueKeysWithValues: files.map { (logicalIdentity($0), $0) })
        var indexed = indexedCatalogFiles
        var batch: [CameraFile] = []
        // STA direct metadata intentionally publishes the first frame as a
        // 1-item batch, then a 3-item warm-up batch, before settling at 12.
        // This is the same first-content latency strategy as
        // `streamStaDirectFileInfo`; ordinary ObjectInfo scans stay at 12.
        var directPublishedCount = 0
        var metadataComplete = true
        var cursors = Array(repeating: 0, count: groups.count)
        var heads = Array<CameraFile?>(repeating: nil, count: groups.count)
        while true {
            try Task.checkCancellation()
            try await waitForForegroundPreview()
            // Fill one head per storage, then select the newest capture date.
            // This is Android's dynamic dual-card merge; handle values never
            // participate in ordering because Nikon embeds format bits in them.
            for index in groups.indices where heads[index] == nil {
                while cursors[index] < groups[index].handles.count {
                    let handle = groups[index].handles[cursors[index]]
                    cursors[index] += 1
                    do {
                        let file: CameraFile
                        if let directReader { file = try await directReader.file(handle: handle, storage: groups[index].storage) }
                        else { file = try await loadObjectInfo(handle: handle) }
                        heads[index] = file
                        break
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as PTPSessionError {
                        if error == .invalidated || error == .timeout { throw error }
                        metadataComplete = false
                    } catch { metadataComplete = false }
                }
            }
            guard let selectedIndex = groups.indices
                .filter({ heads[$0] != nil })
                .max(by: { lhs, rhs in
                    let left = heads[lhs]!.captureDate ?? ""
                    let right = heads[rhs]!.captureDate ?? ""
                    if left == right { return lhs > rhs }
                    return left < right
                }),
                let file = heads[selectedIndex] else { break }
            heads[selectedIndex] = nil
            let key = logicalIdentity(file)
            indexed[file.id] = file
            if let old = byIdentity[key] {
                let merged = old.storageIDs == old.storageIDs.union(file.storageIDs)
                    ? old
                    : CameraFile(id: old.id, storageID: old.storageID, format: old.format,
                                 size: old.size, fileName: old.fileName,
                                 captureDate: old.captureDate, isProtected: old.isProtected,
                                 storageIDs: old.storageIDs.union(file.storageIDs))
                if merged != old, let position = files.firstIndex(of: old) {
                    files[position] = merged
                    byIdentity[key] = merged
                }
            } else {
                byIdentity[key] = file
                files.append(file)
                batch.append(file)
            }
            scanSnapshot?.processedHandles.insert(file.id)
            let batchLimit: Int = directReader == nil ? 12 :
                (directPublishedCount == 0 ? 1 : directPublishedCount < 4 ? 3 : 12)
            if batch.count >= batchLimit {
                try await onBatch?(batch)
                directPublishedCount += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try await onBatch?(batch) }
        try Task.checkCancellation()
        catalogFiles = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        indexedCatalogFiles = indexed
        catalogOrder = files.map(\.id)
        // Only a complete handle snapshot is authoritative. Android keeps the
        // previous baseline after a partial/non-STA response so the next scan
        // can still compute real additions/removals instead of diffing against
        // an incomplete list.
        if handleQueriesSucceeded {
            knownHandles = Set(groups.flatMap(\.handles)).union(Set(existingHandles))
            catalogStorageIDs = storageIDs
        }
        catalogReady = metadataComplete && handleQueriesSucceeded
        lastCatalogCheck = .now
        if catalogReady { scanSnapshot = nil }
        publishCatalog()
        return PhotoScanResult(files: files, removedHandles: removedHandles,
                               addedHandles: addedHandles,
                               handleQueriesSucceeded: handleQueriesSucceeded,
                               metadataComplete: metadataComplete)
    }

    private func logicalIdentity(_ file: CameraFile) -> String {
        "\(file.fileName)|\(file.size)|\(file.captureDate ?? "")"
    }

    /// Compatibility entry point used by non-list callers.
    func loadCatalog(onBatch: (@Sendable ([CameraFile]) async throws -> Void)? = nil) async throws -> [CameraFile] {
        try await scanCatalog(onBatch: onBatch).files
    }

    /// Metadata stream used by the photo list. The underlying scan remains
    /// serialized on this repository actor; each accepted 12-item batch is
    /// yielded at the same boundary as Android's pipeline.
    private func queryStorageID(_ storage: UInt32) -> UInt32 {
        staAlbum != nil && storage & 0xFFFF == 0 ? .max : storage
    }
    private func catalogCommand(_ operation: UInt16, _ parameters: [UInt32] = []) async throws -> PTPResponse {
        var attempts = 0
        while true {
            let response = try await session.executeResponse(operation: operation, parameters: parameters, timeoutNanoseconds: 60_000_000_000)
            if response.code == PTPConstants.responseOK { return response }
            attempts += 1
            if staAlbum != nil && response.code == PTPConstants.deviceBusy && attempts < 3 {
                try await Task.sleep(nanoseconds: 750_000_000)
            } else { throw PTPSessionError.responseCode(response.code) }
        }
    }

    func catalogUpdates() -> AsyncStream<[CameraFile]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            catalogContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeCatalogListener(id) } }
        }
    }
    private func removeCatalogListener(_ id: UUID) { catalogContinuations.removeValue(forKey: id) }
    private func publishCatalog() {
        let files = catalogOrder.compactMap { catalogFiles[$0] }
        for continuation in catalogContinuations.values { continuation.yield(files) }
    }
    func stopMonitoring() {
        eventResolveTask?.cancel(); eventResolveTask = nil
        catalogReady = false; pendingObjects.removeAll()
        catalogContinuations.values.forEach { $0.finish() }
        catalogContinuations.removeAll()
    }
    func receiveEvent(_ payload: Data) {
        if let event = STAEvent.socket(payload) { receiveEvent(event) }
    }
    private func receiveEvent(_ event: STAEvent) {
        switch event.code {
        case 0x4002:
            guard event.handle != 0, event.handle != .max,
                  !knownHandles.contains(event.handle), catalogFiles[event.handle] == nil else { return }
            if pendingObjects[event.handle] == nil { pendingObjects[event.handle] = (0, .now.advanced(by: .milliseconds(90))) }
            scheduleObjectResolver()
        case 0x4003:
            pendingObjects.removeValue(forKey: event.handle)
            if event.handle != 0 && event.handle != .max && catalogReady && !knownHandles.contains(event.handle) { return }
            catalogSyncRequested = true
        default: break
        }
    }
    private var backgroundReadsAllowed: Bool {
        catalogReady && !catalogLoading && activeForegroundReads == 0 &&
            !remoteActive && !fhdActive && !transfersBusy
    }
    /// Android's 2 s polling and 10 s handle-only reconciliation. Never turn a
    /// failed/DeviceBusy response into an authoritative empty card.
    func maintainCatalogIfIdle() async {
        guard staAlbum != nil, backgroundReadsAllowed, !(await session.hasPendingCommand) else { return }
        if catalogSyncRequested || lastCatalogCheck.duration(to: .now) >= .seconds(10) {
            catalogSyncRequested = false
            lastCatalogCheck = .now
            do { try await syncHandleCatalog() } catch { catalogSyncRequested = true }
        }
        guard backgroundReadsAllowed, !Task.isCancelled else { return }
        do {
            var result = try await session.executeResponse(operation: PTPConstants.nikonCompatibilityInit, timeoutNanoseconds: 60_000_000_000)
            var extended = true
            if result.code == PTPConstants.operationNotSupported {
                extended = false
                result = try await session.executeResponse(operation: 0x90C7, timeoutNanoseconds: 60_000_000_000)
            }
            if result.code == PTPConstants.responseOK {
                for event in STAEvent.polled(result.data, extended: extended) ?? [] { receiveEvent(event) }
            }
        } catch {}
        scheduleObjectResolver()
    }
    private func syncHandleCatalog() async throws {
        var current = Set<UInt32>()
        for query in Set(catalogStorageIDs.map(queryStorageID)).sorted() {
            let reply = try await session.execute(operation: PTPConstants.getObjectHandles,
                parameters: [query, .max, 0], timeoutNanoseconds: 60_000_000_000)
            guard let handles = PTPDatasetParser.readObjectHandles(reply.data) else { throw CameraRepositoryError.invalidDataset }
            current.formUnion(handles)
        }
        guard backgroundReadsAllowed, !Task.isCancelled else { catalogSyncRequested = true; return }
        let removed = knownHandles.subtracting(current)
        for handle in removed {
            catalogFiles.removeValue(forKey: handle); pendingObjects.removeValue(forKey: handle)
            catalogOrder.removeAll { $0 == handle }
            await directReader?.invalidate(handle: handle)
        }
        knownHandles.subtract(removed)
        if !removed.isEmpty { publishCatalog() }
        for handle in current.subtracting(knownHandles) { receiveEvent(STAEvent(code: 0x4002, handle: handle)) }
    }
    private func scheduleObjectResolver() {
        guard staAlbum != nil, eventResolveTask == nil, backgroundReadsAllowed,
              let earliest = pendingObjects.values.map(\.ready).min() else { return }
        eventResolveTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: earliest) } catch { return }
            await self?.resolvePendingObjects()
        }
    }
    private func resolvePendingObjects() async {
        defer { eventResolveTask = nil; scheduleObjectResolver() }
        guard backgroundReadsAllowed, !Task.isCancelled else { return }
        let ready = Array(pendingObjects.filter { $0.value.ready <= .now }.keys.sorted().prefix(16))
        if let directReader, ready.contains(where: { pendingObjects[$0]?.attempts == 0 }) {
            // Metadata refresh is compact; missing data still falls back to headers.
            try? await directReader.refreshDates(storageIDs: catalogStorageIDs)
        }
        for handle in ready {
            guard backgroundReadsAllowed, !Task.isCancelled else { return }
            if knownHandles.contains(handle) { pendingObjects.removeValue(forKey: handle); continue }
            do {
                let file: CameraFile
                if let directReader {
                    var storage = catalogStorageIDs.count == 1 ? catalogStorageIDs[0] : UInt32.max
                    if catalogStorageIDs.count > 1 {
                        for id in catalogStorageIDs {
                            if try await loadObjectHandles(storageID: queryStorageID(id)).contains(handle) { storage = id; break }
                        }
                    }
                    file = try await directReader.file(handle: handle, storage: storage)
                } else { file = try await loadObjectInfo(handle: handle) }
                guard backgroundReadsAllowed, !Task.isCancelled else { return }
                if pendingObjects.removeValue(forKey: handle) != nil {
                    knownHandles.insert(handle); catalogFiles[handle] = file
                    catalogOrder.append(handle)
                    publishCatalog()
                }
            } catch {
                guard var pending = pendingObjects[handle] else { continue }
                pending.attempts += 1
                if pending.attempts >= 5 { pendingObjects.removeValue(forKey: handle) }
                else {
                    pending.ready = .now.advanced(by: .milliseconds([180, 360, 720, 1400][pending.attempts - 1]))
                    pendingObjects[handle] = pending
                }
            }
        }
    }

}

private extension Data {
    func readUInt64LE(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return UInt64(self[startIndex + offset]) |
            UInt64(self[startIndex + offset + 1]) << 8 |
            UInt64(self[startIndex + offset + 2]) << 16 |
            UInt64(self[startIndex + offset + 3]) << 24 |
            UInt64(self[startIndex + offset + 4]) << 32 |
            UInt64(self[startIndex + offset + 5]) << 40 |
            UInt64(self[startIndex + offset + 6]) << 48 |
            UInt64(self[startIndex + offset + 7]) << 56
    }
}
