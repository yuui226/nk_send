import Foundation
import Network

struct STAConnectedCamera: Sendable {
    let session: PTPSession
    let album: STAAlbumAccess
    let guid: String?
    let pairingConfirmed: Bool
    let close: @Sendable () async -> Void
    let startEvents: @Sendable (@escaping @Sendable (STAEvent) async -> Void) -> Void
}

struct STAAttemptFailure: Error {
    let cause: any Error
    let guid: String?
    let model: String?
    let storageProbeReached: Bool
    var pairingExchangeStarted = false
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
    typealias Connect = @Sendable (PTPIPCandidate, STAInitiatorIdentity, String?, STAPairingConfirmation?, Bool,
        @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> STAConnectedCamera
    private let profiles: STAProfileStore
    private let connect: Connect
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onStage: @Sendable (STAConnectionStage) async -> Void
    private var pairingStage = false
    private var pairingFlowStarted = false
    private var attemptExchangeStarted = false
    private var receipt: STAPairingConfirmation?
    private var confirmedGUID: String?
    private var reachedStorage = false
    private var known = false
    private let diagnosticSession: UInt64
    private(set) var lastFailure: STAConnectionFailure?

    init(profiles: STAProfileStore, diagnosticSession: UInt64 = 0, connect: @escaping Connect,
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         onStage: @escaping @Sendable (STAConnectionStage) async -> Void) {
        self.diagnosticSession = diagnosticSession
        self.now = now
        self.profiles = profiles; self.connect = connect; self.sleep = sleep; self.onStage = onStage
    }

    func tryCandidate(_ candidate: PTPIPCandidate, expectedGUID: String?) async throws -> STACandidateResult {
        let preferred = profiles.preferredIdentity(for: candidate.ip)
        known = profiles.isKnown(ip: candidate.ip); reachedStorage = false
        pairingStage = false; pairingFlowStarted = false; receipt = nil; confirmedGUID = nil
        let result = try await tryIdentity(preferred, candidate: candidate, expectedGUID: expectedGUID, alternate: false)
        guard case .rejected = result else { return result }
        if preferred == .pairedComputer && pairingFlowStarted { return .rejected }
        let alternate = preferred.alternate
        guard reachedStorage || known || profiles.hasReusableProfile(using: alternate) else { return .rejected }
        try await wait("alternate_identity", 900_000_000)
        return try await tryIdentity(alternate, candidate: candidate, expectedGUID: expectedGUID, alternate: true)
    }

    private func tryIdentity(_ identity: STAInitiatorIdentity, candidate: PTPIPCandidate,
                             expectedGUID: String?, alternate: Bool) async throws -> STACandidateResult {
        let paired = identity == .pairedComputer
        var reconnectUsed = false, recoveryUsed = false, cleanupRecoveryUsed = false, readinessUsed = false
        var restartDeadline: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            attemptExchangeStarted = false
            let allowInlineRecovery = paired && receipt?.remotePermissionVerified == false && !recoveryUsed
            STAConnectionDiagnostics.note(diagnosticSession, "candidate start identity=\(identity.rawValue) alternate=\(alternate) verify=\(receipt != nil)")
            do {
                let camera = try await connect(candidate, identity, confirmedGUID ?? expectedGUID,
                    paired ? receipt : nil, allowInlineRecovery, { [self] stage in
                        if paired && stage == .pairing { await markPairingStarted() }
                        await reportStage(stage)
                    })
                guard !Task.isCancelled else { await camera.close(); throw CancellationError() }
                reachedStorage = true
                if let guid = camera.guid { known = profiles.isKnown(ip: candidate.ip, guid: guid) }
                guard camera.pairingConfirmed, profiles.hasTrustedPairing(camera.guid) else {
                    await camera.close()
                    lastFailure = .init(cause: STAConnectionError.pairingRequired, knownCamera: known)
                    if paired { throw STAPairingConfirmationMissing(cause: STAConnectionError.pairingNotConfirmed) }
                    return .rejected
                }
                do { try remember(camera, candidate, identity) }
                catch { await camera.close(); throw error }
                return .connected(camera)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failed = Self.failure(error)
                reachedStorage = reachedStorage || failed.storageProbeReached
                if let guid = failed.guid { known = profiles.isKnown(ip: candidate.ip, guid: guid) }
                if case STAConnectionError.unexpectedResponder = failed.cause {
                    if confirmedGUID != nil { throw STAPairingConfirmationMissing(cause: failed.cause) }
                    return .unexpectedCamera
                }
                if !alternate || paired || lastFailure == nil { lastFailure = .init(cause: failed.cause, knownCamera: known) }
                if failed.cause is STAPairingConfirmationMissing { throw failed.cause }
                // User-approved 2026-11-08 exception to Android's single readiness
                // retry: Wi-Fi can still be rejoining after the Result ACK. Keep
                // the same receipt/GUID; never repeat an ambiguous Query/Result.
                if paired, receipt != nil, let restartDeadline,
                   !attemptExchangeStarted, !failed.pairingExchangeStarted,
                   Self.isPostPairingNetworkFailure(failed.cause) {
                    let remaining = now().duration(to: restartDeadline)
                    guard remaining > .zero else {
                        throw STAPairingConfirmationMissing(cause: failed.cause)
                    }
                    let parts = min(remaining, .milliseconds(1_200)).components
                    let nanos = UInt64(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
                    lastFailure = nil
                    try await wait("post_pairing_network_retry", max(1, nanos))
                    guard now() < restartDeadline else {
                        throw STAPairingConfirmationMissing(cause: failed.cause)
                    }
                    continue
                }
                if let completed = failed.cause as? STAPairingCompleted {
                    pairingFlowStarted = true
                    guard paired, receipt?.remotePermissionVerified != true,
                          confirmedGUID == nil || confirmedGUID == completed.confirmation.responderGUID else {
                        throw STAPairingConfirmationMissing(cause: completed)
                    }
                    if completed.isRecovery {
                        guard allowInlineRecovery else { throw STAPairingConfirmationMissing(cause: completed) }
                        recoveryUsed = true
                    } else if reconnectUsed { throw STAPairingConfirmationMissing(cause: completed) }
                    reconnectUsed = true; receipt = completed.confirmation
                    let observedAt = now()
                    let acknowledgedAt = min(observedAt, completed.confirmation.resultAcknowledgedAt ?? observedAt)
                    restartDeadline = acknowledgedAt.advanced(by: .seconds(60))
                    confirmedGUID = completed.confirmation.responderGUID
                    try Task.checkCancellation()
                    try profiles.rememberUnlessCancelled(guid: confirmedGUID, ip: candidate.ip, identity: .pairedComputer, model: failed.model)
                    lastFailure = nil
                    try await wait("post_pairing_restart", completed.confirmation.remainingRestartDelay(now: now()))
                } else if let cleanup = failed.cause as? STAPairingCleanupFailure {
                    guard paired, !cleanupRecoveryUsed, let previous = receipt,
                          previous.responderGUID == cleanup.confirmation.responderGUID,
                          cleanup.confirmation.remotePermissionVerified else {
                        throw STAPairingConfirmationMissing(cause: cleanup)
                    }
                    cleanupRecoveryUsed = true
                    receipt = cleanup.confirmation; confirmedGUID = cleanup.confirmation.responderGUID
                    lastFailure = nil
                    try await wait("pairing_cleanup_retry", 1_200_000_000)
                } else if let verification = failed.cause as? STAPairingVerificationFailure {
                    if paired {
                        pairingFlowStarted = true
                        if confirmedGUID == nil { confirmedGUID = failed.guid }
                    }
                    let repairAllowed = !recoveryUsed && receipt?.remotePermissionVerified != true &&
                        (verification.remoteRequestAttempted || verification.pairingOnly)
                    if repairAllowed {
                        recoveryUsed = true; reconnectUsed = false; receipt = nil
                        restartDeadline = nil
                        lastFailure = nil
                        try await wait("pairing_recovery", 6_600_000_000)
                    } else if !readinessUsed && !verification.remoteRequestAttempted && !verification.pairingOnly &&
                                (!alternate || receipt != nil) {
                        readinessUsed = true; lastFailure = nil
                        try await wait("service_ready_retry", 1_200_000_000)
                    } else {
                        if receipt?.remotePermissionVerified == true { throw STAPairingConfirmationMissing(cause: failed.cause) }
                        if paired && pairingFlowStarted { throw STAPairingConfirmationMissing(cause: failed.cause) }
                        return .rejected
                    }
                } else if paired && (attemptExchangeStarted || failed.pairingExchangeStarted) {
                    // Query/Result may already have changed camera state. A
                    // read timeout here is never a generic readiness retry.
                    throw STAPairingConfirmationMissing(cause: failed.cause)
                } else if Self.isTransientReadinessFailure(failed.cause), !readinessUsed, !alternate || receipt != nil {
                    readinessUsed = true; lastFailure = nil
                    try await wait("service_ready_retry", 1_200_000_000)
                } else {
                    if paired && pairingFlowStarted { throw STAPairingConfirmationMissing(cause: failed.cause) }
                    return .rejected
                }
            }
        }
    }
    private func markPairingStarted() { pairingFlowStarted = true; attemptExchangeStarted = true }
    private func wait(_ reason: String, _ nanos: UInt64) async throws {
        #if DEBUG
        let start = ContinuousClock.now
        STAConnectionDiagnostics.note(diagnosticSession, "wait start reason=\(reason) plannedMs=\(nanos / 1_000_000)")
        defer { STAConnectionDiagnostics.note(diagnosticSession, "wait end reason=\(reason) actual=\(start.duration(to: .now))") }
        #endif
        try await sleep(nanos)
        try Task.checkCancellation()
    }

    private func reportStage(_ stage: STAConnectionStage) async {
        switch stage {
        case .pairing: pairingStage = true
        case .connecting: if pairingStage { return }
        case .discovering: if pairingStage { return }
        }
        await onStage(stage)
    }
    private func remember(_ camera: STAConnectedCamera, _ candidate: PTPIPCandidate, _ identity: STAInitiatorIdentity) throws {
        try profiles.rememberUnlessCancelled(guid: camera.guid, ip: candidate.ip, identity: identity, model: camera.album.deviceInfo?.model)
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
    /// Transport loss only. Camera response codes, invalid data, permission
    /// errors and failed remote/inline repairs retain Android's bounded policy.
    private static func isPostPairingNetworkFailure(_ error: any Error) -> Bool {
        if let verification = error as? STAPairingVerificationFailure {
            return !verification.remoteRequestAttempted && !verification.pairingOnly &&
                isPostPairingNetworkFailure(verification.cause)
        }
        if case PTPSessionError.timeout = error { return true }
        if case PTPIPPOSIXChannel.ChannelError.timeout = error { return true }
        if case PTPIPPOSIXChannel.ChannelError.closed = error { return true }
        let code: POSIXErrorCode?
        switch error {
        case NWError.posix(let value): code = value
        case PTPIPPOSIXChannel.ChannelError.system(let value): code = POSIXErrorCode(rawValue: value)
        default: return false
        }
        switch code {
        case .ECONNREFUSED, .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN,
             .ECONNRESET, .ECONNABORTED, .ENOTCONN, .EPIPE: return true
        default: return false
        }
    }
    static func reconnectDelay(attempt: Int) -> UInt64 {
        [3_000_000_000, 8_000_000_000, 15_000_000_000, 30_000_000_000][min(3, max(0, attempt))]
    }

    /// Failed attempts always retire both sockets before the next identity or
    /// candidate starts. An established camera is handed to the session owner.
    static func open(candidate: PTPIPCandidate, identity: STAInitiatorIdentity, expectedGUID: String?,
                     profiles: STAProfileStore, pairingConfirmation: STAPairingConfirmation? = nil,
                     allowInlineRecovery: Bool = false, diagnosticSession: UInt64 = 0,
                     onStage: @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> STAConnectedCamera {
        if let pairingConfirmation, let expectedGUID, expectedGUID != pairingConfirmation.responderGUID {
            throw STAConnectionError.unexpectedResponder(expected: expectedGUID, actual: pairingConfirmation.responderGUID)
        }
        let trace = STAConnectionTrace()
        defer {
            trace.note("connection=END")
            STAConnectionDiagnostics.attempt(diagnosticSession, label: "\(candidate.ip) \(identity.rawValue)", report: trace.report())
        }
        let socket: PTPIPSocketTransport
        do {
            // Android STA uses one blocking command socket + reusable reader.
            // Keep that same path in both build configurations. AP/USB are
            // unchanged. See STA下载-Android与iOS实现差异审查.md for evidence.
            socket = try await PTPIPSocketTransport.open(host: candidate.ip, localAddress: candidate.localAddress,
                staInitiatorID: profiles.initiatorID(identity), expectedGUID: pairingConfirmation?.responderGUID ?? expectedGUID, backend: .bsdSocket, trace: trace)
        } catch {
            trace.note("socket=ERROR reason=\(error)")
            throw STAAttemptFailure(cause: error, guid: nil, model: nil, storageProbeReached: false)
        }
        let session = PTPSession(transport: socket, firstTransactionID: 0, defaultTimeoutNanoseconds: 60_000_000_000)
        let browsing = STABrowsingSession(session: session, guid: socket.responderGUID, identity: identity,
            profiles: profiles, pairingConfirmation: pairingConfirmation, allowInlineRecovery: allowInlineRecovery, trace: trace,
            abortTransport: { socket.close() },
            onStage: onStage)
        do {
            let album = try await withTaskCancellationHandler {
                try await browsing.open()
            } onCancel: { socket.close() }
            try Task.checkCancellation()
            socket.completeSTAHandshake()
            return STAConnectedCamera(session: session, album: album, guid: socket.responderGUID,
                                      pairingConfirmed: !(await browsing.pairingRequired) && profiles.hasTrustedPairing(socket.responderGUID),
                                      close: { await PTPIPSocketTransport.retireOpenedSession(session, socket: socket, opened: true) },
                                      startEvents: { socket.startEvents(onEvent: $0) })
        } catch {
            trace.note("handshake=END reason=\(error)")
            if Task.isCancelled || socket.isClosed || error is STAPairingCompleted {
                socket.close(); _ = await session.invalidate()
            } else {
                await PTPIPSocketTransport.retireOpenedSession(session, socket: socket,
                    opened: await browsing.sessionOpened, timeoutNanoseconds: 5_000_000_000)
            }
            throw STAAttemptFailure(cause: error, guid: socket.responderGUID, model: await browsing.deviceInfo?.model,
                storageProbeReached: await browsing.storageProbeReached, pairingExchangeStarted: await browsing.pairingExchangeStarted)
        }
    }
}

/// CameraViewModel.startStaDiscovery: a saved body's absence is not the final
/// result. Only publish failure after discovery AND the deferred new-body
/// pairing have finished. Kept with the protocol coordinator so regression
/// fixtures exercise the same selection path used by WiFiConnectionService.
actor STACandidateSelection {
    typealias Discover = @Sendable (
        @escaping @Sendable (PTPIPCandidate) async throws -> STAConnectedCamera?
    ) async throws -> STAConnectedCamera?
    let coordinator: STAConnectionCoordinator
    let expectedGUID: String?
    private var deferred: PTPIPCandidate?
    init(coordinator: STAConnectionCoordinator, expectedGUID: String?) {
        self.coordinator = coordinator; self.expectedGUID = expectedGUID
    }
    func connect(discover: Discover) async throws -> STAConnectedCamera {
        let found = try await discover { try await self.tryCandidate($0) }
        if let found { return found }
        try Task.checkCancellation()
        if let camera = try await tryDeferred() { return camera }
        throw await coordinator.lastFailure ?? STAConnectionFailure(cause: STAConnectionError.notFound, knownCamera: false)
    }
    private func tryCandidate(_ candidate: PTPIPCandidate) async throws -> STAConnectedCamera? {
        switch try await coordinator.tryCandidate(candidate, expectedGUID: expectedGUID) {
        case .connected(let camera): return camera
        case .unexpectedCamera: if deferred == nil { deferred = candidate }; return nil
        case .rejected: return nil
        }
    }
    private func tryDeferred() async throws -> STAConnectedCamera? {
        guard let deferred else { return nil }
        if case .connected(let camera) = try await coordinator.tryCandidate(deferred, expectedGUID: nil) { return camera }
        return nil
    }
}
