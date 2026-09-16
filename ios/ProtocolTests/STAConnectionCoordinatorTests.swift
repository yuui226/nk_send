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

    func testPairingReconnectThenOneReadinessRetryUsesSameIdentityAndAndroidDelays() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let store = prefs.store, guid = guid
        let connector = STAAttemptScript([
            .failure(STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: guid, model: "Z 30", storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: PTPSessionError.timeout, guid: guid, model: nil, storageProbeReached: false)),
            .success(fakeSTACamera(guid: guid)),
        ])
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, _ in
            await attempts.append(identity)
            store.markPaired(guid) // NK_PAIRING_RESULT OK, before reconnect.
            return try await connector.next()
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        guard case .connected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail("Not connected") }
        let identities = await attempts.values, delays = await pauses.values
        XCTAssertEqual(identities, [.pairedComputer, .pairedComputer, .pairedComputer])
        XCTAssertEqual(delays, [6_600_000_000, 1_200_000_000])
        XCTAssertEqual(store.mostRecentGUID, guid)
        XCTAssertEqual(store.lastUsedIP, candidate.ip)
        let remaining = await connector.remaining; XCTAssertEqual(remaining, 0)
    }

    func testKnownBodyTriesOnlyOneAlternateIdentityAndPreservesComputerFailure() async throws {
        let prefs = STAProfileFixture(); prefs.store.markPaired(guid)
        prefs.store.remember(guid: guid, ip: candidate.ip, identity: .pairedComputer)
        let identities = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, _, _ in
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
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, _, _ in
            await attempts.append(identity); throw STAConnectionError.cameraRefused
        }, sleep: { _ in XCTFail("No readiness/alternate retry for unknown refusal") }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let identities = await attempts.values
        XCTAssertEqual(identities, [.pairedComputer])
    }

    func testWrongGUIDIsDeferredWithoutRePairingOrAlternateAttempt() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<String?>()
        let other = String(repeating: "2", count: 32), expected = guid
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, guid, _ in
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
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, _ in camera },
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
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, _ in
            await identities.append(identity)
            if identity == .albumExplorer { return camera }
            store.markPaired(new)
            throw STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: new, model: nil, storageProbeReached: true)
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let attempts = await identities.values, delays = await pauses.values
        XCTAssertEqual(attempts, [.albumExplorer, .pairedComputer])
        XCTAssertEqual(delays, [900_000_000])
        XCTAssertEqual(store.mostRecentGUID, new)
        XCTAssertEqual(store.preferredIdentity(for: candidate.ip), .pairedComputer)
    }

    func testCancellationDuringPairingDelayStopsBeforeAnotherSocket() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<Bool>()
        let guid = guid, store = prefs.store
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, _, _, _ in
            await attempts.append(true); store.markPaired(guid)
            throw STAAttemptFailure(cause: STAConnectionError.pairingCompleted, guid: guid, model: nil, storageProbeReached: true)
        }, sleep: { _ in throw CancellationError() }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await attempts.values.count; XCTAssertEqual(count, 1)
        XCTAssertTrue(store.isPaired(guid)) // Cancel does not erase completed camera pairing.
    }

    func testRetryClassificationAndBackoffMatchAndroid() {
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(PTPSessionError.timeout))
        XCTAssertTrue(STAConnectionCoordinator.isTransientReadinessFailure(NWError.posix(.ECONNREFUSED)))
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
