import XCTest

@MainActor
final class PhotoEffectsMasterUITests: XCTestCase {
    func testMasterSwitchDoesNotOpenEditorAndPersistsWithoutClearingRecipe() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let arguments = ["--effects-master-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = arguments + ["--reset-effects-master"]
        app.launch()
        defer { app.terminate() }
        let toggle = app.switches["photo-effects-master-switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<5 where !toggle.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.frame.width, 48, accuracy: 1)
        XCTAssertEqual(toggle.frame.height, 32, accuracy: 1)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertFalse(app.buttons["photo-effects-editor-back"].exists)
        expect(app.staticTexts["effects-master-test-state"], label: "gate=off;recipe=true")
        XCTAssertEqual(toggle.value as? String, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Effects master off retains summaries"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["photo-effects-open-editor"].tap()
        XCTAssertTrue(app.buttons["photo-effects-editor-back"].waitForExistence(timeout: 5))
        app.buttons["photo-effects-editor-back"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0")
        expect(app.staticTexts["effects-master-test-state"], label: "gate=off;recipe=true")
    }
    private func expect(_ element: XCUIElement, label: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
