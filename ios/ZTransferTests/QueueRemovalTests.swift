import Combine
import XCTest
@testable import ZTransfer

@MainActor
final class QueueRemovalTests: XCTestCase {
    func testVisibleTargetsStaggerByPositionWithBoundedDelayAndNoDuplicate() {
        let ids = (0..<10_000).map { _ in UUID() }
        let visible = [(ids[2], CGFloat(160)), (ids[8], 40), (ids[0], -20), (ids[1], 80), (ids[0], 200)]
        XCTAssertEqual(queueRemovalDelays(visible, targets: Set(ids[0...2]), stagger: true),
                       [ids[0]: 0, ids[1]: 20, ids[2]: 40])
        let long = queueRemovalDelays(Array(ids.prefix(7).enumerated().map { ($0.element, CGFloat($0.offset * 60)) }),
                                      targets: Set(ids), stagger: true)
        XCTAssertEqual(long.count, 7)
        XCTAssertEqual(Array(ids.prefix(7)).map { long[$0]! }, [0, 20, 40, 60, 80, 80, 80])
        XCTAssertEqual(queueRemovalDelays(visible, targets: [ids[2]], stagger: false), [ids[2]: 0])
        XCTAssertTrue(queueRemovalDelays(visible, targets: [ids[9]], stagger: true).isEmpty)
    }

    func testOpacityLeadsHeightAndBothStayMonotonic() {
        XCTAssertLessThan(queueRemovalOpacity(0.9), 1)
        XCTAssertEqual(queueRemovalHeight(0.9), 1)
        XCTAssertEqual(queueRemovalOpacity(0.36), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(queueRemovalHeight(0.36), 0)
        var opacity: Float = 1, height: Float = 1
        for step in 0...100 {
            let progress = 1 - Float(step) / 100
            let nextOpacity = queueRemovalOpacity(progress), nextHeight = queueRemovalHeight(progress)
            XCTAssertTrue((0...opacity).contains(nextOpacity)); XCTAssertTrue((0...height).contains(nextHeight))
            opacity = nextOpacity; height = nextHeight
        }
        XCTAssertEqual(opacity, 0); XCTAssertEqual(height, 0)
    }

    func testTimelineUsesFirstDeliveredFrameAndSupportsScaledStagger() {
        let ids = (0..<3).map { _ in UUID() }
        let delays = [ids[0]: 0, ids[1]: 20, ids[2]: 80]
        for scale in [0.0, 0.5, 1, 2, 10] {
            var timeline = QueueRemovalTimeline(delays: delays, durationScale: scale)
            let origin: Int64 = 10_000_000_000
            let first = timeline.advance(origin)
            XCTAssertEqual(first[ids[0]], scale == 0 ? 0 : 1)
            if scale > 0 {
                let same = timeline.advance(origin)
                XCTAssertEqual(first, same, "No elapsed UI frames means no cleanup")
                let midway = timeline.advance(origin + Int64(140_000_000 * scale))
                XCTAssertEqual(midway[ids[0]]!, 0.5, accuracy: 0.0001)
                XCTAssertGreaterThan(midway[ids[2]]!, midway[ids[0]]!)
                XCTAssertFalse(timeline.isFinished)
            }
            _ = timeline.advance(origin + Int64(360_000_000 * scale))
            XCTAssertTrue(timeline.isFinished)
            XCTAssertTrue(timeline.advance(origin + Int64(400_000_000 * scale)).isEmpty)
        }
    }

    func testCleanupWaitsForActualFramesAndReleasesTheWaiterOnCancellation() async throws {
        let id = UUID(), value = AndroidAnimatedOpacity(); value.update(1)
        let frames = QueueRemovalFrames(delays: [id: 80], values: [id: value], automaticFrames: false)
        var finished = false, completedRows: Set<UUID> = []
        frames.onRowsFinished = { completedRows.formUnion($0) }
        let task = Task { try await frames.wait(); finished = true }
        try await wait { frames.isWaitingForFrames }
        frames.advance(0)
        try await Task.sleep(for: .milliseconds(440))
        XCTAssertFalse(finished); XCTAssertEqual(value.value, 1)
        frames.advance(350_000_000)
        XCTAssertFalse(finished); XCTAssertTrue(completedRows.isEmpty)
        frames.advance(360_000_000)
        XCTAssertEqual(value.value, 0); XCTAssertEqual(completedRows, [id])
        XCTAssertFalse(finished, "The 40ms settle begins after frames finish")
        try await task.value
        XCTAssertTrue(finished); XCTAssertFalse(frames.isWaitingForFrames)

        let cancelled = QueueRemovalFrames(delays: [id: 0], values: [id: value], automaticFrames: false)
        let cancellation = Task { try await cancelled.wait() }
        try await wait { cancelled.isWaitingForFrames }
        cancellation.cancel()
        do { try await cancellation.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(cancelled.isWaitingForFrames)
        let empty = QueueRemovalFrames(delays: [:], values: [:], automaticFrames: false)
        try await empty.wait()
        XCTAssertFalse(empty.isWaitingForFrames)
    }

    func testPlacementDoesNotChaseHeightCollapseAndResumesFromFinalPosition() {
        var placement = QueueItemPlacementMotion()
        placement.place(at: .zero, scale: 3)
        placement.place(at: CGPoint(x: 0, y: 100), scale: 3)
        placement.advance(0)
        XCTAssertTrue(placement.isRunning)
        for y in stride(from: 99, through: 0, by: -3) {
            placement.place(at: CGPoint(x: 0, y: y), scale: 3, animated: false)
            XCTAssertFalse(placement.isRunning); XCTAssertEqual(placement.offset, .zero)
        }
        placement.place(at: .zero, scale: 3)
        XCTAssertFalse(placement.isRunning)
        placement.place(at: CGPoint(x: 0, y: 30), scale: 3)
        XCTAssertTrue(placement.isRunning)
        XCTAssertEqual(placement.offset.height, -30)
    }

    func testClearImmediatelyDropsOffscreenTargetsButPreservesNewWorkAndPausedVisibleRows() async throws {
        let suite = "queue-removal.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let ids = await queue.enqueue((1...100).map { file(UInt32($0)) })
        let visible = [ids[99], ids[98], ids[97]]
        let removal = QueueRemovalCoordinator(automaticFrames: false, visibleRows: {
            visible.enumerated().map { ($0.element, CGFloat($0.offset * 120)) }
        })
        let model = TransferQueueViewModel(queue: queue)
        try await wait { model.snapshot.items.count == 100 }
        removal.clear(model: model)
        try await wait { model.snapshot.items.count == 3 && removal.removingIDs == Set(visible) && removal.isWaitingForFrames }
        XCTAssertTrue(model.snapshot.items.allSatisfy { $0.status == .cancelled })
        let enqueued = await queue.enqueue(file(101))
        let newID = try XCTUnwrap(enqueued)
        var structuralFrames = 0, coordinatorFrames = 0
        let snapshotObservation = model.objectWillChange.sink { structuralFrames += 1 }
        let removalObservation = removal.objectWillChange.sink { coordinatorFrames += 1 }
        try await wait { model.snapshot.items.count == 4 }
        structuralFrames = 0; coordinatorFrames = 0
        removal.advance(0)
        for ms in stride(from: 16, through: 256, by: 16) { removal.advance(Int64(ms) * 1_000_000) }
        XCTAssertEqual(structuralFrames, 0); XCTAssertEqual(coordinatorFrames, 0, "Frames publish only to visible row leaves")
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(model.snapshot.items.count, 4); XCTAssertTrue(removal.isClearing)
        removal.advance(280_000_000)
        try await wait { model.snapshot.items.count == 3 }
        removal.advance(320_000_000)
        try await wait { !removal.isClearing }
        XCTAssertEqual(model.snapshot.items.map(\.id), [newID])
        removal.synchronize(liveIDs: [newID])
        XCTAssertTrue(removal.removingIDs.isEmpty)
        snapshotObservation.cancel(); removalObservation.cancel()
    }

    func testPageExitFinishesCapturedClearButCannotTouchTasksAddedAfterward() async throws {
        let suite = "queue-removal-exit.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let ids = await queue.enqueue([file(1), file(2)])
        let removal = QueueRemovalCoordinator(automaticFrames: false, visibleRows: { ids.map { ($0, 0) } })
        let model = TransferQueueViewModel(queue: queue)
        try await wait { model.snapshot.items.count == 2 }
        removal.clear(model: model)
        try await wait { removal.removingIDs == Set(ids) }
        let enqueued = await queue.enqueue(file(3))
        let added = try XCTUnwrap(enqueued)
        removal.leave()
        try await wait { model.snapshot.items.map(\.id) == [added] }
        XCTAssertTrue(removal.removingIDs.isEmpty); XCTAssertFalse(removal.isClearing)
        XCTAssertEqual(model.snapshot.items[0].status, .waiting)
    }

    func testAlreadyDeletedRowNeverRestoresOnLateAnimationCompletion() async throws {
        let suite = "queue-removal-late.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let enqueued = await queue.enqueue(file(1)), id = try XCTUnwrap(enqueued)
        let model = TransferQueueViewModel(queue: queue)
        let removal = QueueRemovalCoordinator(automaticFrames: false, visibleRows: { [(id, 0)] })
        try await wait { model.snapshot.items.count == 1 }
        removal.clear(model: model)
        try await wait { removal.isWaitingForFrames }
        let progress = removal.value(for: id)
        removal.advance(0); removal.advance(140_000_000)
        XCTAssertEqual(progress.value, 0.5)
        let removed = await queue.remove(id: id)
        XCTAssertTrue(removed)
        removal.advance(280_000_000)
        try await wait { !removal.isClearing }
        XCTAssertEqual(progress.value, 0, "Missing is not busy; a late callback must not re-expand the old card")
        XCTAssertTrue(model.snapshot.items.isEmpty)
    }

    private func file(_ id: UInt32) -> CameraFile {
        .init(id: id, storageID: 1, format: 0x3801, size: 1024,
              fileName: "DSC_\(id).JPG", captureDate: nil, isProtected: false)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("Timed out waiting for removal state"); throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
