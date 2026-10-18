import XCTest
@testable import ZTransfer

final class RemoteCameraToolMenuTests: XCTestCase {
    func testPreviewFHDIndicatorUsesTwoStaggeredSegmentsAndRestartsAt1800ms() {
        let start = RemoteReviewLoadingMotion.segments(milliseconds: 0)
        XCTAssertEqual(start, [.init(head: 0, tail: 0), .init(head: 0, tail: 0)])
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 333)[0].tail, 0)
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 375)[0].head, 0.5, accuracy: 0.00001)
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 750)[0].head, 1)
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 1000)[1].head, 0)
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 1183)[0].tail, 1)
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 1267)[1].tail, 0)
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 1567)[1].head, 1)
        XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: 1800), start)
        for time in stride(from: 0.0, through: 1800.0, by: 16.0) {
            XCTAssertEqual(RemoteReviewLoadingMotion.segments(milliseconds: time),
                           RemoteReviewLoadingMotion.segments(milliseconds: time + 1800))
        }
        let arc = RemoteCameraToolIndicatorMotion.arc(milliseconds: 0, strokeWidth: 2)
        XCTAssertEqual(arc.start, -87.1352110, accuracy: 0.000001)
        XCTAssertEqual(arc.sweep, 0.1)
    }

    func testLandscapeParameterListUsesFullHeightAndPrefersLeftOfAnchor() {
        let side = RemoteCameraToolMenuPlacement(host: CGSize(width: 800, height: 360),
            anchor: CGRect(x: 660, y: 130, width: 120, height: 46), landscape: true,
            width: 80, contentHeight: 400, besideAnchor: true)
        XCTAssertEqual(side.availableHeight, 344)
        XCTAssertEqual(side.frame, CGRect(x: 574, y: 0, width: 80, height: 344))
        let right = RemoteCameraToolMenuPlacement(host: CGSize(width: 800, height: 360),
            anchor: CGRect(x: 20, y: 130, width: 100, height: 46), landscape: true,
            width: 80, contentHeight: 100, besideAnchor: true)
        XCTAssertEqual(right.frame, CGRect(x: 126, y: 103, width: 80, height: 100))
    }

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
