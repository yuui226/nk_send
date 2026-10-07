import XCTest
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
