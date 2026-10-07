import XCTest
import CoreGraphics
@testable import ZTransfer

final class CropPreviewBoundsTests: XCTestCase {
    func testPairedBlackBarsAreTrimmed() {
        let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)
        let rect = cropPreviewBounds(width: 100, height: 100) { x, y in (y < 10 || y >= 90) ? black : white }
        XCTAssertEqual(rect, .init(left: 0, top: 10, right: 100, bottom: 90))
    }
    func testEntirelyDarkPhotoIsNeverTrimmed() {
        let black = CGColor(gray: 0, alpha: 1)
        XCTAssertEqual(cropPreviewBounds(width: 100, height: 100) { _, _ in black }, .init(left: 0, top: 0, right: 100, bottom: 100))
    }
}
