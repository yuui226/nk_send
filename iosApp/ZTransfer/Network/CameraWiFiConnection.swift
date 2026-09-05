import Foundation
import ZTransferShared

enum CameraOperationError: Error, LocalizedError {
    case rejected(operation: Int32, response: Int32), malformedDataset(operation: Int32)
    var errorDescription: String? {
        switch self {
        case .rejected(let operation, let response):
            return String(format: "相机操作 0x%04X 返回 0x%04X。", operation, response)
        case .malformedDataset(let operation):
            return String(format: "相机操作 0x%04X 返回不完整的数据，不能当作空列表。", operation)
        }
    }
}

/// Latest-state notifications, NOT an event queue. A changed revision invalidates a catalog
/// snapshot; consumers must rescan instead of using the last event as a complete change log.
struct CameraConnectionSnapshot: Sendable {
    enum Phase: Sendable { case idle, opening, ready, closing, closed }
    let connectionID: UUID
    let phase: Phase
    let eventRevision: UInt64
    let errorDescription: String?
}

/// One AP/STA connection generation. Reconnection creates a new owner; old callbacks cannot publish
/// into it. The owner holds both sockets and the command gate, with no Android/UI dependencies.
/// Raw metadata is exposed here; shared catalog policies will own merging/sorting/publication.
actor CameraWiFiConnection {
    nonisolated let connectionID = UUID()
    nonisolated let updates: AsyncStream<CameraConnectionSnapshot>
    private let notifications: AsyncStream<CameraConnectionSnapshot>.Continuation
    private let command: CameraTCPStream
    private let event: CameraTCPStream
    private let commandChannel: PtpIPChannel
    private let eventChannel: PtpIPChannel
    private let session: PtpIPCommandSession
    nonisolated let stationMode: Bool
    private var prefetchedStorageIDs: [Int32]?
    private var eventTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var phase: CameraConnectionSnapshot.Phase = .idle
    private var eventRevision: UInt64 = 0
    private var terminalError: Error?
    private var downloadActive = false
    private var partialSupport: Int32 = -1
    private let previewPolicy = NativePreviewPolicy()
    private var thumbnailCacheIdentity: String?

    init(command: CameraTCPStream, event: CameraTCPStream, stationMode: Bool = false) {
        self.command = command
        self.event = event
        commandChannel = PtpIPChannel(stream: command)
        eventChannel = PtpIPChannel(stream: event)
        self.stationMode = stationMode
        session = PtpIPCommandSession(stream: command, initialTransactionId: stationMode ? -1 : 0)
        var continuation: AsyncStream<CameraConnectionSnapshot>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        notifications = continuation
    }

    deinit {
        eventTask?.cancel()
        keepaliveTask?.cancel()
        command.close()
        event.close()
        notifications.finish()
    }

    func connect(guid: Data, stationOptions: StationConnectionOptions = StationConnectionOptions(),
                 hasPairingMarker: ((String) throws -> Bool)? = nil,
                 onPairingAcknowledged: ((String) throws -> Void)? = nil) async throws -> LabDeviceInfo? {
        guard phase == .idle else { throw terminalError ?? CameraStreamError.operationInProgress }
        guard guid.count == 16 else { throw CameraStreamError.invalidArgument }
        if stationMode, let expected = stationOptions.expectedResponderGUID,
           NikonStaBridge.shared.normalizeGuid(value: expected) == nil { throw CameraStreamError.invalidArgument }
        phase = .opening
        publish()
        do {
            try await command.connect(timeout: 15)
            try await commandChannel.sendCommandHandshake(guid: guid, name: stationMode ? "ZTransfer" : "NikonPTP",
                                                           standard: stationMode, timeout: 15)
            let acknowledgement = try await commandChannel.readControlPacket(timeout: 15)
            let ack = try await commandChannel.commandAcknowledgement(acknowledgement)
            if stationMode && !NikonStaBridge.shared.expectedResponder(
                expected: NikonStaBridge.shared.normalizeGuid(value: stationOptions.expectedResponderGUID), actual: ack.responderGuidHex
            ) { throw CameraStationError.unexpectedResponder }
            try await event.connect(timeout: 15)
            try await eventChannel.sendEventHandshake(connectionNumber: ack.connectionNumber, timeout: 15)
            let response = try await eventChannel.readControlPacket(timeout: 15)
            guard response.type == PtpConstants.shared.INIT_EVT_ACK else {
                throw PtpIPChannelError.unexpectedPacket(response.type)
            }
            try requirePhase(.opening)
            if !stationMode { startEvents() }
            let opened = try await session.execute(operationCode: PtpConstants.shared.OPEN_SESSION,
                                                   parameters: [stationMode ? 1 : ack.connectionNumber])
            guard opened.code == PtpConstants.shared.RESPONSE_OK || opened.code == PtpConstants.shared.SESSION_ALREADY_OPEN else {
                throw PtpIPSessionError.openRejected(opened.code)
            }
            let identity: LabDeviceInfo?
            if stationMode {
                try await initializeStation(options: stationOptions, responder: ack.responderGuidHex,
                                             hasMarker: hasPairingMarker, acknowledged: onPairingAcknowledged)
                // The normal STA storage-success route must NOT query DeviceInfo unconditionally.
                identity = nil
                startEvents()
            } else {
                let result = try await session.execute(operationCode: PtpConstants.shared.GET_DEVICE_INFO)
                identity = result.code == PtpConstants.shared.RESPONSE_OK
                    ? result.payload.flatMap { PtpIPChannel.deviceInfo($0) } : nil
            }
            try requirePhase(.opening)
            thumbnailCacheIdentity = previewPolicy.cameraKey(info: identity, responderGuid: ack.responderGuidHex,
                                                             sessionId: connectionID.uuidString)
            phase = .ready
            publish()
            startKeepalive()
            return identity
        } catch {
            let failure = terminalError ?? error
            await abort(error: failure)
            throw failure
        }
    }

    func storageIDs() async throws -> [Int32] {
        try requirePhase(.ready)
        if let prefetched = prefetchedStorageIDs { prefetchedStorageIDs = nil; return prefetched }
        return try await identifiers(operation: PtpConstants.shared.GET_STORAGE_IDS, parameters: [])
    }

    func thumbnailCacheKey() -> String? { phase == .ready ? thumbnailCacheIdentity : nil }

    private func initializeStation(options: StationConnectionOptions, responder: String?,
                                   hasMarker: ((String) throws -> Bool)?, acknowledged: ((String) throws -> Void)?) async throws {
        let policy = NikonStaBridge.shared
        let compatibility = try await session.execute(operationCode: policy.COMPATIBILITY_INIT)
        guard compatibility.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: policy.COMPATIBILITY_INIT, response: compatibility.code)
        }
        let storage = try await session.execute(operationCode: PtpConstants.shared.GET_STORAGE_IDS)
        let ids = storage.payload.flatMap { PtpIPChannel.identifiers($0) } ?? []
        let marked = try responder.map { try hasMarker?($0) ?? false } ?? false
        if policy.forcePairing(code: storage.code, force: options.forceProfilePairing, allow: options.allowPairing, marked: marked) {
            try await pairStation(responder: responder, acknowledged: acknowledged)
        }
        let values = KotlinIntArray(size: Int32(ids.count))
        for (index, value) in ids.enumerated() { values.set(index: Int32(index), value: value) }
        if policy.usableStorage(code: storage.code, ids: values) {
            prefetchedStorageIDs = ids
            return
        }
        let device = try await session.execute(operationCode: PtpConstants.shared.GET_DEVICE_INFO)
        let info = device.code == PtpConstants.shared.RESPONSE_OK ? device.payload.flatMap { PtpIPChannel.deviceInfo($0) } : nil
        if policy.pairingOnly(info: info) {
            guard options.allowPairing else { throw CameraStationError.pairingRequired }
            try await pairStation(responder: responder, acknowledged: acknowledged)
        }
        throw CameraStationError.albumUnavailable
    }

    private func pairStation(responder: String?, acknowledged: ((String) throws -> Void)?) async throws {
        guard let responder, let normalized = NikonStaBridge.shared.normalizeGuid(value: responder),
              let acknowledged else { throw CameraStationError.missingIdentity }
        let query = try await session.execute(operationCode: PtpConstants.shared.NK_PAIRING_QUERY)
        guard query.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: PtpConstants.shared.NK_PAIRING_QUERY, response: query.code)
        }
        let result = try await session.execute(operationCode: PtpConstants.shared.NK_PAIRING_RESULT,
                                               parameters: [PtpConstants.shared.RESPONSE_OK])
        guard result.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: PtpConstants.shared.NK_PAIRING_RESULT, response: result.code)
        }
        // Persist at the authoritative OK response, not after the optional pacing event.
        try acknowledged(normalized)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(NikonStaBridge.shared.PAIRING_EVENT_TIMEOUT_MS) / 1000
        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                let packet = try await eventChannel.readControlPacket(timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
                if packet.type == PtpConstants.shared.PING { try await eventChannel.sendPong(timeout: 5) }
                if packet.type == PtpConstants.shared.EVENT,
                   PtpIPChannel.event(packet.payload)?.code == PtpConstants.shared.EVENT_DEVICE_INFO_CHANGED { break }
            }
        } catch { /* Missing pacing event never revokes an already acknowledged pairing. */ }
        _ = try? await session.execute(operationCode: PtpConstants.shared.CLOSE_SESSION, timeout: 5)
        throw CameraStationError.pairingCompleted(normalized)
    }

    func objectHandles(storageID: Int32) async throws -> [Int32] {
        // Exact Android GetObjectHandles arguments, including the vendor-tolerated -1 format.
        try await identifiers(operation: PtpConstants.shared.GET_OBJECT_HANDLES, parameters: [storageID, -1, 0])
    }

    func objectInfo(handle: Int32) async throws -> PtpObjectInfo {
        let operation = PtpConstants.shared.GET_OBJECT_INFO
        let payload = try await metadata(operation: operation, parameters: [handle], limit: 64 * 1024)
        guard let info = PtpIPChannel.objectInfo(handle: handle, payload: payload) else {
            throw CameraOperationError.malformedDataset(operation: operation)
        }
        // Keep association + identityComplete flags. The caller must not treat folders as files
        // or a fallback filename as a complete cache identity. Unknown size remains 0xFFFFFFFF.
        return info
    }

    /// A confirmed miss may be cached; Busy and other errors must remain retryable.
    func thumbnail(handle: Int32) async throws -> Data? {
        try await readThumbnail(handle: handle)
    }

    func backgroundThumbnail(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> Data? {
        try await readThumbnail(handle: handle, admission: { [weak self] in
            guard let self, await self.backgroundReadsAllowed() else { return false }
            return await permitted()
        })
    }

    private func backgroundReadsAllowed() -> Bool { phase == .ready && !downloadActive }

    private func readThumbnail(handle: Int32, admission: (@Sendable () async -> Bool)? = nil) async throws -> Data? {
        let code = PtpConstants.shared.GET_THUMB
        let result = try await previewCommand(operation: code, handle: handle, limit: 4 * 1024 * 1024, admission: admission)
        switch result.code {
        case PtpConstants.shared.RESPONSE_OK: return result.payload
        case PtpConstants.shared.NO_THUMBNAIL_PRESENT, PtpConstants.shared.INVALID_OBJECT_HANDLE: return nil
        default: throw CameraOperationError.rejected(operation: code, response: result.code)
        }
    }

    /// Standard AP camera-generated FHD only. Paired STA uses a different capability/fallback path;
    /// until its MPF/partial-read flow is integrated, return nil so callers use the real thumbnail.
    func fhdPicture(handle: Int32, retryDeviceBusy: Bool = true) async throws -> Data? {
        try requirePhase(.ready)
        if stationMode || previewPolicy.disabled { return nil }
        var remaining = retryDeviceBusy ? previewPolicy.busyRetries : 0
        while true {
            try Task.checkCancellation()
            let result = try await previewCommand(operation: PtpConstants.shared.NK_GET_FHD_PICTURE,
                                                  handle: handle, limit: 32 * 1024 * 1024)
            if previewPolicy.record(response: result.code, hasPayload: result.payload?.isEmpty == false) {
                return result.payload
            }
            guard result.code == PtpConstants.shared.DEVICE_BUSY, remaining > 0 else { return nil }
            remaining -= 1
            try await Task.sleep(nanoseconds: UInt64(previewPolicy.busyDelayMs) * 1_000_000)
        }
    }

    /// Same partial-object command as Android readExifHeader. This standard AP/STA path does
    /// not infer support or retry Busy; paired STA's recent-header cache remains a separate gate.
    func exifHeader(handle: Int32, maximumBytes: Int32) async throws -> Data? {
        try Task.checkCancellation()
        guard maximumBytes > 0, maximumBytes <= 2 * 1024 * 1024,
              let values = PtpTransferBridge.shared.partialParameters(handle: handle, offset: 0, count: Int64(maximumBytes)) else {
            throw CameraStreamError.invalidArgument
        }
        try requirePhase(.ready)
        let parameters = (0..<Int(values.size)).map { values.get(index: Int32($0)) }
        do {
            let result = try await previewCommand(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX,
                parameters: parameters, limit: Int(maximumBytes))
            guard result.code == PtpConstants.shared.RESPONSE_OK, let data = result.payload, !data.isEmpty else { return nil }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            await abort(error: error)
            return nil
        }
    }

    private func previewCommand(operation: Int32, handle: Int32, limit: Int,
                                admission: (@Sendable () async -> Bool)? = nil) async throws -> PtpIPCommandResult {
        try await previewCommand(operation: operation, parameters: [handle], limit: limit, admission: admission)
    }

    private func previewCommand(operation: Int32, parameters: [Int32], limit: Int,
                                admission: (@Sendable () async -> Bool)? = nil) async throws -> PtpIPCommandResult {
        try requirePhase(.ready)
        do {
            let result = try await session.execute(operationCode: operation, parameters: parameters, maximumPayloadBytes: limit,
                                                   backgroundAdmission: admission)
            try requirePhase(.ready)
            return result
        } catch {
            if await session.isClosed() { await abort(error: terminalError ?? error) }
            throw error
        }
    }

    /// A graceful user disconnect attempts CloseSession. Background/cancellation/network loss
    /// use abort, because continuing a partly consumed transaction would corrupt framing.
    func disconnect() async {
        guard phase != .closed && phase != .closing else { return }
        let wasReady = phase == .ready
        phase = .closing
        publish()
        keepaliveTask?.cancel()
        var closeError: Error?
        if wasReady && !Task.isCancelled {
            do {
                // Do not wait behind work already in flight. A busy connection is aborted instead.
                let result = try await session.execute(operationCode: PtpConstants.shared.CLOSE_SESSION,
                                                       timeout: 5, requireIdle: true)
                if result.code != PtpConstants.shared.RESPONSE_OK {
                    closeError = CameraOperationError.rejected(operation: PtpConstants.shared.CLOSE_SESSION, response: result.code)
                }
            } catch CameraStreamError.operationInProgress {
                // Intentional disconnect while busy: close sockets, without reporting a failure.
            } catch { closeError = error }
        }
        await abort(error: closeError)
    }

    func abort(error: Error? = nil) async {
        let pending = eventTask
        let heartbeat = keepaliveTask
        finish(error: error)
        await session.close()
        // Never called from the event task itself: its failure path uses finish + session.close.
        await pending?.value
        await heartbeat?.value
        eventTask = nil
        keepaliveTask = nil
    }

    func snapshot() -> CameraConnectionSnapshot {
        CameraConnectionSnapshot(connectionID: connectionID, phase: phase, eventRevision: eventRevision,
                         errorDescription: terminalError?.localizedDescription)
    }

    private func identifiers(operation: Int32, parameters: [Int32]) async throws -> [Int32] {
        let payload = try await metadata(operation: operation, parameters: parameters, limit: 16 * 1024 * 1024)
        guard let values = PtpIPChannel.identifiers(payload) else {
            throw CameraOperationError.malformedDataset(operation: operation)
        }
        return values
    }

    private func metadata(operation: Int32, parameters: [Int32], limit: Int) async throws -> Data {
        try requirePhase(.ready)
        let result: PtpIPCommandResult
        do {
            result = try await session.execute(operationCode: operation, parameters: parameters,
                                               maximumPayloadBytes: limit)
        } catch {
            // A queued caller's cancellation must not close another caller's active transaction.
            // The gate tells us whether this failure actually poisoned the command socket.
            if await session.isClosed() { await abort(error: terminalError ?? error) }
            throw error
        }
        try requirePhase(.ready)
        guard result.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: operation, response: result.code)
        }
        guard let payload = result.payload else { throw CameraOperationError.malformedDataset(operation: operation) }
        return payload
    }

    private func startEvents() {
        let channel = eventChannel
        // Do not retain this owner during a potentially infinite idle socket read.
        eventTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let packet = try await channel.readControlPacket(timeout: 15, waitForPacket: true)
                    if packet.type == PtpConstants.shared.PING {
                        try await channel.sendPong(timeout: 15)
                    } else if packet.type == PtpConstants.shared.EVENT, PtpIPChannel.event(packet.payload) != nil {
                        await self?.receivedEvent()
                    }
                }
            } catch { await self?.eventFailed(error) }
        }
    }

    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Android CameraViewModel.KEEPALIVE_INTERVAL_MS: same 10-second idle cadence.
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    if await self?.keepalive() != true { return }
                } catch { return }
            }
        }
    }

    /// Any well-framed response proves liveness, including DeviceBusy. Atomic requireIdle skips
    /// rather than queues behind a metadata request. Download-wide inhibition includes chunk gaps.
    func keepalive() async -> Bool {
        guard phase == .ready else { return false }
        if downloadActive { return true }
        do {
            _ = try await session.execute(operationCode: PtpConstants.shared.GET_STORAGE_IDS,
                                           maximumPayloadBytes: 1024 * 1024, requireIdle: true)
            return phase == .ready
        } catch CameraStreamError.operationInProgress {
            return phase == .ready
        } catch {
            // Do not await our own heartbeat task from this failure path.
            if phase == .ready {
                finish(error: error)
                await session.close()
            }
            return false
        }
    }

    private func receivedEvent() {
        guard phase == .opening || phase == .ready else { return }
        eventRevision &+= 1
        publish()
    }

    /// A download-wide reservation excludes a second download and suppresses keepalive even
    /// between chunks. Metadata/preview commands can still take the gate between transactions.
    func download(
        handle: Int32, declaredSize: Int64, resumeOffset: Int64 = 0,
        highThroughput: Bool = false,
        onProgress: ((CameraDownloadProgress) -> Void)? = nil,
        consume: (Data) throws -> Void
    ) async throws -> CameraDownloadStats {
        try requirePhase(.ready)
        guard resumeOffset >= 0 else { throw CameraStreamError.invalidArgument }
        guard !downloadActive else { throw CameraStreamError.operationInProgress }
        downloadActive = true
        defer { downloadActive = false }
        let policy = PtpTransferBridge.shared
        let started = ProcessInfo.processInfo.systemUptime
        var received: Int64 = 0
        var effectiveSize = declaredSize
        var lastProgressTime = started
        func emitProgress(force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastProgressTime >= 0.2 else { return }
            lastProgressTime = now
            onProgress?(CameraDownloadProgress(downloaded: resumeOffset + received,
                total: effectiveSize > 0 && effectiveSize != PtpConstants.shared.SIZE_UNKNOWN ? effectiveSize : 0,
                bytesPerSecond: policy.speed(bytes: received, elapsedMs: Int64((now - started) * 1000))))
        }
        func result() -> CameraDownloadStats {
            emitProgress(force: true)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            return CameraDownloadStats(bytes: resumeOffset + received, transferred: received,
                                       elapsed: elapsed, bytesPerSecond: policy.speed(bytes: received, elapsedMs: Int64(elapsed * 1000)))
        }
        do {
            if policy.querySize(size: declaredSize) {
                let sizeResponse = try await session.execute(operationCode: PtpConstants.shared.NK_GET_OBJECT_SIZE, parameters: [handle])
                let size = sizeResponse.code == PtpConstants.shared.RESPONSE_OK
                    ? sizeResponse.payload.map { PtpIPChannel.objectSize($0) } ?? 0 : 0
                effectiveSize = policy.resolvedSize(declared: declaredSize, queried: size)
            }
            let partial = policy.usePartial(support: partialSupport, size: effectiveSize, resume: resumeOffset,
                                             highThroughput: highThroughput, forcePartial: false)
            if policy.resumeUnavailable(offset: resumeOffset, partial: partial) { throw CameraDownloadError.resumeUnavailable }
            if partial {
                var offset = resumeOffset
                var first = true
                var fellBack = false
                let chunkSize = policy.chunkSize(size: effectiveSize, highThroughput: highThroughput)
                while offset < effectiveSize {
                    try requirePhase(.ready)
                    let requested = min(chunkSize, effectiveSize - offset)
                    guard let values = policy.partialParameters(handle: handle, offset: offset, count: requested) else {
                        throw CameraStreamError.invalidArgument
                    }
                    let parameters = (0..<Int(values.size)).map { values.get(index: Int32($0)) }
                    let chunk = try await session.executeStreaming(
                        operationCode: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX, parameters: parameters,
                        maximumBytes: Int64.max - offset
                    ) { data in
                        try consume(data)
                        received += Int64(data.count)
                        emitProgress()
                    }
                    let action = policy.partialAction(code: chunk.code, first: first, received: chunk.bytes, resume: resumeOffset)
                    if action == policy.FALLBACK {
                        partialSupport = 0
                        fellBack = true
                        break
                    }
                    guard action == policy.ACCEPT else { throw CameraDownloadError.rejected(chunk.code) }
                    partialSupport = 1
                    guard policy.chunkComplete(received: chunk.bytes, declared: chunk.declaredBytes),
                          policy.chunkProgress(received: chunk.bytes) else {
                        throw CameraDownloadError.incomplete(received: chunk.bytes, expected: chunk.declaredBytes)
                    }
                    offset += chunk.bytes
                    first = false
                }
                if !fellBack {
                    guard policy.partialComplete(received: resumeOffset + received, expected: effectiveSize) else {
                        throw CameraDownloadError.incomplete(received: resumeOffset + received, expected: effectiveSize)
                    }
                    return result()
                }
            }
            try requirePhase(.ready)
            let full = try await session.executeStreaming(operationCode: PtpConstants.shared.GET_OBJECT, parameters: [handle]) { data in
                try consume(data)
                received += Int64(data.count)
                emitProgress()
            }
            guard full.code == PtpConstants.shared.RESPONSE_OK else { throw CameraDownloadError.rejected(full.code) }
            guard policy.fullComplete(received: received, declared: full.declaredBytes) else {
                throw CameraDownloadError.incomplete(received: received, expected: full.declaredBytes)
            }
            return result()
        } catch {
            if await session.isClosed() { await abort(error: terminalError ?? error) }
            throw error
        }
    }

    private func eventFailed(_ error: Error) async {
        guard phase != .closed else { return }
        if phase == .closing, (error as? CameraStreamError) == .endOfStream { return }
        finish(error: error)
        await session.close()
    }

    private func requirePhase(_ expected: CameraConnectionSnapshot.Phase) throws {
        try Task.checkCancellation()
        guard phase == expected else { throw terminalError ?? CameraStreamError.closed }
    }

    private func finish(error: Error?) {
        guard phase != .closed else { return }
        phase = .closed
        terminalError = error
        command.close()
        event.close()
        eventTask?.cancel()
        keepaliveTask?.cancel()
        publish()
        notifications.finish()
    }

    private func publish() { notifications.yield(snapshot()) }
}
