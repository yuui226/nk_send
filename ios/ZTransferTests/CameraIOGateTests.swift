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
    func testRatingPhaseBlocksLowPriorityAdmissionButAllowsForegroundTransactions() async throws {
        let gate = CameraIOGate()
        let backgroundStarted = GateTestLatch()
        let order = GateTestOrder()
        await gate.beginRatingPhase()
        let background = Task {
            try await gate.withBackgroundThumbnail {
                await backgroundStarted.signal()
                await order.append("background")
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let didStartBackground = await backgroundStarted.isSignalled()
        XCTAssertFalse(didStartBackground)

        try await gate.withInteractive { await order.append("interactive") }
        try await gate.withPreviewTransaction { await order.append("preview") }
        try await gate.withTransferSlice { await order.append("transfer") }
        try await gate.withRatingTransaction { await order.append("rating") }
        let foregroundOrder = await order.snapshot()
        XCTAssertEqual(foregroundOrder, ["interactive", "preview", "transfer", "rating"])

        await gate.endRatingPhase()
        _ = try await background.value
        let finalOrder = await order.snapshot()
        XCTAssertEqual(finalOrder, ["interactive", "preview", "transfer", "rating", "background"])
    }

    func testSchedulerChoosesPriorityThenFIFOAtTransactionBoundaries() async throws {
        let gate = CameraIOGate()
        let entered = GateTestLatch()
        let release = GateTestLatch()
        let order = GateTestOrder()
        let active = Task {
            try await gate.withBackgroundThumbnail {
                await entered.signal()
                await release.wait()
                await order.append("active")
            }
        }
        await entered.wait()
        let rating = Task { try await gate.withRatingTransaction { await order.append("rating") } }
        let transfer = Task { try await gate.withTransferSlice { await order.append("transfer") } }
        let preview = Task { try await gate.withPreviewTransaction { await order.append("preview") } }
        let interactive = Task { try await gate.withInteractive { await order.append("interactive") } }
        await release.signal()
        _ = await (try? active.value)
        _ = await (try? interactive.value)
        _ = await (try? preview.value)
        _ = await (try? transfer.value)
        _ = await (try? rating.value)
        let orderValues = await order.snapshot()
        XCTAssertEqual(orderValues, ["active", "interactive", "preview", "transfer", "rating"])
    }

    func testShutdownCancelsQueuedWorkAndLeavesActiveTransactionForCleanup() async throws {
        let gate = CameraIOGate()
        let entered = GateTestLatch()
        let release = GateTestLatch()
        let active = Task {
            try await gate.withVisibleThumbnail {
                await entered.signal()
                await release.wait()
            }
        }
        await entered.wait()
        let queued = Task {
            do {
                try await gate.withBackgroundThumbnail { XCTFail("queued work ran after shutdown") }
            } catch is CancellationError { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(20))
        await gate.beginShutdown("test shutdown")
        let queuedCancelled = try await queued.value
        XCTAssertTrue(queuedCancelled)
        let snapshot = await gate.snapshot()
        XCTAssertTrue(snapshot.shuttingDown)
        XCTAssertEqual(snapshot.queued, 0)
        await release.signal()
        _ = await (try? active.value)
        try await gate.withCameraTransaction(.interactive, owner: "CLOSE", allowDuringShutdown: true) { }
    }

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

    func testReservationBlocksBackgroundAndIdleUntilForegroundPairReleases() async throws {
        let gate = CameraIOGate()
        let registered = GateTestLatch()
        let release = GateTestLatch()
        let ordinaryStarted = GateTestLatch()
        let idleStarted = GateTestLatch()
        let reservation = Task {
            try await gate.withInteractivePriority {
                await registered.signal()
                await release.wait()
            }
        }
        await registered.wait()
        let ordinary = Task { try await gate.withCommand { await ordinaryStarted.signal(); return "thumbnail" } }
        let idle = Task { try await gate.withIdleCommand(skippedValue: "skipped") { await idleStarted.signal(); return "idle" } }
        try await Task.sleep(for: .milliseconds(40))
        let didStartOrdinary = await ordinaryStarted.isSignalled()
        let didStartIdle = await idleStarted.isSignalled()
        XCTAssertFalse(didStartOrdinary)
        XCTAssertFalse(didStartIdle)
        await release.signal()
        let ordinaryValue = try await ordinary.value
        let idleValue = try await idle.value
        XCTAssertEqual(ordinaryValue, "thumbnail")
        XCTAssertEqual(idleValue, "idle")
        try await reservation.value
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

@MainActor
private final class PreviewReadOrder {
    var events: [String] = []
}

private actor PreviewTimingTransport: PTPCommandTransport {
    let order: PreviewReadOrder
    init(order: PreviewReadOrder) { self.order = order }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let request = try PTPCodec.decode(command)
        await MainActor.run {
            order.events.append(request.code == PTPConstants.getFHDPicture ? "fhd" : "exif")
        }
        return (PTPCodec.encode(type: .response, code: PTPConstants.responseOK,
                                transactionID: request.transactionID),
                request.code == PTPConstants.getFHDPicture ? Data([1, 2, 3]) : Data())
    }
}

extension CameraIOGateTests {
    @MainActor
    func testCurrentPreviewPublishesBeforeExifAndCachedReadsStaySkipped() async {
        let order = PreviewReadOrder()
        let camera = CameraSession(repository: CameraRepository(
            session: PTPSession(transport: PreviewTimingTransport(order: order))))
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 100,
                              fileName: "DSC_0009.JPG", captureDate: "20261001T120000", isProtected: false)
        let (image, _) = await camera.previewAndExif(file: file, onPreviewLoaded: { data in
            XCTAssertEqual(data, Data([1, 2, 3]))
            order.events.append("preview-visible")
        })
        XCTAssertEqual(image, Data([1, 2, 3]))
        XCTAssertEqual(order.events, ["fhd", "preview-visible", "exif"])
        _ = await camera.previewAndExif(file: file, loadPreview: false, loadExif: false,
                                       onPreviewLoaded: { _ in XCTFail("Cached FHD must not be republished") })
        XCTAssertEqual(order.events, ["fhd", "preview-visible", "exif"])
    }
}
