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

    func testInlineRecoveryPersistsOnlyAfterThirdSessionValidatesAlbum() async throws {
        let prefs = STAProfileFixture(), store = prefs.store, guid = guid
        let start: [STAExchange] = [.init(0x1002, [1]), .init(0x941C),
            .init(0x1004, payload: staU32Array([0x10001]))]
        let pair = start + [.init(0x952B), .init(0x935A, [0x2001])]
        let rejected = start + [.init(0x1001, payload: staDeviceInfo(operations: [0x1001, 0x1002, 0x1003, 0x952B, 0x935A]))]
        let accepted = start + [.init(0x1001, payload: staDeviceInfo()),
            .init(0x1007, [.max, .max, 0], payload: staU32Array([7])),
            .init(0x1008, [7], payload: Data(repeating: 0, count: 53))] + staValidFrameExchanges()
        let wires = [pair, rejected + [.init(0x952B), .init(0x935A, [0x2001])], accepted].map(STAScriptTransport.init)
        let flags = STARecorder<Bool>(), pauses = STARecorder<UInt64>()
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, verify, inline, stage in
            let index = await flags.values.count
            await flags.append(verify != nil)
            XCTAssertFalse(store.isPaired(guid))
            guard index < wires.count else { throw STAFixtureError.unexpectedCommand(0) }
            let session = PTPSession(transport: wires[index])
            let browsing = STABrowsingSession(session: session, guid: guid, identity: identity,
                profiles: store, pairingConfirmation: verify, allowInlineRecovery: inline, onStage: stage)
            do {
                let album = try await browsing.open()
                return STAConnectedCamera(session: session, album: album, guid: guid, pairingConfirmed: true,
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
        XCTAssertEqual(verification, [false, true, true])
        XCTAssertEqual(delays.count, 2)
        XCTAssertTrue(delays.allSatisfy { (6_000_000_000...6_600_000_000).contains($0) })
        for wire in wires { let remaining = await wire.remaining; XCTAssertEqual(remaining, 0) }
    }

    func testPairingReconnectThenOneReadinessRetryUsesSameIdentityAndAndroidDelays() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let store = prefs.store, guid = guid
        let connector = STAAttemptScript([
            .failure(STAAttemptFailure(cause: STAPairingCompleted(confirmation: .init(responderGUID: guid)), guid: guid, model: "Z 30", storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: PTPSessionError.timeout, guid: guid, model: nil, storageProbeReached: false)),
            .success(fakeSTACamera(guid: guid)),
        ])
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, _, _, _ in
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
            .failure(STAAttemptFailure(cause: STAPairingCompleted(confirmation: .init(responderGUID: guid)), guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: STAPairingVerificationFailure(cause: STAConnectionError.pairingNotConfirmed, remoteRequestAttempted: true), guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: STAPairingCompleted(confirmation: .init(responderGUID: guid)), guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAAttemptFailure(cause: STAPairingVerificationFailure(cause: STAConnectionError.pairingNotConfirmed, remoteRequestAttempted: true), guid: guid, model: nil, storageProbeReached: true)),
            .failure(STAConnectionError.cameraRefused)
        ])
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, verify, _, _ in
            await verification.append(verify != nil)
            return try await script.next()
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
        let flags = await verification.values, delays = await pauses.values
        XCTAssertEqual(flags, [false, true, false, true])
        XCTAssertEqual(delays, [6_600_000_000, 6_600_000_000, 6_600_000_000])
        XCTAssertFalse(prefs.store.isPaired(guid))
        let remaining = await script.remaining
        XCTAssertEqual(remaining, 1, "The alternate identity must never bypass failed pairing")
    }

    func testKnownBodyTriesOnlyOneAlternateIdentityAndPreservesComputerFailure() async throws {
        let prefs = STAProfileFixture(); prefs.store.markPaired(guid)
        prefs.store.remember(guid: guid, ip: candidate.ip, identity: .pairedComputer)
        let identities = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, _, _, _, _ in
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
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, _, _, _, _ in
            await attempts.append(identity); throw STAConnectionError.cameraRefused
        }, sleep: { _ in XCTFail("No readiness/alternate retry for unknown refusal") }, onStage: { _ in })
        guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let identities = await attempts.values
        XCTAssertEqual(identities, [.pairedComputer])
    }

    func testWrongGUIDIsDeferredWithoutRePairingOrAlternateAttempt() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<String?>()
        let other = String(repeating: "2", count: 32), expected = guid
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, guid, _, _, _ in
            await attempts.append(guid); throw STAConnectionError.unexpectedResponder(expected: expected, actual: other)
        }, sleep: { _ in XCTFail("Wrong body must leave candidate selection immediately") }, onStage: { _ in })
        guard case .unexpectedCamera = try await coordinator.tryCandidate(candidate, expectedGUID: guid) else { return XCTFail() }
        let forwarded = await attempts.values
        XCTAssertEqual(forwarded, [guid])
        XCTAssertEqual(prefs.store.pairedCameraCount, 0)
    }

    func testMissingSavedBodyContinuesIntoNewBodyPairingWithoutPublishingItsSocketFailure() async throws {
        let prefs = STAProfileFixture()
        defer { withExtendedLifetime(prefs) {} }
        let store = prefs.store, old = guid, new = String(repeating: "2", count: 32)
        let saved = candidate, replacement = PTPIPCandidate(ip: "192.168.5.10", localAddress: "192.168.5.1")
        store.confirmVerifiedPairing(old)
        store.remember(guid: old, ip: saved.ip, identity: .pairedComputer)
        let expected = STARecorder<String?>(), stages = STARecorder<STAConnectionStage>()
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { candidate, identity, expectedGUID, receipt, _, stage in
            await expected.append(expectedGUID)
            if candidate == saved { throw PTPIPPOSIXChannel.ChannelError.system(EHOSTUNREACH) }
            if expectedGUID == old { throw STAConnectionError.unexpectedResponder(expected: old, actual: new) }
            XCTAssertEqual(identity, .pairedComputer)
            XCTAssertTrue(store.hasTrustedPairing(old))
            if receipt == nil {
                XCTAssertNil(expectedGUID, "The old body's GUID must not constrain a new pairing")
                await stage(.pairing)
                throw STAAttemptFailure(cause: STAPairingCompleted(confirmation: .init(responderGUID: new)),
                    guid: new, model: nil, storageProbeReached: true, pairingExchangeStarted: true)
            }
            XCTAssertEqual(expectedGUID, new)
            XCTAssertEqual(receipt?.responderGUID, new)
            store.confirmVerifiedPairing(new)
            return fakeSTACamera(guid: new)
        }, sleep: { _ in }, onStage: { await stages.append($0) })
        let selection = STACandidateSelection(coordinator: coordinator, expectedGUID: store.mostRecentGUID)
        let camera = try await selection.connect { tryCandidate in
            let missing = try await tryCandidate(saved)
            XCTAssertNil(missing)
            let deferred = try await tryCandidate(replacement)
            XCTAssertNil(deferred)
            return nil
        }
        let attempts = await expected.values, progress = await stages.values, failure = await coordinator.lastFailure
        XCTAssertEqual(camera.guid, new)
        XCTAssertEqual(attempts, [old, old, old, nil, new])
        XCTAssertEqual(progress, [.pairing])
        XCTAssertNil(failure)
        XCTAssertTrue(store.hasTrustedPairing(old))
        XCTAssertTrue(store.hasTrustedPairing(new))
        XCTAssertEqual(store.mostRecentGUID, new)
    }

    func testSavedBodyStillWinsWhenDiscoveredAfterAnotherCamera() async throws {
        let prefs = STAProfileFixture()
        defer { withExtendedLifetime(prefs) {} }
        let store = prefs.store, old = guid, new = String(repeating: "2", count: 32)
        let saved = candidate, replacement = PTPIPCandidate(ip: "192.168.5.10", localAddress: "192.168.5.1")
        store.confirmVerifiedPairing(old)
        store.remember(guid: old, ip: saved.ip, identity: .pairedComputer)
        let attempts = STARecorder<String?>()
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { candidate, _, expectedGUID, _, _, _ in
            await attempts.append(expectedGUID)
            XCTAssertEqual(expectedGUID, old)
            if candidate == replacement { throw STAConnectionError.unexpectedResponder(expected: old, actual: new) }
            return fakeSTACamera(guid: old)
        }, sleep: { _ in XCTFail("No retry required") }, onStage: { _ in })
        let selection = STACandidateSelection(coordinator: coordinator, expectedGUID: old)
        let camera = try await selection.connect { tryCandidate in
            let deferred = try await tryCandidate(replacement)
            XCTAssertNil(deferred)
            return try await tryCandidate(saved)
        }
        let actual = await attempts.values
        XCTAssertEqual(actual, [old, old])
        XCTAssertEqual(camera.guid, old)
        XCTAssertFalse(store.isPaired(new))
    }

    func testNewBodyFailureIsReportedOnlyAfterDeferredAttemptAndKeepsOldPairing() async throws {
        let prefs = STAProfileFixture()
        defer { withExtendedLifetime(prefs) {} }
        let store = prefs.store, old = guid, new = String(repeating: "2", count: 32)
        let saved = candidate, replacement = PTPIPCandidate(ip: "192.168.5.10", localAddress: "192.168.5.1")
        store.confirmVerifiedPairing(old)
        store.remember(guid: old, ip: saved.ip, identity: .pairedComputer)
        let attemptedNewPairing = STARecorder<Bool>()
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { candidate, _, expectedGUID, _, _, _ in
            if candidate == saved { throw PTPIPPOSIXChannel.ChannelError.system(EHOSTUNREACH) }
            if expectedGUID == old { throw STAConnectionError.unexpectedResponder(expected: old, actual: new) }
            await attemptedNewPairing.append(true)
            throw STAAttemptFailure(cause: STAConnectionError.cameraRefused, guid: new, model: nil, storageProbeReached: false)
        }, sleep: { _ in }, onStage: { _ in })
        let selection = STACandidateSelection(coordinator: coordinator, expectedGUID: old)
        do {
            _ = try await selection.connect { tryCandidate in
                _ = try await tryCandidate(saved)
                _ = try await tryCandidate(replacement)
                return nil
            }
            XCTFail("An actual new-camera refusal must not be swallowed")
        } catch {
            let failure = try XCTUnwrap(error as? STAConnectionFailure)
            XCTAssertEqual(failure.cause as? STAConnectionError, .cameraRefused)
            XCTAssertFalse(failure.knownCamera)
        }
        let attempts = await attemptedNewPairing.values
        XCTAssertEqual(attempts, [true])
        XCTAssertTrue(store.hasTrustedPairing(old))
        XCTAssertFalse(store.isPaired(new))
    }

    func testCancelledDiscoveryNeverStartsDeferredPairing() async throws {
        let prefs = STAProfileFixture()
        defer { withExtendedLifetime(prefs) {} }
        let store = prefs.store, old = guid, new = String(repeating: "2", count: 32), candidate = candidate
        let attempts = STARecorder<String?>()
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, _, expectedGUID, _, _, _ in
            await attempts.append(expectedGUID)
            throw STAConnectionError.unexpectedResponder(expected: old, actual: new)
        }, sleep: { _ in XCTFail() }, onStage: { _ in })
        let selection = STACandidateSelection(coordinator: coordinator, expectedGUID: old)
        do {
            _ = try await selection.connect { tryCandidate in
                _ = try await tryCandidate(candidate)
                throw CancellationError()
            }
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        let actual = await attempts.values
        XCTAssertEqual(actual, [old])
        XCTAssertFalse(store.isPaired(new))
    }

    func testAlbumAccessCannotActivateWithoutPairingAndClosesRejectedSocket() async throws {
        let prefs = STAProfileFixture(), closed = STARecorder<Bool>()
        let camera = fakeSTACamera(guid: guid, onClose: { Task { await closed.append(true) } })
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, _, _, _ in camera },
            sleep: { _ in XCTFail() }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
        // Yield to the recording actor; close itself is synchronous in production.
        for _ in 0..<10 { await Task.yield() }
        let closures = await closed.values; XCTAssertEqual(closures, [true])
    }

    func testStaleAlbumRouteForDifferentBodyFallsThroughToComputerPairing() async throws {
        let prefs = STAProfileFixture(), identities = STARecorder<STAInitiatorIdentity>(), pauses = STARecorder<UInt64>()
        let old = String(repeating: "2", count: 32), new = guid, store = prefs.store
        store.markPaired(old); store.remember(guid: old, ip: candidate.ip, identity: .albumExplorer)
        let camera = fakeSTACamera(guid: new)
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, _, _, _ in
            await identities.append(identity)
            if identity == .albumExplorer { return camera }
            if await identities.values.count == 2 {
                throw STAAttemptFailure(cause: STAPairingCompleted(confirmation: .init(responderGUID: new)), guid: new, model: nil, storageProbeReached: true)
            }
            store.confirmVerifiedPairing(new)
            return camera
        }, sleep: { await pauses.append($0) }, onStage: { _ in })
        guard case .connected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let attempts = await identities.values, delays = await pauses.values
        XCTAssertEqual(attempts, [.albumExplorer, .pairedComputer, .pairedComputer])
        XCTAssertEqual(delays, [900_000_000, 6_600_000_000])
        XCTAssertTrue(store.hasTrustedPairing(new))
        XCTAssertEqual(store.preferredIdentity(for: candidate.ip), .pairedComputer)
    }

    func testCancellationDuringPairingDelayStopsBeforeAnotherSocket() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<Bool>()
        let guid = guid, store = prefs.store
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, _, _, _, _, _ in
            await attempts.append(true)
            throw STAAttemptFailure(cause: STAPairingCompleted(confirmation: .init(responderGUID: guid)), guid: guid, model: nil, storageProbeReached: true)
        }, sleep: { _ in throw CancellationError() }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await attempts.values.count; XCTAssertEqual(count, 1)
        XCTAssertFalse(store.isPaired(guid)) // Acknowledgment alone is not verified pairing.
    }

    func testRecoveryClearsReceiptButKeepsGUIDAndWrongBodyStopsWholeDiscovery() async throws {
        let prefs = STAProfileFixture(), pinned = STARecorder<String?>(), receipts = STARecorder<Bool>()
        let guid = guid
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, expected, receipt, _, _ in
            await pinned.append(expected); await receipts.append(receipt != nil)
            switch await pinned.values.count {
            case 1: throw STAPairingCompleted(confirmation: .init(responderGUID: guid))
            case 2: throw STAPairingVerificationFailure(cause: PTPSessionError.responseCode(0x200F), remoteRequestAttempted: true)
            default: throw STAConnectionError.unexpectedResponder(expected: guid, actual: String(repeating: "2", count: 32))
            }
        }, sleep: { _ in }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
        let expected = await pinned.values, verified = await receipts.values
        XCTAssertEqual(expected, [nil, guid, guid]); XCTAssertEqual(verified, [false, true, false])
        XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
    }

    func testIncompletePairingNeverUsesSavedRouteToRetryOrSwitchIdentity() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<STAInitiatorIdentity>()
        prefs.store.remember(guid: guid, ip: candidate.ip, identity: .pairedComputer)
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, _, _, _, _ in
            await attempts.append(identity); throw STAPairingConfirmationMissing(cause: PTPSessionError.timeout)
        }, sleep: { _ in XCTFail("Incomplete pairing must stop discovery") }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(STAFailurePolicy.requiresExplicitRetry(error)) }
        let identities = await attempts.values; XCTAssertEqual(identities, [.pairedComputer])
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

    func testSlowNetworkRejoinKeepsReceiptAndRunsPairingExchangeOnlyOnce() async throws {
        let prefs = STAProfileFixture(), store = prefs.store, guid = guid
        let clock = STAAtomicBox(ContinuousClock.now)
        let attempts = STARecorder<STAPairingConfirmation?>()
        let start: [STAExchange] = [.init(0x1002, [1]), .init(0x941C),
            .init(0x1004, payload: staU32Array([0x10001]))]
        let pairing = STAScriptTransport(start + [.init(0x952B), .init(0x935A, [0x2001])])
        let verification = STAScriptTransport(start + [.init(0x1001, payload: staDeviceInfo()),
            .init(0x1007, [.max, .max, 0], payload: staU32Array([7])),
            .init(0x1008, [7], payload: Data(repeating: 0, count: 53))] + staValidFrameExchanges())
        let offline: [any Error] = [
            PTPIPPOSIXChannel.ChannelError.system(ECONNREFUSED),
            PTPIPPOSIXChannel.ChannelError.system(EHOSTUNREACH),
            NWError.posix(.ENETUNREACH), NWError.posix(.ENETDOWN),
            PTPIPPOSIXChannel.ChannelError.system(ECONNRESET),
            PTPIPPOSIXChannel.ChannelError.closed, PTPIPPOSIXChannel.ChannelError.timeout,
            STAPairingVerificationFailure(cause: PTPSessionError.timeout),
        ]
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { candidate, identity, expected, receipt, inline, stage in
            let index = await attempts.values.count
            await attempts.append(receipt)
            XCTAssertEqual(identity, .pairedComputer)
            XCTAssertEqual(candidate.ip, "192.168.5.9")
            XCTAssertEqual(expected, index == 0 ? nil : guid)
            XCTAssertEqual(receipt == nil, index == 0)
            XCTAssertFalse(store.hasTrustedPairing(guid))
            if index > 0 && index <= offline.count {
                clock.value = clock.value.advanced(by: .seconds(2))
                throw offline[index - 1]
            }
            guard index == 0 || index == offline.count + 1 else { throw STAFixtureError.unexpectedCommand(0) }
            let session = PTPSession(transport: index == 0 ? pairing : verification)
            let browsing = STABrowsingSession(session: session, guid: guid, identity: identity,
                profiles: store, pairingConfirmation: receipt, allowInlineRecovery: inline, onStage: stage)
            let album = try await browsing.open()
            return STAConnectedCamera(session: session, album: album, guid: guid, pairingConfirmed: true,
                close: {}, startEvents: { _ in })
        }, sleep: { clock.value = clock.value.advanced(by: .nanoseconds(Int64($0))) },
        now: { clock.value }, onStage: { _ in })
        guard case .connected(let camera) = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        XCTAssertEqual(camera.album.prefetchedHandles?.handles, [7])
        XCTAssertTrue(store.hasTrustedPairing(guid))
        let receipts = await attempts.values
        XCTAssertEqual(receipts.count, offline.count + 2)
        XCTAssertTrue(receipts.dropFirst().allSatisfy { $0 == receipts[1] })
        let pairingLeft = await pairing.remaining, verificationLeft = await verification.remaining
        XCTAssertEqual(pairingLeft, 0); XCTAssertEqual(verificationLeft, 0)
    }

    func testOfflineRestartDeadlineCountsSocketTimeAndDoesNotResetOnFailure() async throws {
        let prefs = STAProfileFixture(), guid = guid
        let start = ContinuousClock.now, clock = STAAtomicBox(ContinuousClock.now)
        clock.value = start
        let attempts = STARecorder<STAPairingConfirmation?>()
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, identity, expected, receipt, _, _ in
            await attempts.append(receipt)
            XCTAssertEqual(identity, .pairedComputer)
            if receipt == nil { throw STAPairingCompleted(confirmation: .init(responderGUID: guid, resultAcknowledgedAt: start)) }
            XCTAssertEqual(expected, guid)
            XCTAssertLessThan(clock.value, start.advanced(by: .seconds(60)))
            clock.value = clock.value.advanced(by: .seconds(3)) // Real TCP attempts consume the same budget.
            throw PTPIPPOSIXChannel.ChannelError.timeout
        }, sleep: { clock.value = clock.value.advanced(by: .nanoseconds(Int64($0))) },
        now: { clock.value }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(STAFailurePolicy.requiresExplicitRetry(error)) }
        let receipts = await attempts.values
        XCTAssertGreaterThan(receipts.count, 3)
        XCTAssertEqual(receipts.filter { $0 == nil }.count, 1)
        XCTAssertEqual(clock.value, start.advanced(by: .seconds(60)))
        XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
    }

    func testRestartDeadlineUsesResultAckRatherThanCleanupCompletion() async throws {
        let prefs = STAProfileFixture(), guid = guid
        let ack = ContinuousClock.now, clock = STAAtomicBox(ContinuousClock.now)
        clock.value = ack.advanced(by: .seconds(59)) // Cleanup has already consumed most of the window.
        let attempts = STARecorder<Bool>(), waits = STARecorder<UInt64>()
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, receipt, _, _ in
            await attempts.append(true)
            if receipt == nil { throw STAPairingCompleted(confirmation: .init(responderGUID: guid, resultAcknowledgedAt: ack)) }
            throw PTPIPPOSIXChannel.ChannelError.system(ECONNREFUSED)
        }, sleep: {
            await waits.append($0)
            clock.value = clock.value.advanced(by: .nanoseconds(Int64($0)))
        }, now: { clock.value }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
        let count = await attempts.values.count, delays = await waits.values
        XCTAssertEqual(count, 2)
        XCTAssertEqual(delays, [0, 1_000_000_000])
        XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
    }

    func testCancellationDuringOfflineRestartWaitStopsWithoutTrustOrAnotherSocket() async throws {
        let prefs = STAProfileFixture(), guid = guid, gate = STAReplyGate()
        let attempts = STARecorder<Bool>()
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, receipt, _, _ in
            await attempts.append(true)
            if receipt == nil { throw STAPairingCompleted(confirmation: .init(responderGUID: guid)) }
            throw PTPIPPOSIXChannel.ChannelError.closed
        }, sleep: { delay in
            if delay == 1_200_000_000 { await gate.enter() }
        }, onStage: { _ in })
        let candidate = candidate
        let task = Task { try await coordinator.tryCandidate(candidate, expectedGUID: nil) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await attempts.values.count
        XCTAssertEqual(count, 2)
        XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
    }

    func testRestartWaitNeverSwallowsProtocolRejectionOrRepeatsAmbiguousExchange() async throws {
        let guid = guid
        let failures: [any Error] = [
            STAConnectionError.cameraRefused, STAConnectionError.pairingQueryFailed(0x201F),
            STAConnectionError.unexpectedResponder(expected: guid, actual: String(repeating: "2", count: 32)),
            PTPSessionError.invalidResponse, PTPIPPOSIXChannel.ChannelError.system(EACCES),
            STAAttemptFailure(cause: PTPIPPOSIXChannel.ChannelError.closed, guid: guid, model: nil,
                              storageProbeReached: true, pairingExchangeStarted: true),
        ]
        for failure in failures {
            let prefs = STAProfileFixture(), attempts = STARecorder<Bool>(), waits = STARecorder<UInt64>()
            let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, receipt, _, _ in
                await attempts.append(true)
                if receipt == nil { throw STAPairingCompleted(confirmation: .init(responderGUID: guid)) }
                throw failure
            }, sleep: { await waits.append($0) }, onStage: { _ in })
            do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
            catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
            let count = await attempts.values.count, delays = await waits.values
            XCTAssertEqual(count, 2)
            XCTAssertEqual(delays, [6_600_000_000])
            XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
        }
    }

    func testNetworkLossBeforeResultAckKeepsOriginalReadinessLimit() async throws {
        for error in [PTPIPPOSIXChannel.ChannelError.system(ECONNREFUSED), .system(EHOSTUNREACH)] {
            let prefs = STAProfileFixture(), attempts = STARecorder<Bool>(), waits = STARecorder<UInt64>()
            let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, receipt, _, _ in
                XCTAssertNil(receipt)
                await attempts.append(true)
                throw error
            }, sleep: { await waits.append($0) }, onStage: { _ in })
            guard case .rejected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
            let count = await attempts.values.count, delays = await waits.values
            XCTAssertEqual(count, error == .system(ECONNREFUSED) ? 2 : 1)
            XCTAssertEqual(delays, error == .system(ECONNREFUSED) ? [1_200_000_000] : [])
        }
    }

    func testReadinessRetryBeforePairingDoesNotConsumeNetworkRestartWindow() async throws {
        let prefs = STAProfileFixture(), store = prefs.store, guid = guid
        let receipts = STARecorder<STAPairingConfirmation?>(), waits = STARecorder<UInt64>()
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, _, receipt, _, _ in
            await receipts.append(receipt)
            XCTAssertEqual(identity, .pairedComputer)
            switch await receipts.values.count {
            case 1: throw PTPIPPOSIXChannel.ChannelError.system(ECONNREFUSED)
            case 2: throw STAPairingCompleted(confirmation: .init(responderGUID: guid))
            case 3, 4: throw PTPIPPOSIXChannel.ChannelError.system(ECONNREFUSED)
            case 5:
                store.confirmVerifiedPairing(guid)
                return fakeSTACamera(guid: guid)
            default: throw STAFixtureError.unexpectedCommand(0)
            }
        }, sleep: { await waits.append($0) }, onStage: { _ in })
        guard case .connected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let values = await receipts.values, delays = await waits.values
        XCTAssertEqual(values.map { $0?.responderGUID }, [nil, nil, guid, guid, guid])
        XCTAssertEqual(delays, [1_200_000_000, 6_600_000_000, 1_200_000_000, 1_200_000_000])
    }

    func testSlowRejoinStillAllowsExactlyOneRealFrameFailureRecovery() async throws {
        for recoverySucceeds in [true, false] {
            let prefs = STAProfileFixture(), store = prefs.store, guid = guid
            let other = String(repeating: "2", count: 32)
            store.confirmVerifiedPairing(other)
            store.remember(guid: other, ip: "192.168.5.10", identity: .pairedComputer)
            let initiator = store.initiatorID(.pairedComputer)
            let receipts = STARecorder<Bool>(), inlineFlags = STARecorder<Bool>()
            let start: [STAExchange] = [.init(0x1002, [1]), .init(0x941C),
                .init(0x1004, payload: staU32Array([0x10001]))]
            let pair = start + [.init(0x952B), .init(0x935A, [0x2001])]
            let album = start + [.init(0x1001, payload: staDeviceInfo()),
                .init(0x1007, [.max, .max, 0], payload: staU32Array([7])),
                .init(0x1008, [7], payload: Data(repeating: 0, count: 53))]
            let failedFrame: [STAExchange] = [.init(0x1015, [0xD1A2], payload: Data([0])),
                .init(0x9201), .init(0x90C8), .init(0x9203, response: 0x200F), .init(0x9202)]
            let wires = [pair, album + failedFrame, pair,
                album + (recoverySucceeds ? staValidFrameExchanges() : failedFrame)].map(STAScriptTransport.init)
            let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, identity, expected, receipt, inline, stage in
                let index = await receipts.values.count
                await receipts.append(receipt != nil); await inlineFlags.append(inline)
                XCTAssertEqual(identity, .pairedComputer)
                XCTAssertEqual(store.initiatorID(identity), initiator)
                XCTAssertEqual(expected, index == 0 ? nil : guid)
                XCTAssertFalse(store.isPaired(guid), "Neither ACK nor a failed frame is trusted")
                XCTAssertTrue(store.hasTrustedPairing(other), "Recovery must not clear other bodies")
                switch index {
                case 1: throw PTPIPPOSIXChannel.ChannelError.system(EHOSTUNREACH)
                case 2: throw PTPIPPOSIXChannel.ChannelError.system(ECONNREFUSED)
                case 5: throw PTPIPPOSIXChannel.ChannelError.closed
                default: break
                }
                let wireIndex: Int
                switch index {
                case 0: wireIndex = 0
                case 3: wireIndex = 1
                case 4: wireIndex = 2
                case 6: wireIndex = 3
                default: throw STAFixtureError.unexpectedCommand(0)
                }
                let session = PTPSession(transport: wires[wireIndex])
                let browsing = STABrowsingSession(session: session, guid: guid, identity: identity,
                    profiles: store, pairingConfirmation: receipt, allowInlineRecovery: inline, onStage: stage)
                let result = try await browsing.open()
                return STAConnectedCamera(session: session, album: result, guid: guid, pairingConfirmed: true,
                    close: {}, startEvents: { _ in })
            }, sleep: { _ in }, onStage: { _ in })
            do {
                guard case .connected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
                XCTAssertTrue(recoverySucceeds)
            } catch {
                XCTAssertFalse(recoverySucceeds)
                XCTAssertTrue(error is STAPairingConfirmationMissing)
            }
            let forwarded = await receipts.values, flags = await inlineFlags.values
            XCTAssertEqual(forwarded, [false, true, true, true, false, true, true])
            XCTAssertEqual(flags, [false, true, true, true, false, false, false])
            XCTAssertEqual(store.hasTrustedPairing(guid), recoverySucceeds)
            XCTAssertEqual(store.pairedCameraCount, recoverySucceeds ? 2 : 1)
            var queries = 0, results = 0
            for wire in wires {
                let remaining = await wire.remaining, commands = await wire.commands
                XCTAssertEqual(remaining, 0)
                queries += commands.filter { $0.code == 0x952B }.count
                results += commands.filter { $0.code == 0x935A }.count
            }
            XCTAssertEqual(queries, 2); XCTAssertEqual(results, 2)
        }
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
        guid: guid, pairingConfirmed: true, close: { onClose() }, startEvents: { _ in })
}
