import XCTest
import UIKit
@testable import ZTransfer

final class AndroidThumbnailProcessorTests: XCTestCase {
    func testLetterboxCropsSymmetricNearBlackRowsAndKeepsOrientation() throws {
        let image = makeImage(width: 100, height: 100) { x, y in
            if y < 10 || y >= 90 { return (0, 0, 0, 255) }
            return (220, 180, 140, 255)
        }

        let result = try XCTUnwrap(AndroidThumbnailProcessor.process(image, fileExtension: ".jpg"))

        XCTAssertEqual(result.cgImage?.width, 100)
        XCTAssertEqual(result.cgImage?.height, 78) // Android's extra 1 px per edge
        XCTAssertEqual(result.imageOrientation, image.imageOrientation)
    }

    func testDarkSceneAtTheFractionLimitIsNotMistakenForLetterbox() throws {
        let image = makeImage(width: 100, height: 100) { _, _ in (12, 12, 12, 255) }

        let result = try XCTUnwrap(AndroidThumbnailProcessor.process(image, fileExtension: ".jpg"))

        XCTAssertEqual(result.cgImage?.width, 100)
        XCTAssertEqual(result.cgImage?.height, 100)
    }

    func testVideoFallbackCropsDarkBandsToTheAndroidFixedFrame() throws {
        let image = makeImage(width: 160, height: 120) { _, y in
            if y < 15 || y >= 105 { return (35, 35, 35, 255) }
            return (180, 140, 100, 255)
        }

        let result = try XCTUnwrap(AndroidThumbnailProcessor.process(image, fileExtension: ".mp4"))

        XCTAssertEqual(result.cgImage?.width, 160)
        XCTAssertEqual(result.cgImage?.height, 88) // 15 px band + Android's 1 px inset per side
    }

    func testInvalidDataIsReturnedUnchanged() {
        let data = Data([0x01, 0x02, 0x03])
        XCTAssertEqual(AndroidThumbnailProcessor.process(data, fileExtension: ".jpg"), data)
    }

    func testCameraCacheRejectsInvalidDataWithoutASecondValidationDecode() {
        XCTAssertTrue(AndroidThumbnailProcessor.processCameraThumbnail(
            Data([0x01, 0x02, 0x03]),
            fileExtension: ".jpg"
        ).isEmpty)
    }

    func testCameraCacheKeepsUncroppedJpegBytesExactly() throws {
        let image = makeImage(width: 100, height: 100) { _, _ in (180, 120, 80, 255) }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let result = try XCTUnwrap(AndroidThumbnailProcessor.processCameraThumbnailResult(
            data,
            fileExtension: ".jpg"
        ))
        XCTAssertEqual(result.data, data)
        XCTAssertEqual(result.image.cgImage?.width, 100)
        XCTAssertEqual(result.image.cgImage?.height, 100)
    }

    func testCameraCacheReturnsCroppedImageWithEncodedCacheBytesFromOneDecode() throws {
        let image = makeImage(width: 100, height: 100) { _, y in
            y < 10 || y >= 90 ? (0, 0, 0, 255) : (220, 180, 140, 255)
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        let result = try XCTUnwrap(AndroidThumbnailProcessor.processCameraThumbnailResult(
            data,
            fileExtension: ".jpg"
        ))
        XCTAssertEqual(result.image.cgImage?.width, 100)
        XCTAssertLessThan(result.image.cgImage?.height ?? 100, 100)
        XCTAssertNotEqual(result.data, data)
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = pixel(x, y)
                bytes[offset] = value.0
                bytes[offset + 1] = value.1
                bytes[offset + 2] = value.2
                bytes[offset + 3] = value.3
            }
        }
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return UIImage(cgImage: context.makeImage()!)
    }
}
