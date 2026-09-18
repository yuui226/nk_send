import Foundation
import Network

struct STAConnectedCamera: Sendable {
    let session: PTPSession
    let album: STAAlbumAccess
    let guid: String?
    let close: @Sendable () async -> Void
    let startEvents: @Sendable (@escaping @Sendable (STAEvent) async -> Void) -> Void
}

struct STAAttemptFailure: Error {
    let cause: any Error
    let guid: String?
    let model: String?
    let storageProbeReached: Bool
}

struct STAConnectionFailure: Error {
    let cause: any Error
    let knownCamera: Bool
}

enum STACandidateResult: Sendable {
    case connected(STAConnectedCamera)
    case rejected
    case unexpectedCamera
}

/// CameraViewModel.tryConnectStaCandidate: bounded retries per identity, followed
/// by one alternate-identity attempt. The outer discovery owns scan retries.
actor STAConnectionCoordinator {
    typealias Connect = @Sendable (PTPIPCandidate, STAInitiatorIdentity, String?,
        @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> STAConnectedCamera
    private let profiles: STAProfileStore
    private let connect: Connect
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let onStage: @Sendable (STAConnectionStage) async -> Void
    private var pairingStage = false
    private(set) var lastFailure: STAConnectionFailure?

    init(profiles: STAProfileStore, connect: @escaping Connect,
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         onStage: @escaping @Sendable (STAConnectionStage) async -> Void) {
        self.profiles = profiles; self.connect = connect; self.sleep = sleep; self.onStage = onStage
    }

    func tryCandidate(_ candidate: PTPIPCandidate, expectedGUID: String?) async throws -> STACandidateResult {
        let preferred = profiles.preferredIdentity(for: candidate.ip)
        var known = profiles.isKnown(ip: candidate.ip)
        var reachedStorage = false
        var pairingReconnectUsed = false
        var readinessRetryUsed = false
        while true {
            try Task.checkCancellation()
            if pairingStage { pairingStage = false; await onStage(.connecting) }
            do {
                let camera = try await connect(candidate, preferred, expectedGUID, reportStage)
                guard !Task.isCancelled else { await camera.close(); throw CancellationError() }
                reachedStorage = true
                if let guid = camera.guid { known = profiles.isKnown(ip: candidate.ip, guid: guid) }
                guard profiles.isPaired(camera.guid) else {
                    lastFailure = STAConnectionFailure(cause: STAConnectionError.pairingRequired, knownCamera: known)
                    await camera.close()
                    if preferred == .albumExplorer { break }
                    return .rejected
                }
                remember(camera, candidate, preferred)
                return .connected(camera)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failed = Self.failure(error)
                reachedStorage = reachedStorage || failed.storageProbeReached
                if let guid = failed.guid { known = profiles.isKnown(ip: candidate.ip, guid: guid) }
                if case STAConnectionError.unexpectedResponder = failed.cause { return .unexpectedCamera }
                lastFailure = STAConnectionFailure(cause: failed.cause, knownCamera: known)
                if case STAConnectionError.pairingCompleted = failed.cause, !pairingReconnectUsed {
                    pairingReconnectUsed = true
                    profiles.remember(guid: failed.guid, ip: candidate.ip, identity: .pairedComputer, model: failed.model)
                    lastFailure = nil
                    try await sleep(6_600_000_000)
                } else if Self.isTransientReadinessFailure(failed.cause), !readinessRetryUsed {
                    readinessRetryUsed = true
                    lastFailure = nil
                    try await sleep(1_200_000_000)
                } else { break }
            }
        }
        let alternate = preferred.alternate
        guard reachedStorage || known || profiles.hasReusableProfile(using: alternate) else { return .rejected }
        try await sleep(900_000_000)
        try Task.checkCancellation()
        do {
            let camera = try await connect(candidate, alternate, expectedGUID, reportStage)
            guard !Task.isCancelled else { await camera.close(); throw CancellationError() }
            guard profiles.isPaired(camera.guid) else {
                lastFailure = STAConnectionFailure(cause: STAConnectionError.pairingRequired, knownCamera: known)
                await camera.close()
                return .rejected
            }
            remember(camera, candidate, alternate)
            return .connected(camera)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let failed = Self.failure(error)
            if let guid = failed.guid { known = profiles.isKnown(ip: candidate.ip, guid: guid) }
            if case STAConnectionError.unexpectedResponder = failed.cause { return .unexpectedCamera }
            if case STAConnectionError.pairingCompleted = failed.cause {
                profiles.remember(guid: failed.guid, ip: candidate.ip, identity: .pairedComputer, model: failed.model)
                lastFailure = nil
            }
            if alternate == .pairedComputer || lastFailure == nil {
                lastFailure = STAConnectionFailure(cause: failed.cause, knownCamera: known)
            }
            return .rejected
        }
    }

    private func reportStage(_ stage: STAConnectionStage) async {
        switch stage {
        case .pairing: pairingStage = true
        case .connecting: if pairingStage { return }
        case .discovering: break
        }
        await onStage(stage)
    }
    private func remember(_ camera: STAConnectedCamera, _ candidate: PTPIPCandidate, _ identity: STAInitiatorIdentity) {
        profiles.remember(guid: camera.guid, ip: candidate.ip, identity: identity, model: camera.album.deviceInfo?.model)
        lastFailure = nil
    }
    private static func failure(_ error: any Error) -> STAAttemptFailure {
        (error as? STAAttemptFailure) ?? STAAttemptFailure(cause: error, guid: nil, model: nil, storageProbeReached: false)
    }
    static func isTransientReadinessFailure(_ error: any Error) -> Bool {
        if case PTPSessionError.timeout = error { return true }
        if case STAConnectionError.albumUnavailable = error { return true }
        if case NWError.posix(let code) = error { return code == .ECONNREFUSED || code == .ETIMEDOUT }
        if case PTPIPPOSIXChannel.ChannelError.timeout = error { return true }
        if case PTPIPPOSIXChannel.ChannelError.system(let code) = error {
            return code == POSIXErrorCode.ECONNREFUSED.rawValue || code == POSIXErrorCode.ETIMEDOUT.rawValue
        }
        return false
    }
    static func reconnectDelay(attempt: Int) -> UInt64 {
        [3_000_000_000, 8_000_000_000, 15_000_000_000, 30_000_000_000][min(3, max(0, attempt))]
    }

    /// Failed attempts always retire both sockets before the next identity or
    /// candidate starts. An established camera is handed to the session owner.
    static func open(candidate: PTPIPCandidate, identity: STAInitiatorIdentity, expectedGUID: String?,
                     profiles: STAProfileStore,
                     onStage: @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> STAConnectedCamera {
        let socket: PTPIPSocketTransport
        do {
            // Android STA uses one blocking command socket + reusable reader.
            // Keep that same path in both build configurations. AP/USB are
            // unchanged. See STA下载-Android与iOS实现差异审查.md for evidence.
            socket = try await PTPIPSocketTransport.open(host: candidate.ip, localAddress: candidate.localAddress,
                staInitiatorID: profiles.initiatorID(identity), expectedGUID: expectedGUID, backend: .bsdSocket)
        } catch { throw STAAttemptFailure(cause: error, guid: nil, model: nil, storageProbeReached: false) }
        let session = PTPSession(transport: socket, firstTransactionID: 0, defaultTimeoutNanoseconds: 60_000_000_000)
        let browsing = STABrowsingSession(session: session, guid: socket.responderGUID, identity: identity,
            profiles: profiles, onStage: onStage, waitForPairingEvent: { await socket.waitForPairingEvent() })
        do {
            let album = try await browsing.open()
            try Task.checkCancellation()
            return STAConnectedCamera(session: session, album: album, guid: socket.responderGUID,
                                      close: { await PTPIPSocketTransport.retireOpenedSession(session, socket: socket, opened: true) },
                                      startEvents: { socket.startEvents(onEvent: $0) })
        } catch {
            await PTPIPSocketTransport.retireOpenedSession(session, socket: socket,
                                                           opened: await browsing.sessionOpened)
            throw STAAttemptFailure(cause: error, guid: socket.responderGUID, model: await browsing.deviceInfo?.model,
                                   storageProbeReached: await browsing.storageProbeReached)
        }
    }
}
