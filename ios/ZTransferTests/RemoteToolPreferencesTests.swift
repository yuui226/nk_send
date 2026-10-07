import XCTest
@testable import ZTransfer

@MainActor
final class RemoteToolPreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "remote-preferences-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testDefaultsAndLegacyFallbackDoNotOverwriteUnknownStoredValuesOnRead() {
        withDefaults { defaults in
            defaults.set(true, forKey: "remote_histogram")
            defaults.set(true, forKey: "remote_waveform")
            defaults.set("unknown", forKey: "remote_histogram_mode")
            defaults.set(9, forKey: "remote_desqueeze_multiplier")
            defaults.set(8, forKey: "remote_locked_rotation")
            let prefs = RemoteToolPreferences(defaults: defaults)
            XCTAssertTrue(prefs.fps)
            XCTAssertTrue(prefs.audio)
            XCTAssertFalse(prefs.hd)
            XCTAssertEqual(prefs.histogram, .luma)
            XCTAssertEqual(prefs.waveform, .luma)
            XCTAssertEqual(prefs.desqueeze, 1)
            XCTAssertEqual(prefs.lockedRotation, 2)
            XCTAssertEqual(defaults.string(forKey: "remote_histogram_mode"), "unknown")
            prefs.histogram = .rgb
            prefs.waveform = .off
            prefs.hd = true
            prefs.fps = false
            prefs.level = true
            let restored = RemoteToolPreferences(defaults: defaults)
            XCTAssertEqual(restored.histogram, .rgb)
            XCTAssertEqual(restored.waveform, .off)
            XCTAssertTrue(restored.hd)
            XCTAssertFalse(restored.fps)
            XCTAssertTrue(restored.level)
        }
    }

    func testHideClosesFeatureAndRestoreDoesNotReactivateIt() {
        withDefaults { defaults in
            let prefs = RemoteToolPreferences(defaults: defaults)
            prefs.hd = true; prefs.level = true; prefs.meter = true
            prefs.histogram = .rgb; prefs.waveform = .rgb; prefs.exposure = .falseColor
            prefs.grid = .golden; prefs.desqueeze = 1.8; prefs.locked = true
            let photo = prefs.layout(movie: false)
            for tool in [RemoteTool.hd, .fps, .histogram, .grid, .exposure, .desqueeze, .level, .meter, .waveform, .lock] {
                photo.setVisible(tool, false)
                photo.setVisible(tool, true)
            }
            prefs.layout(movie: true).setVisible(.audio, false)
            XCTAssertFalse(prefs.hd); XCTAssertFalse(prefs.fps); XCTAssertFalse(prefs.audio)
            XCTAssertFalse(prefs.level); XCTAssertFalse(prefs.meter); XCTAssertFalse(prefs.locked)
            XCTAssertEqual(prefs.histogram, .off); XCTAssertEqual(prefs.waveform, .off)
            XCTAssertEqual(prefs.exposure, .off); XCTAssertEqual(prefs.grid, .off)
            XCTAssertEqual(prefs.desqueeze, 1)
            let restored = RemoteToolPreferences(defaults: defaults)
            XCTAssertFalse(restored.fps)
            XCTAssertFalse(restored.layout(movie: true).visible(.audio))
            XCTAssertTrue(restored.layout(movie: true).visible(.hd))
        }
    }

    func testRepeatedHiddenApplicationDisablesAgainWithoutResettingOtherPreferences() {
        withDefaults { defaults in
            let prefs = RemoteToolPreferences(defaults: defaults)
            let photo = prefs.layout(movie: false)
            photo.setVisible(.hd, false)
            prefs.hd = true // Enabled through the other mode's visible entry.
            photo.setVisible(.hd, false)
            XCTAssertFalse(prefs.hd)
            prefs.disp = .exposure
            prefs.lockedRotation = 2
            for tool in [RemoteTool.record, .whiteBalance, .focusArea, .lut] { photo.setVisible(tool, false) }
            XCTAssertEqual(prefs.disp, .exposure)
            XCTAssertEqual(prefs.lockedRotation, 2)
            XCTAssertEqual(defaults.string(forKey: "remote_disp_mode"), "EXPOSURE")
        }
    }
}
