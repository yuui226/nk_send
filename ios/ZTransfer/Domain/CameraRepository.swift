import Foundation

enum CameraRepositoryError: Error, Equatable, Sendable {
    case invalidDataset
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
    private var activeCatalogScans = 0
    private var catalogLoading: Bool { activeCatalogScans > 0 }
    private var catalogFiles: [UInt32: CameraFile] = [:]
    private var catalogStorageIDs: [UInt32] = []
    private var knownHandles = Set<UInt32>()
    private var catalogReady = false
    private var lastCatalogCheck = ContinuousClock.now
    private var catalogSyncRequested = false
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

    func loadCatalog() async throws -> [CameraFile] {
        activeCatalogScans += 1
        defer { activeCatalogScans -= 1; scheduleObjectResolver() }
        let raw = try await loadStorageIDs()
        let storageIDs = staAlbum == nil ? raw : Array(Set(raw.filter { $0 != 0 && $0 != .max })).sorted()
        let queries = staAlbum == nil && storageIDs.isEmpty ? [UInt32.max] : storageIDs
        var groups: [(storage: UInt32, handles: [UInt32])] = []
        var seen = Set<UInt32>()
        for storage in queries {
            let handles = try await loadObjectHandles(storageID: queryStorageID(storage))
            // The newest-first scan and duplicate suppression match Android.
            let ordered = staAlbum == nil ? handles : Array(handles.reversed())
            groups.append((storage, ordered.filter { seen.insert($0).inserted }))
        }
        if let directReader { try await directReader.prepare(groups: groups) }
        var files: [CameraFile] = []
        for group in groups {
            for handle in group.handles {
                try Task.checkCancellation()
                do {
                    if let directReader { files.append(try await directReader.file(handle: handle, storage: group.storage)) }
                    else { files.append(try await loadObjectInfo(handle: handle)) }
                } catch is CancellationError { throw CancellationError() }
                catch let error as PTPSessionError {
                    if error == .invalidated || error == .timeout { throw error }
                } catch { continue }
            }
        }
        try Task.checkCancellation()
        catalogFiles = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        catalogStorageIDs = queries
        knownHandles = seen
        catalogReady = true
        lastCatalogCheck = .now
        return files
    }

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
        let files = Array(catalogFiles.values)
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
        catalogReady && !catalogLoading && activeForegroundReads == 0 && !remoteActive
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
                    knownHandles.insert(handle); catalogFiles[handle] = file; publishCatalog()
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
