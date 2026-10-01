import XCTest

/// Uses the actual settings trigger and purchase view; no alternate preview
/// screen and no authorization injection. Purchases themselves run in SKTestSession.
final class PremiumPurchaseUITests: XCTestCase {
    func testPurchasePageReachableWithoutCameraAndCanDismissBackToSettings() {
        let app = XCUIApplication(bundleIdentifier: "com.ztransfer.ios")
        app.launchArguments = ["-app_language", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["popup-trigger-settings"].waitForExistence(timeout: 10))
        app.buttons["popup-trigger-settings"].tap()
        for cycle in 1...2 {
            let unlock = app.buttons["解锁高级版"]
            XCTAssertTrue(unlock.waitForExistence(timeout: 5))
            let before = XCTAttachment(screenshot: app.screenshot())
            before.name = "premium-settings-entry-\(cycle)"
            before.lifetime = .keepAlways
            add(before)
            print("PREMIUM_ENTRY frame=\(unlock.frame)")
            var previousFrame = CGRect.zero
            let ready = NSPredicate { _, _ in
                guard unlock.exists, unlock.isHittable else { return false }
                let current = unlock.frame
                defer { previousFrame = current }
                return current == previousFrame && current.width > 0
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)],
                                         timeout: 5), .completed)
            unlock.tap()
            let restore = app.buttons["恢复购买"]
            guard restore.waitForExistence(timeout: 5) else {
                XCTFail("Purchase overlay did not open: \(app.debugDescription)")
                return
            }
            XCTAssertTrue(app.staticTexts["一年高级版"].exists)
            XCTAssertTrue(app.staticTexts["永久高级版"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "premium-purchase-page-\(cycle)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            if !restore.isHittable { app.swipeUp() }
            XCTAssertTrue(restore.isHittable)
            XCTAssertTrue(app.buttons["兑换优惠码"].exists)
            // Close the centered purchase overlay, keeping the settings panel.
            let close = app.buttons["premium-close"]
            if !close.isHittable { app.swipeDown() }
            close.tap()
            XCTAssertTrue(unlock.waitForExistence(timeout: 3))
            XCTAssertFalse(restore.exists)
        }
    }
}
