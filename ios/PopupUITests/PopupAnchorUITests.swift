import XCTest

/// Runs against real pages and their actual laid-out buttons. This catches
/// lost preference propagation / synthetic fallback anchors that unit tests
/// with manually supplied CGRects cannot detect.
final class PopupAnchorUITests: XCTestCase {
    func testActualPopupEntrancesAndReturnEdges() {
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        app.launchArguments = ["-app_language", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["popup-trigger-settings"].waitForExistence(timeout: 10))
        verifyPopup("settings", in: app, gap: 8) {
            app.buttons["关闭"].tap()
        }
        verifyPopup("gps", in: app, gap: 10) {
            app.buttons["popup-trigger-gps"].tap()
        }

        app.buttons["debug-photo-library"].tap()
        XCTAssertTrue(app.buttons["popup-trigger-filter"].waitForExistence(timeout: 10))
        verifyPopup("filter", in: app, gap: 8) {
            // Outside the panel, relative to the actual app viewport.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        }
        // Settings also appears in a different parent hierarchy on this page.
        verifyPopup("settings", in: app, gap: 8) {
            app.buttons["关闭"].tap()
        }
    }

    func testTipPanelsStayBelowTheirActualBulbs() {
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        app.launchArguments = ["-app_language", "zh-Hans"]
        func home() {
            app.launch()
            XCTAssertTrue(app.buttons["popup-trigger-settings"].waitForExistence(timeout: 10))
        }
        home()
        app.buttons["popup-trigger-settings"].tap()
        verifyTip("settings", in: app)
        home()
        app.buttons["popup-trigger-gps"].tap()
        verifyTip("gps", in: app)
        home()
        app.buttons["STA"].tap()
        verifyTip("sta", in: app)
        home()
        app.buttons["AP"].tap()
        verifyTip("ap", in: app)
        home()
        app.swipeUp()
        verifyTip("localEffects", in: app)
        home()
        app.buttons["debug-photo-library"].tap()
        XCTAssertTrue(app.buttons["popup-trigger-filter"].waitForExistence(timeout: 10))
        app.buttons["popup-trigger-settings"].tap()
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "滤镜")).firstMatch.tap()
        verifyTip("photoEffects", in: app)
    }

    private func verifyTip(_ kind: String, in app: XCUIApplication) {
        let button = app.buttons["tip-trigger-\(kind)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let panel = app.scrollViews["tip-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let placedBelow = NSPredicate { _, _ in
            abs(panel.frame.minY - button.frame.maxY - 8) <= (["sta", "ap"].contains(kind) ? 6 : 1)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placedBelow, object: nil)],
                                     timeout: 3), .completed, "\(kind) must remain below its bulb")
        XCTAssertFalse(panel.frame.intersects(button.frame))
        XCTAssertGreaterThan(panel.frame.height, 1)
        print("TIP_EDGE \(kind) button=\(button.frame) panel=\(panel.frame)")
        func capture(_ suffix: String) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "tip-\(kind)-\(suffix)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        capture("open")
        if ["sta", "ap"].contains(kind) {
            let initialFrame = panel.frame
            // Sample longer than the card's complete 2.4-second breath cycle.
            for _ in 0..<7 {
                Thread.sleep(forTimeInterval: 0.4)
                XCTAssertEqual(panel.frame.minX, initialFrame.minX, accuracy: 0.5)
                XCTAssertEqual(panel.frame.minY, initialFrame.minY, accuracy: 0.5)
                XCTAssertEqual(panel.frame.size.width, initialFrame.size.width, accuracy: 0.5)
                XCTAssertEqual(panel.frame.size.height, initialFrame.size.height, accuracy: 0.5)
                XCTAssertFalse(panel.frame.intersects(button.frame))
            }
            print("TIP_STABLE \(kind) panel=\(initialFrame)")
            capture("after-breath")
        }

        // GPS now uses page space, so its normal content should fit without
        // a forced swipe. Visual verification is left to the user this round.
    }

    private func verifyPopup(_ kind: String, in app: XCUIApplication,
                             gap: CGFloat, dismiss: () -> Void) {
        let button = app.buttons["popup-trigger-\(kind)"]
        let panel = app.otherElements["popup-panel-\(kind)"]
        XCTAssertTrue(button.exists)
        XCTAssertTrue(panel.exists)
        let buttonFrame = button.frame
        func checkCollapsed(_ phase: String) {
            let hidden = NSPredicate { _, _ in panel.buttons.count == 0 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 3), .completed)
            print("POPUP_CLOSED \(kind) \(phase) button=\(buttonFrame)")
        }
        checkCollapsed("before opening")
        // Repeat to cover both initial presentation and reopening retained UI.
        for cycle in 1...2 {
            button.tap()
            let visible = NSPredicate { _, _ in panel.buttons.count > 0 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 3), .completed)
            let expanded = panel.frame
            print("POPUP_EDGE \(kind) expanded \(cycle) button=\(buttonFrame) panel=\(expanded)")
            XCTAssertEqual(expanded.minY, buttonFrame.maxY + gap, accuracy: 1, "\(kind) final panel position")
            XCTAssertGreaterThan(expanded.height, 40)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(kind)-expanded-\(cycle)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            if kind == "filter", cycle == 2 {
                app.buttons["日期"].tap()
                XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 3))
                XCTAssertEqual(panel.frame.minY, buttonFrame.maxY + gap, accuracy: 1)
            }
            dismiss()
            checkCollapsed("after closing \(cycle)")
        }
    }
}
