import XCTest
@testable import ZTransfer

final class CropPreviewTests: XCTestCase {
    func testRotationMapsToAndroidDisplayOrientations() {
        XCTAssertEqual(displayOrientation(for: 0), 1)
        XCTAssertEqual(displayOrientation(for: 90), 6)
        XCTAssertEqual(displayOrientation(for: 180), 3)
        XCTAssertEqual(displayOrientation(for: 270), 8)
    }
    func testRawSelectionMapsDisplayBoundsIntoContent() {
        let preview = CropPreview(source: .init(width: 1000, height: 800, mcuWidth: 1, mcuHeight: 1, orientation: 1), imageWidth: 1200, imageHeight: 1000, originalOrientation: 1, content: .init(left: 100, top: 50, right: 1100, bottom: 850), displayOrientation: 1, canonicalOrientation: 1)
        let raw = preview.rawSelection(.init(bounds: .init(left: 0.1, top: 0.2, right: 0.9, bottom: 0.8), orientation: 1))
        XCTAssertEqual(raw, .init(left: 200, top: 210, right: 1000, bottom: 690))
    }
    func testCanonicalSelectionSwapsRatioWhenOrientationAxesDiffer() {
        let preview = CropPreview(source: .init(width: 100, height: 200, mcuWidth: 1, mcuHeight: 1, orientation: 1), imageWidth: 200, imageHeight: 100, originalOrientation: 1, content: .init(left: 0, top: 0, right: 200, bottom: 100), displayOrientation: 6, canonicalOrientation: 1)
        let selection = preview.canonicalSelection(.init(bounds: .init(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9), orientation: 1, ratioWidth: 16, ratioHeight: 9))
        XCTAssertEqual(selection.ratioWidth, 9); XCTAssertEqual(selection.ratioHeight, 16)
    }
}
