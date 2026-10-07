import XCTest
@testable import ZTransfer

final class JpegCropTests: XCTestCase {
    func testExifSixSwapsAxesAndRoundTripsDisplayBounds() {
        let source = JpegCropSource(width: 4000, height: 3000, mcuWidth: 16, mcuHeight: 16, orientation: 6)
        XCTAssertEqual(source.displayWidth, 3000); XCTAssertEqual(source.displayHeight, 4000)
        let rect = CropRect(left: 160, top: 320, right: 2160, bottom: 2320)
        let b = source.displayBounds(rect)
        let resolved = source.align(b)
        XCTAssertEqual(resolved, rect)
    }
    func testRatioAndMCUAlignment() {
        let source = JpegCropSource(width: 4032, height: 3024, mcuWidth: 16, mcuHeight: 16, orientation: 1)
        let recipe = try! JpegCropSelection(bounds: .init(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9), orientation: 1, ratioWidth: 16, ratioHeight: 9).resolve(source)
        XCTAssertEqual(recipe.rect.left % 16, 0); XCTAssertEqual(recipe.rect.top % 16, 0)
        XCTAssertEqual(recipe.rect.width * 9, recipe.rect.height * 16)
    }
    func testChangedOrientationFailsResolution() {
        let selection = JpegCropSelection(bounds: .init(left: 0, top: 0, right: 1, bottom: 1), orientation: 1)
        XCTAssertThrowsError(try selection.resolve(JpegCropSource(width: 100, height: 100, mcuWidth: 8, mcuHeight: 8, orientation: 6)))
    }
}
