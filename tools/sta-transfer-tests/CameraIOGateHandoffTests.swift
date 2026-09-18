import XCTest

private actor HandoffBarrier {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor HandoffOrder {
    private var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
    func snapshot() -> [String] { entries }
}

/// Runs against production CameraIOGate with a host-only scheduling barrier.
/// The barrier adds no admission decision; the real post-grant check must win.
final class CameraIOGateHandoffTests: XCTestCase {
    func testReservationRegisteredAfterTransferGrantRunsBeforeTransfer() async throws {
        let gate = CameraIOGate()
        let granted = HandoffBarrier()
        let resumeGrant = HandoffBarrier()
        let registered = HandoffBarrier()
        let order = HandoffOrder()
        await gate.setTransferHandoffProbe {
            await granted.signal()
            await resumeGrant.wait()
        }
        let transfer = Task {
            try await gate.withTransferSlice { await order.append("transfer") }
        }
        await granted.wait()
        let interactive = Task {
            try await gate.withInteractivePriority {
                await registered.signal()
                try await gate.withCommand { await order.append("preview") }
            }
        }
        await registered.wait()
        await resumeGrant.signal()
        try await transfer.value
        try await interactive.value
        let actual = await order.snapshot()
        XCTAssertEqual(actual, ["preview", "transfer"])
    }

    func testAbandonedTransferGrantDoesNotLeakTheCommandLock() async throws {
        let gate = CameraIOGate()
        let granted = HandoffBarrier()
        let resumeGrant = HandoffBarrier()
        await gate.setTransferHandoffProbe {
            await granted.signal()
            await resumeGrant.wait()
        }
        let transfer = Task { try await gate.withTransferSlice { true } }
        await granted.wait()
        transfer.cancel()
        await resumeGrant.signal()
        do {
            _ = try await transfer.value
            XCTFail("An abandoned transfer must not start a command")
        } catch { XCTAssertTrue(error is CancellationError) }
        let next = try await gate.withCommand { "next" }
        XCTAssertEqual(next, "next")
    }
}
