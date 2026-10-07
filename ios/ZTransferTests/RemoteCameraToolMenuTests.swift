import XCTest
@testable import ZTransfer

final class RemoteCameraToolMenuTests: XCTestCase {
    func testPortraitMenuStaysBelowAndClampsToHost() {
        let placement = RemoteCameraToolMenuPlacement(host: CGSize(width: 320, height: 600),
            anchor: CGRect(x: 270, y: 180, width: 36, height: 36), landscape: false,
            width: 300, contentHeight: 500)
        XCTAssertFalse(placement.opensAbove)
        XCTAssertEqual(placement.availableHeight, 370)
        XCTAssertEqual(placement.frame, CGRect(x: 12, y: 222, width: 300, height: 370))
    }

    func testLandscapeChoosesActualAvailableSideAndLimitsWidth() {
        let above = RemoteCameraToolMenuPlacement(host: CGSize(width: 240, height: 320),
            anchor: CGRect(x: 18, y: 260, width: 36, height: 36), landscape: true,
            width: 300, contentHeight: 160)
        XCTAssertTrue(above.opensAbove)
        XCTAssertEqual(above.frame, CGRect(x: 8, y: 94, width: 224, height: 160))
        let below = RemoteCameraToolMenuPlacement(host: CGSize(width: 600, height: 320),
            anchor: CGRect(x: 18, y: 40, width: 36, height: 36), landscape: true,
            width: 180, contentHeight: 160)
        XCTAssertFalse(below.opensAbove)
        XCTAssertEqual(below.frame, CGRect(x: 18, y: 82, width: 180, height: 160))
    }

    func testPendingRowReversesTheSameEasingAndLoadingHeadTailAreStaggered() {
        XCTAssertEqual(RemoteCameraToolIndicatorMotion.pendingOpacity(milliseconds: 0), 1)
        XCTAssertEqual(RemoteCameraToolIndicatorMotion.pendingOpacity(milliseconds: 600), 0.5)
        XCTAssertEqual(RemoteCameraToolIndicatorMotion.pendingOpacity(milliseconds: 1200), 1)
        XCTAssertEqual(RemoteCameraToolIndicatorMotion.pendingOpacity(milliseconds: 300),
                       RemoteCameraToolIndicatorMotion.pendingOpacity(milliseconds: 900), accuracy: 0.00001)
        let beginning = RemoteCameraToolIndicatorMotion.arc(milliseconds: 0)
        let midpoint = RemoteCameraToolIndicatorMotion.arc(milliseconds: 666)
        XCTAssertEqual(beginning.sweep, 0.1)
        XCTAssertEqual(midpoint.sweep, 290)
        XCTAssertEqual(midpoint.start - beginning.start, 143, accuracy: 0.00001)
        let cycle = RemoteCameraToolIndicatorMotion.arc(milliseconds: 6660)
        XCTAssertEqual(cycle.start, beginning.start)
        XCTAssertEqual(cycle.sweep, beginning.sweep)
    }
}
