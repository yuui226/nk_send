import XCTest
import StoreKitTest
import Vision

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
        let workbench = app.buttons["Filter · LUT · Frame · Watermark"].firstMatch
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
        let type = app.buttons["Type"]
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
        app.launchArguments = ["-app_language", "zh-Hans", "--trace-storekit-startup"]
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

    func testAnnualRenewalShowsDateWithoutPurchaseOptionsAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-app_language", "zh-Hans", "--trace-storekit-startup"]
        addTeardownBlock { app.terminate() }
        app.launch()
        openSettings(app)
        let unlock = app.buttons["解锁高级版"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        tapWhenStable(unlock)
        let buy = app.buttons["premium-purchase-action"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10))
        reveal(buy, in: app)
        tapWhenStable(buy)
        confirmLocalPurchase()
        XCTAssertTrue(app.buttons["高级版"].waitForExistence(timeout: 10))
        dismissPurchaseCompletion()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["premium-close"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)

        let manage = app.buttons["premium-settings-renewal"]
        let nextRenewal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "年费下次续费日期 ")).firstMatch
        for launch in 0..<2 {
            if launch > 0 {
                app.terminate()
                app.launch()
                openSettings(app)
                XCTAssertTrue(app.buttons["高级版"].waitForExistence(timeout: 10))
            }
            XCTAssertTrue(manage.waitForExistence(timeout: 10))
            XCTAssertEqual(manage.label, "续费")
            tapWhenStable(manage)
            XCTAssertTrue(nextRenewal.waitForExistence(timeout: 10))
            assertAnnualRenewalHasNoPurchaseOptions(app)
            XCTAssertTrue(app.staticTexts["续费"].exists)
            XCTAssertFalse(app.staticTexts["功能"].exists)
            let inlineManagement = app.buttons["premium-manage"]
            XCTAssertEqual(inlineManagement.frame.midY, nextRenewal.frame.midY, accuracy: 1)
            attachScreenshot(app, name: "annual-renewal-no-upgrade-launch-\(launch)")
        }

        cancelAnnualRenewalOnApplePage(app, manageLabel: "管理订阅")
        let validUntil = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "有效期至 ")).firstMatch
        XCTAssertTrue(validUntil.waitForExistence(timeout: 10))
        XCTAssertFalse(nextRenewal.exists)
        XCTAssertTrue(app.buttons["高级版"].exists)
        assertAnnualRenewalHasNoPurchaseOptions(app)
        attachScreenshot(app, name: "annual-cancelled-no-upgrade-keeps-paid-term")
    }

    private func assertAnnualRenewalHasNoPurchaseOptions(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["premium-manage"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["premium-plan-annual"].exists)
        XCTAssertFalse(app.buttons["premium-plan-lifetime"].exists)
        XCTAssertFalse(app.buttons["premium-purchase-action"].exists)
        XCTAssertFalse(app.buttons["premium-restore"].exists)
        XCTAssertFalse(app.buttons["premium-options"].exists)
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

        let manage = app.buttons["premium-settings-renewal"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Annual renewal on ")).firstMatch.waitForExistence(timeout: 10))
        assertAnnualRenewalHasNoPurchaseOptions(app)
        cancelAnnualRenewalOnApplePage(app, manageLabel: "Manage subscription")
        XCTAssertFalse(app.staticTexts["Auto-renewal is off"].exists)
        let validUntil = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Valid until ")).firstMatch
        XCTAssertTrue(validUntil.waitForExistence(timeout: 10))
        let paidUntilDate = String(validUntil.label.dropFirst("Valid until ".count))
        XCTAssertTrue(app.buttons["Pro"].exists, "Cancellation keeps the already-paid annual term")
        attachScreenshot(app, name: "annual-cancellation-return-keeps-paid-term")
        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.buttons["Pro"].waitForExistence(timeout: 10))
        tapWhenStable(manage)
        XCTAssertTrue(validUntil.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Auto-renewal is off"].exists)
        assertAnnualRenewalHasNoPurchaseOptions(app)
        attachScreenshot(app, name: "annual-cancellation-after-relaunch")

        let panel = app.descendants(matching: .any).matching(identifier: "premium-purchase-panel").firstMatch
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
        XCTAssertTrue(nextRenewal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Auto-renewal is on"].exists)
        XCTAssertEqual(nextRenewal.label, "Annual renewal on \(paidUntilDate)")
        XCTAssertFalse(validUntil.exists)
        attachScreenshot(app, name: "annual-reenabled-after-relaunch")
    }

    private func cancelAnnualRenewalOnApplePage(_ app: XCUIApplication, manageLabel: String) {
        let panel = app.descendants(matching: .any).matching(identifier: "premium-purchase-panel").firstMatch
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
        // The compact system sheet can still be sliding in when its AX
        // elements first exist. Wait for its actual confirmation to settle.
        tapWhenStable(sheet.buttons["footer"])
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

        let workspace = app.buttons["Filter · LUT · Frame · Watermark"].firstMatch
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

        let brandWasText = verifyBrandControlHasOnlyTextAndOff(app)
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
        verifyBrandControlHasOnlyTextAndOff(app, expectedInitialText: brandWasText)
        verifyFreeWatermarkControls(app)
        attachScreenshot(app, name: "free-workbench-watermark-after-relaunch")
    }

    func testPurchasedWorkbenchEditsAndPersistsTextWatermark() {
        let app = purchaseLifetimeAndRelaunch()

        let workspace = app.buttons["Filter · LUT · Frame · Watermark"].firstMatch
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
        let type = app.buttons["Type"]
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
        app.launchArguments = ["-app_language", "en", "--trace-storekit-startup"]
        addTeardownBlock { app.terminate() }
        app.launch()
        openSettings(app)
        let unlock = app.buttons["Unlock Pro"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        tapWhenStable(unlock)
        let lifetime = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Lifetime Pro")).firstMatch
        XCTAssertTrue(lifetime.waitForExistence(timeout: 10))
        let purchasePanel = app.descendants(matching: .any).matching(identifier: "premium-purchase-panel").firstMatch
        XCTAssertTrue(purchasePanel.waitForExistence(timeout: 10))
        revealFully(lifetime, in: purchasePanel, app: app)
        tapWhenStable(lifetime)
        XCTAssertTrue(lifetime.isSelected, "The lifetime plan must actually be selected before purchase")
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Buy Lifetime Pro")).firstMatch
        revealFully(buy, in: purchasePanel, app: app)
        tapWhenStable(buy)
        confirmLocalPurchase()
        // Effect tests need a completed user purchase, not delivery before
        // Apple's success acknowledgement. The immediate-exit test separately
        // exercises that earlier boundary.
        let success = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["You’re all set."]
        XCTAssertTrue(success.waitForExistence(timeout: 10))
        XCTAssertTrue(success.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "[Environment: Xcode]")).firstMatch.exists)
        success.buttons["OK"].tap()
        let delivered = app.buttons["Pro"].waitForExistence(timeout: 10)
        if !delivered {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "shared-purchase-not-delivered"
            shot.lifetime = .keepAlways
            add(shot)
            print("PURCHASE_SYSTEM_UI \(XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)")
        }
        XCTAssertTrue(delivered, app.debugDescription)
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
        let workspace = app.buttons["Filter · LUT · Frame · Watermark"].firstMatch
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
        let type = app.buttons["Type"]
        revealEffectsControl(type, in: app, scrollView: panel)
        // The unlabeled Android-style wheel exposes its option as AX value.
        let replace = app.buttons.matching(NSPredicate(format: "value == %@", "Replace logo")).firstMatch
        if type.value as? String != "Logo" { tapWhenStable(type) }
        // Without a stored logo the type wheel opens the picker directly.
        // With one, explicitly replace it so every run exercises real import.
        if replace.waitForExistence(timeout: 2), replace.isHittable {
            tapWhenStable(replace)
        } else {
            let cancel = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "Cancel", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
            cancel.tap()
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
        let cancel = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "Cancel", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        // Apple's remote picker owns this button and its animation. XCTest
        // tap performs its own hit testing; repeated full picker snapshots in
        // our app-animation helper can consume the deadline before two samples.
        cancel.tap()
        XCTAssertEqual(type.value as? String, "Logo")
        for name in names { XCTAssertEqual(app.buttons[name].value as? String, savedValues[name]) }
        attachScreenshot(app, name: inCameraSettings ? "camera-image-watermark-after-cancel" : "purchased-workbench-image-watermark-after-cancel")
        if inCameraSettings {
            // Later style edits remain an editor draft until leaving it.
            revealEffectsControl(app.buttons["photo-effects-editor-back"], in: app, scrollView: panel, scrollToTop: true)
            attachScreenshot(app, name: "camera-logo-full-preview-after-cancel")
            // Sample the same viewport after the 220 ms transition. This is
            // visual evidence, not a substitute for a pixel-ready assertion.
            Thread.sleep(forTimeInterval: 0.5)
            attachScreenshot(app, name: "camera-logo-full-preview-after-cancel-plus-500ms")
            tapWhenStable(app.buttons["photo-effects-editor-back"])
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
        if inCameraSettings {
            revealEffectsControl(app.buttons["photo-effects-editor-back"], in: app, scrollView: panel, scrollToTop: true)
            Thread.sleep(forTimeInterval: 0.5)
            attachScreenshot(app, name: "camera-logo-full-preview-after-relaunch")
        }
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

    /// The shell verifies exactly one new JPEG and unchanged originals.
    /// Permission changes happen in the real Settings UI, never in a mock
    /// authorizer or a simctl grant between the failed and successful saves.
    func testWorkbenchDeniedPhotoSaveRecoversAfterSettingsAuthorization() {
        verifyWorkbenchPhotoSave(allow: false, recoverInSettings: true)
    }

    private func verifyWorkbenchPhotoSave(allow: Bool, count: Int = 1, recoverInSettings: Bool = false) {
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
        let workbench = app.buttons["Filter · LUT · Frame · Watermark"].firstMatch
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
        // Android LocalPhotoBatchButton now separates the selection count
        // (reselect action) from the short Generate label.
        let reselect = app.buttons["Choose again (\(count))"]
        XCTAssertTrue(reselect.waitForExistence(timeout: 10), app.debugDescription)
        let generate = app.buttons["Generate"].firstMatch
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
        XCTAssertTrue(reselect.exists, app.debugDescription)
        if !allow {
            tapWhenStable(generate)
            XCTAssertTrue(app.buttons["Generation failed"].waitForExistence(timeout: 10))
            XCTAssertFalse(system.alerts.firstMatch.exists, "A denied permission must not be requested repeatedly")
            attachScreenshot(app, name: "photo-save-denied-retry")
            if recoverInSettings {
                allowPhotoAddInSystemSettings()
                let stateAfterSettings = app.state
                let lifecycle = XCTAttachment(string: "App state after changing Photos Add permission: \(stateAfterSettings.rawValue)")
                lifecycle.name = "photo-permission-return-lifecycle"
                lifecycle.lifetime = .keepAlways
                add(lifecycle)
                app.activate()
                if stateAfterSettings == .notRunning {
                    // The observed simulator TCC log explicitly terminates
                    // this App when kTCCServicePhotosAdd changes. Selection is
                    // process-local; use the real picker again after that
                    // system restart, without bypassing the new permission.
                    XCTAssertTrue(workbench.waitForExistence(timeout: 10))
                    tapWhenStable(workbench)
                    revealEffectsControl(choose, in: app)
                    tapWhenStable(choose)
                    selectSystemPhotos(app, count: count)
                }
                XCTAssertTrue(reselect.waitForExistence(timeout: 10),
                              "A surviving process must retain its batch; a system restart must allow reselection")
                XCTAssertTrue(generate.waitForExistence(timeout: 10))
                let retryReady = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in generate.isEnabled }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [retryReady], timeout: 5), .completed)
                revealEffectsControl(generate, in: app)
                tapWhenStable(generate)
                XCTAssertTrue(app.buttons["Saved \(count) photos"].waitForExistence(timeout: 15),
                              app.debugDescription)
                XCTAssertFalse(app.staticTexts["1 photos could not be saved. Originals are unchanged."].exists)
                XCTAssertFalse(system.alerts.firstMatch.exists,
                               "Settings authorization must allow saving without another permission prompt")
                attachScreenshot(app, name: "photo-save-after-settings-authorization")
            }
        }
    }

    private func allowPhotoAddInSystemSettings() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        addTeardownBlock { settings.terminate() }
        let rootNames = ["Settings", "设置", "設定"]
        // iOS 26's Settings collection cells have no accessibility label;
        // the actual Apps action is the nested button exposed by the system.
        let apps = settings.buttons["com.apple.settings.apps"]
        // Settings may restore its last subpage. Back out through its actual
        // navigation bar, then scroll its normal Apps entry into view.
        for _ in 0..<8 {
            if apps.exists, apps.isHittable { break }
            let atRoot = settings.navigationBars.matching(NSPredicate(format: "identifier IN %@", rootNames)).firstMatch.exists
            if atRoot {
                settings.swipeUp()
            } else {
                let back = settings.navigationBars.buttons.firstMatch
                XCTAssertTrue(back.waitForExistence(timeout: 3), settings.debugDescription)
                back.tap()
            }
        }
        XCTAssertTrue(apps.exists && apps.isHittable, settings.debugDescription)
        tapWhenStable(apps)
        let search = settings.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            tapWhenStable(search)
            search.typeText("Z传")
        }
        let ownApp = settings.cells.containing(.staticText, identifier: "Z传").firstMatch
        for _ in 0..<8 {
            if ownApp.exists, ownApp.isHittable { break }
            settings.swipeUp()
        }
        XCTAssertTrue(ownApp.exists && ownApp.isHittable, settings.debugDescription)
        tapWhenStable(ownApp)
        let photos = settings.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            "Photos", "照片", "相片")).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5), settings.debugDescription)
        tapWhenStable(photos)
        let addOnly = settings.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["Add Photos Only", "仅添加照片", "只添加照片", "僅加入照片", "僅新增照片"]
        )).firstMatch
        XCTAssertTrue(addOnly.waitForExistence(timeout: 5), settings.debugDescription)
        attachScreenshot(settings, name: "system-settings-photos-denied")
        tapWhenStable(addOnly)
        attachScreenshot(settings, name: "system-settings-photos-add-allowed")
        // The following production save plus filesystem verification is the
        // effective permission check; cell selection traits vary by OS.
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
        let brandWasText = verifyBrandControlHasOnlyTextAndOff(app, scrollView: panel)
        verifyFreeWatermarkControls(app, scrollView: panel)
        attachScreenshot(app, name: "free-camera-effects-locked")
        // Android saves the draft on returning to main settings; this is not
        // a discard/cancel action. Exercise that actual route before relaunch.
        revealEffectsControl(app.buttons["photo-effects-editor-back"], in: app, scrollView: panel, scrollToTop: true)
        tapWhenStable(app.buttons["photo-effects-editor-back"])
        XCTAssertTrue(app.buttons["Unlock Pro"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        panel = openCameraEffects(app, expectPro: false)
        revealEffectsControl(filter, in: app, scrollView: panel)
        XCTAssertEqual(filter.value as? String, savedFilter)
        revealEffectsControl(frame, in: app, scrollView: panel)
        XCTAssertEqual(frame.value as? String, savedFrame)
        verifyBrandControlHasOnlyTextAndOff(app, scrollView: panel, expectedInitialText: brandWasText)
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
        let type = app.buttons["Type"]
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
        // The production entry is a Button; its label is combined for AX.
        let entry = app.buttons["photo-effects-open-editor"]
        let mainPanel = app.scrollViews.containing(.button, identifier: "photo-effects-open-editor").firstMatch
        XCTAssertTrue(mainPanel.waitForExistence(timeout: 5), app.debugDescription)
        revealEffectsControl(entry, in: app, scrollView: mainPanel)
        tapWhenStable(entry)
        let editor = app.scrollViews.containing(.button, identifier: "Frame").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        return editor
    }

    /// User-approved iOS difference: the metadata control must skip the
    /// removed brand graphic, while the separate user-image Logo wheel stays.
    @discardableResult
    private func verifyBrandControlHasOnlyTextAndOff(_ app: XCUIApplication,
                                                    scrollView: XCUIElement? = nil,
                                                    expectedInitialText: Bool? = nil) -> Bool {
        let settings = app.buttons.matching(NSPredicate(format: "value == %@", "Frame settings")).firstMatch
        let text = app.buttons["Brand · Text"].firstMatch
        let off = app.buttons["Brand"].firstMatch
        let logo = app.buttons["Brand · Logo"].firstMatch
        let wasExpanded = text.exists || off.exists
        if !wasExpanded {
            revealEffectsControl(settings, in: app, scrollView: scrollView)
            tapWhenStable(settings)
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            text.exists || off.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, app.debugDescription)
        XCTAssertFalse(logo.exists, "The removed graphical brand state must not be exposed")
        let initiallyText = text.exists
        if let expectedInitialText {
            XCTAssertEqual(initiallyText, expectedInitialText, "Brand visibility must survive relaunch")
        }
        if !initiallyText {
            revealEffectsControl(off, in: app, scrollView: scrollView)
            tapWhenStable(off)
            XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        }
        revealEffectsControl(text, in: app, scrollView: scrollView)
        if scrollView != nil { waitForCameraBrandPreview(app, hasBrand: true) }
        tapWhenStable(text)
        XCTAssertTrue(off.waitForExistence(timeout: 5), "Text must switch directly to off, skipping the former logo state")
        XCTAssertFalse(logo.exists)
        if scrollView != nil { waitForCameraBrandPreview(app, hasBrand: false) }
        attachScreenshot(app, name: scrollView == nil ? "workbench-brand-off-no-graphic-option" : "camera-brand-off-no-graphic-option")
        tapWhenStable(off)
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Off must switch directly to ordinary brand text")
        XCTAssertFalse(logo.exists)
        if scrollView != nil { waitForCameraBrandPreview(app, hasBrand: true) }
        attachScreenshot(app, name: scrollView == nil ? "workbench-brand-text-no-graphic-option" : "camera-brand-text-no-graphic-option")
        // Restore the previous visible state so the existing filter/frame and
        // watermark-lock checks keep testing the same persisted preferences.
        if !initiallyText {
            tapWhenStable(text)
            XCTAssertTrue(off.waitForExistence(timeout: 5), app.debugDescription)
        }
        if !wasExpanded {
            revealEffectsControl(settings, in: app, scrollView: scrollView)
            tapWhenStable(settings)
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !text.exists && !off.exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        }
        return initiallyText
    }

    /// This Debug camera fixture renders the conspicuous model placeholder
    /// Z 233 over its real sample photo, as verified in the original captures.
    /// Require that model in the actual preview pixels, so an empty, cropped
    /// or failed OCR result can never count as a hidden-brand success.
    private func waitForCameraBrandPreview(_ app: XCUIApplication, hasBrand: Bool) {
        let deadline = Date().addingTimeInterval(20)
        var consecutiveMatches = 0
        var observations: [String] = []
        while Date() < deadline {
            let screen = app.frame
            let popup = app.otherElements["popup-panel-settings"].frame.intersection(screen)
            let filter = app.buttons["Photo filter"].firstMatch
            guard filter.exists, screen.width > 0, screen.height > 0,
                  popup.width > 0, filter.frame.minY > popup.minY else {
                observations.append("The preview region above Photo filter is not visible")
                break
            }
            let preview = CGRect(x: popup.minX, y: popup.minY,
                                 width: popup.width, height: filter.frame.minY - popup.minY)
                .intersection(screen)
            let screenshot = app.screenshot()
            guard let image = screenshot.image.cgImage else {
                observations.append("The app screenshot has no CGImage")
                break
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            // Test-only CPU recognition avoids hardware/model warm-up stalls
            // and works on the minimum iOS 16 runtime as well as simulators.
            request.usesCPUOnly = true
            // Vision uses normalized bottom-left coordinates; XCUI frames
            // use screen points from the top-left, independent of pixel scale.
            request.regionOfInterest = CGRect(
                x: (preview.minX - screen.minX) / screen.width,
                y: 1 - (preview.maxY - screen.minY) / screen.height,
                width: preview.width / screen.width,
                height: preview.height / screen.height)
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let tokens = lines.map { $0.uppercased().filter { $0.isLetter || $0.isNumber } }
                let modelVisible = tokens.contains { $0.contains("Z233") }
                let brandVisible = tokens.contains { $0.contains("NIKON") }
                observations.append("expectedBrand=\(hasBrand); model=\(modelVisible); brand=\(brandVisible); OCR=\(lines)")
                consecutiveMatches = modelVisible && brandVisible == hasBrand ? consecutiveMatches + 1 : 0
                if consecutiveMatches == 2 { return }
            } catch {
                consecutiveMatches = 0
                observations.append("OCR error: \(error)")
            }
            // This is only the OCR polling interval. Success requires two
            // observed matching frames, never merely the passage of time.
            Thread.sleep(forTimeInterval: 0.2)
        }
        attachScreenshot(app, name: hasBrand ? "camera-brand-text-preview-not-ready" : "camera-brand-off-preview-not-ready")
        let trace = XCTAttachment(string: observations.joined(separator: "\n"))
        trace.name = "camera-brand-preview-ocr-observations"
        trace.lifetime = .keepAlways
        add(trace)
        XCTFail("Camera preview did not show Z 233 with brand \(hasBrand ? "visible" : "hidden") within 20 seconds")
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

        let type = app.buttons["Type"]
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

    private func revealEffectsControl(_ element: XCUIElement, in app: XCUIApplication, scrollView: XCUIElement? = nil, scrollToTop: Bool = false) {
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
            let down = scrollToTop || (element.exists && element.frame.minY < viewport.minY)
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
            (language: "zh-Hans", unlock: "解锁高级版", restore: "恢复购买",
             terms: "年费版按年自动续订", restored: "未找到有效的高级版购买记录"),
            (language: "zh-Hant", unlock: "解鎖高級版", restore: "恢復購買",
             terms: "年費版按年自動續訂", restored: "未找到有效的高級版購買記錄"),
            (language: "en", unlock: "Unlock Pro", restore: "Restore purchases",
             terms: "Annual Pro renews yearly", restored: "No active Pro purchase found")
        ]
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        for copy in copies {
            app.launchArguments = ["-app_language", copy.language, "--trace-storekit-startup"]
            app.launch()
            openSettings(app)
            let unlock = app.buttons[copy.unlock]
            XCTAssertTrue(unlock.waitForExistence(timeout: 10), app.debugDescription)
            tapWhenStable(unlock)
            let panel = app.descendants(matching: .any).matching(identifier: "premium-purchase-panel").firstMatch
            let close = app.buttons["premium-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            XCTAssertTrue(app.frame.contains(panel.frame), "The panel must fit the screen")
            XCTAssertTrue(close.isHittable, "The fixed header remains reachable")
            let annual = app.buttons["premium-plan-annual"]
            let lifetime = app.buttons["premium-plan-lifetime"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                annual.isEnabled && lifetime.isEnabled
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            XCTAssertTrue(annual.label.contains("39.90"), annual.label)
            XCTAssertTrue(annual.label.contains("≈"), "The monthly reference stays subordinate to the annual total")
            XCTAssertTrue(lifetime.label.contains("99.90"), lifetime.label)
            XCTAssertTrue(panel.buttons["premium-restore"].exists)
            XCTAssertFalse(app.buttons["premium-options"].exists)
            XCTAssertFalse(panel.buttons["legal-link-privacy"].exists)
            XCTAssertFalse(panel.buttons["legal-link-terms"].exists)
            let disclosure = panel.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", copy.terms)).firstMatch
            XCTAssertTrue(disclosure.exists)
            let buy = app.buttons["premium-purchase-action"]
            revealFully(buy, in: panel, app: app)
            let originalPanel = panel.frame
            let originalCTA = buy.frame
            for (index, plan) in [lifetime, annual, lifetime, annual].enumerated() {
                revealFully(plan, in: panel, app: app)
                tapWhenStable(plan)
                XCTAssertTrue(plan.isSelected)
                XCTAssertEqual(panel.frame.minY, originalPanel.minY, accuracy: 0.5)
                XCTAssertEqual(panel.frame.height, originalPanel.height, accuracy: 0.5)
                XCTAssertEqual(buy.frame.height, originalCTA.height, accuracy: 0.5)
                XCTAssertTrue(disclosure.exists, "Selecting lifetime must not remove the annual disclosure")
                if index < 2 { attachScreenshot(app, name: "premium-compact-\(copy.language)-\(index)") }
            }
            let restore = panel.buttons["premium-restore"]
            XCTAssertEqual(restore.label, copy.restore)
            revealFully(restore, in: panel, app: app)
            tapWhenStable(restore)
            let authentication = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                .alerts["Sign in with Apple Account"]
            if authentication.waitForExistence(timeout: 3) {
                // Explicit restore may authenticate; only acknowledge Xcode's
                // simulated login, never a real Apple Account credential prompt.
                let simulation = authentication.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                    "simulate authenticating", "[Environment: Xcode]")).firstMatch
                guard simulation.exists else {
                    XCTFail("Refusing to acknowledge a non-Xcode authentication prompt")
                    return
                }
                authentication.buttons["OK"].tap()
            }
            XCTAssertTrue(app.staticTexts[copy.restored].waitForExistence(timeout: 15), app.debugDescription)
            tapWhenStable(close)
            XCTAssertTrue(unlock.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["legal-link-privacy"].exists)
            XCTAssertTrue(app.buttons["legal-link-terms"].exists)
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
        var observations: [String] = []
        let began = Date()
        let stable = NSPredicate { _, _ in
            // Read enabled/frame from one snapshot. Separate property queries
            // each traverse the remote Photos hierarchy and can exhaust the
            // timeout before two samples, even for a stationary system button.
            guard let snapshot = try? element.snapshot() else {
                observations.append("\(Date().timeIntervalSince(began)): snapshot unavailable")
                return false
            }
            let hittable = element.isHittable
            observations.append("\(Date().timeIntervalSince(began)): enabled=\(snapshot.isEnabled), hittable=\(hittable), frame=\(snapshot.frame)")
            guard snapshot.isEnabled, hittable else { return false }
            let current = snapshot.frame
            defer { previous = current }
            return current == previous && current.width > 0
        }
        // Camera preview accessibility snapshots can take several seconds on
        // the compact simulator. Still require two identical, hittable frames.
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 10)
        if result != .completed {
            attachScreenshot(XCUIApplication(), name: "unstable-control")
            let trace = XCTAttachment(string: observations.joined(separator: "\n"))
            trace.name = "unstable-control-observations"
            trace.lifetime = .keepAlways
            add(trace)
        }
        XCTAssertEqual(result, .completed, "Control did not settle: \(element), last frame: \(previous)")
        element.tap()
    }
}
