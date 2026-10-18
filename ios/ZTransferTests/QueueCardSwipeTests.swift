import XCTest
import UIKit
import SwiftUI
@testable import ZTransfer

@MainActor
final class QueueRemovalCoordinatorTests: XCTestCase {
    private func file(_ id: UInt32) -> CameraFile {
        .init(id: id, storageID: 1, format: 0x3801, size: 100,
              fileName: "DSC_\(id).JPG", captureDate: nil, isProtected: false)
    }
    private func fixture() async -> (TransferQueue, TransferQueueViewModel, String) {
        let suite = "queue-removal-\(UUID())"
        let queue = await Task.detached { TransferQueue(defaults: UserDefaults(suiteName: suite)!) }.value
        let model = TransferQueueViewModel(queue: queue)
        return (queue, model, suite)
    }
    private func wait(_ model: TransferQueueViewModel,
                      until matches: (TransferQueueSnapshot) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !matches(model.snapshot), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(matches(model.snapshot))
    }
    func testClearLeavingAndReenteringCancelsOldCleanupAndAllowsNewClear() async throws {
        let (queue, model, suite) = await fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        _ = await queue.enqueue([file(1), file(2), file(3)])
        try await wait(model) { $0.items.count == 3 }
        let removal = QueueRemovalCoordinator()
        removal.clear(model: model)
        XCTAssertTrue(removal.isClearing)
        XCTAssertEqual(removal.removingIDs.count, 3)
        try await wait(model) { $0.items.allSatisfy { $0.status == .cancelled } }
        removal.leave()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.snapshot.items.count, 3, "Leaving cancels both delayed deletions")
        XCTAssertFalse(removal.isClearing); XCTAssertTrue(removal.removingIDs.isEmpty)
        removal.clear(model: model)
        try await wait(model) { $0.items.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        removal.synchronize(liveIDs: Set(model.snapshot.items.map(\.id)))
        XCTAssertFalse(removal.isClearing); XCTAssertTrue(removal.removingIDs.isEmpty)
        removal.leave()
    }
    func testDisposedSingleSwipeRemainsCancelledButClearCleansOffscreenCards() async throws {
        let (queue, model, suite) = await fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let enqueued = await queue.enqueue(file(1))
        let id = try XCTUnwrap(enqueued)
        try await wait(model) { $0.items.count == 1 }
        let removal = QueueRemovalCoordinator()
        removal.withdraw(id, model: model)
        removal.abandon(id)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.snapshot.items.map(\.status), [.cancelled])
        removal.clear(model: model)
        removal.abandon(id)
        XCTAssertTrue(removal.isClearing)
        try await wait(model) { $0.items.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(removal.isClearing)
        removal.leave()
    }
    func testClearFallbackIncludesNewTerminalTasksButProtectsNewWaitingWork() async throws {
        let (queue, model, suite) = await fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        _ = await queue.enqueue([file(1), file(2)])
        try await wait(model) { $0.items.count == 2 }
        let removal = QueueRemovalCoordinator()
        removal.clear(model: model)
        try await wait(model) { $0.items.allSatisfy { $0.status == .cancelled } }
        let newIDs = await queue.enqueue([file(3), file(4)])
        await queue.withdraw(id: newIDs[1])
        try await wait(model) { $0.items.count == 4 && $0.items.last?.status == .cancelled }
        let visibility = model.snapshot.actionVisibility(excluding: removal.removingIDs, suppressAll: removal.isClearing)
        XCTAssertFalse(visibility.hasClearable); XCTAssertFalse(visibility.hasRetryable)
        try await wait(model) { $0.items.map(\.file.id) == [3] }
        XCTAssertEqual(model.snapshot.items.first?.status, .waiting)
        removal.synchronize(liveIDs: Set(model.snapshot.items.map(\.id)))
        XCTAssertTrue(removal.removingIDs.isEmpty)
        removal.leave()
    }
    func testPendingTasksDoNotRetainTheirScreenOwner() async throws {
        let (queue, model, suite) = await fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        _ = await queue.enqueue(file(1))
        try await wait(model) { $0.items.count == 1 }
        weak var released: QueueRemovalCoordinator?
        do {
            let removal = QueueRemovalCoordinator()
            released = removal; removal.clear(model: model)
        }
        XCTAssertNil(released)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.snapshot.items.map(\.status), [.cancelled])
    }
}

final class QueueCardProgressVisibilityTests: XCTestCase {
    func testMountIsQuietAndCompletionRetainsProgressForExactDelayAndFade() {
        XCTAssertFalse(QueueCardProgressVisibility(status: .completed).retained)
        var state = QueueCardProgressVisibility(status: .transferring)
        XCTAssertEqual(state.alpha.value, 1)
        XCTAssertFalse(state.isRunning)
        state.update(.completed); state.advance(0); state.advance(100_000_000)
        XCTAssertEqual(state.alpha.value, 1)
        XCTAssertTrue(state.retained)
        state.advance(210_000_000)
        XCTAssertEqual(state.alpha.value, 0.2244387, accuracy: 0.00001)
        state.advance(319_000_000); XCTAssertTrue(state.retained)
        state.advance(320_000_000); XCTAssertFalse(state.retained)
        XCTAssertFalse(state.isRunning)
    }

    func testFailureAndRetryReverseFromDisplayedOpacityThenSettle() {
        var state = QueueCardProgressVisibility(status: .transferring)
        state.update(.failed); state.advance(0); state.advance(90_000_000)
        XCTAssertEqual(state.alpha.value, 0.2244387, accuracy: 0.00001)
        let displayed = state.alpha.value, velocity = state.alpha.velocity
        state.update(.transferring)
        XCTAssertEqual(state.alpha.value, displayed)
        XCTAssertEqual(state.alpha.velocity, velocity)
        state.advance(1_000_000_000)
        XCTAssertEqual(state.alpha.value, 1); XCTAssertTrue(state.retained)
        state.update(.cancelled); state.advance(2_000_000_000); state.advance(2_180_000_000)
        XCTAssertFalse(state.retained)
    }

    @MainActor func testClockStopsOnCompletionResetAndOwnerRelease() {
        let clock = QueueCardProgressVisibilityClock(status: .transferring)
        clock.update(.completed); XCTAssertTrue(clock.clockRunning)
        clock.advance(0); clock.advance(320_000_000)
        XCTAssertFalse(clock.clockRunning); XCTAssertFalse(clock.retained)
        clock.update(.transferring); XCTAssertTrue(clock.clockRunning)
        clock.reset(.transferring)
        XCTAssertFalse(clock.clockRunning); XCTAssertEqual(clock.opacity.value, 1)
        weak var released: QueueCardProgressVisibilityClock?
        do {
            let transient = QueueCardProgressVisibilityClock(status: .transferring)
            released = transient; transient.update(.failed)
        }
        XCTAssertNil(released)
    }
}

final class QueueCardSwipeTests: XCTestCase {
    func testHorizontalSlopConsumesOnlyExcessAndVerticalIntentRejects() {
        var input = QueueCardSwipeTouch()
        input.down(.zero)
        XCTAssertEqual(input.move(.init(x: 8, y: 0)), [])
        XCTAssertEqual(input.move(.init(x: 11, y: 1)), [.begin, .delta(3)])
        XCTAssertEqual(input.move(.init(x: 16, y: 3)), [.delta(5)])
        input.reset()
        input.down(.zero)
        XCTAssertEqual(input.move(.init(x: 2, y: 12)), [.reject])
        XCTAssertEqual(input.move(.init(x: 50, y: 12)), [])
        input.down(.zero)
        XCTAssertEqual(input.move(.init(x: -12, y: 2)), [.begin, .delta(-4)])
    }

    func testPointerHandoffKeepsAccumulatedSlopAndAvoidsFingerJump() {
        var input = QueueCardSwipeTouch()
        input.down(.init(x: 10, y: 10))
        XCTAssertEqual(input.move(.init(x: 15, y: 10)), [])
        input.handOff(to: .init(x: 100, y: 100))
        XCTAssertEqual(input.move(.init(x: 104, y: 100)), [.begin, .delta(1)])
        input.handOff(to: .init(x: 200, y: 200))
        XCTAssertEqual(input.move(.init(x: 197, y: 200)), [.delta(-3)])
    }

    @MainActor
    func testMarkerAttachesToScrollAndDetachReleasesAnimatingCard() {
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 300, height: 600))
        let controller = UIViewController()
        window.rootViewController = controller
        let scroll = UIScrollView(frame: window.bounds)
        controller.view.addSubview(scroll)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        weak var released: QueueCardSwipeInput.Marker?
        autoreleasepool {
            let marker = QueueCardSwipeInput.Marker(frame: .init(x: 0, y: 0, width: 200, height: 100))
            released = marker
            marker.configure(.init(enabled: true, removing: false, onOffset: { _ in }, onRemove: {
                XCTFail("A detached card must never request removal")
            }))
            scroll.addSubview(marker)
            XCTAssertTrue(marker.recognizer.view === scroll)
            XCTAssertFalse(marker.isUserInteractionEnabled, "Marker must not intercept button hit testing")
            marker.deliver([.begin, .delta(80)])
            marker.endDrag(cancelled: false)
            marker.detach()
            XCTAssertNil(marker.recognizer.view)
            marker.removeFromSuperview()
        }
        XCTAssertNil(released, "Display link or gesture must not retain a detached card")
    }

    func testDistanceThresholdBothDirectionsAndNoEarlyRemoval() {
        for sign: Float in [-1, 1] {
            for distance: Float in [32, 33, 100, 150] {
                var state = QueueCardSwipeState(enabled: true)
                state.beginDrag()
                state.drag(by: sign * distance, width: 100)
                XCTAssertEqual(state.offset, sign * min(distance, 100))
                state.endDrag(width: 100, exitMargin: 48)
                XCTAssertEqual(state.flying, distance >= 33)
                XCTAssertFalse(state.advance(0))
                XCTAssertFalse(state.advance(179_000_000))
                XCTAssertEqual(state.advance(180_000_000), distance >= 33)
                XCTAssertEqual(state.offset, distance >= 33 ? sign * 148 : 0)
                XCTAssertFalse(state.advance(360_000_000), "Removal is delivered once")
            }
        }
    }

    @MainActor
    func testHorizontalFlyoutDoesNotAbandonButVerticalDisposalDoes() {
        let window = UIWindow(frame: .init(x: 0, y: 0, width: 300, height: 600))
        let controller = UIViewController()
        window.rootViewController = controller
        let scroll = UIScrollView(frame: window.bounds)
        controller.view.addSubview(scroll)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for position in [CGPoint(x: -400, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 0, y: 700)] {
            var abandoned = 0
            let marker = QueueCardSwipeInput.Marker(frame: CGRect(origin: position, size: .init(width: 200, height: 100)))
            marker.configure(.init(enabled: false, removing: true, onOffset: { _ in }, onRemove: {},
                                   onRemovalAbandoned: { abandoned += 1 }))
            scroll.addSubview(marker)
            marker.detach()
            marker.removeFromSuperview()
            XCTAssertEqual(abandoned, position.y > 600 ? 1 : 0)
        }
    }

    func testCancelAndNewDragInterruptFromDisplayedOffset() {
        var state = QueueCardSwipeState(enabled: true)
        state.drag(by: 80, width: 100)
        state.cancelDrag()
        XCTAssertFalse(state.advance(0))
        XCTAssertFalse(state.advance(90_000_000))
        let displayed = state.offset
        XCTAssertGreaterThan(displayed, 0)
        XCTAssertLessThan(displayed, 80)
        state.beginDrag()
        XCTAssertFalse(state.isAnimating)
        state.drag(by: -10, width: 100)
        XCTAssertEqual(state.offset, displayed - 10)
        XCTAssertFalse(state.advance(300_000_000))
        XCTAssertEqual(state.offset, displayed - 10)
    }

    func testBusyDuringFlightCancelsRemovalAndRestores() {
        var state = QueueCardSwipeState(enabled: true)
        state.drag(by: -40, width: 100)
        state.endDrag(width: 100, exitMargin: 48)
        XCTAssertFalse(state.advance(0))
        XCTAssertFalse(state.advance(90_000_000))
        let interrupted = state.offset
        state.configure(enabled: false, removing: false)
        XCTAssertFalse(state.flying)
        XCTAssertEqual(state.offset, interrupted)
        XCTAssertFalse(state.advance(100_000_000))
        XCTAssertFalse(state.advance(280_000_000))
        XCTAssertEqual(state.offset, 0)
        state.configure(enabled: true, removing: false)
        XCTAssertFalse(state.advance(500_000_000), "Old flight cannot remove a newly idle card")
    }

    func testRecompositionDoesNotRestartFlightAndRemovingRechecksLatestEnabled() {
        var state = QueueCardSwipeState(enabled: true)
        state.drag(by: 40, width: 100)
        state.endDrag(width: 100, exitMargin: 48)
        XCTAssertFalse(state.advance(0))
        state.configure(enabled: true, removing: false)
        XCTAssertFalse(state.advance(90_000_000))
        state.beginDrag()
        state.drag(by: -90, width: 100)
        XCTAssertTrue(state.flying)
        // Removing=true preserves the flight, but latestEnabled is checked at
        // completion (e.g. an overlapping accessibility clear action).
        state.configure(enabled: false, removing: true)
        XCTAssertFalse(state.advance(180_000_000))
        XCTAssertFalse(state.flying)
        XCTAssertFalse(state.advance(200_000_000))
        XCTAssertFalse(state.advance(380_000_000))
        XCTAssertEqual(state.offset, 0)
    }

    func testEligibilityExcludesActiveGenerationAndClearAll() {
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                              fileName: "a.JPG", captureDate: nil, isProtected: false)
        for status: TransferStatus in [.waiting, .transferring, .completed, .failed, .cancelled] {
            for generating in [false, true] {
                var item = TransferQueueItem(id: UUID(), file: file, status: status)
                item.isGeneratingFrame = generating
                XCTAssertEqual(QueueCardSwipeState.isEnabled(item: item, removing: false, clearing: false),
                               status != .transferring && !generating)
                XCTAssertFalse(QueueCardSwipeState.isEnabled(item: item, removing: true, clearing: false))
                XCTAssertFalse(QueueCardSwipeState.isEnabled(item: item, removing: false, clearing: true))
            }
        }
    }
}

@MainActor
final class QueueCardPresentationTests: XCTestCase {
    private func file(_ id: UInt32) -> CameraFile {
        .init(id: id, storageID: 1, format: 0x3801, size: 1024,
              fileName: "DSC_\(id).JPG", captureDate: nil, isProtected: false)
    }

    func testOriginalSkipDoesNotHideRealDownloadOrConflateDerivedSkip() {
        for status: TransferStatus in [.waiting, .transferring, .completed, .failed, .cancelled] {
            for downloaded in [false, true] {
                for originalExists in [false, true] {
                    for skipped in [false, true] {
                        var item = TransferQueueItem(id: UUID(), file: file(1), status: status)
                        item.elapsedMs = downloaded ? 2000 : nil
                        item.downloadMBps = downloaded ? 23 : 0
                        item.outputURL = originalExists ? URL(fileURLWithPath: "/tmp/existing.JPG") : nil
                        item.skipped = skipped
                        let expected = status == .completed && !downloaded && (originalExists || skipped)
                        XCTAssertEqual(TransferQueueCardText(item: item).transferSkipped, expected)
                        item.frameGenerationSkipped = true
                        XCTAssertEqual(TransferQueueCardText(item: item).transferSkipped, expected,
                            "Derived skip must not change the original's download presentation")
                        item.isGeneratingFrame = true
                        XCTAssertEqual(TransferQueueCardText(item: item).transferSkipped, expected,
                            "A reused original still shows skipped while its new effect is generated")
                    }
                }
            }
        }
    }

    func testRealQueueSurfaceSwipesBothDirectionsThenWithdrawsAndCollapses() async throws {
        let suite = "queue-card-surface-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = await Task.detached { TransferQueue(defaults: UserDefaults(suiteName: suite)!) }.value
        let model = TransferQueueViewModel(queue: queue)
        _ = await queue.enqueue([file(1), file(2)])
        let directory = DirectoryAccessStore(defaults: UserDefaults(suiteName: suite)!)
        let visibility = QueueHostVisibility()
        let host = UIHostingController(rootView: QueueVisibilityHost(model: model, directory: directory,
                                                                    visibility: visibility))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.snapshot.items.count, 2)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-queue-swipe-cards.png"))

        for (remaining, direction) in [(1, Float(1)), (0, Float(-1))] {
            host.view.layoutIfNeeded()
            let markers = findMarkers(in: host.view).sorted {
                $0.convert(CGPoint.zero, to: window).y < $1.convert(CGPoint.zero, to: window).y
            }
            let marker = try XCTUnwrap(markers.first)
            XCTAssertTrue(marker.recognizer.isEnabled)
            XCTAssertTrue(marker.recognizer.view is UIScrollView)
            let origin = marker.convert(CGPoint.zero, to: window)
            // Exercise the production recognizer receiver, display link,
            // SwiftUI offset, queue callback and delayed removal chain together.
            marker.deliver([.begin, .delta(Float(marker.bounds.width) * 0.4 * direction)])
            try await Task.sleep(for: .milliseconds(40))
            let moved = marker.convert(CGPoint.zero, to: window)
            XCTAssertGreaterThan((moved.x - origin.x) * CGFloat(direction), marker.bounds.width * 0.3)
            marker.endDrag(cancelled: false)
            try await Task.sleep(for: .milliseconds(70))
            XCTAssertEqual(model.snapshot.items.count, remaining + 1, "Flight must finish before removal")
            let deadline = ContinuousClock.now + .seconds(3)
            while model.snapshot.items.count > remaining, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.snapshot.items.count, remaining)
            try await Task.sleep(for: .milliseconds(80))
        }

        // Unmount the actual screen after withdraw but before collapse ends.
        // Android cancels that item's removal coroutine and leaves it cancelled.
        _ = await queue.enqueue(file(3))
        try await Task.sleep(for: .milliseconds(300))
        let marker = try XCTUnwrap(findMarkers(in: host.view).first)
        marker.deliver([.begin, .delta(Float(marker.bounds.width) * 0.4)])
        marker.endDrag(cancelled: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.snapshot.items.first?.status != .cancelled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.snapshot.items.first?.status, .cancelled)
        visibility.visible = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.snapshot.items.map(\.file.id), [3], "Leaving must not run a detached deletion")
        XCTAssertEqual(model.snapshot.items.first?.status, .cancelled)
        visibility.visible = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(findMarkers(in: host.view).count, 1)
        XCTAssertTrue(try XCTUnwrap(findMarkers(in: host.view).first).recognizer.isEnabled)
    }

    private final class QueueHostVisibility: ObservableObject { @Published var visible = true }
    private struct QueueVisibilityHost: View {
        let model: TransferQueueViewModel
        let directory: DirectoryAccessStore
        @ObservedObject var visibility: QueueHostVisibility
        var body: some View {
            if visibility.visible {
                TransferQueueView(model: model, session: nil, directory: directory,
                    isSessionConnected: false, onNavigateBack: {})
            } else { Color.clear }
        }
    }

    private func findMarkers(in view: UIView) -> [QueueCardSwipeInput.Marker] {
        (view as? QueueCardSwipeInput.Marker).map { [$0] } ?? view.subviews.flatMap { findMarkers(in: $0) }
    }
}
