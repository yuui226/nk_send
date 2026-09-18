import XCTest
@testable import ZTransfer

private actor GateTestLatch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !signalled else { return }
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if signalled { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func isSignalled() -> Bool { signalled }
}

private actor GateTestOrder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor FrameworkManagedPTPReplay: PTPCommandTransport {
    nonisolated var managesCommandTimeouts: Bool { true }
    private let started: GateTestLatch
    private let release = GateTestLatch()
    private(set) var cancellationRequested = false

    init(started: GateTestLatch) { self.started = started }

    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        await started.signal()
        await release.wait()
        let request = try PTPCodec.decode(command)
        return (PTPCodec.encode(type: .response, code: PTPConstants.responseOK,
                                transactionID: request.transactionID), Data())
    }

    func finish() async { await release.signal() }

    func cancelPTP(transactionID: UInt32) async -> Bool {
        cancellationRequested = true
        await release.signal()
        return false
    }
}

final class CameraIOGateTests: XCTestCase {
    func testCancellingFrameworkManagedCommandDrainsWithoutDisconnecting() async throws {
        let started = GateTestLatch()
        let transport = FrameworkManagedPTPReplay(started: started)
        let session = PTPSession(transport: transport)
        let command = Task { try await session.executeResponse(operation: PTPConstants.getDeviceInfo) }
        await started.wait()
        command.cancel()
        await transport.finish()
        let response = try await command.value
        let cancellationRequested = await transport.cancellationRequested
        let invalidated = await session.isInvalidated
        XCTAssertEqual(response.code, PTPConstants.responseOK)
        XCTAssertFalse(cancellationRequested)
        XCTAssertFalse(invalidated)
    }

    func testEffectPreviewWaitsForEveryForegroundOwnerAndReleasesFillGate() async throws {
        let repository = CameraRepository(debugData: .shared)
        let entered = GateTestLatch()
        let release = GateTestLatch()
        await repository.setTransfersBusy(true)
        await repository.setRemoteActive(true)
        await repository.setFHDActive(true)

        let preview = Task {
            try await repository.withEffectPreviewPriority {
                await entered.signal()
                await release.wait()
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        var didEnter = await entered.isSignalled()
        XCTAssertFalse(didEnter)

        await repository.setTransfersBusy(false)
        try await Task.sleep(for: .milliseconds(30))
        didEnter = await entered.isSignalled()
        XCTAssertFalse(didEnter)
        await repository.setRemoteActive(false)
        try await Task.sleep(for: .milliseconds(30))
        didEnter = await entered.isSignalled()
        XCTAssertFalse(didEnter)
        await repository.setFHDActive(false)
        await entered.wait()
        var fillAllowed = await repository.backgroundThumbnailFillAllowed()
        XCTAssertFalse(fillAllowed)

        await release.signal()
        try await preview.value
        fillAllowed = await repository.backgroundThumbnailFillAllowed()
        XCTAssertTrue(fillAllowed)
    }

    func testReservationDoesNotBlockOrdinaryOrIdleCommandsBetweenFHDAndExif() async throws {
        let gate = CameraIOGate()
        let values = try await AsyncDeadline.run(nanoseconds: 1_000_000_000, timeoutError: PTPSessionError.timeout) {
            try await gate.withInteractivePriority {
                let ordinary = try await gate.withCommand { "thumbnail" }
                let idle = try await gate.withIdleCommand(skippedValue: "skipped") { "idle" }
                return [ordinary, idle]
            }
        }
        XCTAssertEqual(values, ["thumbnail", "idle"])
    }

    func testAlreadyCancelledCallerDoesNotRunOnAnUnlockedGate() async throws {
        let gate = CameraIOGate()
        let ready = GateTestLatch()
        let task = Task {
            await ready.wait()
            return try await gate.withCommand { true }
        }
        task.cancel()
        await ready.signal()
        do { _ = try await task.value; XCTFail("Cancelled command executed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await gate.withCommand { true }
        XCTAssertTrue(next)
    }

    func testInteractiveWaiterRunsBeforeNextTransferSlice() async throws {
        let gate = CameraIOGate()
        let order = GateTestOrder()
        let firstEntered = GateTestLatch()
        let releaseFirst = GateTestLatch()
        let interactiveRegistered = GateTestLatch()

        let first = Task {
            try await gate.withTransferSlice {
                await order.append("transfer-1")
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        let interactive = Task {
            try await gate.withInteractivePriority {
                await interactiveRegistered.signal()
                try await gate.withInteractive { await order.append("interactive") }
            }
        }
        await interactiveRegistered.wait()
        let second = Task {
            try await gate.withTransferSlice { await order.append("transfer-2") }
        }

        await releaseFirst.signal()
        _ = await (try? first.value)
        _ = await (try? interactive.value)
        _ = await (try? second.value)
        let values = await order.snapshot()
        XCTAssertEqual(values, ["transfer-1", "interactive", "transfer-2"])
    }

    func testPriorityReservationKeepsTransferOutBetweenInteractiveCommands() async throws {
        let gate = CameraIOGate()
        let order = GateTestOrder()
        let startTransfer = GateTestLatch()
        let transferStarted = GateTestLatch()

        let foreground = Task {
            try await gate.withInteractivePriority {
                try await gate.withInteractive { await order.append("fhd") }
                await startTransfer.signal()
                await transferStarted.wait()
                try await gate.withInteractive { await order.append("exif") }
            }
        }
        await startTransfer.wait()
        let transfer = Task {
            await transferStarted.signal()
            try await gate.withTransferSlice { await order.append("transfer") }
        }
        _ = await (try? foreground.value)
        _ = await (try? transfer.value)
        let values = await order.snapshot()
        XCTAssertEqual(values, ["fhd", "exif", "transfer"])
    }

    func testCancelledPriorityReservationDoesNotBlockTransfers() async throws {
        let gate = CameraIOGate()
        let registered = GateTestLatch()
        let reservation = Task {
            try await gate.withInteractivePriority {
                await registered.signal()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        await registered.wait()
        reservation.cancel()
        _ = await (try? reservation.value)
        try await gate.withTransferSlice { }
    }

    func testIdleCommandIsSkippedForWholeDownloadActivity() async throws {
        let gate = CameraIOGate()
        let betweenSlices = GateTestLatch()
        let finishDownload = GateTestLatch()
        let download = Task {
            try await gate.withDownloadActivity {
                try await gate.withTransferSlice { }
                await betweenSlices.signal()
                await finishDownload.wait()
                try await gate.withTransferSlice { }
            }
        }
        await betweenSlices.wait()

        let result = try await gate.withIdleCommand(skippedValue: "skipped") { "ran" }
        XCTAssertEqual(result, "skipped")
        await finishDownload.signal()
        _ = await (try? download.value)
        let after = try await gate.withIdleCommand(skippedValue: "skipped") { "ran" }
        XCTAssertEqual(after, "ran")
    }

    func testIdleCommandRechecksActivityAfterWaitingForSlice() async throws {
        let gate = CameraIOGate()
        let sliceEntered = GateTestLatch()
        let releaseSlice = GateTestLatch()
        let downloadRegistered = GateTestLatch()
        let finishDownload = GateTestLatch()

        let holder = Task {
            try await gate.withTransferSlice {
                await sliceEntered.signal()
                await releaseSlice.wait()
            }
        }
        await sliceEntered.wait()
        let idle = Task {
            try await gate.withIdleCommand(skippedValue: "skipped") { "ran" }
        }
        await Task.yield()
        let download = Task {
            try await gate.withDownloadActivity {
                await downloadRegistered.signal()
                await finishDownload.wait()
            }
        }
        await downloadRegistered.wait()
        await releaseSlice.signal()
        let idleResult = try await idle.value
        XCTAssertEqual(idleResult, "skipped")
        await finishDownload.signal()
        _ = await (try? holder.value)
        _ = await (try? download.value)
    }

    func testCancelledDownloadRestoresIdleCommands() async throws {
        let gate = CameraIOGate()
        let registered = GateTestLatch()
        let download = Task {
            try await gate.withDownloadActivity {
                await registered.signal()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        await registered.wait()
        download.cancel()
        _ = await (try? download.value)
        let result = try await gate.withIdleCommand(skippedValue: false) { true }
        XCTAssertTrue(result)
    }
}
