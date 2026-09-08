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

/// A cursor belongs to one connection, not a device name or a reconnecting UI page.
struct CameraEventCursor: Sendable, Equatable {
    let connectionID: UUID
    let revision: UInt64
}

struct CameraEventRecord: Sendable, Equatable {
    let revision: UInt64
    let code: Int32
    let transactionID: Int64
    let firstParameter: Int64
}

struct CameraEventBatch: Sendable {
    let cursor: CameraEventCursor
    let events: [CameraEventRecord]
    /// Initial attachment, stale generation or evicted history: rescan, never apply a partial log.
    let requiresRescan: Bool
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
    private var eventRecords: [CameraEventRecord] = []
    static let eventHistoryLimit = 256
    private var terminalError: Error?
    private var downloadActive = false
    private var partialSupport: Int32 = -1
    private let previewPolicy = NativePreviewPolicy()
    private let staPreviewPolicy = NativeStaPreviewPolicy()
    private let directDecoder = PreviewImageDecoder()
    private var thumbnailCacheIdentity: String?
    private var verifiedResponderGUID: String?
    private var directObjectReadValidated = false
    private var prefetchedStationHandles: (storage: Int32, handles: [Int32])?
    private var stationDeviceInfo: LabDeviceInfo?
    private let directMetadata = NativeStaDirectMetadata()
    private var directNamesLoaded = false
    private var directNameValueSupported: Bool?
    private var directStorageByHandle: [Int32: Int32] = [:]
    private var directHeaders: [Int32: Data] = [:]
    private var directHeaderOrder: [Int32] = []
    private var directInfos: [Int32: PtpObjectInfo] = [:]
    private var directContentRevision: UInt64 = 0
    private var directRawReferences: [Int32: [NefPreviewReference]] = [:]
    private var directRawHint: NefPreviewReference?
    private var directThumbnailMisses = Set<Int32>()

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
                 onPairingAcknowledged: ((String) throws -> Void)? = nil,
                 onPairingStarted: (() async -> Void)? = nil) async throws -> LabDeviceInfo? {
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
                                             hasMarker: hasPairingMarker, acknowledged: onPairingAcknowledged,
                                             pairingStarted: onPairingStarted)
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
            verifiedResponderGUID = NikonStaBridge.shared.normalizeGuid(value: ack.responderGuidHex)
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
    /// Pairing/history may use only the responder acknowledged by this ready session, never a
    /// display name, Bonjour candidate or thumbnail-cache fallback containing a session UUID.
    func responderGUID() -> String? { phase == .ready ? verifiedResponderGUID : nil }
    func usesDirectObjectReads() -> Bool { phase == .ready && directObjectReadValidated }

    func resolvedRemoteHost() async -> String? {
        guard phase == .ready else { return nil }
        let host = await command.resolvedRemoteHost()
        return phase == .ready ? host : nil
    }

    private func initializeStation(options: StationConnectionOptions, responder: String?,
                                   hasMarker: ((String) throws -> Bool)?, acknowledged: ((String) throws -> Void)?,
                                   pairingStarted: (() async -> Void)?) async throws {
        let policy = NikonStaBridge.shared
        let compatibility = try await session.execute(operationCode: policy.COMPATIBILITY_INIT)
        guard compatibility.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: policy.COMPATIBILITY_INIT, response: compatibility.code)
        }
        let storage = try await session.execute(operationCode: PtpConstants.shared.GET_STORAGE_IDS)
        let ids = storage.payload.flatMap { PtpIPChannel.identifiers($0) } ?? []
        let marked = try responder.map { try hasMarker?($0) ?? false } ?? false
        if policy.forcePairing(code: storage.code, force: options.forceProfilePairing, allow: options.allowPairing, marked: marked) {
            await pairingStarted?()
            try requirePhase(.opening)
            try await pairStation(responder: responder, acknowledged: acknowledged)
        }
        let values = KotlinIntArray(size: Int32(ids.count))
        for (index, value) in ids.enumerated() { values.set(index: Int32(index), value: value) }
        if policy.usableStorage(code: storage.code, ids: values) && !options.exploreAlbumAccess {
            prefetchedStorageIDs = ids
            return
        }
        let device = try await session.execute(operationCode: PtpConstants.shared.GET_DEVICE_INFO)
        let info = device.code == PtpConstants.shared.RESPONSE_OK ? device.payload.flatMap { PtpIPChannel.deviceInfo($0) } : nil
        stationDeviceInfo = info
        if policy.pairingOnly(info: info) {
            guard options.allowPairing else { throw CameraStationError.pairingRequired }
            await pairingStarted?()
            try requirePhase(.opening)
            try await pairStation(responder: responder, acknowledged: acknowledged)
        }
        if options.exploreAlbumAccess {
            if policy.usableStorage(code: storage.code, ids: values),
               try await validateStationObjectAccess(storageIDs: ids) {
                prefetchedStorageIDs = ids
                return
            }
            // Android's one bounded application-mode probe. No identity guessing or AP fallback.
            let changed = try await session.execute(operationCode: 0x9435, parameters: [1])
            if changed.code == PtpConstants.shared.RESPONSE_OK {
                do {
                    _ = try await session.execute(operationCode: policy.COMPATIBILITY_INIT)
                    let modeStorage = try await session.execute(operationCode: PtpConstants.shared.GET_STORAGE_IDS)
                    let modeIDs = modeStorage.payload.flatMap { PtpIPChannel.identifiers($0) } ?? []
                    let native = KotlinIntArray(size: Int32(modeIDs.count))
                    for (index, value) in modeIDs.enumerated() { native.set(index: Int32(index), value: value) }
                    if policy.usableStorage(code: modeStorage.code, ids: native),
                       try await validateStationObjectAccess(storageIDs: modeIDs) {
                        prefetchedStorageIDs = modeIDs
                        return
                    }
                } catch {
                    // Best effort only on the same command owner; a poisoned transport stays closed.
                    _ = try? await session.execute(operationCode: 0x9435, parameters: [0], timeout: 5)
                    throw error
                }
                _ = try? await session.execute(operationCode: 0x9435, parameters: [0], timeout: 5)
            }
        }
        throw CameraStationError.albumUnavailable
    }

    /// Mirrors NikonCamera.validateStaObjectAccess: first/middle/last ObjectInfo, then ONE
    /// bounded thumbnail/size/prefix sample only when ObjectInfo was denied. Never GetObject.
    private func validateStationObjectAccess(storageIDs: [Int32]) async throws -> Bool {
        try requirePhase(.opening)
        let response = try await session.execute(operationCode: PtpConstants.shared.GET_OBJECT_HANDLES,
            parameters: [-1, -1, 0], maximumPayloadBytes: 16 * 1024 * 1024)
        guard response.code == PtpConstants.shared.RESPONSE_OK,
              let data = response.payload, let handles = PtpIPChannel.identifiers(data), !handles.isEmpty else { return false }
        var accessible = true
        var sampled = Set<Int>()
        for index in [0, (handles.count - 1) / 2, handles.count - 1] where sampled.insert(index).inserted {
            let result = try await session.execute(operationCode: PtpConstants.shared.GET_OBJECT_INFO,
                parameters: [handles[index]], maximumPayloadBytes: 64 * 1024)
            if result.code != PtpConstants.shared.RESPONSE_OK || (result.payload?.count ?? 0) < 53 { accessible = false }
        }
        if !accessible {
            let handle = handles[0]
            _ = try await session.execute(operationCode: PtpConstants.shared.GET_THUMB,
                parameters: [handle], maximumPayloadBytes: 4 * 1024 * 1024)
            let size = try await session.execute(operationCode: PtpConstants.shared.NK_GET_OBJECT_SIZE,
                parameters: [handle], maximumPayloadBytes: 64 * 1024)
            let prefix = try await session.execute(operationCode: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX,
                parameters: [handle, 0, 0, 64 * 1024, 0], maximumPayloadBytes: 64 * 1024)
            accessible = size.code == PtpConstants.shared.RESPONSE_OK &&
                size.payload.map { PtpIPChannel.objectSize($0) > 0 } == true &&
                prefix.code == PtpConstants.shared.RESPONSE_OK && prefix.payload?.isEmpty == false
            directObjectReadValidated = accessible
        }
        if accessible {
            let usable = storageIDs.filter { $0 != 0 && $0 != -1 }
            if usable.count == 1 {
                let id = usable[0]
                prefetchedStationHandles = (id & 0xFFFF == 0 ? -1 : id, handles)
            }
        }
        return accessible
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
        try requirePhase(.ready)
        if let prefetched = prefetchedStationHandles, prefetched.storage == storageID {
            prefetchedStationHandles = nil
            return prefetched.handles
        }
        // Exact Android GetObjectHandles arguments, including the vendor-tolerated -1 format.
        try await identifiers(operation: PtpConstants.shared.GET_OBJECT_HANDLES, parameters: [storageID, -1, 0])
    }

    func objectInfo(handle: Int32) async throws -> PtpObjectInfo {
        if directObjectReadValidated { return try await directObjectInfo(handle: handle) }
        let operation = PtpConstants.shared.GET_OBJECT_INFO
        let payload = try await metadata(operation: operation, parameters: [handle], limit: 64 * 1024)
        guard let info = PtpIPChannel.objectInfo(handle: handle, payload: payload) else {
            throw CameraOperationError.malformedDataset(operation: operation)
        }
        // Keep association + identityComplete flags. The caller must not treat folders as files
        // or a fallback filename as a complete cache identity. Unknown size remains 0xFFFFFFFF.
        return info
    }

    func newObjectInfo(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> PtpObjectInfo {
        if directObjectReadValidated { return try await directObjectInfo(handle: handle, permitted: permitted) }
        let operation = PtpConstants.shared.GET_OBJECT_INFO
        let result = try await previewCommand(operation: operation, handle: handle, limit: 64 * 1024, admission: permitted)
        guard result.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: operation, response: result.code)
        }
        guard let data = result.payload, let info = PtpIPChannel.objectInfo(handle: handle, payload: data) else {
            throw CameraOperationError.malformedDataset(operation: operation)
        }
        return info
    }

    func catalogStorageIDs(permitted: @escaping @Sendable () async -> Bool) async throws -> [Int32] {
        // Event-driven storage changes require a fresh wire query, never handshake-prefetched IDs.
        try await catalogIdentifiers(operation: PtpConstants.shared.GET_STORAGE_IDS, parameters: [], permitted: permitted)
    }

    func catalogObjectHandles(storageID: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> [Int32] {
        try await catalogIdentifiers(operation: PtpConstants.shared.GET_OBJECT_HANDLES,
                                     parameters: [storageID, -1, 0], permitted: permitted)
    }

    func catalogObjectInfo(handle: Int32, permitted: @escaping @Sendable () async -> Bool) async throws -> PtpObjectInfo {
        if directObjectReadValidated { return try await directObjectInfo(handle: handle, permitted: permitted) }
        let operation = PtpConstants.shared.GET_OBJECT_INFO
        let data = try await catalogMetadata(operation: operation, parameters: [handle], limit: 64 * 1024, permitted: permitted)
        guard let info = PtpIPChannel.objectInfo(handle: handle, payload: data) else {
            throw CameraOperationError.malformedDataset(operation: operation)
        }
        return info
    }

    /// Enumeration supplies the shared-validated membership. Do not infer slots from raw handle bits.
    func prepareDirectCatalog(storageIDs: [Int32], storageByHandle: [Int32: Int32],
                              permitted: @escaping @Sendable () async -> Bool) async throws {
        try requirePhase(.ready)
        guard directObjectReadValidated else { return }
        let revision = directContentRevision
        directStorageByHandle = storageByHandle
        // A refreshed directory must re-observe object bytes/size; failed compact indexes do not
        // erase valid prior name/date entries. The catalog retains its prior complete snapshot.
        directInfos.removeAll()
        let policy = NikonStaBridge.shared, bridge = NativeStaDirectBridge.shared
        if !directNamesLoaded {
            if policy.advertises(info: stationDeviceInfo, operation: PtpConstants.shared.GET_OBJECT_PROP_LIST) {
                let result = try await directCommand(operation: PtpConstants.shared.GET_OBJECT_PROP_LIST,
                    parameters: [-1, 0, PtpConstants.shared.OBJECT_PROP_OBJECT_FILE_NAME, 0, 0],
                    limit: 16 * 1024 * 1024, permitted: permitted)
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                if result.code == PtpConstants.shared.RESPONSE_OK, let data = result.payload {
                    bridge.loadNames(model: directMetadata, data: data as NSData)
                }
            }
            directNamesLoaded = true
        }
        if policy.advertises(info: stationDeviceInfo, operation: PtpConstants.shared.NK_GET_OBJECTS_METADATA) {
            for store in storageIDs.isEmpty ? [-1] : storageIDs {
                let result = try await directCommand(operation: PtpConstants.shared.NK_GET_OBJECTS_METADATA,
                    parameters: [store, 0, 0], limit: 16 * 1024 * 1024, permitted: permitted)
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                if result.code == PtpConstants.shared.RESPONSE_OK, let data = result.payload {
                    bridge.loadDates(model: directMetadata, data: data as NSData)
                }
            }
        }
    }

    private func directCommand(operation: Int32, parameters: [Int32], limit: Int,
                               permitted: (@Sendable () async -> Bool)? = nil) async throws -> PtpIPCommandResult {
        let admission: (@Sendable () async -> Bool)?
        if let permitted {
            admission = { [weak self] in
                guard let self, await self.backgroundReadsAllowed() else { return false }
                return await permitted()
            }
        } else { admission = nil }
        return try await previewCommand(operation: operation, parameters: parameters, limit: limit, admission: admission)
    }

    private func directObjectInfo(handle: Int32, permitted: (@Sendable () async -> Bool)? = nil) async throws -> PtpObjectInfo {
        try requirePhase(.ready)
        if let permitted, !(await permitted()) { throw CameraStreamError.operationInProgress }
        if let cached = directInfos[handle] { return cached }
        let revision = directContentRevision
        let bridge = NativeStaDirectBridge.shared
        if directMetadata.name(handle: handle) == nil, directNameValueSupported != false {
            if NikonStaBridge.shared.advertises(info: stationDeviceInfo, operation: PtpConstants.shared.GET_OBJECT_PROP_VALUE) {
                let result = try await directCommand(operation: PtpConstants.shared.GET_OBJECT_PROP_VALUE,
                    parameters: [handle, PtpConstants.shared.OBJECT_PROP_OBJECT_FILE_NAME], limit: 64 * 1024, permitted: permitted)
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                let name = result.code == PtpConstants.shared.RESPONSE_OK
                    ? result.payload.flatMap { bridge.loadName(model: directMetadata, handle: handle, data: $0 as NSData) } : nil
                directNameValueSupported = name != nil
            } else { directNameValueSupported = false }
        }
        let sizeResult = try await directCommand(operation: PtpConstants.shared.NK_GET_OBJECT_SIZE,
            parameters: [handle], limit: 64 * 1024, permitted: permitted)
        guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
        guard sizeResult.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: PtpConstants.shared.NK_GET_OBJECT_SIZE, response: sizeResult.code)
        }
        let size = sizeResult.payload.map { PtpIPChannel.objectSize($0) } ?? 0
        guard size > 0 else { throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_OBJECT_SIZE) }
        let storage = directStorageByHandle[handle] ?? 0
        if let indexed = directMetadata.indexedInfo(handle: handle, size: size, storageId: storage) {
            directInfos[handle] = indexed
            return indexed
        }
        let header = try await directPrefix(handle: handle, count: Int(min(size, 128 * 1024)), permitted: permitted)
        guard let header, !header.isEmpty() else {
            throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
        }
        let exif = try PreviewExifReader.metadata(header: header)
        var captureDate = exif?.dateTime
        let mediaExtension = bridge.mediaExtension(data: header as NSData)
        if mediaExtension == ".mov" || mediaExtension == ".mp4" {
            captureDate = PreviewMediaDate.video(header) ?? captureDate ?? directMetadata.captureDate(handle: handle)
            if captureDate == nil, size > Int64(header.count) {
                let count = Int(min(size, 256 * 1024))
                if let tail = try await directPartial(handle: handle, offset: size - Int64(count), count: count, permitted: permitted) {
                    captureDate = PreviewMediaDate.video(tail)
                }
            }
        }
        guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
        guard let info = bridge.headerInfo(model: directMetadata, handle: handle, size: size,
            data: header as NSData, exifDate: captureDate, storageId: storage) else {
            throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
        }
        try requirePhase(.ready)
        if let permitted, !(await permitted()) { throw CameraStreamError.operationInProgress }
        directInfos[handle] = info
        if info.fileName?.lowercased().hasSuffix(".nef") == true {
            let references = bridge.rawIndexed(data: header as NSData)
            if !references.isEmpty { directRawReferences[handle] = references }
        }
        return info
    }

    private func directPrefix(handle: Int32, count: Int, permitted: (@Sendable () async -> Bool)? = nil) async throws -> Data? {
        guard count > 0, count <= 16 * 1024 * 1024 else { throw CameraStreamError.invalidArgument }
        let retained = directHeaders[handle] ?? Data()
        let revision = directContentRevision
        if retained.count >= count { return Data(retained.prefix(count)) }
        guard let suffix = try await directPartial(handle: handle, offset: Int64(retained.count),
            count: count - retained.count, permitted: permitted) else { return nil }
        guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
        let bytes = retained + suffix
        directHeaders[handle] = Data(bytes.prefix(512 * 1024))
        directHeaderOrder.removeAll { $0 == handle }; directHeaderOrder.append(handle)
        while directHeaderOrder.count > 4 { directHeaders.removeValue(forKey: directHeaderOrder.removeFirst()) }
        return bytes
    }

    private func directPartial(handle: Int32, offset: Int64, count: Int,
                               permitted: (@Sendable () async -> Bool)? = nil) async throws -> Data? {
        guard count > 0, count <= 16 * 1024 * 1024,
              let native = PtpTransferBridge.shared.partialParameters(handle: handle, offset: offset, count: Int64(count)) else {
            throw CameraStreamError.invalidArgument
        }
        let result = try await directCommand(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX,
            parameters: (0..<Int(native.size)).map { native.get(index: Int32($0)) }, limit: count, permitted: permitted)
        guard result.code == PtpConstants.shared.RESPONSE_OK, let data = result.payload, !data.isEmpty else { return nil }
        return data
    }

    private func catalogIdentifiers(operation: Int32, parameters: [Int32],
                                    permitted: @escaping @Sendable () async -> Bool) async throws -> [Int32] {
        let data = try await catalogMetadata(operation: operation, parameters: parameters, limit: 16 * 1024 * 1024, permitted: permitted)
        guard let ids = PtpIPChannel.identifiers(data) else { throw CameraOperationError.malformedDataset(operation: operation) }
        return ids
    }

    private func catalogMetadata(operation: Int32, parameters: [Int32], limit: Int,
                                 permitted: @escaping @Sendable () async -> Bool) async throws -> Data {
        let result = try await previewCommand(operation: operation, parameters: parameters, limit: limit, admission: { [weak self] in
            // PtpIPCommandSession invokes this after FIFO acquisition, BEFORE allocating a TID.
            guard let self, await self.backgroundReadsAllowed() else { return false }
            return await permitted()
        })
        guard result.code == PtpConstants.shared.RESPONSE_OK else {
            throw CameraOperationError.rejected(operation: operation, response: result.code)
        }
        guard let data = result.payload else { throw CameraOperationError.malformedDataset(operation: operation) }
        return data
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
        if directObjectReadValidated { return try await directThumbnail(handle: handle, permitted: admission) }
        let code = PtpConstants.shared.GET_THUMB
        let result = try await previewCommand(operation: code, handle: handle, limit: 4 * 1024 * 1024, admission: admission)
        switch result.code {
        case PtpConstants.shared.RESPONSE_OK: return result.payload
        case PtpConstants.shared.NO_THUMBNAIL_PRESENT, PtpConstants.shared.INVALID_OBJECT_HANDLE: return nil
        default: throw CameraOperationError.rejected(operation: code, response: result.code)
        }
    }

    private func directFhdPicture(handle: Int32, retryDeviceBusy: Bool) async throws -> Data? {
        let revision = directContentRevision
        for operation in [PtpConstants.shared.NK_GET_FHD_PICTURE, PtpConstants.shared.NK_GET_LARGE_THUMB] {
            guard staPreviewPolicy.shouldRequest(operation: operation,
                advertised: NikonStaBridge.shared.advertises(info: stationDeviceInfo, operation: operation)) else { continue }
            var retries = retryDeviceBusy ? previewPolicy.busyRetries : 0
            while true {
                let result = try await previewCommand(operation: operation, handle: handle, limit: 32 * 1024 * 1024)
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                let payload = result.code == PtpConstants.shared.RESPONSE_OK ? result.payload : nil
                let valid = try payload.map { try PreviewImageDecoder.cameraPreviewDimensions($0) != nil } ?? false
                staPreviewPolicy.record(operation: operation, response: result.code, validJpeg: valid)
                if valid { return payload }
                if result.code == PtpConstants.shared.DEVICE_BUSY, retries > 0 {
                    retries -= 1
                    try await Task.sleep(nanoseconds: UInt64(previewPolicy.busyDelayMs) * 1_000_000)
                    continue
                }
                break
            }
        }
        guard let info = directInfos[handle], let name = info.fileName?.lowercased() else { return nil }
        if name.hasSuffix(".nef") { return try await directRawPreview(info: info) }
        guard name.hasSuffix(".jpg"),
              let header = try await directPrefix(handle: handle, count: Int(min(info.size, 128 * 1024))) else { return nil }
        // Shared MPF reader returns secondary images only, in original FHD/4K/VGA preference order.
        for reference in NativeStaDirectBridge.shared.mpf(data: header as NSData, objectSize: info.size) {
            guard let data = try await directPartial(handle: handle, offset: reference.offset, count: Int(reference.length)),
                  data.count == Int(reference.length),
                  NativeRawPreviewBridge.shared.isCompleteJpeg(data: data as NSData),
                  try PreviewImageDecoder.rawPreviewPixels(data) > 0 else { continue }
            guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
            return data
        }
        return nil
    }

    private func directThumbnail(handle: Int32, permitted: (@Sendable () async -> Bool)?) async throws -> Data? {
        let revision = directContentRevision
        if directThumbnailMisses.contains(handle) { return nil }
        let info = try await directObjectInfo(handle: handle, permitted: permitted)
        let name = info.fileName?.lowercased() ?? ""
        if name.hasSuffix(".nef") { return try await directRawThumbnail(info: info, permitted: permitted) }
        guard let header = try await directPrefix(handle: handle, count: Int(min(info.size, 128 * 1024)), permitted: permitted) else {
            throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
        }
        if name.hasSuffix(".jpg"), let segment = NativeStaDirectBridge.shared.exifSegment(data: header as NSData) {
            let start = Int(segment.offset), end = start + Int(segment.length)
            guard start >= 0, end <= header.count else { throw PreviewImageError.invalidImage }
            let envelope = Data([0xFF, 0xD8]) + header.subdata(in: start..<end) + Data([0xFF, 0xD9])
            let data = try await directDecoder.embeddedExifThumbnailPNG(envelope)
            guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
            return data
        }
        if name.hasSuffix(".mov") || name.hasSuffix(".mp4") {
            if let range = NativeStaDirectBridge.shared.scannedJpeg(data: header as NSData) {
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                return header.subdata(in: Int(range.offset)..<(Int(range.offset) + Int(range.length)))
            }
            let maximum = Int(min(info.size, 8 * 1024 * 1024))
            guard let data = try await directPrefix(handle: handle, count: maximum, permitted: permitted) else {
                throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
            }
            guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
            if let range = NativeStaDirectBridge.shared.scannedJpeg(data: data as NSData) {
                let start = Int(range.offset), end = start + Int(range.length)
                guard start >= 0, end <= data.count else { throw PreviewImageError.invalidImage }
                return data.subdata(in: start..<end)
            }
            let frame = try await directDecoder.videoThumbnail(data, fileExtension: name.hasSuffix(".mov") ? ".mov" : ".mp4")
            guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
            if let frame { return frame }
            if data.count == maximum { directThumbnailMisses.insert(handle); return nil }
            throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.GET_THUMB)
        }
        // A completed JPEG header without an embedded thumbnail is a deterministic miss.
        // RAW/video short reads must remain retryable instead of poisoning the negative cache.
        if !name.hasSuffix(".jpg") { throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.GET_THUMB) }
        guard header.count >= Int(min(info.size, 128 * 1024)) else {
            throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
        }
        guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
        return nil
    }

    /// Original Nikon RAW grid route: smallest indexed JPEG, learned offset hint, then bounded
    /// incremental TIFF/scan fallback. Unlike FHD, Android accepts SOI-only referenced thumbnails.
    private func directRawThumbnail(info: PtpObjectInfo, permitted: (@Sendable () async -> Bool)?) async throws -> Data? {
        let handle = info.handle, revision = directContentRevision, bridge = NativeStaDirectBridge.shared
        func accept(_ data: Data?) -> Data? {
            guard let data, data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
            return data
        }
        func slice(_ data: Data, _ range: NefPreviewReference) -> Data? {
            guard range.offset >= 0, range.length > 0, range.offset <= Int64(data.count) - Int64(range.length) else { return nil }
            return data.subdata(in: Int(range.offset)..<(Int(range.offset) + Int(range.length)))
        }
        if let reference = directRawReferences[handle]?.last {
            let data = accept(try await directPartial(handle: handle, offset: reference.offset,
                count: Int(reference.length), permitted: permitted))
            guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
            guard let data else { throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.GET_THUMB) }
            return data
        }
        if let hint = directRawHint, hint.offset >= 0, hint.offset < info.size,
           let plan = bridge.rawThumbnailProbe(available: info.size - hint.offset, previous: hint.length) {
            if var data = try await directPartial(handle: handle, offset: hint.offset, count: Int(plan.initialBytes), permitted: permitted) {
                var range = bridge.scannedJpeg(data: data as NSData)
                if range == nil, data.count < Int(plan.maximumBytes),
                   let suffix = try await directPartial(handle: handle, offset: hint.offset + Int64(data.count),
                        count: Int(plan.maximumBytes) - data.count, permitted: permitted) {
                    data.append(suffix); range = bridge.scannedJpeg(data: data as NSData)
                }
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                if let range, let result = slice(data, range) {
                    let absolute = NefPreviewReference(offset: hint.offset + range.offset, length: range.length)
                    directRawHint = absolute; directRawReferences[handle] = [absolute]
                    return result
                }
            }
        }
        var accumulated = directHeaders[handle] ?? Data()
        let maximum = Int(min(info.size, 16 * 1024 * 1024))
        var referenced = false
        for configured in [240, 256, 512, 1024, 2048, 4096, 8192, 16384] {
            try Task.checkCancellation()
            if let permitted, !(await permitted()) { throw CameraStreamError.operationInProgress }
            let target = min(maximum, configured * 1024)
            if accumulated.count < target {
                guard let suffix = try await directPartial(handle: handle, offset: Int64(accumulated.count),
                    count: target - accumulated.count, permitted: permitted) else {
                    throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
                }
                accumulated.append(suffix)
            }
            guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
            directHeaders[handle] = Data(accumulated.prefix(512 * 1024))
            directHeaderOrder.removeAll { $0 == handle }; directHeaderOrder.append(handle)
            while directHeaderOrder.count > 4 { directHeaders.removeValue(forKey: directHeaderOrder.removeFirst()) }
            let references = bridge.rawIndexed(data: accumulated as NSData)
            if let reference = references.last {
                referenced = true
                if let data = accept(try await directPartial(handle: handle, offset: reference.offset,
                    count: Int(reference.length), permitted: permitted)) {
                    guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                    directRawHint = reference; directRawReferences[handle] = references
                    return data
                }
            }
            if let range = bridge.scannedJpeg(data: accumulated as NSData), let result = slice(accumulated, range) {
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                directRawHint = range; directRawReferences[handle] = [range]
                return result
            }
            if accumulated.count >= maximum {
                if !referenced { directThumbnailMisses.insert(handle); return nil }
                break
            }
            if accumulated.count < target { break }
        }
        throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.GET_THUMB)
    }

    private func directRawPreview(info: PtpObjectInfo,
                                  permitted: (@Sendable () async -> Bool)? = nil) async throws -> Data? {
        let handle = info.handle, revision = directContentRevision
        let bridge = NativeStaDirectBridge.shared
        var accumulated = directHeaders[handle] ?? Data()
        let maximum = Int(min(info.size, 16 * 1024 * 1024))
        guard maximum > 0 else { return nil }
        var tried = Set<String>()
        var bestScanned: Data?
        for configured in [128, 240, 256, 512, 1024, 2048, 4096, 8192, 16384] {
            try Task.checkCancellation()
            if let permitted, !(await permitted()) { throw CameraStreamError.operationInProgress }
            let target = min(maximum, configured * 1024)
            if accumulated.count < target {
                guard let suffix = try await directPartial(handle: handle, offset: Int64(accumulated.count),
                    count: target - accumulated.count, permitted: permitted) else {
                    throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
                }
                accumulated.append(suffix)
            }
            guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
            // A bounded four-prefix cache; the current 16 MiB scan buffer is not retained by the session.
            directHeaders[handle] = Data(accumulated.prefix(512 * 1024))
            directHeaderOrder.removeAll { $0 == handle }; directHeaderOrder.append(handle)
            while directHeaderOrder.count > 4 { directHeaders.removeValue(forKey: directHeaderOrder.removeFirst()) }
            let indexed = bridge.rawIndexed(data: accumulated as NSData)
            let candidates = staPreviewPolicy.rawCandidates(values: indexed)
            var fallback: Data?
            for reference in candidates {
                let key = "\(reference.offset):\(reference.length)"
                guard reference.offset >= 0, reference.length > 0, reference.length <= 16 * 1024 * 1024,
                      reference.offset <= info.size - Int64(reference.length), tried.insert(key).inserted else { continue }
                let data: Data?
                let end = reference.offset + Int64(reference.length)
                if end <= Int64(accumulated.count) {
                    data = accumulated.subdata(in: Int(reference.offset)..<Int(end))
                } else {
                    data = try await directPartial(handle: handle, offset: reference.offset,
                        count: Int(reference.length), permitted: permitted)
                }
                guard let data, data.count == Int(reference.length),
                      NativeRawPreviewBridge.shared.isCompleteJpeg(data: data as NSData),
                      let bounds = try PreviewImageDecoder.cameraPreviewDimensions(data) else { continue }
                guard revision == directContentRevision else { throw CameraStreamError.operationInProgress }
                fallback = data
                if staPreviewPolicy.rawPreviewAdequate(width: bounds.width, height: bounds.height) { return data }
            }
            if let fallback { return fallback }
            if let range = bridge.scannedJpeg(data: accumulated as NSData) {
                let end = Int(range.offset) + Int(range.length)
                if end <= accumulated.count, Int(range.length) > (bestScanned?.count ?? 0) {
                    bestScanned = accumulated.subdata(in: Int(range.offset)..<end)
                }
            }
            if accumulated.count >= maximum { break }
            if accumulated.count < target {
                throw CameraOperationError.malformedDataset(operation: PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX)
            }
        }
        if let bestScanned, try PreviewImageDecoder.rawPreviewPixels(bestScanned) > 0 { return bestScanned }
        return nil
    }

    /// Same interactive owner for standard AP/STA and validated direct-STA previews.
    func fhdPicture(handle: Int32, retryDeviceBusy: Bool = true) async throws -> Data? {
        try await withInteractivePreviewPriority {
            try await self.readFhdPicture(handle: handle, retryDeviceBusy: retryDeviceBusy)
        }
    }

    private func readFhdPicture(handle: Int32, retryDeviceBusy: Bool) async throws -> Data? {
        try requirePhase(.ready)
        if directObjectReadValidated { return try await directFhdPicture(handle: handle, retryDeviceBusy: retryDeviceBusy) }
        if previewPolicy.disabled { return nil }
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

    /// Same partial-object command and direct recent-header reuse as Android readExifHeader.
    func exifHeader(handle: Int32, maximumBytes: Int32) async throws -> Data? {
        try await withInteractivePreviewPriority {
            try await self.readExifHeader(handle: handle, maximumBytes: maximumBytes)
        }
    }

    private func readExifHeader(handle: Int32, maximumBytes: Int32) async throws -> Data? {
        try Task.checkCancellation()
        guard maximumBytes > 0, maximumBytes <= 2 * 1024 * 1024,
              let values = PtpTransferBridge.shared.partialParameters(handle: handle, offset: 0, count: Int64(maximumBytes)) else {
            throw CameraStreamError.invalidArgument
        }
        try requirePhase(.ready)
        if directObjectReadValidated, let retained = directHeaders[handle] {
            return Data(retained.prefix(Int(maximumBytes)))
        }
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

    /// Borrow the same command owner's window; no second socket, gate or queue is created.
    func beginInteractivePreview() async throws -> UUID {
        try requirePhase(.ready)
        let token = try await session.beginInteractivePreview()
        do {
            try Task.checkCancellation()
            try requirePhase(.ready)
            return token
        } catch {
            await session.endInteractivePreview(token)
            throw error
        }
    }

    func endInteractivePreview(_ token: UUID) async {
        await session.endInteractivePreview(token)
    }

    private func withInteractivePreviewPriority<T>(_ block: () async throws -> T) async throws -> T {
        let token = try await beginInteractivePreview()
        do {
            let result = try await block()
            await endInteractivePreview(token)
            return result
        } catch {
            await endInteractivePreview(token)
            throw error
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
                         errorDescription: terminalError.map(TransferFailureMessage.describe))
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
                    } else if packet.type == PtpConstants.shared.EVENT, let decoded = PtpIPChannel.event(packet.payload) {
                        await self?.receivedEvent(decoded)
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

    /// Non-destructive read: a slow/reopened consumer cannot steal another reader's events.
    /// Keep using the single latest-state observer as a wakeup; do not add an AsyncStream consumer.
    func events(after cursor: CameraEventCursor?) throws -> CameraEventBatch {
        try requirePhase(.ready)
        let current = CameraEventCursor(connectionID: connectionID, revision: eventRevision)
        guard let cursor, cursor.connectionID == connectionID, cursor.revision <= eventRevision,
              cursor.revision == eventRevision || eventRecords.first.map({ cursor.revision >= $0.revision - 1 }) == true else {
            return CameraEventBatch(cursor: current, events: [], requiresRescan: true)
        }
        return CameraEventBatch(cursor: current, events: eventRecords.filter { $0.revision > cursor.revision }, requiresRescan: false)
    }

    private func receivedEvent(_ decoded: PtpIpEvent) async {
        guard phase == .opening || phase == .ready else { return }
        if directObjectReadValidated {
            if [Int32(0x4003), 0x4007].contains(decoded.code) {
                directContentRevision &+= 1
                let handle = Int32(truncatingIfNeeded: decoded.firstParameter)
                directInfos.removeValue(forKey: handle); directHeaders.removeValue(forKey: handle)
                directHeaderOrder.removeAll { $0 == handle }; directMetadata.invalidate(handle: handle)
                directRawReferences.removeValue(forKey: handle); directThumbnailMisses.remove(handle); directRawHint = nil
            } else if [Int32(0x4004), 0x4005, 0x400C].contains(decoded.code) {
                directContentRevision &+= 1
                directInfos.removeAll(); directHeaders.removeAll(); directHeaderOrder.removeAll()
                directMetadata.clear(); directNamesLoaded = false; directNameValueSupported = nil
                directRawReferences.removeAll(); directThumbnailMisses.removeAll(); directRawHint = nil
            }
        }
        // Never wrap a cursor into the range of an old history. Closing preserves fail-closed semantics.
        guard eventRevision < UInt64.max else { await abort(error: CameraStreamError.invalidArgument); return }
        eventRevision += 1
        eventRecords.append(CameraEventRecord(revision: eventRevision, code: decoded.code,
            transactionID: decoded.transactionId, firstParameter: decoded.firstParameter))
        if eventRecords.count > Self.eventHistoryLimit { eventRecords.removeFirst(eventRecords.count - Self.eventHistoryLimit) }
        publish()
    }

    /// A download-wide reservation excludes a second download and suppresses keepalive even
    /// between chunks. Metadata/preview commands can still take the gate between transactions.
    func download(
        handle: Int32, declaredSize: Int64, resumeOffset: Int64 = 0,
        highThroughput: Bool = false,
        onProgress: ((CameraDownloadProgress) -> Void)? = nil,
        consume: @escaping (Data) throws -> Void
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
                                             highThroughput: highThroughput, forcePartial: directObjectReadValidated)
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
                        maximumBytes: directObjectReadValidated ? requested : Int64.max - offset
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
        eventRecords.removeAll(keepingCapacity: false)
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
