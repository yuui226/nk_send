import XCTest
import UIKit
import SwiftUI
@testable import ZTransfer

actor GateTestLatch {
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
    func testCancellationAfterSelectionBeforeAcquireReturnsReleasesActiveTicket() async throws {
        let gate = CameraIOGate()
        let holderEntered = GateTestLatch(), releaseHolder = GateTestLatch()
        let selected = GateTestLatch(), returnFromAdmission = GateTestLatch()
        let successorEntered = GateTestLatch()
        let holder = Task {
            try await gate.withInteractive {
                await holderEntered.signal()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()
        await gate.setAdmissionHandoffProbe(owner: "CANCEL_AT_ACQUIRE") {
            await selected.signal()
            await returnFromAdmission.wait()
        }
        let cancelled = Task {
            try await gate.withCameraTransaction(.rating, owner: "CANCEL_AT_ACQUIRE") {
                XCTFail("Cancellation at admission must not enter the camera operation")
            }
        }
        let queuedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.snapshot().queued != 1, ContinuousClock.now < queuedDeadline { await Task.yield() }
        let queued = await gate.snapshot().queued
        XCTAssertEqual(queued, 1)
        await releaseHolder.signal()
        await selected.wait()
        let selectedOwner = await gate.snapshot().activeOwner
        XCTAssertEqual(selectedOwner, "CANCEL_AT_ACQUIRE")
        let successor = Task {
            try await gate.withInteractive { await successorEntered.signal() }
        }
        cancelled.cancel()
        await returnFromAdmission.signal()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await holder.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await successorEntered.isSignalled()), ContinuousClock.now < deadline { await Task.yield() }
        let ran = await successorEntered.isSignalled()
        XCTAssertTrue(ran, "No phantom active owner may prevent the next transaction")
        if !ran { successor.cancel() }
        _ = try? await successor.value
        let finished = await gate.snapshot()
        XCTAssertNil(finished.activeKind)
        XCTAssertEqual(finished.activeOwner, "none")
        XCTAssertEqual(finished.queued, 0)
    }

    func testNestedTransactionFailsWithoutQueuingOrReleasingOuterOwner() async throws {
        let gate = CameraIOGate()
        try await gate.withInteractive {
            do {
                _ = try await gate.withRatingTransaction { 1 }
                XCTFail("Nested transactions must fail before admission")
            } catch {
                XCTAssertEqual(error as? CameraSchedulerError, .nestedTransaction)
            }
            let snapshot = await gate.snapshot()
            XCTAssertEqual(snapshot.activeKind, .interactive)
            XCTAssertEqual(snapshot.queued, 0)
        }
        let next = try await gate.withTransferSlice { 2 }
        XCTAssertEqual(next, 2)
    }

    func testTransactionMarkerIsPerCameraAndRestoredAfterThrowing() async throws {
        let first = CameraIOGate()
        let second = CameraIOGate()
        do {
            try await first.withInteractive {
                let result = try await second.withInteractive { 7 }
                XCTAssertEqual(result, 7)
                throw CameraSchedulerError.nestedTransaction
            }
        } catch {
            XCTAssertEqual(error as? CameraSchedulerError, .nestedTransaction)
        }
        let result = try await first.withInteractive { 9 }
        XCTAssertEqual(result, 9)
    }

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
        func waitUntilQueued(_ expected: Int) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                if await gate.snapshot().queued == expected { break }
                await Task.yield()
            }
            let queued = await gate.snapshot().queued
            XCTAssertEqual(queued, expected, "All competing tickets must be queued before releasing the active transaction")
        }
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
        // Android's interactivePreemptsPreviewTransferAndRating yields its runBlocking
        // event loop before release. Swift Tasks may start in any order, so observe
        // actual queue admission instead of assuming creation means registration.
        await waitUntilQueued(4)
        let orderBeforeRelease = await order.snapshot()
        XCTAssertTrue(orderBeforeRelease.isEmpty, "A higher priority ticket cannot interrupt an active transaction")
        await release.signal()
        try await active.value
        try await interactive.value
        try await preview.value
        try await transfer.value
        try await rating.value
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

    func testQueuedIdleWaitsUntilDownloadEndsEvenWhenQueuedBeforeDownloadStarts() async throws {
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.snapshot().queued != 1, ContinuousClock.now < deadline { await Task.yield() }
        let queued = await gate.snapshot().queued
        XCTAssertEqual(queued, 1)
        let download = Task {
            try await gate.withDownloadActivity {
                await downloadRegistered.signal()
                await finishDownload.wait()
            }
        }
        await downloadRegistered.wait()
        await releaseSlice.signal()
        _ = await (try? holder.value)
        let between = await gate.snapshot()
        XCTAssertEqual(between.queued, 1)
        XCTAssertEqual(between.activeDownloads, 1)
        XCTAssertNil(between.activeKind, "Idle must not run in a download's local-work gap")
        await finishDownload.signal()
        _ = await (try? download.value)
        let idleResult = try await idle.value
        XCTAssertEqual(idleResult, "ran", "A queued request may run once the whole file is finished")
    }

    func testSelectedHeartbeatRechecksDownloadBeforeOperationStarts() async throws {
        let gate = CameraIOGate()
        let selected = GateTestLatch(), admitted = GateTestLatch()
        let downloading = GateTestLatch(), finishDownload = GateTestLatch()
        // Android's corresponding test holds the protocol mutex after ticket
        // selection. Swift's admission probe exposes that same handoff window.
        await gate.setAdmissionHandoffProbe(owner: "IDLE") {
            await selected.signal(); await admitted.wait()
        }
        let heartbeat = Task { try await gate.withIdleCommand(skippedValue: "skipped") { "ran" } }
        await selected.wait()
        let download = Task {
            try await gate.withDownloadActivity {
                await downloading.signal(); await finishDownload.wait()
            }
        }
        await downloading.wait()
        await admitted.signal()
        let result = try await heartbeat.value
        XCTAssertEqual(result, "skipped")
        await finishDownload.signal()
        try await download.value
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
    var previewHandles: [UInt32] = []
}

private actor PreviewTimingTransport: PTPCommandTransport {
    let order: PreviewReadOrder
    let previewData: Data
    init(order: PreviewReadOrder, previewData: Data = Data([1, 2, 3])) {
        self.order = order; self.previewData = previewData
    }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let request = try PTPCodec.decode(command)
        await MainActor.run {
            order.events.append(request.code == PTPConstants.getFHDPicture ? "fhd" : "exif")
            if request.code == PTPConstants.getFHDPicture, request.payload.count >= 4 {
                let handle = request.payload.prefix(4).enumerated().reduce(UInt32.zero) { $0 | UInt32($1.element) << (8 * $1.offset) }
                order.previewHandles.append(handle)
            }
        }
        return (PTPCodec.encode(type: .response, code: PTPConstants.responseOK,
                                transactionID: request.transactionID),
                request.code == PTPConstants.getFHDPicture ? previewData : Data())
    }
}

extension CameraIOGateTests {
    @MainActor
    func testFullPhotoPreviewPageLoadsNeighborsAndReusesCachedPage() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = try autoreleasepool {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 3072), format: format).image { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        }
        let baseline = try previewTestPhysicalFootprint()
        let sampler = Task.detached(priority: .utility) { () throws -> (peak: UInt64, count: Int) in
            var peak = baseline, count = 0
            while !Task.isCancelled {
                peak = max(peak, try previewTestPhysicalFootprint())
                count += 1
                do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
            }
            return (peak, count)
        }
        defer { sampler.cancel() }
        let order = PreviewReadOrder()
        let camera = CameraSession(repository: CameraRepository(session: PTPSession(
            transport: PreviewTimingTransport(order: order, previewData: data))))
        let files = (1...4).map { CameraFile(id: UInt32($0), storageID: 1, format: 0x3801,
            size: UInt64(data.count), fileName: "IMG_\($0).JPG", captureDate: nil, isProtected: false) }
        var selected: CameraFile? = files[0]
        let suite = "preview-page-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let transferQueue = await Task.detached { TransferQueue(defaults: UserDefaults(suiteName: suite)!) }.value
        let queue = TransferQueueViewModel(queue: transferQueue)
        let controller = UIHostingController(rootView: PhotoPreviewView(session: camera, queueModel: queue,
            files: files, selectedFile: Binding(get: { selected }, set: { selected = $0 }), collapseBursts: false))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        controller.view.layoutIfNeeded()
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Preview page did not reach expected state; handles=\(order.previewHandles)")
        }
        try await waitFor { order.previewHandles.contains(2) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let pager = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }
            .first { $0.isPagingEnabled && $0.contentSize.width > $0.bounds.width })
        let initialOffset = pager.contentOffset
        pager.setContentOffset(CGPoint(x: initialOffset.x + pager.bounds.width, y: initialOffset.y), animated: true)
        try await waitFor { selected?.id == 2 && order.previewHandles.contains(3) }
        let readsOfFirst = order.previewHandles.filter { $0 == 1 }.count
        pager.setContentOffset(CGPoint(x: pager.contentOffset.x - pager.bounds.width, y: pager.contentOffset.y), animated: true)
        try await waitFor { selected?.id == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(order.previewHandles.filter { $0 == 1 }.count, readsOfFirst)
        XCTAssertEqual(readsOfFirst, 1)
        for target in [2, 3, 4, 3, 2, 1] {
            let direction: CGFloat = target > Int(selected?.id ?? 0) ? 1 : -1
            pager.setContentOffset(CGPoint(x: pager.contentOffset.x + direction * pager.bounds.width,
                                          y: pager.contentOffset.y), animated: true)
            try await waitFor { selected?.id == UInt32(target) }
            // Give the real current-page decode and serial neighbor loader time
            // to publish, including after a page leaves the +/-2 cache window.
            try await Task.sleep(for: .milliseconds(300))
        }
        try await waitFor { order.previewHandles.filter { $0 == 1 }.count >= 2 }
        XCTAssertEqual(selected?.id, 1)
        sampler.cancel()
        let measurement = try await sampler.value
        XCTAssertGreaterThan(measurement.count, 100)
        print("F046 full-page paging: baseline=\(baseline), sampledPeak=\(measurement.peak), delta=\(measurement.peak - baseline), samples=\(measurement.count), requestedIntervalMs=2, requests=\(order.previewHandles)")
    }

    @MainActor
    func testRealLargePreviewDecodeCompletesBeforeExifAndCancellationSkipsExif() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = try autoreleasepool {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 3072), format: format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        }
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: UInt64(data.count),
                              fileName: "DSC_0009.JPG", captureDate: nil, isProtected: false)
        for cancel in [false, true] {
            let order = PreviewReadOrder()
            let camera = CameraSession(repository: CameraRepository(session: PTPSession(
                transport: PreviewTimingTransport(order: order, previewData: data))))
            let decoded = GateTestLatch(), release = GateTestLatch()
            let operation = Task { @MainActor in
                await camera.previewAndExif(file: file, onPreviewLoaded: { bytes in
                    do {
                        let content = try await loadCameraPhotoPreviewContent(try XCTUnwrap(bytes))
                        XCTAssertEqual(content?.image.cgImage?.width, 1920)
                        XCTAssertEqual(content?.image.cgImage?.height, 1440)
                        XCTAssertNotNil(content?.histogram)
                        order.events.append("decoded")
                    } catch { XCTFail("Unexpected preview decoding error: \(error)") }
                    await decoded.signal()
                    await release.wait()
                })
            }
            await decoded.wait()
            XCTAssertEqual(order.events, ["fhd", "decoded"])
            if cancel { operation.cancel() }
            await release.signal()
            _ = await operation.value
            XCTAssertEqual(order.events, cancel ? ["fhd", "decoded"] : ["fhd", "decoded", "exif"])
            // The cancelled interactive reservation must not prevent a new request.
            _ = try await camera.preview(handle: file.id)
            XCTAssertEqual(order.events.last, "fhd")
        }
    }

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

extension CameraIOGateTests {
    func testRepositoryFrameMetadataUsesBackgroundLaneAndWaitsForRatingPhase() async throws {
        let started = GateTestLatch()
        let wire = FrameworkManagedPTPReplay(started: started)
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                              fileName: "source.JPG", captureDate: "20261016T010000", isProtected: false)
        await repository.beginRatingPhase()
        let read = Task { try await repository.frameMetadataHeader(file: file, expectedSource: nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await repository.cameraSchedulerSnapshot().queued != 1, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let queued = await repository.cameraSchedulerSnapshot()
        XCTAssertEqual(queued.queued, 1)
        let premature = await started.isSignalled()
        XCTAssertFalse(premature)
        await repository.endRatingPhase()
        await started.wait()
        let active = await repository.cameraSchedulerSnapshot()
        XCTAssertEqual(active.activeKind, .backgroundThumbnail)
        XCTAssertEqual(active.activeOwner, "BACKGROUND_THUMBNAIL")
        await wire.finish()
        _ = try await read.value
        let ended = await repository.cameraSchedulerSnapshot()
        XCTAssertNil(ended.activeKind)
    }
}
