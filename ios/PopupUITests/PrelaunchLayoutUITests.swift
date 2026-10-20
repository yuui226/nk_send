import XCTest

/// Baseline real-page captures for the seven-device release matrix.
/// These checks do not claim hardware-camera or complete visual acceptance.
final class PrelaunchLayoutUITests: XCTestCase {
    /// Reuses the production overlay fixture and the established paging/zoom
    /// expectations in PhotoPreviewInteractionUITests. No camera I/O claim.
    func testPhotoPreviewPagingZoomAndEffectsBaselines() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        app.launchArguments = ["--photo-preview-ui-test", "--preview-effects-gesture-test",
                               "-app_language", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["open-preview-0"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let state = app.staticTexts["preview-state"]
        func expect(_ value: String) {
            let match = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", value), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 10), .completed)
        }
        expect("page=0")
        capture(app, "L04-preview-first")
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        right.press(forDuration: 0.05, thenDragTo: left)
        expect("page=1")
        capture(app, "L04-preview-next")
        app.pinch(withScale: 2, velocity: 1)
        expect("zoom=1")
        expect("pinch=0")
        capture(app, "L04-preview-zoom")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()
        expect("zoom=0")
        let effects = app.buttons["Edit photo effects"]
        XCTAssertTrue(effects.isHittable)
        effects.tap()
        let back = app.buttons["photo-effects-editor-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        capture(app, "L05-preview-effects")
        back.tap()
        expect("page=1")
        XCTAssertTrue(effects.isHittable)
    }

    func testEffectsEditorAndMonitorOrientationBaselines() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        defer { app.terminate() }
        app.launchArguments = ["--effects-master-ui-test", "--reset-effects-master",
                               "-app_language", "zh-Hans", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["photo-effects-open-editor"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        capture(app, "L05-effects-entry")
        entry.tap()
        let modules = app.buttons["photo-effect-modules"]
        XCTAssertTrue(modules.waitForExistence(timeout: 5))
        capture(app, "L05-effects-editor")
        modules.tap()
        let filter = app.buttons["photo-effect-module-1"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        capture(app, "L05-effects-modules")
        XCTAssertTrue(filter.isHittable)
        app.terminate()

        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test",
                               "-app_language", "zh-Hans", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let open = app.buttons["open-monitor"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let rotate = app.buttons["remote-tool-rotate"]
        let input = app.otherElements["remote-viewfinder-input"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        capture(app, "L06-monitor-portrait")
        for index in 1...3 {
            XCTAssertTrue(rotate.isHittable)
            rotate.tap()
            let dock = app.buttons[index < 3 ? "remote-landscape-dock" : "remote-tools-manage"]
            XCTAssertTrue(dock.waitForExistence(timeout: 5))
            capture(app, "L06-monitor-rotation-\(index)")
            XCTAssertTrue(input.isHittable)
        }
    }

    func testGPSActionCanBeReachedWithoutWorkbenchOverlap() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        app.launchArguments = ["-app_language", "zh-Hans", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        defer { app.terminate() }
        let trigger = app.buttons["popup-trigger-gps"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 15))
        trigger.tap()
        let action = app.descendants(matching: .any).matching(identifier: "gps-status-control").firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let workspace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "滤镜")).firstMatch
        XCTAssertTrue(workspace.exists)
        let scroll = app.scrollViews["gps-panel-scroll"]
        if scroll.exists { scroll.swipeUp() }
        capture(app, "L02-gps-action-reachability")
        XCTAssertGreaterThan(action.frame.height, 0)
        XCTAssertTrue(action.isHittable)
        XCTAssertLessThanOrEqual(action.frame.maxY, workspace.frame.minY,
                                "GPS action must be reachable above the fixed workbench entry")
    }

    func testHomeWirelessSettingsGPSAndPhotoPages() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        app.launchArguments = ["-app_language", "zh-Hans", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["popup-trigger-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        capture(app, "L02-home")
        for mode in ["STA", "AP"] {
            let tab = app.buttons[mode]
            XCTAssertTrue(tab.isHittable)
            tab.tap()
            capture(app, "L02-home-\(mode)")
            let help = app.buttons["tip-trigger-\(mode.lowercased())"]
            XCTAssertTrue(help.isHittable)
            help.tap()
            let panel = app.scrollViews["tip-panel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            capture(app, "L02-help-\(mode)")
            help.tap()
            waitForRemoval(panel)
        }
        app.buttons["popup-trigger-gps"].tap()
        let gpsAction = app.descendants(matching: .any).matching(identifier: "gps-status-control").firstMatch
        XCTAssertTrue(gpsAction.waitForExistence(timeout: 5))
        XCTAssertTrue(gpsAction.isHittable)
        capture(app, "L02-gps")
        app.buttons["popup-trigger-gps"].tap()
        waitForRemoval(gpsAction)
        settings.tap()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture(app, "L07-settings")
        close.tap()
        let library = app.buttons["debug-photo-library"]
        XCTAssertTrue(library.isHittable)
        library.tap()
        let filter = app.buttons["popup-trigger-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        capture(app, "L03-photo-list")
        filter.tap()
        capture(app, "L03-filter")
        filter.tap()
        let queue = app.buttons["workspace-queue-open"]
        XCTAssertTrue(queue.isHittable)
        queue.tap()
        let back = app.buttons["workspace-queue-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        capture(app, "L03-empty-queue")
        back.tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
    }

    private func waitForRemoval(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // Allow the existing finite opening animation to finish before capture.
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
