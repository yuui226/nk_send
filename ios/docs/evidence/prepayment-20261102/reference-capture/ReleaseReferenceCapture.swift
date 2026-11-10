import XCTest

final class ReleaseReferenceCapture: XCTestCase {
    @MainActor
    func testCurrentReleaseHomeAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["popup-trigger-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        var selected = false
        for _ in 0..<4 {
            settings.tap()
            let language = app.buttons.matching(NSPredicate(format: "label IN %@", ["Language", "语言", "語言"])).firstMatch
            XCTAssertTrue(language.waitForExistence(timeout: 5), app.debugDescription)
            if !language.isHittable { app.scrollViews.firstMatch.swipeUp() }
            if let value = language.value as? String, value == "简体中文" {
                selected = true
                app.buttons["关闭"].firstMatch.tap()
                break
            }
            language.tap() // Actual settings wheel; its commit closes the panel.
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(selected, "Simplified Chinese must be selected through the real control")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["debug-simulator-entry"].exists)
        capture(app, "01-connect")
        settings.tap()
        XCTAssertTrue(app.buttons["关闭"].firstMatch.waitForExistence(timeout: 5))
        let language = app.buttons["语言"].firstMatch
        XCTAssertEqual(language.value as? String, "简体中文")
        capture(app, "02-settings")
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(settings.isHittable)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
