import Foundation

enum STAConnectionStage: Equatable, Sendable { case discovering(String?), pairing, connecting }

enum STAConnectionError: Error, Equatable, Sendable {
    case cameraRefused
    case unexpectedResponder(expected: String, actual: String?)
    case pairingNotConfirmed
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
    private let pairingConfirmation: STAPairingConfirmation?
    private let allowInlineRecovery: Bool
    private var verifyingPairing = false
    private let onStage: @Sendable (STAConnectionStage) async -> Void
    private let trace: STAConnectionTrace
    private let abortTransport: @Sendable () -> Void
    private(set) var pairingRequired = false
    private(set) var pairingExchangeStarted = false
    private(set) var storageProbeReached = false
    private(set) var sessionOpened = false
    private(set) var deviceInfo: PTPDeviceInfo?
    private var sawEmptyHandles = false
    private var sawHandles = false
    private var directRead = false
    private var prefetchedHandles: (storageID: UInt32, handles: [UInt32])?

    init(session: PTPSession, guid: String?, identity: STAInitiatorIdentity, profiles: STAProfileStore,
         pairingConfirmation: STAPairingConfirmation? = nil,
         allowInlineRecovery: Bool = false,
         trace: STAConnectionTrace = .init(),
         abortTransport: @escaping @Sendable () -> Void = {},
         onStage: @escaping @Sendable (STAConnectionStage) async -> Void) {
        self.pairingConfirmation = pairingConfirmation
        self.allowInlineRecovery = allowInlineRecovery
        self.trace = trace; self.abortTransport = abortTransport
        self.session = session; self.guid = guid; self.identity = identity; self.profiles = profiles
        self.onStage = onStage
    }

    func open() async throws -> STAAlbumAccess {
        if let receipt = pairingConfirmation {
            guard guid == receipt.responderGUID else {
                throw STAConnectionError.unexpectedResponder(expected: receipt.responderGUID, actual: guid)
            }
            guard identity == .pairedComputer else { throw STAConnectionError.pairingNotConfirmed }
        }
        verifyingPairing = pairingConfirmation != nil || profiles.requiresPairingVerification(guid)
        let opened = try await command(PTPConstants.openSession, [1])
        guard opened.code == PTPConstants.responseOK || opened.code == PTPConstants.sessionAlreadyOpen else {
            throw PTPSessionError.responseCode(opened.code)
        }
        sessionOpened = true
        let compatibility = try await command(PTPConstants.nikonCompatibilityInit)
        guard compatibility.code == PTPConstants.responseOK else {
            throw STAConnectionError.initializationFailed(compatibility.code)
        }
        if let receipt = pairingConfirmation, receipt.remotePermissionVerified {
            try await STAPairingLiveView.finishCleanup(session: session, confirmation: receipt,
                responderGUID: guid, trace: trace, abort: abortTransport)
        }
        let storage = try await command(PTPConstants.getStorageIDs)
        storageProbeReached = true
        let ids = PTPDatasetParser.readStorageIDs(storage.data) ?? []
        let allowsPairing = identity == .pairedComputer
        // Android forceProfilePairing is true only for the computer identity.
        if storage.code == PTPConstants.responseOK && allowsPairing && !profiles.isPaired(guid) && !verifyingPairing {
            try await pair()
        }
        let info = try await command(PTPConstants.getDeviceInfo)
        if info.code == PTPConstants.responseOK { deviceInfo = PTPDatasetParser.parseDeviceInfo(info.data) }
        let pairingOnly: Set<UInt16> = [0x1001, 0x1002, 0x1003, 0x952B, 0x935A]
        if verifyingPairing && (info.code != PTPConstants.responseOK || deviceInfo?.operations.isEmpty != false) {
            try await rejectUnconfirmedPairing(cause: info.code == PTPConstants.responseOK ? nil : PTPSessionError.responseCode(info.code))
        }
        if deviceInfo?.operations == pairingOnly {
            pairingRequired = true
            if allowsPairing || verifyingPairing { try profiles.invalidatePairingUnlessCancelled(guid) }
            if verifyingPairing {
                if allowsPairing && allowInlineRecovery && pairingConfirmation?.remotePermissionVerified == false {
                    try await pair(isRecovery: true)
                }
                try await rejectUnconfirmedPairing(pairingOnly: true)
            }
            if allowsPairing { try await pair() }
        }
        await onStage(.connecting)
        if storage.code == PTPConstants.responseOK && !ids.isEmpty,
           try await validateObjectAccess(storageIDs: ids) { return try await access(ids) }

        let mode = try await command(PTPConstants.nikonChangeApplicationMode, [1])
        if mode.code == PTPConstants.responseOK {
            _ = try await command(PTPConstants.nikonCompatibilityInit)
            let modeStorage = try await command(PTPConstants.getStorageIDs)
            let modeIDs = PTPDatasetParser.readStorageIDs(modeStorage.data) ?? []
            if modeStorage.code == PTPConstants.responseOK && !modeIDs.isEmpty,
               try await validateObjectAccess(storageIDs: modeIDs) { return try await access(modeIDs) }
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
            if info.code != PTPConstants.responseOK || info.data.count < 53 { allAccessible = false; break }
        }
        if !allAccessible {
            let handle = handles[0]
            let size = try await command(PTPConstants.getObjectSize, [handle])
            var sizeReader = PTPDataReader(size.data)
            let byteCount = size.code == PTPConstants.responseOK ? (sizeReader.readUInt64() ?? 0) : 0
            guard byteCount > 0, byteCount <= UInt64(Int64.max) else { return false }
            let partial = try await command(PTPConstants.getPartialObjectEx, [handle, 0, 0, 65_536, 0])
            if partial.code == PTPConstants.responseOK && !partial.data.isEmpty {
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
    private func access(_ storages: [UInt32]) async throws -> STAAlbumAccess {
        try Task.checkCancellation()
        if let receipt = pairingConfirmation, !receipt.remotePermissionVerified {
            try await STAPairingLiveView.verify(session: session, operations: deviceInfo?.operations ?? [],
                trace: trace, confirmation: receipt, abort: abortTransport)
        }
        if verifyingPairing { try profiles.confirmVerifiedPairingUnlessCancelled(guid) }
        return STAAlbumAccess(storageIDs: storages, prefetchedHandles: prefetchedHandles,
                       directObjectRead: directRead, deviceInfo: deviceInfo)
    }
    private func rejectUnconfirmedPairing(cause: (any Error)? = nil, pairingOnly: Bool = false) async throws -> Never {
        try Task.checkCancellation()
        throw STAPairingVerificationFailure(cause: cause ?? STAConnectionError.pairingNotConfirmed,
                                           pairingOnly: pairingOnly)
    }

    private func pair(isRecovery: Bool = false) async throws -> Never {
        try Task.checkCancellation()
        guard let guid else { throw STAPairingConfirmationMissing() }
        pairingRequired = true
        pairingExchangeStarted = true
        await onStage(.pairing)
        do {
            let query = try await command(PTPConstants.nikonPairingQuery)
            guard query.code == PTPConstants.responseOK else { throw STAConnectionError.pairingQueryFailed(query.code) }
            let result = try await command(PTPConstants.nikonPairingResult, [UInt32(PTPConstants.responseOK)])
            guard result.code == PTPConstants.responseOK else { throw STAConnectionError.pairingResultFailed(result.code) }
            let acknowledgedAt = ContinuousClock.now
            try Task.checkCancellation()
            // ca03503c: no 0x4008 wait and no CloseSession on a restarting camera.
            throw STAPairingCompleted(confirmation: .init(responderGUID: guid,
                resultAcknowledgedAt: acknowledgedAt), isRecovery: isRecovery)
        } catch {
            abortTransport()
            throw error
        }
    }
    private func command(_ operation: UInt16, _ parameters: [UInt32] = []) async throws -> PTPResponse {
        // ca03503c: handles have 30 s total, with the transport retaining a 5 s
        // idle limit; all other handshake responses have a 5 s total budget.
        let reply = try await session.executeResponse(operation: operation, parameters: parameters,
            timeoutNanoseconds: operation == PTPConstants.getObjectHandles ? 30_000_000_000 : 5_000_000_000)
        trace.note(String(format: "op=0x%04X rc=0x%04X bytes=%d", operation, reply.code, reply.data.count))
        return reply
    }
}
