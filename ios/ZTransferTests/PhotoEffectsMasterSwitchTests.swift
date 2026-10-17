import XCTest
@testable import ZTransfer

@MainActor
final class PhotoEffectsMasterPreferenceTests: XCTestCase {
    func testMasterPreferenceRestoresAndDoesNotRewriteRecipeOrLocalScope() throws {
        let name = "EffectsMaster.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = PhotoEffectsStore(defaults: isolated)
        XCTAssertTrue(store.isEnabled)
        var settings = store.settings
        settings.photoFrameEnabled = true
        settings.photoFramePreset = .cinema
        store.update(settings)
        let snapshot = store.settings
        let encoded = isolated.data(forKey: "photoEffectsSettings.v1")
        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.settings, snapshot)
        XCTAssertEqual(isolated.data(forKey: "photoEffectsSettings.v1"), encoded)
        let restored = PhotoEffectsStore(defaults: isolated)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.settings, snapshot)
        let local = PhotoEffectsStore(defaults: isolated, scope: .localPhotos)
        XCTAssertTrue(local.isEnabled)
        let localRecipe = local.settings
        local.setEnabled(true)
        XCTAssertFalse(isolated.bool(forKey: "photo_effects_enabled"))
        XCTAssertEqual(local.settings, localRecipe)
        restored.setEnabled(true)
        XCTAssertTrue(PhotoEffectsStore(defaults: isolated).isEnabled)
        XCTAssertEqual(restored.settings, snapshot)
    }
}

final class PhotoEffectsSwitchMotionTests: XCTestCase {
    func testAndroidGeometryTimingAndRTL() {
        var motion = PhotoEffectsSwitchMotion(checked: false, accent: 0xFFFFB74D, foreground: 0xFFE0E0E0, secondary: 0xFFB0B0B0)
        XCTAssertEqual(motion.thumbCenterX(rightToLeft: false), 10)
        XCTAssertEqual(motion.thumbCenterX(rightToLeft: true), 26)
        XCTAssertEqual(motion.track.value, 0x29E0E0E0)
        motion.update(checked: true, accent: 0xFFFFB74D, foreground: 0xFFE0E0E0, secondary: 0xFFB0B0B0)
        motion.advance(0); motion.advance(90_000_000)
        XCTAssertEqual(motion.position.value, 0.7755613, accuracy: 0.0001)
        XCTAssertTrue(motion.isRunning)
        motion.advance(180_000_000)
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.thumbCenterX(rightToLeft: false), 26)
        XCTAssertEqual(motion.thumbCenterX(rightToLeft: true), 10)
        XCTAssertEqual(motion.track.value, 0xFFFFB74D)
        XCTAssertEqual(motion.thumb.value, 0xFFFFFFFF)
    }
    func testInterruptedSwitchAndPaletteChangeResumeFromDisplayedValues() {
        var motion = PhotoEffectsSwitchMotion(checked: true, accent: 0xFFFFB74D, foreground: 0xFFE0E0E0, secondary: 0xFFB0B0B0)
        motion.update(checked: false, accent: 0xFFFFB74D, foreground: 0xFFE0E0E0, secondary: 0xFFB0B0B0)
        motion.advance(0); motion.advance(60_000_000)
        let displayed = motion.position.value
        motion.update(checked: true, accent: 0xFFEF6C00, foreground: 0xFF1C1C1E, secondary: 0xFF6E6E73)
        XCTAssertEqual(motion.position.value, displayed, accuracy: 0.0001)
        motion.advance(240_000_000)
        XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(motion.track.value, 0xFFEF6C00)
        XCTAssertEqual(motion.position.value, 1)
    }
}
