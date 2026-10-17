import XCTest
@testable import ZTransfer
final class IncrementalLocalizationTests: XCTestCase {
    func testNewResourcesReachActualAppLookupInEveryLanguage() {
        for language in ["en", "zh", "hant"] {
            for key in ["remote_tool_picture_control", "picture_control_check_slot", "picture_control_read_timeout",
                        "remote_review_retry", "lut_folder", "picture_control_flexible_color_unsupported"] {
                XCTAssertNotEqual(AppLocalized.resource(key, language: language), key)
            }
        }
        XCTAssertEqual(String(format: AppLocalized.resource("picture_control_check_slot", language: "en"), 9), "Operation failed. Check C9.")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.97")
    }
    func testPlatformSpecificKeysSurviveAndroidRegeneration() {
        for key in ["skin_liquid_glass", "local_photo_ios_save_hint", "cd_remote_fullscreen_exit"] {
            XCTAssertNotEqual(AppLocalized.resource(key, language: "en"), key)
        }
    }
}
