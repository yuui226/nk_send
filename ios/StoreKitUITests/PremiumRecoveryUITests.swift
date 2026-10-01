import XCTest
import StoreKitTest

/// Exercises the actual App process and purchase button. Killing the App is
/// distinct from replacing one manager inside a still-running StoreKit client.
/// Run through StoreKit/test-recovery-ui.sh, which prepares/cleans the local
/// transaction environment in the authorized application-hosted test process.
@MainActor
final class PremiumRecoveryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLifetimePurchaseSurvivesImmediateAppRelaunch() throws {
        try verifyLifetimeRecovery(acknowledgeSuccess: false)
    }

    func testDebugPremiumAnimationPreviewKeepsFreeWatermarkLocked() {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "en"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let camera = app.buttons["debug-photo-library"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["popup-trigger-filter"].waitForExistence(timeout: 10))
        let editor = openCameraEffectsFromPhotoList(app, expectPro: false)
        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app, scrollView: editor)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        verifyFreeWatermarkControls(app, scrollView: editor)
        attachScreenshot(app, name: "debug-premium-preview-keeps-free-watermark")

        app.terminate()
        app.launch()
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        tapWhenStable(camera)
        XCTAssertTrue(app.buttons["popup-trigger-filter"].waitForExistence(timeout: 10))
        openSettings(app)
        XCTAssertTrue(app.buttons["Unlock Pro"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Pro"].exists)
    }

    func testLifetimePurchaseClosesAfterSystemAcknowledgement() throws {
        try verifyLifetimeRecovery(acknowledgeSuccess: true)
    }

    func testPurchasedBadgeCelebratesWithoutReopeningPurchaseInBothSettings() {
        let app = purchaseLifetimeAndRelaunch()
        for camera in [false, true] {
            if camera {
                app.terminate()
                app.launch()
                let library = app.buttons["debug-photo-library"]
                XCTAssertTrue(library.waitForExistence(timeout: 10))
                tapWhenStable(library)
                XCTAssertTrue(app.buttons["popup-trigger-filter"].waitForExistence(timeout: 10))
            }
            openSettings(app)
            let badge = app.buttons["Pro"]
            XCTAssertTrue(badge.waitForExistence(timeout: 10))
            tapWhenStable(badge)
            badge.tap()
            attachScreenshot(app, name: camera ? "camera-pro-badge-celebration" : "connection-pro-badge-celebration")
            XCTAssertFalse(app.buttons["premium-close"].exists,
                           "An already-purchased badge celebrates without opening a purchase page")
            XCTAssertTrue(badge.exists)
            app.buttons["popup-trigger-settings"].tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !badge.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                           "The celebration must leave settings closable")
        }
    }

    func testRefundWhileWorkbenchEditorIsOpenRestoresFreeWatermark() throws {
        let app = purchaseLifetimeAndRelaunch()
        // Initialize only after the signed App is installed and running.
        // Do not reset/clear its purchase: refund the actual UI transaction.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ZTransfer", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        let purchased = try XCTUnwrap(session.allTransactions().last {
            $0.productIdentifier == "com.ztransfer.ios.pro.lifetime" && $0.cancelDate == nil
        }, "The UI runner must control the real local purchase before testing a refund")
        let workbench = app.buttons["Filter · Frame · Watermark"].firstMatch
        XCTAssertTrue(workbench.waitForExistence(timeout: 10))
        tapWhenStable(workbench)
        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        let watermark = app.buttons["Watermark"]
        revealEffectsControl(watermark, in: app)
        if watermark.value as? String == "Off" { tapWhenStable(watermark) }
        let settings = app.buttons.matching(NSPredicate(format: "value == %@", "Watermark settings")).firstMatch
        revealEffectsControl(settings, in: app)
        tapWhenStable(settings)
        let type = app.buttons["Watermark type"]
        revealEffectsControl(type, in: app)
        if type.value as? String == "Logo" { tapWhenStable(type) }
        let text = app.textFields.firstMatch
        revealEffectsControl(text, in: app)
        replaceWatermarkText(text, with: "REFUND KEEP SIGNATURE", in: app)
        tapWhenStable(text)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "paid-editor-before-refund")

        try session.refundTransaction(identifier: purchased.identifier)
        let free = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            text.exists && text.value as? String == "ZTransfer" && !text.isEnabled
                && !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [free], timeout: 10), .completed,
                       "A StoreKit refund must update the open editor and dismiss its keyboard")
        XCTAssertEqual(type.value as? String, "Text")
        tapLockedEffectsControl(text, in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        for name in ["Size", "Opacity"] {
            let control = app.buttons[name]
            revealEffectsControl(control, in: app)
            XCTAssertEqual(control.value as? String, "80%")
            XCTAssertFalse(control.isEnabled)
        }
        attachScreenshot(app, name: "open-editor-after-storekit-refund")
        let filter = app.buttons["Photo filter"]
        revealEffectsControl(filter, in: app)
        let original = filter.value as? String
        tapWhenStable(filter)
        XCTAssertNotEqual(filter.value as? String, original, "Filters remain free after a refund")
        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["Unlock Pro"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Pro"].exists)
    }

    private func verifyLifetimeRecovery(acknowledgeSuccess: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "zh-Hans"]
        addTeardownBlock {
            app.terminate()
        }
        app.launch()
        openSettings(app)
        let unlock = app.buttons["解锁高级版"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        tapWhenStable(unlock)
        let lifetime = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "永久高级版")).firstMatch
        XCTAssertTrue(lifetime.waitForExistence(timeout: 10), app.debugDescription)
        tapWhenStable(lifetime)
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "购买永久高级版")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 10), app.debugDescription)
        if !buy.isHittable { app.swipeUp() }
        tapWhenStable(buy)
        confirmLocalPurchase()
        let pro = app.buttons["高级版"]
        if !pro.waitForExistence(timeout: 10) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "purchase-not-delivered"
            shot.lifetime = .keepAlways
            add(shot)
            print("PURCHASE_SYSTEM_UI \(XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)")
            XCTFail("Purchase did not deliver Pro: \(app.debugDescription)")
        }
        if acknowledgeSuccess {
            // purchase() may return only after the system's success alert is
            // acknowledged; the transaction listener can unlock Pro earlier.
            dismissPurchaseCompletion()
            let closed = NSPredicate { _, _ in !app.buttons["premium-close"].exists }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5), .completed,
                           "A lifetime purchase without an annual subscription must close the purchase page")
        }
        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(pro.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["解锁高级版"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lifetime-pro-after-cold-launch"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAnnualToLifetimeKeepsRenewalManagementAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "zh-Hans"]
        addTeardownBlock { app.terminate() }
        app.launch()
        openSettings(app)
        let unlock = app.buttons["解锁高级版"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        tapWhenStable(unlock)
        let annualBuy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "购买一年高级版")).firstMatch
        XCTAssertTrue(annualBuy.waitForExistence(timeout: 10))
        reveal(annualBuy, in: app)
        tapWhenStable(annualBuy)
        confirmLocalPurchase()
        XCTAssertTrue(app.buttons["高级版"].waitForExistence(timeout: 10))
        dismissPurchaseCompletion()
        let closed = NSPredicate { _, _ in !app.buttons["premium-close"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5), .completed,
                       "Annual purchase must close the purchase page")

        let manage = app.buttons["管理订阅"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(app.staticTexts["自动续订已开启"].waitForExistence(timeout: 10))
        let nextRenewal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "年费下次续费日期 ")).firstMatch
        XCTAssertTrue(nextRenewal.exists)
        let annualPlan = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "一年高级版")).firstMatch
        XCTAssertFalse(annualPlan.isEnabled, "An active annual subscriber must not buy another annual term")
        let lifetimeBuy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "购买永久高级版")).firstMatch
        reveal(lifetimeBuy, in: app)
        tapWhenStable(lifetimeBuy)
        let disclosure = app.alerts["永久高级版"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.staticTexts["购买永久版不会自动取消年费，请在购买后前往苹果订阅管理取消续订，避免重复扣费。"].exists)
        disclosure.buttons["取消"].tap()
        XCTAssertTrue(lifetimeBuy.isEnabled)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").otherElements["payment-sheet"].exists)

        tapWhenStable(lifetimeBuy)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.buttons["继续购买"].tap()
        confirmLocalPurchase()
        let followup = app.staticTexts["永久版已生效。请管理原年费订阅，确认关闭自动续订。"]
        XCTAssertTrue(followup.waitForExistence(timeout: 10), app.debugDescription)
        dismissPurchaseCompletion()
        XCTAssertTrue(app.staticTexts["自动续订已开启"].exists)
        XCTAssertFalse(lifetimeBuy.exists)
        XCTAssertTrue(app.buttons["premium-close"].exists, "Keep the management page open after upgrading")
        attachScreenshot(app, name: "annual-to-lifetime-cancellation-guidance")

        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["高级版"].waitForExistence(timeout: 10))
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(followup.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["自动续订已开启"].exists)
        XCTAssertTrue(nextRenewal.exists)
        XCTAssertFalse(lifetimeBuy.exists)
        attachScreenshot(app, name: "annual-management-after-lifetime-cold-launch")

        cancelAnnualRenewalOnApplePage(app, manageLabel: "管理订阅")
        XCTAssertTrue(app.staticTexts["自动续订已关闭"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["永久高级版"].exists)
        XCTAssertFalse(followup.exists, "Stop asking to cancel only after Apple confirms renewal is off")
        XCTAssertFalse(nextRenewal.exists)
        XCTAssertFalse(annualPlan.exists)
        XCTAssertFalse(lifetimeBuy.exists)
        attachScreenshot(app, name: "lifetime-after-cancelling-annual-renewal")

        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["高级版"].waitForExistence(timeout: 10))
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(app.staticTexts["自动续订已关闭"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["永久高级版"].exists)
        XCTAssertFalse(followup.exists)
        XCTAssertFalse(nextRenewal.exists)
        XCTAssertFalse(annualPlan.exists)
        XCTAssertFalse(lifetimeBuy.exists)
        attachScreenshot(app, name: "lifetime-and-cancelled-annual-after-relaunch")
    }

    func testAppleSubscriptionManagementCancelsRenewalAndKeepsPaidTerm() {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "en"]
        addTeardownBlock { app.terminate() }
        app.launch()
        openSettings(app)
        let unlock = app.buttons["Unlock Pro"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        tapWhenStable(unlock)
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Buy Annual Pro")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 10))
        reveal(buy, in: app)
        tapWhenStable(buy)
        confirmLocalPurchase()
        XCTAssertTrue(app.buttons["Pro"].waitForExistence(timeout: 10))
        dismissPurchaseCompletion()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["premium-close"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)

        let manage = app.buttons["Manage subscription"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(app.staticTexts["Auto-renewal is on"].waitForExistence(timeout: 10))
        cancelAnnualRenewalOnApplePage(app, manageLabel: "Manage subscription")
        XCTAssertTrue(app.staticTexts["Auto-renewal is off"].waitForExistence(timeout: 10), app.debugDescription)
        let validUntil = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Valid until ")).firstMatch
        XCTAssertTrue(validUntil.exists)
        let paidUntilDate = String(validUntil.label.dropFirst("Valid until ".count))
        XCTAssertTrue(app.buttons["Pro"].exists, "Cancellation keeps the already-paid annual term")
        attachScreenshot(app, name: "annual-cancellation-return-keeps-paid-term")
        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["Pro"].waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(app.staticTexts["Auto-renewal is off"].waitForExistence(timeout: 10))
        XCTAssertTrue(validUntil.exists)
        attachScreenshot(app, name: "annual-cancellation-after-relaunch")

        let panel = app.scrollViews["premium-purchase-panel"]
        let systemManage = panel.buttons["Manage subscription"]
        revealFully(systemManage, in: panel, app: app)
        tapWhenStable(systemManage)
        let applePage = app.webViews["AMS.WebPage"]
        let annualOption = applePage.staticTexts["一年高级版 (1年)"]
        XCTAssertTrue(annualOption.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(applePage.staticTexts["Select an option to resubscribe."].exists)
        attachScreenshot(app, name: "apple-cancelled-subscription-before-reenable")
        tapWhenStable(annualOption)
        confirmLocalPurchase()
        // The resubscribe completion is attached to the presented management
        // controller in the App, unlike the initial SpringBoard purchase.
        let success = app.alerts["You’re all set."]
        XCTAssertTrue(success.waitForExistence(timeout: 10), app.debugDescription)
        success.buttons["OK"].tap()
        // A system success alert temporarily hides the management page from
        // the App's accessibility tree. Dismiss it before waiting for the page;
        // transient absence is not proof that the sheet has closed.
        XCTAssertTrue(applePage.staticTexts["Cancel Subscription"].waitForExistence(timeout: 30), app.debugDescription)
        attachScreenshot(app, name: "apple-subscription-reenabled")
        let done = app.navigationBars["AMSUIEngagementView"].buttons["right_bar_button_item"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        tapWhenStable(done)
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !applePage.exists && panel.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["Auto-renewal is on"].waitForExistence(timeout: 10), app.debugDescription)
        let nextRenewal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Annual renewal on ")).firstMatch
        XCTAssertTrue(nextRenewal.exists)
        XCTAssertEqual(nextRenewal.label, "Annual renewal on \(paidUntilDate)")
        XCTAssertFalse(validUntil.exists)
        XCTAssertFalse(app.staticTexts["Auto-renewal is off"].exists)
        XCTAssertTrue(app.buttons["Pro"].exists)
        revealFully(nextRenewal, in: panel, app: app, scrollDown: true)
        attachScreenshot(app, name: "annual-reenabled-return")
        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["Pro"].waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(app.staticTexts["Auto-renewal is on"].waitForExistence(timeout: 10))
        XCTAssertTrue(nextRenewal.exists)
        XCTAssertEqual(nextRenewal.label, "Annual renewal on \(paidUntilDate)")
        XCTAssertFalse(validUntil.exists)
        attachScreenshot(app, name: "annual-reenabled-after-relaunch")
    }

    private func cancelAnnualRenewalOnApplePage(_ app: XCUIApplication, manageLabel: String) {
        let panel = app.scrollViews["premium-purchase-panel"]
        let systemManage = panel.buttons[manageLabel]
        revealFully(systemManage, in: panel, app: app)
        tapWhenStable(systemManage)
        // Apple's local management sheet exposes this web action as text,
        // not an accessibility button. Scope it to the actual system page.
        let applePage = app.webViews["AMS.WebPage"]
        let cancel = applePage.staticTexts["Cancel Subscription"]
        let canCancel = cancel.waitForExistence(timeout: 30)
        attachScreenshot(app, name: "apple-subscription-management-before-cancel")
        XCTAssertTrue(canCancel, app.debugDescription)
        XCTAssertTrue(applePage.staticTexts["ZTransfer Pro"].exists)
        XCTAssertTrue(applePage.staticTexts["一年高级版"].exists)
        // Both callers check Apple's explicit Xcode/no-charge confirmation
        // before buying; cancel only the annual product shown on this page.
        tapWhenStable(cancel)
        let confirmation = app.alerts["Confirm Cancellation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        confirmation.buttons["Confirm"].tap()
        attachScreenshot(app, name: "apple-subscription-management-cancelled")
        // In the Xcode management page the close action is titled Cancel,
        // distinct from the Cancel Subscription action in the web content.
        let done = app.navigationBars["AMSUIEngagementView"].buttons["right_bar_button_item"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        done.tap()
    }

    private func confirmLocalPurchase() {
        // The confirmation belongs to SpringBoard. Never confirm a real
        // payment if this runner was launched without its local fixture.
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let sheet = system.otherElements["payment-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.staticTexts["Xcode"].exists)
        // Resubscribing prepends an immediate-change notice to this same
        // text element. Still require Apple's complete no-charge statement.
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "For testing purposes only. You will not be charged for confirming this purchase.")).firstMatch.exists)
        sheet.buttons["footer"].tap()
    }

    func testFreeWorkbenchLocksWatermarkButAllowsFiltersAndFrames() {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "en"]
        addTeardownBlock { app.terminate() }
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["Unlock Pro"].waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()
        app.launch()

        let workspace = app.buttons["Filter · Frame · Watermark"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), app.debugDescription)
        tapWhenStable(workspace)
        let filter = app.buttons["Photo filter"]
        revealEffectsControl(filter, in: app)
        let originalFilter = filter.value as? String
        tapWhenStable(filter)
        XCTAssertNotEqual(filter.value as? String, originalFilter)
        let selectedFilter = filter.value as? String

        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app)
        let originalFrame = frame.value as? String
        tapWhenStable(frame)
        XCTAssertNotEqual(frame.value as? String, originalFrame)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        let selectedFrame = frame.value as? String
        XCTAssertNotEqual(selectedFrame, "Off")

        verifyFreeWatermarkControls(app)
        attachScreenshot(app, name: "free-workbench-watermark-locked")

        // The free choices persist without turning a locked default watermark
        // into an editable preference when the actual App is relaunched.
        app.terminate()
        app.launch()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        tapWhenStable(workspace)
        revealEffectsControl(filter, in: app)
        XCTAssertEqual(filter.value as? String, selectedFilter)
        revealEffectsControl(frame, in: app)
        XCTAssertEqual(frame.value as? String, selectedFrame)
        verifyFreeWatermarkControls(app)
        attachScreenshot(app, name: "free-workbench-watermark-after-relaunch")
    }

    func testPurchasedWorkbenchEditsAndPersistsTextWatermark() {
        let app = purchaseLifetimeAndRelaunch()

        let workspace = app.buttons["Filter · Frame · Watermark"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        tapWhenStable(workspace)
        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        let watermark = app.buttons["Watermark"]
        revealEffectsControl(watermark, in: app)
        if watermark.value as? String == "Off" { tapWhenStable(watermark) }
        XCTAssertEqual(watermark.value as? String, "On")
        tapWhenStable(watermark)
        XCTAssertEqual(watermark.value as? String, "Off")
        tapWhenStable(watermark)
        XCTAssertEqual(watermark.value as? String, "On")

        let settings = app.buttons.matching(NSPredicate(format: "value == %@", "Watermark settings")).firstMatch
        tapWhenStable(settings)
        let type = app.buttons["Watermark type"]
        revealEffectsControl(type, in: app)
        if type.value as? String == "Logo" { tapWhenStable(type) }
        XCTAssertEqual(type.value as? String, "Text")
        let text = app.textFields.firstMatch
        revealEffectsControl(text, in: app)
        XCTAssertTrue(text.isEnabled)
        replaceWatermarkText(text, with: "UI PRO TEST", in: app)

        let names = ["Font", "Size", "Opacity", "Position", "Color", "Legibility"]
        var savedValues: [String: String] = [:]
        for name in names {
            let control = app.buttons[name]
            revealEffectsControl(control, in: app)
            XCTAssertTrue(control.isEnabled)
            let before = control.value as? String
            tapWhenStable(control)
            XCTAssertNotEqual(control.value as? String, before)
            savedValues[name] = control.value as? String
            XCTAssertNotNil(savedValues[name])
        }
        XCTAssertFalse(app.staticTexts["Available in Pro only"].exists)
        attachScreenshot(app, name: "purchased-workbench-text-watermark-edited")

        app.terminate()
        app.launch()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        tapWhenStable(workspace)
        revealEffectsControl(settings, in: app)
        tapWhenStable(settings)
        revealEffectsControl(text, in: app)
        XCTAssertTrue(text.isEnabled)
        XCTAssertEqual(text.value as? String, "UI PRO TEST")
        for name in names {
            let control = app.buttons[name]
            revealEffectsControl(control, in: app)
            XCTAssertTrue(control.isEnabled)
            XCTAssertEqual(control.value as? String, savedValues[name])
        }
        attachScreenshot(app, name: "purchased-workbench-text-watermark-after-relaunch")
    }

    private func replaceWatermarkText(_ text: XCUIElement, with value: String, in app: XCUIApplication) {
        let previousText = text.value as? String ?? ""
        tapWhenStable(text)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let visibleWhileEditing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            text.isHittable && !text.frame.intersects(keyboard.frame)
        }, object: nil)
        let visibleResult = XCTWaiter.wait(for: [visibleWhileEditing], timeout: 10)
        attachScreenshot(app, name: "watermark-text-above-keyboard")
        XCTAssertEqual(visibleResult, .completed, "Focused watermark must remain visible above the keyboard")
        if !previousText.isEmpty {
            // A tap may put the caret in the middle of an existing value.
            text.press(forDuration: 1)
            let selectAll = app.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", ["Select All", "全选", "全選"])
            ).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), app.debugDescription)
            tapWhenStable(selectAll)
        }
        text.typeText(value + "\n")
        let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !keyboard.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
        XCTAssertEqual(text.value as? String, value)
    }

    private func purchaseLifetimeAndRelaunch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "en"]
        addTeardownBlock { app.terminate() }
        app.launch()
        openSettings(app)
        let unlock = app.buttons["Unlock Pro"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        tapWhenStable(unlock)
        let lifetime = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Lifetime Pro")).firstMatch
        XCTAssertTrue(lifetime.waitForExistence(timeout: 10))
        tapWhenStable(lifetime)
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Buy Lifetime Pro")).firstMatch
        reveal(buy, in: app)
        tapWhenStable(buy)
        confirmLocalPurchase()
        XCTAssertTrue(app.buttons["Pro"].waitForExistence(timeout: 10), app.debugDescription)
        dismissPurchaseCompletion()
        app.terminate()
        app.launch()
        return app
    }

    func testPurchasedWorkbenchImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch() {
        verifyImageWatermarkImport(inCameraSettings: false)
    }

    func testPurchasedCameraImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch() {
        verifyImageWatermarkImport(inCameraSettings: true)
    }

    private func verifyImageWatermarkImport(inCameraSettings: Bool) {
        let app = purchaseLifetimeAndRelaunch()
        let workspace = app.buttons["Filter · Frame · Watermark"].firstMatch
        func openEditor() -> XCUIElement? {
            if inCameraSettings { return openCameraEffects(app, expectPro: true) }
            XCTAssertTrue(workspace.waitForExistence(timeout: 10))
            tapWhenStable(workspace)
            return nil
        }
        var panel = openEditor()
        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app, scrollView: panel)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        let watermark = app.buttons["Watermark"]
        revealEffectsControl(watermark, in: app, scrollView: panel)
        if watermark.value as? String == "Off" { tapWhenStable(watermark) }
        XCTAssertEqual(watermark.value as? String, "On")
        let settings = app.buttons.matching(NSPredicate(format: "value == %@", "Watermark settings")).firstMatch
        revealEffectsControl(settings, in: app, scrollView: panel)
        tapWhenStable(settings)
        let type = app.buttons["Watermark type"]
        revealEffectsControl(type, in: app, scrollView: panel)
        let replace = app.buttons["Replace logo"]
        if type.value as? String != "Logo" { tapWhenStable(type) }
        // Without a stored logo the type wheel opens the picker directly.
        // With one, explicitly replace it so every run exercises real import.
        if replace.waitForExistence(timeout: 2), replace.isHittable {
            tapWhenStable(replace)
        } else {
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
            tapWhenStable(cancel)
            XCTAssertEqual(type.value as? String, "Text")
            XCTAssertTrue(type.staticTexts["Text"].exists,
                          "Cancelling the first logo picker must restore the visible wheel to Text")
            attachScreenshot(app, name: "first-logo-picker-cancel-keeps-text")
            tapWhenStable(type)
        }
        selectFirstSystemPhoto(app)
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            type.exists && type.value as? String == "Logo" && replace.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 10), .completed, app.debugDescription)
        if inCameraSettings {
            // Android saves a successful logo import immediately, even if
            // the app is killed before the editor is explicitly dismissed.
            app.terminate()
            app.launch()
            panel = openEditor()
            revealEffectsControl(settings, in: app, scrollView: panel)
            tapWhenStable(settings)
            revealEffectsControl(type, in: app, scrollView: panel)
            XCTAssertEqual(type.value as? String, "Logo")
            XCTAssertTrue(replace.isEnabled)
            attachScreenshot(app, name: "camera-logo-import-saved-before-dismissal")
        }
        XCTAssertFalse(app.textFields.firstMatch.exists)
        XCTAssertFalse(app.buttons["Font"].exists)
        XCTAssertFalse(app.buttons["Color"].exists)
        XCTAssertFalse(app.buttons["Legibility"].exists)
        let names = ["Size", "Opacity", "Position"]
        var savedValues: [String: String] = [:]
        for name in names {
            let control = app.buttons[name]
            revealEffectsControl(control, in: app, scrollView: panel)
            XCTAssertTrue(control.isEnabled)
            let before = control.value as? String
            tapWhenStable(control)
            XCTAssertNotEqual(control.value as? String, before)
            savedValues[name] = control.value as? String
            XCTAssertNotNil(savedValues[name])
        }
        XCTAssertFalse(app.staticTexts["Available in Pro only"].exists)
        revealEffectsControl(replace, in: app, scrollView: panel)
        tapWhenStable(replace)
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        tapWhenStable(cancel)
        XCTAssertEqual(type.value as? String, "Logo")
        for name in names { XCTAssertEqual(app.buttons[name].value as? String, savedValues[name]) }
        attachScreenshot(app, name: inCameraSettings ? "camera-image-watermark-after-cancel" : "purchased-workbench-image-watermark-after-cancel")
        if inCameraSettings {
            // Later style edits remain an editor draft until leaving it.
            tapWhenStable(app.buttons["chevron.left"])
            XCTAssertTrue(app.buttons["Pro"].waitForExistence(timeout: 5))
        }

        app.terminate()
        app.launch()
        panel = openEditor()
        revealEffectsControl(settings, in: app, scrollView: panel)
        tapWhenStable(settings)
        revealEffectsControl(type, in: app, scrollView: panel)
        XCTAssertEqual(type.value as? String, "Logo")
        XCTAssertTrue(replace.isEnabled)
        for name in names {
            let control = app.buttons[name]
            revealEffectsControl(control, in: app, scrollView: panel)
            XCTAssertTrue(control.isEnabled)
            XCTAssertEqual(control.value as? String, savedValues[name])
        }
        attachScreenshot(app, name: inCameraSettings ? "camera-image-watermark-after-relaunch" : "purchased-workbench-image-watermark-after-relaunch")
    }

    private func selectFirstSystemPhoto(_ app: XCUIApplication) {
        selectSystemPhotos(app, count: 1)
    }

    private func selectSystemPhotos(_ app: XCUIApplication, count: Int) {
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        // After resetting Photos privacy, its remote accessibility grid can
        // arrive later than the visible sheet. Wait for the real image node.
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertGreaterThanOrEqual(photos.count, count)
        attachScreenshot(app, name: "system-photo-picker-before-selection")
        // This OS exposes the photo's visible bounds but reports no hit point
        // for its accessibility Image. Touch its verified on-screen center.
        for index in 0..<count {
            let photo = photos.element(boundBy: index)
            XCTAssertTrue(app.frame.contains(photo.frame), app.debugDescription)
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let add = app.buttons["Add"].firstMatch
        if count > 1 {
            XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
            attachScreenshot(app, name: "system-photo-picker-multiple-selected")
        }
        if add.waitForExistence(timeout: 2), add.isHittable { tapWhenStable(add) }
    }

    func testFreeWorkbenchSavesPhotoThroughSystemAuthorization() {
        verifyWorkbenchPhotoSave(allow: true)
    }

    func testFreeWorkbenchSavesTwoPhotosThroughSystemAuthorization() {
        verifyWorkbenchPhotoSave(allow: true, count: 2)
    }

    func testWorkbenchDeniedPhotoSaveReportsFailureAndCanRetry() {
        verifyWorkbenchPhotoSave(allow: false)
    }

    private func verifyWorkbenchPhotoSave(allow: Bool, count: Int = 1) {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "en"]
        addTeardownBlock {
            // A failed run can leave the system sheet alive after the App
            // exits. Dismiss only our known request, so the next run cannot
            // have XCTest's default handler silently grant this old request.
            let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if prompt.staticTexts["用于保存工作台生成的效果图"].exists {
                prompt.buttons.matching(NSPredicate(format: "label IN %@",
                    ["Don’t Allow", "Don't Allow", "不允许", "不允許"])).firstMatch.tap()
            }
            app.terminate()
        }
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["Unlock Pro"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        let workbench = app.buttons["Filter · Frame · Watermark"].firstMatch
        XCTAssertTrue(workbench.waitForExistence(timeout: 10))
        tapWhenStable(workbench)
        if count > 1 {
            let filter = app.buttons["Photo filter"]
            revealEffectsControl(filter, in: app)
            if filter.value as? String == "Off" { tapWhenStable(filter) }
            XCTAssertNotEqual(filter.value as? String, "Off")
        }
        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        let watermark = app.buttons["Watermark"]
        revealEffectsControl(watermark, in: app)
        XCTAssertEqual(watermark.value as? String, "On")
        // The lock overlay remains tappable to explain the Pro restriction;
        // validate its behavior instead of the composite accessibility flag.
        tapLockedEffectsControl(watermark, in: app)
        XCTAssertEqual(watermark.value as? String, "On")
        let choose = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose photo")).firstMatch
        revealEffectsControl(choose, in: app)
        tapWhenStable(choose)
        selectSystemPhotos(app, count: count)
        let generate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Generate and save (\(count))")).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10), app.debugDescription)
        revealEffectsControl(generate, in: app)
        tapWhenStable(generate)

        // The script resets only this test App's Photos permissions. Require
        // the actual system authorization prompt, never a pre-granted shortcut.
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = system.alerts.firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), system.debugDescription)
        XCTAssertTrue(prompt.staticTexts["用于保存工作台生成的效果图"].exists,
                      "Only respond to this App's add-photos permission request")
        attachScreenshot(system, name: "system-add-photos-authorization")
        let label = allow ? ["Allow", "允许", "允許", "Allow Adding Photos", "允许添加照片", "允許加入照片"]
                          : ["Don’t Allow", "Don't Allow", "不允许", "不允許"]
        let response = prompt.buttons.matching(NSPredicate(format: "label IN %@", label)).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 5), system.debugDescription)
        tapWhenStable(response)
        // The terminal label belongs to the disabled batch button. SwiftUI
        // exposes it as the button's label, not a separate StaticText node.
        let result = app.buttons[allow ? "Saved \(count) photos" : "Generation failed"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
        if !allow {
            XCTAssertTrue(app.staticTexts["1 photos could not be saved. Originals are unchanged."].exists)
        }
        attachScreenshot(app, name: allow ? "photo-save-complete" : "photo-save-denied")
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in generate.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["Replace photo"].exists, app.debugDescription)
        if !allow {
            tapWhenStable(generate)
            XCTAssertTrue(app.buttons["Generation failed"].waitForExistence(timeout: 10))
            XCTAssertFalse(system.alerts.firstMatch.exists, "A denied permission must not be requested repeatedly")
            attachScreenshot(app, name: "photo-save-denied-retry")
        }
    }

    func testFreeCameraEffectsKeepWatermarkLockedAndSaveFreeChoices() {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "en"]
        addTeardownBlock { app.terminate() }
        app.launch()
        var panel = openCameraEffects(app, expectPro: false)
        let filter = app.buttons["Photo filter"]
        revealEffectsControl(filter, in: app, scrollView: panel)
        let previousFilter = filter.value as? String
        tapWhenStable(filter)
        XCTAssertNotEqual(filter.value as? String, previousFilter)
        let savedFilter = filter.value as? String
        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app, scrollView: panel)
        let previousFrame = frame.value as? String
        tapWhenStable(frame)
        XCTAssertNotEqual(frame.value as? String, previousFrame)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        let savedFrame = frame.value as? String
        verifyFreeWatermarkControls(app, scrollView: panel)
        attachScreenshot(app, name: "free-camera-effects-locked")
        // Android saves the draft on returning to main settings; this is not
        // a discard/cancel action. Exercise that actual route before relaunch.
        tapWhenStable(app.buttons["chevron.left"])
        XCTAssertTrue(app.buttons["Unlock Pro"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        panel = openCameraEffects(app, expectPro: false)
        revealEffectsControl(filter, in: app, scrollView: panel)
        XCTAssertEqual(filter.value as? String, savedFilter)
        revealEffectsControl(frame, in: app, scrollView: panel)
        XCTAssertEqual(frame.value as? String, savedFrame)
        verifyFreeWatermarkControls(app, scrollView: panel)
        attachScreenshot(app, name: "free-camera-effects-after-relaunch")
    }

    func testPurchasedCameraEffectsSaveTextWatermarkWhenPopupCloses() {
        let app = purchaseLifetimeAndRelaunch()
        var panel = openCameraEffects(app, expectPro: true)
        let frame = app.buttons["Frame"]
        revealEffectsControl(frame, in: app, scrollView: panel)
        if frame.value as? String == "Off" { tapWhenStable(frame) }
        let watermark = app.buttons["Watermark"]
        revealEffectsControl(watermark, in: app, scrollView: panel)
        if watermark.value as? String == "Off" { tapWhenStable(watermark) }
        XCTAssertEqual(watermark.value as? String, "On")
        let settings = app.buttons.matching(NSPredicate(format: "value == %@", "Watermark settings")).firstMatch
        revealEffectsControl(settings, in: app, scrollView: panel)
        tapWhenStable(settings)
        let type = app.buttons["Watermark type"]
        revealEffectsControl(type, in: app, scrollView: panel)
        if type.value as? String == "Logo" { tapWhenStable(type) }
        XCTAssertEqual(type.value as? String, "Text")
        let text = app.textFields.firstMatch
        revealEffectsControl(text, in: app, scrollView: panel)
        XCTAssertTrue(text.isEnabled)
        replaceWatermarkText(text, with: "CAMERA PRO TEST", in: app)
        let names = ["Font", "Size", "Opacity", "Position", "Color", "Legibility"]
        var savedValues: [String: String] = [:]
        for name in names {
            let control = app.buttons[name]
            revealEffectsControl(control, in: app, scrollView: panel)
            XCTAssertTrue(control.isEnabled)
            let before = control.value as? String
            tapWhenStable(control)
            XCTAssertNotEqual(control.value as? String, before)
            savedValues[name] = control.value as? String
            XCTAssertNotNil(savedValues[name])
        }
        XCTAssertFalse(app.staticTexts["Available in Pro only"].exists)
        attachScreenshot(app, name: "purchased-camera-effects-edited")
        // Android saves on outside dismissal as well as the internal back
        // button. Derive the backdrop tap from the actual popup bounds.
        let popup = app.otherElements["popup-panel-settings"]
        let bounds = popup.frame
        let appBounds = app.frame
        let triggerBottom = app.buttons["popup-trigger-settings"].frame.maxY
        XCTAssertLessThan(triggerBottom, bounds.minY)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: bounds.midX - appBounds.minX,
            dy: (triggerBottom + bounds.minY) / 2 - appBounds.minY
        )).tap()
        // The animation host stays mounted when closed; its content must no
        // longer be exposed or interactive, rather than the host being removed.
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !frame.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        for relaunch in [false, true] {
            if relaunch {
                app.terminate()
                app.launch()
                panel = openCameraEffects(app, expectPro: true)
            } else {
                panel = openCameraEffectsFromPhotoList(app, expectPro: true)
            }
            revealEffectsControl(settings, in: app, scrollView: panel)
            tapWhenStable(settings)
            revealEffectsControl(text, in: app, scrollView: panel)
            XCTAssertTrue(text.isEnabled)
            XCTAssertEqual(text.value as? String, "CAMERA PRO TEST")
            for name in names {
                let control = app.buttons[name]
                revealEffectsControl(control, in: app, scrollView: panel)
                XCTAssertTrue(control.isEnabled)
                XCTAssertEqual(control.value as? String, savedValues[name])
            }
            attachScreenshot(app, name: relaunch ? "purchased-camera-effects-after-relaunch" : "purchased-camera-effects-after-dismissal")
        }
    }

    private func openCameraEffects(_ app: XCUIApplication, expectPro: Bool) -> XCUIElement {
        let camera = app.buttons["debug-photo-library"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        tapWhenStable(camera)
        XCTAssertTrue(app.buttons["popup-trigger-filter"].waitForExistence(timeout: 10))
        return openCameraEffectsFromPhotoList(app, expectPro: expectPro)
    }

    private func openCameraEffectsFromPhotoList(_ app: XCUIApplication, expectPro: Bool) -> XCUIElement {
        openSettings(app)
        XCTAssertTrue(app.buttons[expectPro ? "Pro" : "Unlock Pro"].waitForExistence(timeout: 10))
        let title = "Filter · Frame · Watermark"
        let entry = app.staticTexts[title].firstMatch
        let mainPanel = app.scrollViews.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(mainPanel.waitForExistence(timeout: 5), app.debugDescription)
        revealEffectsControl(entry, in: app, scrollView: mainPanel)
        tapWhenStable(entry)
        let editor = app.scrollViews.containing(.button, identifier: "Frame").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        return editor
    }

    private func verifyFreeWatermarkControls(_ app: XCUIApplication, scrollView: XCUIElement? = nil) {
        let watermark = app.buttons["Watermark"]
        revealEffectsControl(watermark, in: app, scrollView: scrollView)
        XCTAssertEqual(watermark.value as? String, "On")
        tapLockedEffectsControl(watermark, in: app, scrollView: scrollView)
        XCTAssertEqual(watermark.value as? String, "On")

        let settings = app.buttons.matching(NSPredicate(format: "value == %@", "Watermark settings")).firstMatch
        revealEffectsControl(settings, in: app, scrollView: scrollView)
        tapWhenStable(settings)
        let text = app.textFields.matching(NSPredicate(format: "value == %@", "ZTransfer")).firstMatch
        revealEffectsControl(text, in: app, scrollView: scrollView)
        XCTAssertFalse(text.isEnabled)
        // Touch the disabled editor's overlay, as a user would. Calling the
        // stable enabled-button helper here would avoid the very lock tested.
        tapLockedEffectsControl(text, in: app, scrollView: scrollView)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(text.value as? String, "ZTransfer")

        let type = app.buttons["Watermark type"]
        XCTAssertEqual(type.value as? String, "Text")
        tapLockedEffectsControl(type, in: app, scrollView: scrollView)
        XCTAssertEqual(type.value as? String, "Text", "Free users cannot switch to an image watermark")
        let size = app.buttons["Size"]
        revealEffectsControl(size, in: app, scrollView: scrollView)
        XCTAssertEqual(size.value as? String, "80%")
        XCTAssertEqual(app.buttons["Opacity"].value as? String, "80%")
        for name in ["Font", "Size", "Opacity", "Position", "Color", "Legibility"] {
            let control = app.buttons[name]
            revealEffectsControl(control, in: app, scrollView: scrollView)
            XCTAssertFalse(control.isEnabled)
            let originalValue = control.value as? String
            XCTAssertNotNil(originalValue)
            tapLockedEffectsControl(control, in: app, scrollView: scrollView)
            XCTAssertEqual(control.value as? String, originalValue)
        }
    }

    private func revealEffectsControl(_ element: XCUIElement, in app: XCUIApplication, scrollView: XCUIElement? = nil) {
        let surface = scrollView ?? app
        var visibleFrame = surface.frame.intersection(app.frame)
        let popup = app.otherElements["popup-panel-settings"]
        if scrollView != nil, popup.exists {
            // The scroll view extends beyond the popup's interactive bounds.
            // Its own trailing gutter can therefore hit the backdrop instead.
            visibleFrame = visibleFrame.intersection(popup.frame)
        }
        let viewport = visibleFrame.insetBy(dx: scrollView == nil ? 10 : 1, dy: scrollView == nil ? 24 : 1)
        for _ in 0..<6 {
            if element.exists, viewport.contains(element.frame), element.isHittable { return }
            let down = element.exists && element.frame.minY < viewport.minY
            // The editor contains vertical wheels across its center. Scroll
            // the page gutter so this gesture cannot modify another setting.
            let gutterX = scrollView == nil ? 0.98 : (visibleFrame.maxX - 8 - surface.frame.minX) / surface.frame.width
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: gutterX, dy: down ? 0.3 : 0.8))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: gutterX, dy: down ? 0.8 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        attachScreenshot(app, name: "unreachable-effects-control")
        XCTFail("Editor control is not fully visible: \(element)\n\(app.debugDescription)")
    }

    private func tapLockedEffectsControl(_ element: XCUIElement, in app: XCUIApplication, scrollView: XCUIElement? = nil) {
        revealEffectsControl(element, in: app, scrollView: scrollView)
        let hint = app.staticTexts["Available in Pro only"]
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !hint.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 4), .completed,
                       "Wait for the previous hint so this tap must produce a new one")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(hint.waitForExistence(timeout: 2), app.debugDescription)
    }

    func testPurchasePageLayoutInAllLanguages() {
        let copies = [
            (language: "zh-Hans", unlock: "解锁高级版", annual: "一年高级版", lifetime: "永久高级版",
             restore: "恢复购买", redeem: "兑换优惠码", terms: "年费每年扣费一次", buy: "购买一年高级版"),
            (language: "zh-Hant", unlock: "解鎖高級版", annual: "一年高級版", lifetime: "永久高級版",
             restore: "恢復購買", redeem: "兌換優惠碼", terms: "年費每年扣費一次", buy: "購買一年高級版"),
            (language: "en", unlock: "Unlock Pro", annual: "Annual Pro", lifetime: "Lifetime Pro",
             restore: "Restore purchases", redeem: "Redeem offer code", terms: "Annual Pro is billed once a year", buy: "Buy Annual Pro")
        ]
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        for copy in copies {
            app.launchArguments = ["-app_language", copy.language]
            app.launch()
            openSettings(app)
            let unlock = app.buttons[copy.unlock]
            XCTAssertTrue(unlock.waitForExistence(timeout: 10), app.debugDescription)
            tapWhenStable(unlock)
            let panel = app.scrollViews["premium-purchase-panel"]
            XCTAssertTrue(panel.waitForExistence(timeout: 10))
            XCTAssertTrue(app.frame.contains(panel.frame), "The scroll viewport must fit the screen: \(panel.frame)")
            revealFully(panel.buttons["premium-close"], in: panel, app: app, scrollDown: true)
            attachScreenshot(app, name: "premium-layout-\(copy.language)-top")

            let annual = panel.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", copy.annual)).firstMatch
            revealFully(annual, in: panel, app: app)
            XCTAssertTrue(annual.isEnabled)
            XCTAssertTrue(annual.label.contains("39.99"), annual.label)
            XCTAssertTrue(annual.label.contains("3.33"), annual.label)
            let lifetime = panel.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", copy.lifetime)).firstMatch
            revealFully(lifetime, in: panel, app: app)
            XCTAssertTrue(lifetime.isEnabled)
            XCTAssertTrue(lifetime.label.contains("99.99"), lifetime.label)
            attachScreenshot(app, name: "premium-layout-\(copy.language)-plans")

            let terms = panel.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", copy.terms)).firstMatch
            revealFully(terms, in: panel, app: app)
            let buy = panel.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", copy.buy)).firstMatch
            revealFully(buy, in: panel, app: app)
            XCTAssertTrue(buy.isEnabled)
            let restore = panel.buttons[copy.restore]
            let redeem = panel.buttons[copy.redeem]
            revealFully(restore, in: panel, app: app)
            revealFully(redeem, in: panel, app: app)
            XCTAssertLessThanOrEqual(restore.frame.maxX, redeem.frame.minX + 1)
            attachScreenshot(app, name: "premium-layout-\(copy.language)-actions")

            let close = panel.buttons["premium-close"]
            revealFully(close, in: panel, app: app, scrollDown: true)
            tapWhenStable(close)
            XCTAssertTrue(unlock.waitForExistence(timeout: 5))
            XCTAssertFalse(panel.exists)
            app.terminate()
        }
    }

    private func revealFully(_ element: XCUIElement, in panel: XCUIElement,
                             app: XCUIApplication, scrollDown: Bool = false) {
        for _ in 0..<8 {
            if element.exists, element.isHittable, panel.frame.insetBy(dx: -1, dy: -1).contains(element.frame) {
                XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(element.frame), app.debugDescription)
                return
            }
            if scrollDown { panel.swipeDown() } else { panel.swipeUp() }
        }
        attachScreenshot(app, name: "premium-layout-unreachable")
        XCTFail("Control does not fit the purchase viewport: \(element)\n\(app.debugDescription)")
    }

    private func dismissPurchaseCompletion() {
        let success = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["You’re all set."]
        if success.waitForExistence(timeout: 3) { success.buttons.firstMatch.tap() }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            if element.isHittable { return }
            app.swipeUp()
        }
        attachScreenshot(app, name: "unreachable-purchase-control")
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openSettings(_ app: XCUIApplication) {
        // A previous local billing-retry test can leave Apple's notice above
        // the next App launch even after its transaction history is cleared.
        // Cancel only this explicitly identified Xcode notice; never resolve
        // billing or dismiss an unrelated system sheet on the user's behalf.
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.staticTexts["Billing Problem"].exists {
            XCTAssertTrue(system.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[Xcode]")).firstMatch.exists,
                          system.debugDescription)
            system.buttons["Cancel"].tap()
        }
        let settings = app.buttons["popup-trigger-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
    }

    private func tapWhenStable(_ element: XCUIElement) {
        var previous = CGRect.zero
        let stable = NSPredicate { _, _ in
            // Read enabled/frame from one snapshot. Separate property queries
            // each traverse the remote Photos hierarchy and can exhaust the
            // timeout before two samples, even for a stationary system button.
            guard let snapshot = try? element.snapshot(), snapshot.isEnabled, element.isHittable else { return false }
            let current = snapshot.frame
            defer { previous = current }
            return current == previous && current.width > 0
        }
        // Camera preview accessibility snapshots can take several seconds on
        // the compact simulator. Still require two identical, hittable frames.
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 10)
        if result != .completed {
            attachScreenshot(XCUIApplication(), name: "unstable-control")
        }
        XCTAssertEqual(result, .completed, "Control did not settle: \(element), last frame: \(previous)")
        element.tap()
    }
}
