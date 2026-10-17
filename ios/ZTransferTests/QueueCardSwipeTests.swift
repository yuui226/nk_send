import XCTest
import UIKit
@testable import ZTransfer

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
