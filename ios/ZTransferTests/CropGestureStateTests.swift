import XCTest
@testable import ZTransfer

final class CropGestureStateTests: XCTestCase {
    func testPanClampsToViewport() {
        var state = CropGestureState(bounds: .init(left: 0.2, top: 0.2, right: 0.8, bottom: 0.8))
        state.pan(dx: 0.5, dy: -0.5)
        XCTAssertEqual(state.bounds.left, 0.4, accuracy: 0.0001); XCTAssertEqual(state.bounds.top, 0, accuracy: 0.0001)
        XCTAssertEqual(state.bounds.right, 1, accuracy: 0.0001); XCTAssertEqual(state.bounds.bottom, 0.6, accuracy: 0.0001)
    }
    func testZoomUsesAnchorAndClampsBounds() {
        var state = CropGestureState(bounds: .init(left: 0, top: 0, right: 1, bottom: 1))
        state.zoom(scale: 2, anchor: .init(x: 0.25, y: 0.75))
        XCTAssertEqual(state.bounds, .init(left: 0.125, top: 0.375, right: 0.625, bottom: 0.875))
    }
    func testRatioKeepsCenterAndFitsViewport() {
        var state = CropGestureState(bounds: .init(left: 0.1, top: 0.2, right: 0.9, bottom: 0.8))
        state.setRatio(width: 1, height: 1)
        XCTAssertEqual(state.bounds.left, 0.2, accuracy: 0.0001)
        XCTAssertEqual(state.bounds.right, 0.8, accuracy: 0.0001)
        XCTAssertEqual(state.bounds.top, 0.2, accuracy: 0.0001)
        XCTAssertEqual(state.bounds.bottom, 0.8, accuracy: 0.0001)
    }
}
