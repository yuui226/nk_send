import XCTest
import UIKit
@testable import ZTransfer

final class PhotoFrameMetadataSettingsTests: XCTestCase {
    func testWidthUsesAndroidBoundsAndFivePercentSteps() {
        XCTAssertEqual(normalizePhotoFrameWidthPercent(59), 60)
        XCTAssertEqual(normalizePhotoFrameWidthPercent(61), 60)
        XCTAssertEqual(normalizePhotoFrameWidthPercent(63), 65)
        XCTAssertEqual(normalizePhotoFrameWidthPercent(147), 145)
        XCTAssertEqual(normalizePhotoFrameWidthPercent(148), 150)
        XCTAssertEqual(normalizePhotoFrameWidthPercent(201), 200)
    }

    func testBackdropPercentBounds() {
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(-1), 0)
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(0), 0)
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(100), 100)
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(200), 200)
        XCTAssertEqual(normalizePhotoFrameBackdropPercent(201), 200)
    }

    func testOldPayloadDefaultsNewFields() throws {
        let data = Data(#"{"showDate":true,"showTime":true,"showBrand":true,"showModel":true}"#.utf8)
        let value = try JSONDecoder().decode(PhotoFrameMetadataSettings.self, from: data)
        XCTAssertEqual(value.widthPercent, 100)
        XCTAssertEqual(value.backgroundBlurPercent, 100)
        XCTAssertEqual(value.backgroundMaskPercent, 100)
        XCTAssertFalse(value.showCity)
        XCTAssertEqual(value.brandStyle, .text)
    }

    func testExportUsesWidthSettingsWithoutChangingPhotoSourceSize() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFrameBorderEnabled = true; settings.photoFramePreset = .brandInset
        var outputs: [UIImage] = []
        for width in [60, 100, 200] {
            var copy = settings; copy.metadata.widthPercent = width
            outputs.append(try PhotoEffectsRenderer.render(source, settings: copy))
        }
        XCTAssertLessThan(outputs[0].size.width, outputs[1].size.width)
        XCTAssertLessThan(outputs[1].size.width, outputs[2].size.width)
        XCTAssertEqual(outputs.map { $0.size.height }, outputs.map { $0.size.height }.sorted())
    }
}

final class ParameterPosterBadgeRenderingTests: XCTestCase {
    private let exposure = PhotoFrameMetadata(make: nil, model: nil, lensModel: nil,
        focalLength: "50mm", aperture: "f/2.8", shutter: "1/125", iso: "ISO100",
        exposureCompensation: nil, dateTime: nil)

    private func render(_ size: CGSize, percent: Int = 100, preview: CGFloat? = nil,
                        showExposure: Bool = true) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFrameBorderEnabled = true
        settings.photoFramePreset = .parameterPoster; settings.watermark.enabled = false
        settings.metadata = .defaults(for: .parameterPoster)
        settings.metadata.widthPercent = percent
        settings.metadata.showFocalLength = showExposure; settings.metadata.showExposure = showExposure
        return try PhotoEffectsRenderer.render(source, settings: settings, metadata: exposure, previewLongEdge: preview)
    }

    // Reference coordinates from Android ParameterPosterFrame, with exposure
    // only. Probe horizontal edges away from glyphs, so text alone cannot pass.
    private func borderPoints(_ size: CGSize, percent: Int) -> [CGPoint] {
        let portrait = size.height > size.width, ratio = CGFloat(percent) / 100
        let s = size.width * (portrait ? 0.052 : 0.038)
        let rowHeight = s * 2.65, total = rowHeight * 4, boxHeight = s * 1.88
        let top = size.width * 0.11 * ratio
        let bandHeight = max(size.width * 0.48 * ratio, total + size.width * 0.095 * ratio)
        let x = portrait ? size.width * 0.36 * ratio : size.width * (0.10 * ratio + 0.025)
        let y = portrait ? top + (size.height - total) / 2 : top + size.height + (bandHeight - total) / 2
        return (0..<4).flatMap { row -> [CGPoint] in
            let boxTop = y + CGFloat(row) * rowHeight + (rowHeight - boxHeight) / 2
            return [CGPoint(x: x + s * 1.3, y: boxTop), CGPoint(x: x + s * 1.3, y: boxTop + boxHeight)]
        }
    }

    private func brightestPixels(_ image: UIImage, around points: [CGPoint]) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return points.map { point in
            var brightest: UInt8 = 0
            for y in max(0, Int(point.y) - 1)...min(cg.height - 1, Int(point.y) + 1) {
                for x in max(0, Int(point.x) - 1)...min(cg.width - 1, Int(point.x) + 1) {
                    let i = (y * cg.width + x) * 4
                    brightest = max(brightest, min(bytes[i], bytes[i + 1], bytes[i + 2]))
                }
            }
            return brightest
        }
    }

    func testAllFourBadgesHaveOutlinesAcrossOrientationsAndBorderWidths() throws {
        for size in [CGSize(width: 400, height: 600), CGSize(width: 600, height: 400), CGSize(width: 400, height: 400)] {
            for percent in [60, 100, 200] {
                let output = try render(size, percent: percent)
                let pixels = try brightestPixels(output, around: borderPoints(size, percent: percent))
                // A 1.292px Android stroke can split across two pixel rows;
                // half coverage is still an intact antialiased white outline.
                XCTAssertTrue(pixels.allSatisfy { $0 > 127 }, "Missing badge edges: \(size), \(percent)%: \(pixels)")
            }
        }
    }

    func testPreviewScalesOutlinesTogetherWithLabelsAndValues() throws {
        let size = CGSize(width: 400, height: 600)
        let original = try render(size)
        let preview = try render(size, preview: 600)
        let scale = 600 / max(original.size.width, original.size.height)
        let points = borderPoints(size, percent: 100).map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        XCTAssertTrue(try brightestPixels(preview, around: points).allSatisfy { $0 > 100 })
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ztransfer-parameter-poster.png")
        try XCTUnwrap(preview.pngData()).write(to: path)
        print("VISUAL_FIXTURE: \(path.path)")
    }

    func testDisabledExposureDoesNotLeaveEmptyBadgeFrames() throws {
        let size = CGSize(width: 400, height: 600)
        let output = try render(size, showExposure: false)
        XCTAssertTrue(try brightestPixels(output, around: borderPoints(size, percent: 100)).allSatisfy { $0 < 128 })
    }

    func testLabelsKeepAndroidOrderAndStripOnlyApertureAndISOPrefixes() {
        let rows = PhotoEffectsRenderer.parameterPosterExposure(exposure)
        XCTAssertEqual(rows.map(\.label), ["FL", "F", "ISO", "S"])
        XCTAssertEqual(rows.map(\.value), ["50mm", "2.8", "100", "1/125"])
    }
}

final class PhotoMetadataSnapshotBoundsTests: XCTestCase {
    func testQueueBoundsEveryAndroidLabelWithoutSplittingSurrogatePairs() {
        let long = String(repeating: "x", count: 65_000)
        let model = String(repeating: "a", count: 255) + "📷" + long
        let source = PhotoFrameMetadata(make: long, model: model, lensModel: long,
            focalLength: long, aperture: long, shutter: long, iso: long,
            exposureCompensation: "+0.3", dateTime: long, latitude: 24.5,
            longitude: 118.2, altitude: 15, city: long, region: long)
        let result = source.boundedForQueue()
        XCTAssertEqual(result.model, String(repeating: "a", count: 255))
        for label in [result.make, result.lensModel, result.focalLength, result.aperture,
                      result.shutter, result.iso, result.dateTime, result.city, result.region] {
            XCTAssertEqual(label, String(repeating: "x", count: 256))
        }
        XCTAssertEqual(result.latitude, source.latitude)
        XCTAssertEqual(result.longitude, source.longitude)
        XCTAssertEqual(result.altitude, source.altitude)
        XCTAssertEqual(result.exposureCompensation, source.exposureCompensation)
        XCTAssertEqual(result.boundedForQueue(), result)
    }

    func testExactUTF16BoundaryPreservesEmojiAndNil() {
        let model = String(repeating: "a", count: 254) + "📷"
        let source = PhotoFrameMetadata(make: nil, model: model, lensModel: nil,
            focalLength: "35mm", aperture: "f/2.8", shutter: "1/100", iso: "ISO100",
            exposureCompensation: nil, dateTime: nil)
        XCTAssertEqual(source.boundedForQueue(), source)
    }
}

final class PreparedPhotoMetadataTests: XCTestCase {
    func testAndroidStructuralBoundariesAndNonzeroDataIndex() {
        let exif = Data([255, 216, 255, 225, 0, 10, 69, 120, 105, 102, 0, 0, 73, 73])
        XCTAssertEqual(JpegMetadataHeader.inspect(exif), .exifComplete)
        XCTAssertEqual(JpegMetadataHeader.inspect(exif.prefix(12)), .incomplete)
        let xmp = Data([255, 216, 255, 225, 0, 5, 88, 77, 80])
        XCTAssertEqual(JpegMetadataHeader.inspect(xmp), .incomplete)
        XCTAssertEqual(JpegMetadataHeader.inspect(xmp + Data([255, 218])), .noExif)
        for bad in [Data([137, 80, 78, 71]), Data([255, 216, 255, 225, 0, 1]), Data([255,216,255,0])] {
            XCTAssertEqual(JpegMetadataHeader.inspect(bad), .invalid)
            XCTAssertEqual(PreparedPhotoMetadata.parse(bad).state, .failed)
        }
        XCTAssertEqual(JpegMetadataHeader.inspect(Data([255,216,255,225,255,255])), .incomplete)
        let prefixed = Data([0, 1, 2]) + exif
        XCTAssertEqual(JpegMetadataHeader.inspect(prefixed.dropFirst(3)), .exifComplete)
        XCTAssertEqual(PreparedPhotoMetadata.parse(xmp + Data([255,218])).state, .noExif)
        XCTAssertEqual(PreparedPhotoMetadata.parse(Data([255,216])).state, .partial)
    }

    func testCacheIsAccessOrderedBoundsAbsenceAndDoesNotCacheFailure() {
        var cache = PhotoMetadataResultCache<Int>()
        let absent = PreparedPhotoMetadata(value: nil, state: .noExif)
        for key in 0..<256 { cache.insert(absent, for: key) }
        XCTAssertEqual(cache.value(for: 0), absent)
        cache.insert(.init(value: nil, state: .partial), for: 256)
        XCTAssertEqual(cache.count, 256)
        XCTAssertNil(cache.value(for: 1))
        XCTAssertEqual(cache.value(for: 0), absent)
        cache.insert(.init(value: nil, state: .failed), for: 999)
        XCTAssertNil(cache.value(for: 999))
        XCTAssertEqual(cache.count, 256)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testFailedAndSparseLargerHeadersKeepReliableFields() {
        let old = PhotoFrameMetadata(make: "Nikon", model: "Z 30", lensModel: "Lens",
            focalLength: "35mm", aperture: "f/2.8", shutter: "1/100", iso: "ISO100",
            exposureCompensation: nil, dateTime: "today", latitude: 24.5, longitude: 118.2)
        let failure = PreparedPhotoMetadata(value: nil, state: .failed).merging(previous: old)
        XCTAssertEqual(failure.value, old)
        XCTAssertEqual(failure.state, .failed)
        let next = PhotoFrameMetadata(make: " ", model: "New", lensModel: nil,
            focalLength: nil, aperture: nil, shutter: nil, iso: nil,
            exposureCompensation: nil, dateTime: nil, altitude: 10)
        let merged = PreparedPhotoMetadata(value: next, state: .complete).merging(previous: old)
        XCTAssertEqual(merged.value?.make, old.make)
        XCTAssertEqual(merged.value?.model, "New")
        XCTAssertEqual(merged.value?.latitude, old.latitude)
        XCTAssertEqual(merged.value?.altitude, 10)
        XCTAssertEqual(merged.value?.lensModel, old.lensModel)
    }
}
