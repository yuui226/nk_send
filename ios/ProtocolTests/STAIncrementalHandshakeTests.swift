import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

/// Android ca03503c: Result ACK, bounded repairs, actual-frame cleanup proof,
/// and absolute response budgets. Scripted sessions never mutate real profiles.
@MainActor
final class STAIncrementalHandshakeTests: XCTestCase {
    private let guid = String(repeating: "1", count: 32)
    private let candidate = PTPIPCandidate(ip: "192.168.5.9", localAddress: "192.168.5.1")

    func testDeadlineIsSharedByFragmentsAndRetainsHandleIdleLimit() throws {
        let start = ContinuousClock.now, clock = STAAtomicBox(ContinuousClock.now)
        clock.value = start
        let short = STAHandshakeDeadline(nanoseconds: 5_000_000_000, now: { clock.value })
        let handles = STAHandshakeDeadline(nanoseconds: 30_000_000_000, now: { clock.value })
        for elapsed in [0, 1, 2, 3, 4] {
            clock.value = start.advanced(by: .seconds(elapsed))
            XCTAssertEqual(try short.remainingNanoseconds(), UInt64(5 - elapsed) * 1_000_000_000)
            XCTAssertEqual(try handles.remainingNanoseconds(), 5_000_000_000)
        }
        clock.value = start.advanced(by: .seconds(5))
        XCTAssertThrowsError(try short.remainingNanoseconds())
        clock.value = start.advanced(by: .milliseconds(29_999))
        XCTAssertEqual(try handles.remainingNanoseconds(), 1_000_000)
        clock.value = start.advanced(by: .seconds(30))
        XCTAssertThrowsError(try handles.remainingNanoseconds())
    }

    func testCancelledQueuedShutterIsNeverSentAndSessionRemainsUsable() async throws {
        let permission = PTPCommandPermission(), gate = STAReplyGate()
        let wire = STAScriptTransport([.init(0x1001), .init(0x1004)])
        await wire.beforeNextReply(0x1001) { await gate.enter() }
        let session = PTPSession(transport: wire)
        let blocker = Task { try await session.executeResponse(operation: 0x1001) }
        await gate.waitUntilEntered()
        let shutter = Task { try await session.executeResponseIfCurrent(operation: PTPConstants.captureInMedia,
            parameters: [.max, 0], permission: permission) }
        for _ in 0..<20 { await Task.yield() }
        permission.invalidate(); await gate.release()
        _ = try await blocker.value
        let suppressed = try await shutter.value
        XCTAssertNil(suppressed)
        _ = try await session.executeResponse(operation: 0x1004)
        let codes = await wire.commands.map(\.code)
        XCTAssertEqual(codes, [0x1001, 0x1004])
    }

    func testCancellationAfterShutterDispatchDrainsWithoutCancellingTheSession() async throws {
        let permission = PTPCommandPermission(), gate = STAReplyGate()
        let wire = STAScriptTransport([.init(PTPConstants.captureInMedia, [.max, 0]), .init(0x1004)])
        await wire.beforeNextReply(PTPConstants.captureInMedia) { await gate.enter() }
        let session = PTPSession(transport: wire)
        let shutter = Task { try await session.executeResponseIfCurrent(operation: PTPConstants.captureInMedia,
            parameters: [.max, 0], permission: permission) }
        await gate.waitUntilEntered(); permission.invalidate(); await gate.release()
        let response = try await shutter.value
        XCTAssertEqual(response?.code, PTPConstants.responseOK)
        _ = try await session.executeResponse(operation: 0x1004)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testTransportPreflightSuppressionDoesNotInvalidateOrAbortAnUnsentCommand() async throws {
        let permission = PTPCommandPermission()
        let wire = STAScriptTransport([.init(PTPConstants.captureInMedia, [.max, 0]), .init(0x1004)])
        await wire.beforeNextReply(PTPConstants.captureInMedia) { throw PTPCommandNotSent() }
        let session = PTPSession(transport: wire)
        let response = try await session.executeResponseIfCurrent(operation: PTPConstants.captureInMedia,
            parameters: [.max, 0], permission: permission)
        XCTAssertNil(response)
        _ = try await session.executeResponse(operation: 0x1004)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testRestartDelayIncludesCleanupAndClampsClockBoundary() {
        let start = ContinuousClock.now
        let receipt = STAPairingConfirmation(responderGUID: guid, resultAcknowledgedAt: start)
        XCTAssertEqual(receipt.remainingRestartDelay(now: start), 6_600_000_000)
        XCTAssertEqual(receipt.remainingRestartDelay(now: start.advanced(by: .milliseconds(250))), 6_350_000_000)
        XCTAssertEqual(receipt.remainingRestartDelay(now: start.advanced(by: .seconds(20))), 0)
        XCTAssertEqual(receipt.remainingRestartDelay(now: start.advanced(by: .seconds(-1))), 6_600_000_000)
        XCTAssertEqual(STAPairingConfirmation(responderGUID: guid).remainingRestartDelay(now: start), 6_600_000_000)
    }

    func testRejectedQueryOrResultAbortsWithoutFurtherCommands() async throws {
        for queryFails in [true, false] {
            let prefs = STAProfileFixture(), aborted = STAAtomicBox(false)
            let steps: [STAExchange] = [.init(0x1002, [1]), .init(0x941C),
                .init(0x1004, payload: staU32Array([0x10001])), .init(0x952B, response: queryFails ? 0x200F : 0x2001)]
                + (queryFails ? [] : [.init(0x935A, [0x2001], response: 0x200F)])
            let wire = STAScriptTransport(steps)
            let browsing = STABrowsingSession(session: PTPSession(transport: wire), guid: guid,
                identity: .pairedComputer, profiles: prefs.store, abortTransport: { aborted.value = true }, onStage: { _ in })
            do { _ = try await browsing.open(); XCTFail() }
            catch { XCTAssertEqual(error as? STAConnectionError, queryFails ? .pairingQueryFailed(0x200F) : .pairingResultFailed(0x200F)) }
            XCTAssertTrue(aborted.value)
            XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
            let left = await wire.remaining
            XCTAssertEqual(left, 0)
        }
    }

    func testVerificationReadFailureRetainsReceiptAndNeverRepeatsPairing() async throws {
        let prefs = STAProfileFixture(), receipts = STARecorder<STAPairingConfirmation?>(), waits = STARecorder<UInt64>()
        let guid = guid, store = prefs.store
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, _, _, receipt, _, _ in
            await receipts.append(receipt)
            switch await receipts.values.count {
            case 1: throw STAPairingCompleted(confirmation: .init(responderGUID: guid))
            case 2: throw STAPairingVerificationFailure(cause: PTPSessionError.responseCode(0x2019))
            default:
                store.confirmVerifiedPairing(guid)
                return fakeSTACamera(guid: guid)
            }
        }, sleep: { await waits.append($0) }, onStage: { _ in })
        guard case .connected = try await coordinator.tryCandidate(candidate, expectedGUID: nil) else { return XCTFail() }
        let forwarded = await receipts.values, delays = await waits.values
        XCTAssertEqual(forwarded.map { $0?.responderGUID }, [nil, guid, guid])
        XCTAssertEqual(delays, [6_600_000_000, 1_200_000_000])
    }

    func testInlineRepairAndFrameFailureShareOneRepairBudget() async throws {
        let prefs = STAProfileFixture(), flags = STARecorder<Bool>(), waits = STARecorder<UInt64>(), guid = guid
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, _, inline, _ in
            await flags.append(inline)
            switch await flags.values.count {
            case 1: throw STAPairingCompleted(confirmation: .init(responderGUID: guid))
            case 2: throw STAPairingCompleted(confirmation: .init(responderGUID: guid), isRecovery: true)
            default: throw STAPairingVerificationFailure(cause: PTPSessionError.responseCode(0x200F), remoteRequestAttempted: true)
            }
        }, sleep: { await waits.append($0) }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
        let recorded = await flags.values, delays = await waits.values
        XCTAssertEqual(recorded, [false, true, false])
        XCTAssertEqual(delays, [6_600_000_000, 6_600_000_000])
        XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
    }

    func testCleanupRecoveryRequiresSameBodyAndRunsAtMostOnce() async throws {
        for wrongBody in [true, false] {
            let prefs = STAProfileFixture(), forwarded = STARecorder<STAPairingConfirmation?>(), waits = STARecorder<UInt64>()
            let guid = guid
            let proof = STAPairingConfirmation(responderGUID: wrongBody ? String(repeating: "2", count: 32) : guid,
                                               remotePermissionVerified: true)
            let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, receipt, inline, _ in
                await forwarded.append(receipt)
                if await forwarded.values.count == 1 { throw STAPairingCompleted(confirmation: .init(responderGUID: guid)) }
                if receipt?.remotePermissionVerified == true { XCTAssertFalse(inline) }
                throw STAPairingCleanupFailure(confirmation: proof, cause: PTPSessionError.timeout)
            }, sleep: { await waits.append($0) }, onStage: { _ in })
            do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
            catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
            let receipts = await forwarded.values, delays = await waits.values
            XCTAssertEqual(receipts.count, wrongBody ? 2 : 3)
            XCTAssertEqual(delays, wrongBody ? [6_600_000_000] : [6_600_000_000, 1_200_000_000])
            XCTAssertFalse(prefs.store.hasTrustedPairing(guid))
        }
    }

    func testFailedPairingExchangeNeverUsesReadinessRetry() async throws {
        let prefs = STAProfileFixture(), attempts = STARecorder<Bool>(), guid = guid
        let coordinator = STAConnectionCoordinator(profiles: prefs.store, connect: { _, _, _, _, _, _ in
            await attempts.append(true)
            throw STAAttemptFailure(cause: PTPSessionError.timeout, guid: guid, model: nil,
                                   storageProbeReached: true, pairingExchangeStarted: true)
        }, sleep: { _ in XCTFail("No retry after ambiguous Query/Result") }, onStage: { _ in })
        do { _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil); XCTFail() }
        catch { XCTAssertTrue(error is STAPairingConfirmationMissing) }
        let count = await attempts.values.count
        XCTAssertEqual(count, 1)
    }

    func testPairingStageDoesNotRegressAcrossReconnect() async throws {
        let prefs = STAProfileFixture(), stages = STARecorder<STAConnectionStage>(), attempts = STARecorder<Bool>()
        let store = prefs.store, guid = guid
        let coordinator = STAConnectionCoordinator(profiles: store, connect: { _, _, _, _, _, stage in
            await attempts.append(true)
            if await attempts.values.count == 1 {
                await stage(.pairing)
                await stage(.connecting)
                throw STAPairingCompleted(confirmation: .init(responderGUID: guid))
            }
            await stage(.connecting); await stage(.discovering("192.168.5.9"))
            store.confirmVerifiedPairing(guid)
            return fakeSTACamera(guid: guid)
        }, sleep: { _ in }, onStage: { await stages.append($0) })
        _ = try await coordinator.tryCandidate(candidate, expectedGUID: nil)
        let published = await stages.values
        XCTAssertEqual(published, [.pairing])
    }

    func testVerifiedCleanupRunsBeforeStorageAndNeverRequestsAnotherFrame() async throws {
        for alreadyStopped in [false, true] {
            let prefs = STAProfileFixture()
            let cleanup: [STAExchange] = [.init(0x1015, [0xD1A2], payload: Data([alreadyStopped ? 0 : 1]))]
                + (alreadyStopped ? [] : [.init(0x9202), .init(0x1015, [0xD1A2], payload: Data([0]))])
            let wire = STAScriptTransport([.init(0x1002, [1]), .init(0x941C)] + cleanup + [
                .init(0x1004, payload: staU32Array([0x10001])), .init(0x1001, payload: staDeviceInfo()),
                .init(0x1007, [.max, .max, 0], payload: staU32Array([7])), .init(0x1008, [7], payload: Data(repeating: 0, count: 53))])
            let browsing = STABrowsingSession(session: PTPSession(transport: wire), guid: guid, identity: .pairedComputer,
                profiles: prefs.store, pairingConfirmation: .init(responderGUID: guid, remotePermissionVerified: true),
                allowInlineRecovery: true, onStage: { _ in })
            _ = try await browsing.open()
            XCTAssertTrue(prefs.store.hasTrustedPairing(guid))
            let remaining = await wire.remaining, commands = await wire.commands
            XCTAssertEqual(remaining, 0)
            XCTAssertFalse(commands.contains { [0x9201, 0x9203, 0x952B, 0x935A].contains($0.code) })
        }
    }

    func testValidFrameCleanupFailureCarriesProofWithoutTrust() async throws {
        var steps = staValidFrameExchanges(); steps[steps.count - 1] = .init(0x9202, response: 0x200F)
        let wire = STAScriptTransport(steps), aborted = STAAtomicBox(false)
        do {
            try await STAPairingLiveView.verify(session: PTPSession(transport: wire), operations: [], trace: .init(),
                confirmation: .init(responderGUID: guid), abort: { aborted.value = true })
            XCTFail()
        } catch let failure as STAPairingCleanupFailure {
            XCTAssertEqual(failure.confirmation.responderGUID, guid)
            XCTAssertTrue(failure.confirmation.remotePermissionVerified)
        }
        XCTAssertTrue(aborted.value)
    }

    func testCleanupAckStillRequiresStoppedStatusAndNeverRepeatsEnd() async throws {
        let time = STAAtomicBox(ContinuousClock.now), aborted = STAAtomicBox(false)
        let wire = STAScriptTransport([.init(0x1015, [0xD1A2], payload: Data([1])), .init(0x9202),
                                      .init(0x1015, [0xD1A2], payload: Data([1]))])
        do {
            try await STAPairingLiveView.finishCleanup(session: PTPSession(transport: wire),
                confirmation: .init(responderGUID: guid, remotePermissionVerified: true), responderGUID: guid,
                trace: .init(), abort: { aborted.value = true }, now: { time.value },
                sleep: { _ in time.value = time.value.advanced(by: .seconds(5)) })
            XCTFail()
        } catch { XCTAssertTrue(error is STAPairingCleanupFailure) }
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x1015, 0x9202, 0x1015])
        XCTAssertTrue(aborted.value)
    }
}
