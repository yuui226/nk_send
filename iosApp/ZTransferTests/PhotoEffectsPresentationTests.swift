import XCTest
@testable import ZTransfer

final class PhotoEffectsPresentationTests: XCTestCase {
    @MainActor
    func testPresentationRouteOpensAndDismisses() {
        let route = PhotoEffectsPresentation()
        XCTAssertFalse(route.isPresented)
        route.present()
        XCTAssertTrue(route.isPresented)
        route.dismiss()
        XCTAssertFalse(route.isPresented)
    }

    @MainActor
    func testPhotoEffectsHelpFollowsFullSystemLanguageTagAndSharedWording() {
        let model = PhotoEffectsHelpModel(languageTag: "zh-Hant-TW")
        XCTAssertEqual(model.text.longPressHint, "長按照片濾鏡撥輪：按分類選擇濾鏡")
        model.updateLanguage("en-US")
        XCTAssertEqual(model.text.longPressHint, "Hold the photo filter dial: choose by category")
    }
}
