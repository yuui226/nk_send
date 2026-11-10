import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import ZTransfer

final class PhotoCaptureExifTests: XCTestCase {
    /// Android PhotoCaptureExifInstrumentation: real encode/read/copy/reopen,
    /// including nonstandard high-speed exposures that a display string loses.
    func testEffectJPEGPreservesPreciseExposureAndAdditionalCaptureFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64), format: format).image {
            UIColor.systemBlue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        }
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 72), format: format).image {
            UIColor.systemOrange.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 48, height: 72))
        }
        let exposures: [Double] = [1/60, 1/125, 1/1145, 1/1600, 1/8000, 1/16000,
                                   137/1_000_000, 1_234_567/100_000_000, 1/3, 1.5, 30]
        for exposure in exposures {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            let numeric: [CFString: Double] = [
                kCGImagePropertyExifExposureTime: exposure,
                kCGImagePropertyExifShutterSpeedValue: -log2(exposure),
                kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifApertureValue: 2.970854,
                kCGImagePropertyExifFocalLength: 2.2,
            ]
            let text: [CFString: String] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:28 12:34:56",
                kCGImagePropertyExifSubsecTimeOriginal: "789",
                kCGImagePropertyExifOffsetTimeOriginal: "+08:00",
                kCGImagePropertyExifLensSerialNumber: "Lens fixture",
                kCGImagePropertyExifBodySerialNumber: "Body fixture",
                kCGImagePropertyExifCameraOwnerName: "Owner fixture",
            ]
            var exif: [CFString: Any] = numeric
            for (key, value) in text { exif[key] = value }
            exif[kCGImagePropertyExifISOSpeedRatings] = [640]
            let tiff: [CFString: String] = [
                kCGImagePropertyTIFFArtist: "Photographer", kCGImagePropertyTIFFCopyright: "Copyright fixture",
                kCGImagePropertyTIFFImageDescription: "Capture description",
            ]
            CGImageDestinationAddImage(destination, try XCTUnwrap(original.cgImage), [
                kCGImagePropertyOrientation: 6, kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyTIFFDictionary: tiff,
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.234567,
                    kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 121.456789,
                    kCGImagePropertyGPSLongitudeRef: "E", kCGImagePropertyGPSImgDirectionRef: "T",
                    kCGImagePropertyGPSImgDirection: 95.25, kCGImagePropertyGPSMapDatum: "WGS-84",
                    kCGImagePropertyGPSHPositioningError: 2.5],
            ] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let bytes = data as Data
            let sourceURL = directory.appendingPathComponent("source.jpg")
            try bytes.write(to: sourceURL)
            let sourceProperties = try properties(bytes)
            let sourceExif = try XCTUnwrap(sourceProperties[kCGImagePropertyExifDictionary] as? NSDictionary)
            // Check that the fixture itself retained the requested precision.
            XCTAssertEqual(try XCTUnwrap(sourceExif[kCGImagePropertyExifExposureTime] as? NSNumber).doubleValue,
                           exposure, accuracy: max(abs(exposure) * 1e-8, 1e-12))
            for useURL in [false, true] {
                let output = try XCTUnwrap(useURL
                    ? PhotoEffectsJPEGEncoder.encode(rendered, copyingMetadataFrom: sourceURL)
                    : PhotoEffectsJPEGEncoder.encode(rendered, copyingMetadataFrom: bytes))
                let saved = try properties(output)
                let savedExif = try XCTUnwrap(saved[kCGImagePropertyExifDictionary] as? NSDictionary)
                for key in numeric.keys {
                    let before = try XCTUnwrap(sourceExif[key] as? NSNumber).doubleValue
                    let after = try XCTUnwrap(savedExif[key] as? NSNumber).doubleValue
                    XCTAssertEqual(after, before, accuracy: max(abs(before) * 1e-8, 1e-12), "\(key) \(exposure)")
                }
                for (key, value) in text { XCTAssertEqual(savedExif[key] as? String, value) }
                let savedTIFF = try XCTUnwrap(saved[kCGImagePropertyTIFFDictionary] as? NSDictionary)
                for (key, value) in tiff { XCTAssertEqual(savedTIFF[key] as? String, value) }
                let beforeGPS = try XCTUnwrap(sourceProperties[kCGImagePropertyGPSDictionary] as? NSDictionary)
                let afterGPS = try XCTUnwrap(saved[kCGImagePropertyGPSDictionary] as? NSDictionary)
                for key in [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLongitude,
                            kCGImagePropertyGPSImgDirection, kCGImagePropertyGPSHPositioningError] {
                    XCTAssertEqual(try XCTUnwrap(afterGPS[key] as? NSNumber).doubleValue,
                                   try XCTUnwrap(beforeGPS[key] as? NSNumber).doubleValue, accuracy: 1e-8)
                }
                XCTAssertEqual(afterGPS[kCGImagePropertyGPSMapDatum] as? String, "WGS-84")
                XCTAssertEqual((saved[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((saved[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 48)
                XCTAssertEqual((saved[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 72)
                XCTAssertEqual((savedExif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue, 48)
                XCTAssertEqual((savedExif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue, 72)
                XCTAssertNil(savedExif[kCGImagePropertyExifMakerNote])
                XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
            }
        }
    }

    private func properties(_ data: Data) throws -> NSDictionary {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
    }
}
