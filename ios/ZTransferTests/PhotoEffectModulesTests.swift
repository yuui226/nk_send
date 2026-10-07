import XCTest
@testable import ZTransfer

final class PhotoEffectModulesTests: XCTestCase {
    func testNormalizeRejectsEmptyAndUnknownBits() {
        XCTAssertEqual(normalizePhotoEffectModules(0), allPhotoEffectModules)
        XCTAssertEqual(normalizePhotoEffectModules(16), allPhotoEffectModules)
        XCTAssertEqual(normalizePhotoEffectModules(17), 1)
    }

    func testFreeEditionBindsFrameAndWatermarkVisibility() {
        XCTAssertEqual(effectivePhotoEffectModules(1 | PhotoEffectModule.frame.rawValue, isPro: false), 13)
        XCTAssertEqual(effectivePhotoEffectModules(1, isPro: false), 1)
        XCTAssertEqual(effectivePhotoEffectModules(1, isPro: true), 1)
    }

    func testOldPayloadGetsAllModules() throws {
        let value = try JSONDecoder().decode(PhotoEffectsSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(value.photoEffectModules, allPhotoEffectModules)
    }

    func testHiddenModulesDisableActiveEffectsButPreserveDraftSettings() {
        var value = PhotoEffectsSettings()
        value.photoFrameEnabled = true
        value.photoFrameBorderEnabled = true
        value.photoEffectModules = PhotoEffectModule.filter.rawValue
        value.watermark.enabled = true
        let effective = effectivePhotoEffectsSettings(value, isPro: true)
        XCTAssertFalse(effective.photoFrameEnabled)
        XCTAssertFalse(effective.photoFrameBorderEnabled)
        XCTAssertFalse(effective.watermark.enabled)
        XCTAssertTrue(value.watermark.enabled)
    }
}
