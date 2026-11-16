import XCTest
import CoreGraphics
@testable import ZTransfer

final class CropPreviewBoundsTests: XCTestCase {
    func testReviewOrientationMatchesAndroidCropRulesAndReadiness() {
        XCTAssertEqual(reviewDisplayRotationDegrees(sourceOrientation: 6, embeddedOrientation: nil, width: 1920, height: 1080), 90)
        XCTAssertEqual(reviewDisplayRotationDegrees(sourceOrientation: 6, embeddedOrientation: nil, width: 1080, height: 1620), 0)
        XCTAssertEqual(reviewDisplayRotationDegrees(sourceOrientation: 8, embeddedOrientation: 1, width: 1920, height: 1080), -90)
        XCTAssertEqual(reviewDisplayRotationDegrees(sourceOrientation: 3, embeddedOrientation: 3, width: 1920, height: 1080), 180)
        XCTAssertNil(reviewDisplayRotationDegrees(sourceOrientation: 5, embeddedOrientation: 5, width: 1920, height: 1080))
        XCTAssertNil(reviewDisplayRotationDegrees(sourceOrientation: nil, embeddedOrientation: nil, width: 1920, height: 1080))
        for orientation in [nil, 1] as [Int?] {
            XCTAssertFalse(reviewOrientationSettled(embeddedOrientation: orientation, exifFinished: false))
            XCTAssertTrue(reviewOrientationSettled(embeddedOrientation: orientation, exifFinished: true))
        }
        for orientation in 2...8 {
            XCTAssertTrue(reviewOrientationSettled(embeddedOrientation: orientation, exifFinished: false))
        }
        XCTAssertEqual(nearestRotationDegrees(from: 90, to: -270), 90)
        XCTAssertEqual(nearestRotationDegrees(from: 90, to: -180), 180)
        XCTAssertEqual(nearestRotationDegrees(from: 180, to: -180), 180)
    }

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
