import XCTest
@testable import ZTransfer

private actor KeepaliveReplay {
    var results: [Bool]
    var delays: [UInt64] = []
    var probes = 0
    var losses = 0
    let cancelAtSleep: Int?
    init(_ results: [Bool], cancelAtSleep: Int? = nil) {
        self.results = results; self.cancelAtSleep = cancelAtSleep
    }
    func probe() -> Bool {
        probes += 1
        return results.isEmpty ? false : results.removeFirst()
    }
    func sleep(_ nanos: UInt64) throws {
        delays.append(nanos)
        if delays.count == cancelAtSleep { throw CancellationError() }
    }
    func lost() { losses += 1 }
}

private actor KeepaliveWire: PTPCommandTransport {
    let recovers: Bool
    private(set) var commands = 0
    init(recovers: Bool) { self.recovers = recovers }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        commands += 1
        if commands == 1 { throw PTPSessionError.timeout }
        let request = try PTPCodec.decode(command)
        return (PTPCodec.encode(type: .response, code: PTPConstants.responseOK,
                               transactionID: request.transactionID), Data())
    }
    func cancelPTP(transactionID: UInt32) async -> Bool { recovers }
}

final class WiFiKeepaliveTests: XCTestCase {
    func testFirstFailureSurvivesAndSuccessResetsConsecutiveFailures() async {
        let replay = KeepaliveReplay([false, true, false, false])
        await WiFiKeepaliveLoop.run(probe: { await replay.probe() },
                                   sleep: { try await replay.sleep($0) }, onLost: { await replay.lost() })
        let delays = await replay.delays, probes = await replay.probes, losses = await replay.losses
        XCTAssertEqual(delays, [10, 1, 10, 10, 1, 10].map { UInt64($0) * 1_000_000_000 })
        XCTAssertEqual(probes, 4)
        XCTAssertEqual(losses, 1)
    }

    func testCancellationDuringRetryDelayDoesNotReportLoss() async {
        let replay = KeepaliveReplay([false, false], cancelAtSleep: 2)
        await WiFiKeepaliveLoop.run(probe: { await replay.probe() },
                                   sleep: { try await replay.sleep($0) }, onLost: { await replay.lost() })
        let probes = await replay.probes, losses = await replay.losses
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(losses, 0)
    }

    func testCancelledProbeCannotPublishLateFailure() async {
        let entered = GateTestLatch(), release = GateTestLatch()
        let replay = KeepaliveReplay([])
        let task = Task {
            await WiFiKeepaliveLoop.run(probe: {
                await entered.signal(); await release.wait(); return false
            }, sleep: { try await replay.sleep($0) }, onLost: { await replay.lost() })
        }
        await entered.wait()
        task.cancel()
        await release.signal()
        await task.value
        let losses = await replay.losses, delays = await replay.delays
        XCTAssertEqual(losses, 0)
        XCTAssertEqual(delays, [10_000_000_000])
    }

    func testRetiredSessionCountsSecondFailureWithoutAnotherCommand() async {
        let wire = KeepaliveWire(recovers: false)
        let session = PTPSession(transport: wire)
        let repository = CameraRepository(session: session)
        let replay = KeepaliveReplay([])
        await WiFiKeepaliveLoop.run(probe: { await repository.keepalive() },
                                   sleep: { try await replay.sleep($0) }, onLost: { await replay.lost() })
        let commands = await wire.commands, invalidated = await session.isInvalidated
        let losses = await replay.losses, delays = await replay.delays
        XCTAssertEqual(commands, 1)
        XCTAssertTrue(invalidated)
        XCTAssertEqual(losses, 1)
        XCTAssertEqual(delays, [10_000_000_000, 1_000_000_000, 10_000_000_000])
    }

    func testRecoveredProtocolAbortCanProbeAgainOnSameSession() async {
        let wire = KeepaliveWire(recovers: true)
        let session = PTPSession(transport: wire)
        let repository = CameraRepository(session: session)
        let first = await repository.keepalive()
        let invalidated = await session.isInvalidated
        let second = await repository.keepalive()
        let commands = await wire.commands
        XCTAssertFalse(first)
        XCTAssertFalse(invalidated)
        XCTAssertTrue(second)
        XCTAssertEqual(commands, 2)
    }
}
