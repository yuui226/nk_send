import Foundation

enum STAConnectionStage: Equatable, Sendable { case discovering(String?), pairing, connecting }

enum STAConnectionError: Error, Equatable, Sendable {
    case cameraRefused
    case unexpectedResponder(expected: String, actual: String?)
    case pairingCompleted
    case noMedia
    case albumUnavailable(UInt16)
    case initializationFailed(UInt16)
    case pairingQueryFailed(UInt16)
    case pairingResultFailed(UInt16)
    case pairingRequired
    case notFound
}

struct STAAlbumAccess: Sendable {
    let storageIDs: [UInt32]
    let prefetchedHandles: (storageID: UInt32, handles: [UInt32])?
    let directObjectRead: Bool
    let deviceInfo: PTPDeviceInfo?
}

/// NikonCamera.connectSta / initializeStaBrowsingSession, in the same command
/// order as Android. UIKit, discovery and reconnect scheduling stay outside.
actor STABrowsingSession {
    let session: PTPSession
    private let guid: String?
    private let identity: STAInitiatorIdentity
    private let profiles: STAProfileStore
    private let onStage: @Sendable (STAConnectionStage) async -> Void
    private let waitForPairingEvent: @Sendable () async -> Void
    private(set) var storageProbeReached = false
    private(set) var deviceInfo: PTPDeviceInfo?
    private var sawEmptyHandles = false
    private var sawHandles = false
    private var directRead = false
    private var prefetchedHandles: (storageID: UInt32, handles: [UInt32])?

    init(session: PTPSession, guid: String?, identity: STAInitiatorIdentity, profiles: STAProfileStore,
         onStage: @escaping @Sendable (STAConnectionStage) async -> Void,
         waitForPairingEvent: @escaping @Sendable () async -> Void) {
        self.session = session; self.guid = guid; self.identity = identity; self.profiles = profiles
        self.onStage = onStage; self.waitForPairingEvent = waitForPairingEvent
    }

    func open() async throws -> STAAlbumAccess {
        let opened = try await command(PTPConstants.openSession, [1])
        guard opened.code == PTPConstants.responseOK || opened.code == PTPConstants.sessionAlreadyOpen else {
            throw PTPSessionError.responseCode(opened.code)
        }
        let compatibility = try await command(PTPConstants.nikonCompatibilityInit)
        guard compatibility.code == PTPConstants.responseOK else {
            throw STAConnectionError.initializationFailed(compatibility.code)
        }
        let storage = try await command(PTPConstants.getStorageIDs)
        storageProbeReached = true
        let ids = PTPDatasetParser.readStorageIDs(storage.data) ?? []
        let allowsPairing = identity == .pairedComputer
        // Android forceProfilePairing is true only for the computer identity.
        if storage.code == PTPConstants.responseOK && allowsPairing && !profiles.isPaired(guid) {
            try await pair()
        }
        let info = try await command(PTPConstants.getDeviceInfo)
        if info.code == PTPConstants.responseOK { deviceInfo = PTPDatasetParser.parseDeviceInfo(info.data) }
        let pairingOnly: Set<UInt16> = [0x1001, 0x1002, 0x1003, 0x952B, 0x935A]
        if allowsPairing && deviceInfo?.operations == pairingOnly { try await pair() }
        await onStage(.connecting)
        if storage.code == PTPConstants.responseOK && !ids.isEmpty,
           try await validateObjectAccess(storageIDs: ids) { return access(ids) }

        let mode = try await command(PTPConstants.nikonChangeApplicationMode, [1])
        if mode.code == PTPConstants.responseOK {
            _ = try await command(PTPConstants.nikonCompatibilityInit)
            let modeStorage = try await command(PTPConstants.getStorageIDs)
            let modeIDs = PTPDatasetParser.readStorageIDs(modeStorage.data) ?? []
            if modeStorage.code == PTPConstants.responseOK && !modeIDs.isEmpty,
               try await validateObjectAccess(storageIDs: modeIDs) { return access(modeIDs) }
            _ = try? await command(PTPConstants.nikonChangeApplicationMode, [0])
        }
        if sawEmptyHandles && !sawHandles { throw STAConnectionError.noMedia }
        throw STAConnectionError.albumUnavailable(storage.code)
    }

    private func validateObjectAccess(storageIDs: [UInt32]) async throws -> Bool {
        let reply = try await command(PTPConstants.getObjectHandles, [.max, .max, 0])
        let handles = PTPDatasetParser.readObjectHandles(reply.data) ?? []
        sawHandles = sawHandles || !handles.isEmpty
        sawEmptyHandles = sawEmptyHandles || (reply.code == PTPConstants.responseOK && reply.data == Data([0, 0, 0, 0]))
        guard reply.code == PTPConstants.responseOK, !handles.isEmpty else { return false }
        var indexes: [Int] = []
        for index in [0, (handles.count - 1) / 2, handles.count - 1] where !indexes.contains(index) { indexes.append(index) }
        var allAccessible = true
        for index in indexes {
            let info = try await command(PTPConstants.getObjectInfo, [handles[index]])
            if info.code != PTPConstants.responseOK || info.data.count < 53 { allAccessible = false }
        }
        if !allAccessible {
            let handle = handles[0]
            _ = try await command(PTPConstants.getThumb, [handle])
            let size = try await command(PTPConstants.getObjectSize, [handle])
            let partial = try await command(PTPConstants.getPartialObjectEx, [handle, 0, 0, 65_536, 0])
            var sizeReader = PTPDataReader(size.data)
            let byteCount = size.code == PTPConstants.responseOK ? (sizeReader.readUInt64() ?? 0) : 0
            if byteCount > 0 && byteCount <= UInt64(Int64.max) && partial.code == PTPConstants.responseOK && !partial.data.isEmpty {
                directRead = true
                rememberHandles(storageIDs, handles)
                return true
            }
        }
        if allAccessible { rememberHandles(storageIDs, handles) }
        return allAccessible
    }

    private func rememberHandles(_ storages: [UInt32], _ handles: [UInt32]) {
        let usable = storages.filter { $0 != 0 && $0 != .max }
        guard usable.count == 1 else { return }
        let id = usable[0]
        prefetchedHandles = (id & 0xFFFF == 0 ? .max : id, handles)
    }
    private func access(_ storages: [UInt32]) -> STAAlbumAccess {
        STAAlbumAccess(storageIDs: storages, prefetchedHandles: prefetchedHandles,
                       directObjectRead: directRead, deviceInfo: deviceInfo)
    }
    private func pair() async throws -> Never {
        await onStage(.pairing)
        let query = try await command(PTPConstants.nikonPairingQuery)
        guard query.code == PTPConstants.responseOK else { throw STAConnectionError.pairingQueryFailed(query.code) }
        let result = try await command(PTPConstants.nikonPairingResult, [UInt32(PTPConstants.responseOK)])
        guard result.code == PTPConstants.responseOK else { throw STAConnectionError.pairingResultFailed(result.code) }
        try Task.checkCancellation()
        profiles.markPaired(guid)
        await waitForPairingEvent()
        _ = try? await command(PTPConstants.closeSession)
        try Task.checkCancellation()
        throw STAConnectionError.pairingCompleted
    }
    private func command(_ operation: UInt16, _ parameters: [UInt32] = []) async throws -> PTPResponse {
        // Android switches both PTP/IP sockets from the 5 s handshake timeout
        // to its 60 s normal read timeout before initializeStaBrowsingSession.
        try await session.executeResponse(operation: operation, parameters: parameters,
                                          timeoutNanoseconds: 60_000_000_000)
    }
}
