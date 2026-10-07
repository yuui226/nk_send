import XCTest
@testable import ZTransfer

final class CropViewportTests: XCTestCase {
    func testZoomIsClampedAndPanAccumulates() {
        var state = CropViewportState()
        state.applyMagnification(20); XCTAssertEqual(state.scale, 8)
        state.applyMagnification(0.01); XCTAssertEqual(state.scale, 1)
        state.applyTranslation(.init(width: 12, height: -4)); state.applyTranslation(.init(width: 3, height: 2))
        XCTAssertEqual(state.offset, .init(x: 15, y: -2))
    }
    func testPlacementMapsContentIntoImageRect() {
        let preview = CropPreview(source: .init(width: 100, height: 80, mcuWidth: 1, mcuHeight: 1, orientation: 1), imageWidth: 100, imageHeight: 80, originalOrientation: 1, content: .init(left: 10, top: 8, right: 90, bottom: 72), displayOrientation: 1, canonicalOrientation: 1)
        let rect = CropImagePlacement(image: .init(x: 0, y: 0, width: 200, height: 160), viewport: .init(width: 200, height: 160), rotation: 0).contentRect(preview: preview)
        XCTAssertEqual(rect, .init(x: 20, y: 16, width: 160, height: 128))
    }
}
