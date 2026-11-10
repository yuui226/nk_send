import XCTest
@testable import ZTransfer

final class PhotoPreviewReturnGeometryTests: XCTestCase {
    func testTargetLeavesAndroid88PointsAtDifferentGridSizes() {
        XCTAssertEqual(photoPreviewReturnAnchor(viewportHeight: 822, itemHeight: 118), 0.125)
        let sizes: [(CGFloat, CGFloat)] = [(700, 118), (500, 250), (900, 90)]
        for (viewport, item) in sizes {
            let anchor = photoPreviewReturnAnchor(viewportHeight: viewport, itemHeight: item)
            XCTAssertEqual(viewport * anchor - item * anchor, 88, accuracy: 0.0001)
        }
    }

    func testShortViewportAndInvalidGeometryCannotProduceAnInvalidScrollAnchor() {
        XCTAssertEqual(photoPreviewReturnAnchor(viewportHeight: 200, itemHeight: 180), 1)
        XCTAssertEqual(photoPreviewReturnAnchor(viewportHeight: 200, itemHeight: 400), 0)
        for value in [CGFloat(0), -.infinity, .infinity, .nan] {
            XCTAssertEqual(photoPreviewReturnAnchor(viewportHeight: value, itemHeight: 118), 0)
            XCTAssertEqual(photoPreviewReturnAnchor(viewportHeight: 700, itemHeight: value), 0)
        }
    }
}
