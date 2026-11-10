import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

@MainActor
final class STAPairingConfirmationTests: XCTestCase {
    let guid = String(repeating: "1", count: 32)
    let initial: [STAExchange] = [.init(0x1002, [1]), .init(0x941C), .init(0x1004, payload: staU32Array([0x10001]))]
    var album: [STAExchange] { initial + [.init(0x1001, payload: staDeviceInfo()),
        .init(0x1007, [.max, .max, 0], payload: staU32Array([11, 12, 13])), .init(0x1008, [11], payload: Data(repeating: 0, count: 53)),
        .init(0x1008, [12], payload: Data(repeating: 0, count: 53)), .init(0x1008, [13], payload: Data(repeating: 0, count: 53))] }

    func testResultAckCreatesPendingReceiptWithoutEventOrTrust() async throws {
        let prefs = STAProfileFixture(), wire = STAScriptTransport(initial + [.init(0x952B), .init(0x935A, [0x2001])])
        let browsing = STABrowsingSession(session: PTPSession(transport: wire), guid: guid, identity: .pairedComputer,
            profiles: prefs.store, onStage: { _ in })
        let started = ContinuousClock.now
        do { _ = try await browsing.open(); XCTFail() }
        catch let result as STAPairingCompleted {
            XCTAssertEqual(result.confirmation.responderGUID, guid)
            XCTAssertFalse(result.confirmation.remotePermissionVerified)
            XCTAssertFalse(result.isRecovery)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.confirmation.resultAcknowledgedAt), started)
        }
        XCTAssertFalse(prefs.store.isPaired(guid))
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x1002, 0x941C, 0x1004, 0x952B, 0x935A])
    }
    func testFreshReceiptWaitsForValidFrameBeforeWritingPairing() async throws {
        let prefs = STAProfileFixture(), wire = STAScriptTransport(album + staValidFrameExchanges())
        let gate = STAReplyGate(), store = prefs.store
        await wire.beforeNextReply(0x9203) { await gate.enter() }
        let browsing = make(wire, store: store, receipt: .init(responderGUID: guid))
        let task = Task { try await browsing.open() }
        await gate.waitUntilEntered(); XCTAssertFalse(store.isPaired(guid))
        await gate.release(); _ = try await task.value
        XCTAssertTrue(store.hasTrustedPairing(guid))
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testResetAndCancelDuringFrameCannotResurrectClearedPairing() async throws {
        let prefs = STAProfileFixture(), wire = STAScriptTransport(album + staValidFrameExchanges())
        let gate = STAReplyGate(), store = prefs.store
        await wire.beforeNextReply(0x9203) { await gate.enter() }
        let browsing = make(wire, store: store, receipt: .init(responderGUID: guid))
        let task = Task { try await browsing.open() }
        await gate.waitUntilEntered(); task.cancel()
        STAProfileStore(preferences: prefs.connection, pairing: prefs.pairing).resetPairing()
        await gate.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(store.isPaired(guid)); XCTAssertNil(store.lastUsedIP)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0, "Owned monitor still ends")
    }
    func testSavedTrustedPairingNeverProbesLiveView() async throws {
        let prefs = STAProfileFixture(); prefs.store.confirmVerifiedPairing(guid)
        let wire = STAScriptTransport(album)
        _ = try await make(wire, store: prefs.store).open()
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testWrongReceiptBodyAndWrongIdentityRejectedBeforeAnyCommand() async throws {
        let prefs = STAProfileFixture()
        for identity in [STAInitiatorIdentity.pairedComputer, .albumExplorer] {
            let wire = STAScriptTransport([])
            let receipt = STAPairingConfirmation(responderGUID: identity == .pairedComputer ? String(repeating: "2", count: 32) : guid)
            let browsing = STABrowsingSession(session: PTPSession(transport: wire), guid: guid, identity: identity, profiles: prefs.store,
                pairingConfirmation: receipt, onStage: { _ in })
            do { _ = try await browsing.open(); XCTFail() } catch { XCTAssertTrue(error is STAConnectionError) }
            let commands = await wire.commands; XCTAssertTrue(commands.isEmpty)
        }
    }
    func testProbeStopsAfterFirstDeniedInfoAndNeverReadsThumbnail() async throws {
        let prefs = STAProfileFixture(); prefs.store.confirmVerifiedPairing(guid)
        let wire = STAScriptTransport(Array(album.prefix(5)) + [.init(0x1008, [11], response: 0x200F),
            .init(0x9421, [11], payload: staInteger(UInt64(100))), .init(0x9431, [11, 0, 0, 65_536, 0], payload: Data([1]))])
        let result = try await make(wire, store: prefs.store).open()
        XCTAssertTrue(result.directObjectRead)
        let commands = await wire.commands
        XCTAssertEqual(commands.filter { $0.code == 0x1008 }.count, 1)
        XCTAssertFalse(commands.contains { $0.code == 0x100A })
    }
    func testInvalidSizeNeverStartsPartialObjectRead() async throws {
        for size in [Data(), staInteger(UInt32(10)), staInteger(UInt64(0)), staInteger(UInt64.max)] {
            let prefs = STAProfileFixture(); prefs.store.confirmVerifiedPairing(guid)
            let wire = STAScriptTransport(Array(album.prefix(5)) + [.init(0x1008, [11], response: 0x200F),
                .init(0x9421, [11], payload: size), .init(0x9435, [1], response: 0x2005)])
            do { _ = try await make(wire, store: prefs.store).open(); XCTFail() }
            catch { XCTAssertEqual(error as? STAConnectionError, .albumUnavailable(0x2001)) }
            let commands = await wire.commands
            XCTAssertFalse(commands.contains { $0.code == 0x9431 || $0.code == 0x100A })
        }
    }
    func testCancelledFinalWritesCannotRestoreProofRouteOrInvalidateNewProof() async throws {
        let prefs = STAProfileFixture(), store = prefs.store, guid = guid
        store.confirmVerifiedPairing(guid)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            for write in [ { try store.confirmVerifiedPairingUnlessCancelled(guid) },
                           { try store.invalidatePairingUnlessCancelled(guid) },
                           { try store.rememberUnlessCancelled(guid: guid, ip: "10.0.0.2", identity: .pairedComputer) }] {
                XCTAssertThrowsError(try write()) { XCTAssertTrue($0 is CancellationError) }
            }
        }
        try await task.value
        XCTAssertTrue(store.hasTrustedPairing(guid)); XCTAssertNil(store.lastUsedIP)
    }
    private func make(_ wire: STAScriptTransport, store: STAProfileStore, receipt: STAPairingConfirmation? = nil) -> STABrowsingSession {
        STABrowsingSession(session: PTPSession(transport: wire), guid: guid, identity: .pairedComputer, profiles: store,
            pairingConfirmation: receipt, onStage: { _ in })
    }
}
