import XCTest
import UIKit
@testable import ZTransfer

/// Ports StaJpegThumbnailTest and StaJpegThumbnailInstrumentation, including
/// real native JPEG decoding/encoding, not just the selection policy.
final class STAJpegThumbnailTests: XCTestCase {
    func testChoosesSmallestIndependentPreviewAndHonorsBudget() {
        typealias Preview = STAMediaMetadata.Preview
        let fhd = Preview(offset: 100_000, length: 240_000, imageType: 0x010002)
        let vga = Preview(offset: 400_000, length: 40_000, imageType: 0x010001)
        XCTAssertEqual(STAJpegThumbnail.select([fhd, vga]), vga)
        XCTAssertNil(STAJpegThumbnail.select([
            Preview(offset: 0, length: 4000, imageType: 0x010001),
            Preview(offset: 100, length: 4000, imageType: 0x030000),
            Preview(offset: 100, length: 262_145, imageType: 0x010002),
            Preview(offset: 100, length: 3, imageType: 0x010001)
        ]))
        XCTAssertNil(STAJpegThumbnail.select([]))
        let limit = Preview(offset: 100_000, length: 262_144, imageType: 0x010002)
        XCTAssertEqual(STAJpegThumbnail.select([limit]), limit)
    }

    func testRealJPEGResizingPreservesAspectAndDoesNotUpscale() throws {
        for (width, height) in [(1920, 1280), (1280, 1920), (320, 240), (3840, 2560)] {
            let source = jpeg(width, height)
            XCTAssertLessThanOrEqual(source.count, STAJpegThumbnail.maximumBytes)
            let bytes = try XCTUnwrap(STAJpegThumbnail.create(source, fallbackLongEdge: 160))
            let image = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
            XCTAssertEqual(max(image.width, image.height), min(max(width, height), 640))
            XCTAssertEqual(Double(image.width) / Double(image.height), Double(width) / Double(height), accuracy: 0.01)
            XCTAssertEqual(image.width > image.height, width > height)
        }
    }

    func testNonImprovementTruncationOversizeAndInvalidJPEGKeepFallback() {
        XCTAssertNil(STAJpegThumbnail.create(jpeg(160, 120), fallbackLongEdge: 160))
        XCTAssertNil(STAJpegThumbnail.create(jpeg(640, 480), fallbackLongEdge: 640))
        XCTAssertNil(STAJpegThumbnail.create(Data(jpeg(640, 480).dropLast()), fallbackLongEdge: 160))
        XCTAssertNil(STAJpegThumbnail.create(Data(count: 262_145), fallbackLongEdge: 160))
        XCTAssertNil(STAJpegThumbnail.create(Data([255, 216, 255, 217]), fallbackLongEdge: 160))
    }

    private func jpeg(_ width: Int, _ height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .jpegData(withCompressionQuality: 0.85) { context in
                UIColor(red: 66 / 255, green: 128 / 255, blue: 192 / 255, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }
}
