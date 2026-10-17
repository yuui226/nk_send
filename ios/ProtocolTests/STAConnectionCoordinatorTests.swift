import XCTest
import Network
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

@MainActor
final class STAConnectionCoordinatorTests: XCTestCase {
    let guid = String(repeating: "1", count: 32)
    let candidate = PTPIPCandidate(ip: "192.168.5.9", localAddress: "192.168.5.1")

    func testRealBrowsingRecoveryPersistsOnlyAfterFourthSessionValidatesAlbum() async throws {
        let prefs = STAProfileFixture(), store = prefs.store, guid = guid
        let start: [STAExchange] = [.init(0x1002, [1]), .init(0x941C),
            .init(0x1004, payload: staU32Array([0x10001]))]
        let pair = start + [.init(0x952B), .init(0x935A, [0x2001]), .init(0x1003)]
        let rejected = start + [.init(0x1001, payload: staDeviceInfo(operations: [0x1001, 0x1002, 0x1003, 0x952B, 0x935A]))]
        let accepted = start + [.init(0x1001, payload: staDeviceInfo()),
            .init(0x1007, [.max, .max, 0], payload: staU32Array([7])),
            .init(0x1008, [7], payload: Data(repeating: 0, count: 53))]
        let wires = [pair, rejected, pair, accepted].map(STAScriptTransport.init)
        let flags = STARecorder<Bool>(), pauses = STARecorder<UInt64>()
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, verify, stage in
            let index = await flags.values.count
            await flags.append(verify)
            XCTAssertFalse(store.isPaired(guid))
            guard index < wires.count else { throw STAFixtureError.unexpectedCommand(0) }
            let session = PTPSession(transport: wires[index])
            let browsing = STABrowsingSession(session: session, guid: guid, identity: identity,
                profiles: store, verifyPairingCompletion: verify, onStage: stage,
                waitForPairingEvent: { XCTAssertFalse(store.isPaired(guid)) })
            do {
                let album = try await browsing.open()
                return STAConnectedCamera(session: session, album: album, guid: guid,
                    close: {}, startEvents: { _ in })
            } catch {
                throw STAAttemptFailure(cause: error, guid: guid, model: nil,
                    storageProbeReached: await browsing.storageProbeReached)
            }
        }, sleep: { delay in
            XCTAssertFalse(store.isPaired(guid))
            await pauses.append(delay)
        }, onStage: { _ in })
        guard case .connected(let camera) = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else {
            return XCTFail("Recovery did not establish an album session")
        }
        XCTAssertEqual(camera.album.prefetchedHandles?.handles, [7])
        XCTAssertTrue(store.hasTrustedPairing(guid))
        XCTAssertTrue(STAProfileStore(preferences: prefs.connection, pairing: prefs.pairing).hasTrustedPairing(guid))
        let verification = await flags.values, delays = await pauses.values
        XCTAssertEqual(verification, [false, true, false, true])
        XCTAssertEqual(delays, Array(repeating: 6_600_000_000, count: 3))
        for wire in wires { let remaining = await wire.remaining; XCTAssertEqual(remaining, 0) }
    }

    func testPairingReconnectThenOneReadinessRetryUsesSameIdentityAndAndroidDelays() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let store = prefs.store, guid = guid
        let connector = STAAttemptScript([
            .failure(STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: guid, model: "Z 30", storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: PTPSessionError.timeout, guid: guid, model: nil, storageProbeReached: false)),
            .success(fakeSTACamera(guid: guid)),
        ])
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, _, _ in
            await attempts.append(identity)
            let camera = try await connector.next()
            store.confirmVerifiedPairing(guid) // Successful DeviceInfo/album verification.
            return camera
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        guard case .connected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail("Not connected") }
        let identities = await attempts.values, delays = await pauses.values
        XCTAssertEqual(identities, [.pairedComputer, .pairedComputer, .pairedComputer])
        XCTAssertEqual(delays, [6_600_000_000, 1_200_000_000])
        XCTAssertEqual(store.mostRecentGUID, guid)
        XCTAssertEqual(store.lastUsedIP, candidate.ip)
        let remaining = await connector.remaining; XCTAssertEqual(remaining, 0)
    }

    func testUnconfirmedPairingAllowsOnlyOneRecoveryAndForwardsVerification() async throws {
        let prefs = STAProfileFixture(), verification = STARecorder<Bool>(), pauses = STARecorder<UInt64>()
        let guid = guid
        let script = STAAttemptScript([
            .failure(STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: STAConnectionError.pairingNotConfirmed, guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: STAConnectionError.pairingNotConfirmed, guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAConnectionError.cameraRefused)
        ])
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, verify, _ in
            await verification.append(verify)
            return try await script.next()
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let flags = await verification.values, delays = await pauses.values
        XCTAssertEqual(flags, [false, true, false, true, false])
        XCTAssertEqual(delays, [6_600_000_000, 6_600_000_000, 6_600_000_000, 900_000_000])
        XCTAssertFalse(prefs.store.isPaired(guid))
        let remaining = await script.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testKnownBodyTriesOnlyOneAlternateIdentityAndPreservesComputerFailure() async throws {
        let prefs = STAProfileFixture(); prefs.store.markPaired(guid)
        prefs.store.remember(guid: guid, ip: candidate.ip, identity: .pairedComputer)
        let identities = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, _, _, _ in
            await identities.append(identity)
            throw identity == .pairedComputer ? STAConnectionError.initializationFailed(0x200F) : STAConnectionError.cameraRefused
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: guid) else { return XCTFail() }
        let attempts = await identities.values, delays = await pauses.values
        XCTAssertEqual(attempts, [.pairedComputer, .albumExplorer])
        XCTAssertEqual(delays, [900_000_000])
        let failure = await coordinator.lastFailure
        XCTAssertEqual(failure?.cause as? STAConnectionError, .initializationFailed(0x200F))
    }

    func testUnknownRefusedEndpointDoesNotProbeAlternateIdentities() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<STAInitiatorIdentity>()
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, _, _, _ in
            await attempts.append(identity); throw STAConnectionError.cameraRefused
        }, sleep: { _ in XCTFail("No readiness/alternate retry for unknown refusal") }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let identities = await attempts.values
        XCTAssertEqual(identities, [.pairedComputer])
    }

    func testWrongGUIDIsDeferredWithoutRePairingOrAlternateAttempt() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<String?>()
        let other = String(repeating: "2", count: 32), expected = guid
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, guid, _, _ in
            await attempts.append(guid); throw STAConnectionError.unexpectedResponder(expected: expected, actual: other)
        }, sleep: { _ in XCTFail("Wrong body must leave candidate selection immediately") }, onStage: { _ in })
        guard case .unexpectedCamera = try await coordinator.tryCandidate(candidate, expectedGUID: guid) else { return XCTFail() }
        let forwarded = await attempts.values
        XCTAssertEqual(forwarded, [guid])
        XCTAssertEqual(prefs.store.pairedCameraCount, 0)
    }

    func testAlbumAccessCannotActivateWithoutPairingAndClosesRejectedSocket() async throws {
        let prefs = STAProfileFixture(), closed = STARecorder<Bool>()
        let camera = fakeSTACamera(guid: guid, onClose: { Task { await closed.append(true) } })
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, _, _ in camera },
            sleep: { _ in XCTFail() }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let failure = await coordinator.lastFailure
        XCTAssertEqual(failure?.cause as? STAConnectionError, .pairingRequired)
        // Yield to the recording actor; close itself is synchronous in production.
        for _ in 0..<10 { await Task.yield() }
        let closures = await closed.values; XCTAssertEqual(closures, [true])
    }

    func testStaleAlbumRouteForDifferentBodyFallsThroughToComputerPairing() async throws {
        let prefs = STAProfileFixture(), identities = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let old = String(repeating: "2", count: 32), new = guid, store = prefs.store
        store.markPaired(old); store.remember(guid: old, ip: candidate.ip, identity: .albumExplorer)
        let camera = fakeSTACamera(guid: new)
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, _, _ in
            await identities.append(identity)
            if identity == .albumExplorer { return camera }
            throw STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: new, model: nil, storageProbeReached: true)
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let attempts = await identities.values, delays = await pauses.values
        XCTAssertEqual(attempts, [.albumExplorer, .pairedComputer])
        XCTAssertEqual(delays, [900_000_000])
        XCTAssertFalse(store.isPaired(new))
        // Android chooses routes from confirmed profiles only; the new body is not confirmed yet.
        XCTAssertEqual(store.preferredIdentity(for: candidate.ip), .albumExplorer)
    }

    func testCancellationDuringPairingDelayStopsBeforeAnotherSocket() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<Bool>()
        let guid = guid, store = prefs.store
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, _, _, _, _ in
            await attempts.append(true)
            throw STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: guid, model: nil, storageProbeReached: true)
        }, sleep: { _ in throw CancellationError() }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await attempts.values.count; XCTAssertEqual(count, 1)
        XCTAssertFalse(store.isPaired(guid)) // Acknowledgment alone is not verified pairing.
    }

    func testRetryClassificationAndBackoffMatchAndroid() {
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(PTPSessionError.timeout))
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(NWError.posix(.ECONNREFUSED)))
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(PTPIPPOSIXChannel.ChannelError.timeout))
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(PTPIPPOSIXChannel.ChannelError.system(POSIXErrorCode.ECONNREFUSED.rawValue)))
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(PTPIPPOSIXChannel.ChannelError.system(POSIXErrorCode.ETIMEDOUT.rawValue)))
        XCTAssertFalse(STAConnectionCoordinator.isTransientReadinessFailure(PTPIPPOSIXChannel.ChannelError.system(POSIXErrorCode.EHOSTUNREACH.rawValue)))
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(STAConnectionError.albumUnavailable(0x2001)))
        XCTAssertFalse(STAConnectionCoordinator.isTransientReadinessFailure(NWError.posix(.EHOSTUNREACH)))
        XCTAssertFalse(STAConnectionCoordinator.isTransientReadinessFailure(STAConnectionError.noMedia))
        XCTAssertFalse(STAConnectionCoordinator.isTransientReadinessFailure(STAConnectionError.cameraRefused))
        XCTAssertEqual((0..<6).map(STAConnectionCoordinator.reconnectDelay), [3, 8, 15, 30, 30, 30].map { UInt64($0) * 1_000_000_000 })
    }
}

actor STAAttemptScript {
    private var results: [Result<STAConnectedCamera, any Error>]
    var remaining: Int { results.count }
    init(_ results: [Result<STAConnectedCamera, any Error>]) { self.results = results }
    func next() throws -> STAConnectedCamera {
        guard !results.isEmpty else { throw STAFixtureError.unexpectedCommand(0) }
        return try results.removeFirst().get()
    }
}
func fakeSTACamera(guid: String, onClose: @escaping @Sendable () -> Void = {}) -> STAConnectedCamera {
    STAConnectedCamera(session: PTPSession(transport: STAScriptTransport([])),
        album: STAAlbumAccess(storageIDs: [0x10001], prefetchedHandles: (0x10001, [1]), directObjectRead: false, deviceInfo: nil),
        guid: guid, close: { onClose() }, startEvents: { _ in })
}
