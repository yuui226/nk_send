import XCTest
import UIKit
import ImageIO
@testable import ZTransfer

final class PhotoFrameCoordinateFormatTests: XCTestCase {
    private func metadata(_ latitude: Double, _ longitude: Double, altitude: Double? = nil) -> PhotoFrameMetadata {
        PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil,
            shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil,
            latitude: latitude, longitude: longitude, altitude: altitude)
    }

    func testEveryTemplateRendersPlaceAndSingleZeroAxisCoordinatesIndependently() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let source = PhotoFrameMetadata(make: "Nikon", model: "Z8", lensModel: nil,
            focalLength: nil, aperture: nil, shutter: nil, iso: nil,
            exposureCompensation: nil, dateTime: nil, latitude: 0, longitude: 120,
            altitude: nil, city: "Hangzhou", region: "Xihu")
        for preset in PhotoFramePreset.allCases {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true
            settings.photoFrameBorderEnabled = true
            settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.metadata.showCity = false; settings.metadata.showRegion = false
            settings.metadata.showCoordinates = false; settings.metadata.showAltitude = false
            let none = try PhotoEffectsRenderer.render(image, settings: settings, metadata: source).pngData()
            settings.metadata.showCity = true; settings.metadata.showRegion = true
            let place = try PhotoEffectsRenderer.render(image, settings: settings, metadata: source).pngData()
            XCTAssertNotEqual(place, none, "Place missing in \(preset)")
            settings.metadata.showCity = false; settings.metadata.showRegion = false
            settings.metadata.showCoordinates = true
            let coordinates = try PhotoEffectsRenderer.render(image, settings: settings, metadata: source).pngData()
            XCTAssertNotEqual(coordinates, none, "Single-zero coordinates missing in \(preset)")
            XCTAssertNotEqual(coordinates, place, "Place and coordinate controls conflated in \(preset)")
        }
    }

    func testAndroidDecimalMinutesAndCarry() {
        let cases: [(Double, Double, String)] = [
            (31.2304, 121.4737, "N 31°13.824', E 121°28.422'"),
            (-33.8688, 151.2093, "S 33°52.128', E 151°12.558'"),
            (40.7128, -74.006, "N 40°42.768', W 74°00.360'"),
            (24 + 59.9996 / 60, 179.99999999, "N 25°00.000', E 180°00.000'"),
            (-90, -180, "S 90°00.000', W 180°00.000'"),
            (0, 30, "N 0°00.000', E 30°00.000'"),
            (51.5, 0, "N 51°30.000', E 0°00.000'")
        ]
        for (latitude, longitude, text) in cases { XCTAssertEqual(metadata(latitude, longitude).locationRow, text) }
        XCTAssertEqual(metadata(30.25, -120.15, altitude: 520).locationRow, "N 30°15.000', W 120°09.000'  520m")
    }

    func testPresentationKeepsSingleZeroAxesButRejectsPlaceholdersAndInvalidValues() {
        var settings = PhotoFrameMetadataSettings(); settings.showCoordinates = true
        for (latitude, longitude) in [(0.0, 30.0), (51.5, 0.0)] {
            let result = presentedPhotoFrameMetadata(metadata(latitude, longitude), settings: settings)
            XCTAssertEqual(result.latitude, latitude); XCTAssertEqual(result.longitude, longitude)
            XCTAssertNotNil(result.locationRow)
        }
        for (latitude, longitude) in [(0.0, 0.0), (91.0, 20.0), (30.0, 181.0), (Double.nan, 20.0), (30.0, Double.infinity)] {
            let source = metadata(latitude, longitude)
            XCTAssertNil(source.locationRow)
            let result = presentedPhotoFrameMetadata(source, settings: settings)
            XCTAssertNil(result.latitude); XCTAssertNil(result.longitude)
        }
    }
    func testJPEGEncodingPreservesSingleZeroAxesAndRejectsInvalidCameraCoordinates() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        for (latitude, longitude) in [(0.0, -30.0), (-51.5, 0.0), (90.0, 180.0),
                                      (0.0, 0.0), (91.0, 30.0), (30.0, 181.0),
                                      (Double.nan, 20.0), (30.0, Double.infinity)] {
            let data = try XCTUnwrap(PhotoEffectsJPEGEncoder.encode(image, copyingMetadataFrom: Data(), cameraMetadata: metadata(latitude, longitude)))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
            let gps = properties[kCGImagePropertyGPSDictionary] as? NSDictionary
            if validPhotoFrameCoordinates(latitude, longitude) {
                XCTAssertEqual((gps?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue, abs(latitude))
                XCTAssertEqual((gps?[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue, abs(longitude))
                XCTAssertEqual(gps?[kCGImagePropertyGPSLatitudeRef] as? String, latitude < 0 ? "S" : "N")
                XCTAssertEqual(gps?[kCGImagePropertyGPSLongitudeRef] as? String, longitude < 0 ? "W" : "E")
            } else {
                XCTAssertNil(gps?[kCGImagePropertyGPSLatitude])
                XCTAssertNil(gps?[kCGImagePropertyGPSLongitude])
            }
        }
    }

    func testPlaceRowsAreIndependentTrimmedAndDeduplicated() {
        func place(_ city: String?, _ region: String?, latitude: Double? = 30.25) -> PhotoFrameMetadata {
            PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil,
                shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil,
                latitude: latitude, longitude: 120.15, altitude: 520, city: city, region: region)
        }
        let coordinates = "N 30°15.000', E 120°09.000'  520m"
        XCTAssertEqual(place(" 杭州市 ", "西湖区").locationRows, ["杭州市 · 西湖区", coordinates])
        XCTAssertEqual(place("杭州市", "杭州市").locationRows, ["杭州市", coordinates])
        XCTAssertEqual(place(" ", nil).locationRows, [coordinates])
        XCTAssertEqual(place(nil, "西湖区", latitude: nil).locationRows, ["西湖区", "520m"])
        XCTAssertEqual(place("Paris", "PARIS").locationRows.first, "Paris · PARIS")
    }

    func testPosterKeepsCoordinatesAndSpacedAltitudeOnSeparateRows() {
        XCTAssertEqual(metadata(0, -30, altitude: -12).parameterPosterLocationRows,
                       ["N 0°00.000'", "W 30°00.000'", "-12 m"])
        XCTAssertEqual(metadata(51.5, 0).parameterPosterLocationRows,
                       ["N 51°30.000'", "E 0°00.000'"])
        XCTAssertEqual(metadata(0, 0, altitude: 520).parameterPosterLocationRows, ["520 m"])
        XCTAssertTrue(metadata(.nan, 20, altitude: .infinity).parameterPosterLocationRows.isEmpty)
    }

}

final class PhotoBackdropBlurTests: XCTestCase {
    func testProxyPolicyAcrossEveryTemplateAndLevel() {
        for preset in PhotoFramePreset.allCases {
            for level in stride(from: 0, through: 200, by: 10) {
                let expected = !preset.supportsBackdropControls ? 192 : level == 0 ? 1024 : level < 50 ? 384 : 192
                XCTAssertEqual(photoFrameBackdropPreviewLongEdge(preset, blurPercent: level), expected)
            }
        }
    }

    func testActualBackgroundUsesSharpZeroAndLargerLowBlurProxy() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            UIColor.white.setFill(); context.fill(CGRect(x: 512, y: 0, width: 512, height: 1024))
        }
        let zero = PhotoEffectsRenderer.blurredBackground(source, size: source.size, blurPercent: 0)
        let low = PhotoEffectsRenderer.blurredBackground(source, size: source.size, blurPercent: 10)
        let normal = PhotoEffectsRenderer.blurredBackground(source, size: source.size, blurPercent: 100)
        XCTAssertEqual(zero.size.width, 1024)
        XCTAssertEqual(low.size.width, 384)
        XCTAssertEqual(normal.size.width, 192)
        func bytes(_ image: UIImage) throws -> [UInt8] {
            let cg = try XCTUnwrap(image.cgImage)
            var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &data, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return data
        }
        XCTAssertEqual(try bytes(zero), try bytes(source))
        let lowPixels = try bytes(low)
        let edge = lowPixels[(192 * 384 + 191) * 4]
        XCTAssertGreaterThan(edge, 0)
        XCTAssertLessThan(edge, 255)
    }
    func testMaskAlphaScalesOnlyAdjustableLayersAndClamps() {
        for alpha in [62, 66, 92, 132, 150] {
            XCTAssertEqual(photoFrameBackdropMaskAlpha(alpha, percent: 0), 0)
            XCTAssertEqual(photoFrameBackdropMaskAlpha(alpha, percent: 100), alpha)
            XCTAssertEqual(photoFrameBackdropMaskAlpha(alpha, percent: 200), min(255, alpha * 2))
        }
        XCTAssertEqual(photoFrameBackdropMaskAlpha(150, percent: 50), 75)
        XCTAssertEqual(photoFrameBackdropMaskAlpha(150, percent: Int.max), 255)
        XCTAssertEqual(photoFrameBackdropMaskAlpha(150, percent: Int.min), 0)
    }

    func testAllSupportedMaskLevelsChangeActualExportPixels() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        for preset in PhotoFramePreset.allCases where preset.supportsBackdropControls {
            let light = preset == .mist || preset == .frosted
            let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format).image { context in
                (light ? UIColor.black : UIColor.white).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            }
            var samples: [UInt8] = []
            for level in [0, 50, 100, 200] {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true; settings.photoFramePreset = preset
                settings.watermark.enabled = false
                settings.metadata = .defaults(for: preset)
                settings.metadata.backgroundBlurPercent = 100
                settings.metadata.backgroundMaskPercent = level
                let output = try PhotoEffectsRenderer.render(source, settings: settings, metadata: nil)
                let cg = try XCTUnwrap(output.cgImage)
                var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                samples.append(bytes[0])
            }
            for index in 0..<3 {
                if light { XCTAssertLessThan(samples[index], samples[index + 1], "\(preset)") }
                else { XCTAssertGreaterThan(samples[index], samples[index + 1], "\(preset)") }
            }
        }
    }

    func testOriginalBudgetIncludesLargerBackdropBeforeAllocation() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { _ in }
        func required(_ blur: Int, border: Bool = true) throws -> Int64 {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFrameBorderEnabled = border
            settings.metadata.backgroundBlurPercent = blur
            do {
                _ = try PhotoEffectsRenderer.render(source, settings: settings, availableMemory: { 0 })
                XCTFail("Zero available memory must reject the original render")
                return 0
            } catch let error as PhotoAllocationRejected { return error.required }
        }
        let baseline = try required(100)
        XCTAssertEqual(try required(0) - baseline, 1024 * 1024 * 8)
        XCTAssertEqual(try required(10) - baseline, 384 * 384 * 8)
        XCTAssertEqual(try required(0, border: false), try required(100, border: false))
    }

    func testBackgroundProxyDimensionsForPortraitLandscapeAndPanorama() {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        for size in [CGSize(width: 400, height: 300), CGSize(width: 300, height: 400), CGSize(width: 800, height: 100), CGSize(width: 6400, height: 100), CGSize(width: 100, height: 6400)] {
            for (level, edge) in [(0, 1024), (10, 384), (100, 192)] {
                let result = PhotoEffectsRenderer.blurredBackground(source, size: size, blurPercent: level)
                let short = max(level == 0 ? 1 : 96, (CGFloat(edge) * min(size.width, size.height) / max(size.width, size.height)).rounded())
                XCTAssertEqual(max(result.size.width, result.size.height), CGFloat(edge))
                XCTAssertEqual(min(result.size.width, result.size.height), short)
                XCTAssertEqual(result.size.width > result.size.height, size.width > size.height)
            }
        }
    }

    func testCinemaTreatmentKeepsProxyDimensionsAndSourcePixels() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 144), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 192, height: 144))
        }
        let original = try XCTUnwrap(source.pngData())
        let zero = PhotoEffectsRenderer.cinemaBackdropProxy(source, maskPercent: 0)
        let strong = PhotoEffectsRenderer.cinemaBackdropProxy(source, maskPercent: 200)
        XCTAssertEqual(zero.size, source.size)
        XCTAssertEqual(strong.size, source.size)
        XCTAssertEqual(try XCTUnwrap(source.pngData()), original)
        XCTAssertNotEqual(zero.pngData(), source.pngData(), "Fixed bottom legibility gradient survives zero mask")
        XCTAssertNotEqual(zero.pngData(), strong.pngData())
    }

    func testZeroBlurKeepsBothEndsOfExtremeAspectSources() throws {
        func pixels(_ image: UIImage) throws -> [UInt8] {
            let cg = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return bytes
        }
        for size in [CGSize(width: 1024, height: 16), CGSize(width: 16, height: 1024)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width > size.height ? 128 : 16,
                                    height: size.height > size.width ? 128 : 16))
                UIColor.blue.setFill()
                context.fill(CGRect(x: size.width > size.height ? 896 : 0,
                                    y: size.height > size.width ? 896 : 0,
                                    width: size.width > size.height ? 128 : 16,
                                    height: size.height > size.width ? 128 : 16))
            }
            let output = PhotoEffectsRenderer.blurredBackground(source, size: size, blurPercent: 0)
            XCTAssertEqual(output.size, size)
            XCTAssertEqual(try pixels(output), try pixels(source))
        }
    }

}
