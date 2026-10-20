import XCTest

@MainActor
final class QueueRetryUITests: XCTestCase {
    func testTopPillThemedIconActivatesAndCancelsAcrossSkins() {
        continueAfterFailure = false
        for skin in ["FROSTED_GLASS", "TITANIUM", "WOOD", "CAMERA_CONTROLS", "LIQUID_GLASS"] {
            let app = XCUIApplication()
            app.launchArguments = ["--queue-top-pill-test", "-app_language", "en", "-skin_preset", skin]
            app.launch()
            let pill = app.buttons["queue-top-pill"]
            let activations = app.staticTexts["queue-top-pill-activations"]
            XCTAssertTrue(pill.waitForExistence(timeout: 5))
            pill.tap()
            expectLabel(activations, "1")
            let next = app.buttons["queue-top-pill-next"]
            for _ in 0..<3 { next.tap() }
            expectAbsent(app.staticTexts["2"])
            pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)))
            expectLabel(activations, "1")
            pill.tap()
            expectLabel(activations, "2")
            next.tap()
            pill.tap()
            expectLabel(activations, "3")
            app.terminate()
        }
    }

    func testTopPillKeepsRightEdgeAndReleasesWidthAcrossModes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-top-pill-test", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        func layoutFrame() -> CGRect {
            let values = app.staticTexts["queue-top-pill-frame"].label
                .split(separator: ",").compactMap { Double($0) }
            guard values.count == 4 else { return .zero }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        let next = app.buttons["queue-top-pill-next"]
        XCTAssertTrue(app.staticTexts["9"].waitForExistence(timeout: 5))
        let paused = layoutFrame()
        var frames = ["paused": paused.debugDescription]
        func waitForFrame(_ condition: @escaping (CGRect) -> Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                condition(layoutFrame())
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                           "Actual button frame: \(layoutFrame()); previous frames: \(frames)")
        }
        next.tap()
        XCTAssertTrue(app.staticTexts["10.0 MB/s"].waitForExistence(timeout: 5))
        waitForFrame { $0.width > paused.width + 20 }
        let downloading = layoutFrame()
        frames["download"] = downloading.debugDescription
        XCTAssertEqual(downloading.maxX, paused.maxX, accuracy: 1)
        next.tap()
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 5))
        expectAbsent(app.staticTexts["10.0 MB/s"])
        waitForFrame { $0.width < downloading.width - 10 }
        let generating = layoutFrame()
        frames["generating"] = generating.debugDescription
        XCTAssertEqual(generating.maxX, paused.maxX, accuracy: 1)
        next.tap()
        expectAbsent(app.staticTexts["2"])
        waitForFrame { abs($0.width - 40) < 0.5 }
        frames["icon"] = layoutFrame().debugDescription
        XCTAssertEqual(layoutFrame().maxX, paused.maxX, accuracy: 1)
        next.tap()
        XCTAssertTrue(app.staticTexts["9"].waitForExistence(timeout: 5))
        waitForFrame { abs($0.width - paused.width) < 0.5 }
        XCTAssertEqual(layoutFrame().maxX, paused.maxX, accuracy: 1)
        let attachment = XCTAttachment(string: frames.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        attachment.name = "Production top pill frames"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTopPillAnimatorSwitchesTaskAndRetainsLastOwnerThroughCompletion() {
        let app = XCUIApplication()
        app.launchArguments = ["--queue-top-pill-test", "--queue-top-pill-success", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        let observed = app.staticTexts["queue-top-pill-progress"]
        let next = app.buttons["queue-top-pill-next"]
        expectLabel(observed, "00000000-0000-0000-0000-000000000001|0.000")
        next.tap()
        expectLabel(observed, "00000000-0000-0000-0000-000000001001|0.250")
        next.tap()
        expectLabel(observed, "00000000-0000-0000-0000-000000002001|1.000")
        next.tap()
        expectLabel(app.buttons["queue-top-pill"], "Done")
        expectLabel(observed, "00000000-0000-0000-0000-000000002001|1.000")
        next.tap()
        expectLabel(observed, "00000000-0000-0000-0000-000000000001|0.000")
    }

    func testWaitingCountChangesDoNotRestartProductionGracePeriod() {
        let app = XCUIApplication()
        app.launchArguments = ["--queue-pill-grace-test", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        app.buttons["grace-start"].tap()
        expectLabel(app.staticTexts["grace-updates"], "finished")
        let label = app.staticTexts["grace-first-visible"].label
        let values = label.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(values.count, 2, label)
        guard values.count == 2 else { return }
        XCTAssertGreaterThanOrEqual(values[0], 300, "Must retain the 350ms grace period")
        XCTAssertLessThan(values[0], 850, "Must appear while counts are still changing")
        XCTAssertGreaterThan(values[1], 1)
        XCTAssertLessThan(values[1], 11, "Must not wait until the last count update")
    }

    func testTopQueuePillUsesProductionPausedDownloadAndGenerationStates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-top-pill-test", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["9"].waitForExistence(timeout: 5))
        app.buttons["queue-top-pill-next"].tap()
        XCTAssertTrue(app.staticTexts["10.0 MB/s"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3"].waitForExistence(timeout: 5))
        expectAbsent(app.staticTexts["9"])
        app.buttons["queue-top-pill-next"].tap()
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 5))
        expectAbsent(app.staticTexts["10.0 MB/s"])
        expectAbsent(app.staticTexts["3"])
        XCTAssertTrue(app.descendants(matching: .any)["queue-pill-generation-icon"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Production top pill generating"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["queue-top-pill-next"].tap()
        expectAbsent(app.staticTexts["2"])
        XCTAssertNotEqual(app.buttons["queue-top-pill"].label, "Done")
        XCTAssertTrue(app.buttons["queue-top-pill"].exists)
        app.buttons["queue-top-pill-next"].tap()
        XCTAssertTrue(app.staticTexts["9"].waitForExistence(timeout: 5))
    }

    func testTopQueuePillCompletionStillShowsDoneAndNewBatchClearsIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-top-pill-test", "--queue-top-pill-success", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["9"].waitForExistence(timeout: 5))
        let next = app.buttons["queue-top-pill-next"]
        next.tap()
        XCTAssertTrue(app.staticTexts["3"].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 5))
        next.tap()
        expectLabel(app.buttons["queue-top-pill"], "Done")
        let done = XCTAttachment(screenshot: app.screenshot())
        done.name = "Production top pill completion fill"
        done.lifetime = .keepAlways
        add(done)
        next.tap()
        XCTAssertTrue(app.staticTexts["9"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.buttons["queue-top-pill"].label, "Done")
    }

    func testConfirmationClosesForControlEventAndLostEligibility() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "--queue-confirmation-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
        app.buttons["retry-connection"].tap()
        let confirm = app.buttons["queue-confirm-action"]
        for trigger in ["queue-retry-all", "queue-clear-all"] {
            app.buttons[trigger].tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            app.buttons["queue-test-control"].tap()
            expectAbsent(confirm)
        }
        app.buttons["queue-clear-all"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons["queue-test-remove"].tap()
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=0;done=0")
        expectAbsent(confirm)
        XCTAssertFalse(app.buttons["queue-clear-all"].exists)
    }

    func testConfirmationsUseSeparateInlineAnchorsAndToggleClosed() {
        let app = launch(noSession: false)
        defer { app.terminate() }
        app.buttons["retry-connection"].tap()
        let retry = app.buttons["queue-retry-all"]
        let clear = app.buttons["queue-clear-all"]
        let confirm = app.buttons["queue-confirm-action"]
        let idleRetryY = retry.frame.minY
        let idleClear = clear.frame
        retry.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertLessThan(confirm.frame.maxY, retry.frame.minY)
        XCTAssertEqual(retry.frame.minY, idleRetryY, accuracy: 2)
        let retryPanel = app.otherElements["popup-panel-queueRetry"]
        XCTAssertTrue(retryPanel.exists)
        let retryWidth = retryPanel.frame.width
        XCTAssertLessThan(retryWidth, 260)
        retry.tap()
        expectAbsent(confirm)
        clear.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertLessThan(confirm.frame.maxY, clear.frame.minY)
        XCTAssertEqual(clear.frame.minX, idleClear.minX, accuracy: 1)
        XCTAssertEqual(clear.frame.minY, idleClear.minY, accuracy: 1)
        let clearPanel = app.otherElements["popup-panel-queueClear"]
        XCTAssertTrue(clearPanel.exists)
        XCTAssertGreaterThan(clearPanel.frame.width, retryWidth)
        XCTAssertEqual(clearPanel.frame.width, 260, accuracy: 1)
        XCTAssertGreaterThan(app.staticTexts["queue-confirmation-subtitle"].frame.height, 20)
        // Accessibility bounds need not equal the button layout bounds.
        // Check the specified 20pt content inset instead.
        XCTAssertEqual(clearPanel.frame.maxX, app.frame.maxX - 20, accuracy: 1)
        // Approved iOS rule: confirmations overlay the queue without moving
        // either FAB, including the retry button behind the clear panel.
        XCTAssertEqual(retry.frame.minY, idleRetryY, accuracy: 2)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Clear confirmation overlays fixed FABs"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["queue-cancel-action"].tap()
        expectAbsent(confirm)
        XCTAssertEqual(retry.frame.minY, idleRetryY, accuracy: 2)
    }

    func testConfirmedRetryReturnsUsableWhenTheAttemptFailsAgain() {
        let app = launch(noSession: false)
        defer { app.terminate() }
        app.buttons["retry-connection"].tap()
        let retry = app.buttons["queue-retry-all"]
        let original = retry.frame
        retry.tap()
        let confirm = app.buttons["queue-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectAbsent(confirm)
        // The fixture's camera fails immediately. A new eligible retry must
        // enter after the joint fade, without retaining an invisible trigger.
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
        expectEnabled(retry, true)
        XCTAssertEqual(retry.frame.minY, original.minY, accuracy: 1)
        retry.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons["queue-cancel-action"].tap()
        expectAbsent(confirm)
        XCTAssertTrue(retry.isHittable)
    }

    func testConfirmationScrimBlocksScrollAndDismissalRestoresIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "--queue-confirmation-scroll-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=12;done=0")
        let top = app.staticTexts["RETRY_12.JPG"]
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        let originalY = top.frame.minY
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 60, dy: 500))
        let end = origin.withOffset(CGVector(dx: 60, dy: 280))
        app.buttons["queue-clear-all"].tap()
        let confirm = app.buttons["queue-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(confirm.exists)
        XCTAssertEqual(top.frame.minY, originalY, accuracy: 1)
        // A tap on the scrim closes it; the same drag must then reach the list.
        start.tap()
        expectAbsent(confirm)
        start.press(forDuration: 0.05, thenDragTo: end)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !top.exists || abs(top.frame.minY - originalY) > 10
        }, object: top)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
    }

    func testNewTransferClosesRetryButRetainsEligibleClearConfirmation() {
        continueAfterFailure = false
        for trigger in ["queue-retry-all", "queue-clear-all"] {
            let app = XCUIApplication()
            app.launchArguments = ["--queue-retry-ui-test", "--queue-confirmation-activity-test",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            defer { app.terminate() }
            expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
            app.buttons["retry-connection"].tap()
            app.buttons[trigger].tap()
            let confirm = app.buttons["queue-confirm-action"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            app.buttons["queue-test-start-new"].tap()
            expectLabel(app.staticTexts["queue-test-activity"], "running")
            if trigger == "queue-retry-all" {
                expectAbsent(confirm)
                expectAbsent(app.buttons["queue-retry-all"])
                app.buttons["queue-clear-all"].tap()
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            } else {
                // Already-open clear confirmation survives the same transition.
                XCTAssertTrue(confirm.exists)
            }
            expectLabel(app.staticTexts["queue-test-activity"], "running")
            confirm.tap()
            expectLabel(app.staticTexts["retry-fixture-state"], "failed=0;done=0")
            expectLabel(app.staticTexts["queue-test-activity"], "running")
            XCTAssertTrue(app.staticTexts["RETRY_3.JPG"].exists)
        }
    }

    func testRealDoubleTapClosesAndReopensUsableConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "--queue-confirmation-reversal-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
        let clear = app.buttons["queue-clear-all"]
        clear.tap()
        let confirm = app.buttons["queue-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        clear.doubleTap()
        // Prove both real button actions ran. A very fast double tap may
        // coalesce before a closing frame; this is not a mid-mesh reversal test.
        expectLabel(app.staticTexts["queue-confirmation-toggles"], "toggles=3")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=0;done=0")
        expectAbsent(confirm)
    }

    func testOrdinaryConfirmationCloseRendersIntermediateFramesBeforeZero() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "--queue-confirmation-reversal-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
        let clear = app.buttons["queue-clear-all"]
        clear.tap()
        let confirm = app.buttons["queue-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        clear.tap()
        expectLabel(app.staticTexts["queue-confirmation-animation"], "closing=true;reversed=false;zero=true")
        expectAbsent(confirm)
        XCTAssertTrue(clear.exists)
    }

    func testProductionConfirmationReversesFromRenderedClosingFrame() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "--queue-confirmation-frame-reversal-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
        let clear = app.buttons["queue-clear-all"]
        clear.tap()
        let confirm = app.buttons["queue-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        clear.tap()
        // DEBUG schedules the same production toggle from a rendered p<0.8
        // closing frame. This verifies lifecycle, not synthetic touch timing.
        expectLabel(app.staticTexts["queue-confirmation-animation"], "closing=true;reversed=true;zero=false")
        expectLabel(app.staticTexts["queue-confirmation-toggles"], "toggles=3")
        expectLabel(app.staticTexts["queue-confirmation-mounts"], "mounts=1")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=0;done=0")
        expectAbsent(confirm)
    }

    func testLongTitleRendersInProductionCardAndKeepsAccessibleFullName() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "--queue-long-title-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
        let title = app.staticTexts["A_VERY_LONG_CAMERA_CAPTURE_FILENAME_123456_1.JPG"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(title.frame.width, 60)
        XCTAssertLessThan(title.frame.width, 300)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Long queue filenames preserve number and extension"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["retry-local-first"].tap()
        expectEnabled(app.buttons["queue-retry-1"], true)
        app.buttons["queue-retry-1"].tap()
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=1;done=1")
        XCTAssertTrue(title.exists)
    }

    func testGenerationCardWaitingSkippedAndErrorInThreeLanguages() {
        continueAfterFailure = false
        for (language, watermark, waiting, skipped, failure) in [
            ("en", "Watermark", "Waiting", "Skipped", "Generation failed"),
            ("zh-Hans", "水印", "等待", "跳过", "生成失败"),
            ("zh-Hant", "浮水印", "等待", "跳過", "產生失敗")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--queue-card-presentation-test", "-app_language", language]
            app.launch()
            XCTAssertTrue(app.staticTexts[watermark].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["2 KB"].exists)
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", waiting)).firstMatch.exists)
            for phase in ["waiting", "skipped", "error"] {
                if phase == "skipped" {
                    app.buttons["queue-card-next-state"].tap()
                    XCTAssertTrue(app.staticTexts[skipped].waitForExistence(timeout: 5))
                    XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", waiting)).firstMatch.exists)
                    XCTAssertFalse(app.staticTexts[watermark].exists)
                } else if phase == "error" {
                    app.buttons["queue-card-next-state"].tap()
                    XCTAssertTrue(app.staticTexts[failure + ": GENERATION_ERROR"].waitForExistence(timeout: 5))
                    XCTAssertFalse(app.staticTexts[skipped].exists)
                    XCTAssertFalse(app.staticTexts["TRANSFER_ERROR_MUST_BE_HIDDEN"].exists)
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Queue card \(language) \(phase)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    func testCropFilterAndSkippedEffectsUseThreeLanguageResources() {
        continueAfterFailure = false
        for (language, combined, skipped) in [
            ("en", "Crop · Watermark · Forest Verdure 64%", "Crop · Effects skipped"),
            ("zh-Hans", "裁切 · 水印 · 森屿青 64%", "裁切 · 照片效果已跳过"),
            ("zh-Hant", "裁切 · 浮水印 · 森嶼青 64%", "裁切 · 照片效果已略過")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--queue-card-presentation-test", "--queue-card-crop-test",
                                   "-app_language", language]
            app.launch()
            XCTAssertTrue(app.staticTexts[combined].waitForExistence(timeout: 5))
            for phase in ["combined", "effects-skipped", "cancelled"] {
                if phase == "effects-skipped" {
                    app.buttons["queue-card-next-state"].tap()
                    XCTAssertTrue(app.staticTexts[skipped].waitForExistence(timeout: 5))
                    XCTAssertFalse(app.staticTexts[combined].exists)
                } else if phase == "cancelled" {
                    app.buttons["queue-card-next-state"].tap()
                    XCTAssertTrue(app.staticTexts[combined].waitForExistence(timeout: 5))
                    XCTAssertFalse(app.buttons["queue-retry-79"].exists)
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Crop card \(language) \(phase)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    func testCropOnlyUnknownSizeProgressAndLongTitleInThreeLanguages() {
        continueAfterFailure = false
        for (language, crop) in [("en", "Crop"), ("zh-Hans", "裁切"), ("zh-Hant", "裁切")] {
            let app = XCUIApplication()
            app.launchArguments = ["--queue-card-presentation-test", "--queue-card-download-test",
                                   "-app_language", language]
            app.launch()
            let title = app.staticTexts["A_VERY_LONG_CAMERA_CAPTURE_FILENAME_123456.JPG"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[crop].exists)
            for (phase, size) in ["—", "1 KB", "2 KB"].enumerated() {
                if phase > 0 { app.buttons["queue-card-next-state"].tap() }
                XCTAssertTrue(app.staticTexts[size].waitForExistence(timeout: 5))
                XCTAssertTrue(title.exists)
                XCTAssertTrue(app.staticTexts[crop].exists)
                XCTAssertFalse(app.staticTexts["9 KB"].exists)
                if phase > 0 { XCTAssertFalse(app.staticTexts["—"].exists) }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Crop download \(language) phase \(phase)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    func testQueueCardSurfaceInLightAndDark() {
        continueAfterFailure = false
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--queue-card-presentation-test", "-app_language", "en"]
            if dark { app.launchArguments.append("--queue-card-dark") }
            app.launch()
            XCTAssertTrue(app.staticTexts["Watermark"].waitForExistence(timeout: 5))
            for phase in ["waiting", "failed"] {
                if phase == "failed" {
                    app.buttons["queue-card-next-state"].tap()
                    app.buttons["queue-card-next-state"].tap()
                    XCTAssertTrue(app.staticTexts["Generation failed: GENERATION_ERROR"].waitForExistence(timeout: 5))
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Card surface \(dark ? "dark" : "light") \(phase)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    func testQueuePillsEnterAndExitThroughActualDisplayFrames() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-card-presentation-test", "--queue-pill-visibility-test", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        let trace = app.staticTexts["queue-pill-visibility-trace"]
        expectLabel(trace, "entered=;exited=")
        XCTAssertFalse(app.staticTexts["10 MB/s"].exists)
        app.buttons["queue-card-next-state"].tap()
        expectLabel(trace, "entered=60,80,150;exited=")
        XCTAssertTrue(app.staticTexts["10 MB/s"].exists)
        XCTAssertTrue(app.staticTexts["1.2s"].exists)
        XCTAssertTrue(app.staticTexts["2.4s"].exists)
        let entered = XCTAttachment(screenshot: app.screenshot())
        entered.name = "Three pills entered"; entered.lifetime = .keepAlways; add(entered)
        app.buttons["queue-card-next-state"].tap()
        expectLabel(trace, "entered=60,80,150;exited=60,80,150")
        expectAbsent(app.staticTexts["10 MB/s"])
        expectAbsent(app.staticTexts["1.2s"])
        expectAbsent(app.staticTexts["2.4s"])
        XCTAssertTrue(app.staticTexts["2 KB"].exists)
        let exited = XCTAttachment(screenshot: app.screenshot())
        exited.name = "Three pills exited"; exited.lifetime = .keepAlways; add(exited)
    }

    func testQueuePillsReverseFromActualExitFrameWithoutResetOrRemount() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-card-presentation-test", "--queue-pill-visibility-test",
                               "--queue-pill-reversal-test", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        app.buttons["queue-card-next-state"].tap()
        expectLabel(app.staticTexts["queue-pill-visibility-trace"], "entered=60,80,150;exited=")
        // The second tap exits. The fixture reverses only after all three
        // production display callbacks have observed an intermediate exit alpha.
        app.buttons["queue-card-next-state"].tap()
        expectLabel(app.staticTexts["queue-pill-reversal-trace"],
                    "reversed=60,80,150;resumed=60,80,150;continuous=true;stable=true")
        for text in ["10 MB/s", "1.2s", "2.4s"] { XCTAssertTrue(app.staticTexts[text].exists) }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Pills after actual-frame reversal"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRealCardSpeedGrowsAndShrinksToTheRightWithoutTruncating() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-card-presentation-test", "--queue-speed-width-test", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        let pill = app.otherElements["queue-card-speed-79"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        let first = pill.frame
        for (phase, speed) in ["9.9 MB/s", "999.9 MB/s", "1.0 MB/s"].enumerated() {
            if phase > 0 { app.buttons["queue-card-next-state"].tap() }
            XCTAssertTrue(app.staticTexts[speed].waitForExistence(timeout: 3))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "speed-width-\(phase)"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertEqual(pill.frame.minX, first.minX, accuracy: 0.5)
            XCTAssertLessThan(pill.frame.maxX, app.frame.width - 20)
            if phase == 1 { XCTAssertGreaterThan(pill.frame.width, first.width + 10) }
            if phase == 2 { XCTAssertEqual(pill.frame.width, first.width, accuracy: 1) }
        }
    }

    func testQueuePillWidthExpandsWithinConstraintAndShrinksToWaitingIcon() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-card-presentation-test", "--queue-pill-width-test", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        let pill = app.otherElements["queue-pill-width"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        let initial = pill.frame
        XCTAssertLessThan(initial.width, 120)
        for phase in 1...3 {
            app.buttons["queue-card-next-state"].tap()
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let width = pill.frame.width
                if phase == 1 { return width > initial.width + 20 && width <= 120.5 }
                if phase == 2 { return abs(width - 30) < 0.5 }
                return abs(width - initial.width) < 0.5
            }, object: pill)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            XCTAssertEqual(pill.frame.minX, initial.minX, accuracy: 0.5)
            XCTAssertEqual(pill.frame.height, 20, accuracy: 0.5)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Pill width phase \(phase)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testQueueBadgeSixStatesInLightAndDark() {
        continueAfterFailure = false
        for dark in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--queue-card-presentation-test", "--queue-card-badge-test", "-app_language", "en"]
            if dark { app.launchArguments.append("--queue-card-dark") }
            app.launch()
            for phase in 0..<6 {
                expectLabel(app.staticTexts["queue-card-badge-phase"], "badge-phase-\(phase)")
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Badge \(dark ? "dark" : "light") state \(phase)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.buttons["queue-card-next-state"].tap()
            }
            expectLabel(app.staticTexts["queue-card-badge-phase"], "badge-phase-0")
            app.terminate()
        }
    }

    private func expectAbsent(_ element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }

    func testNewFailureDuringRealClearWindowDoesNotExposeCardActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "--queue-clear-window-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expectLabel(app.staticTexts["queue-clear-active"], "active")
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=1;done=0")
        app.buttons["queue-clear-all"].tap()
        let confirm = app.buttons["queue-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectLabel(app.staticTexts["queue-clear-trace"], "late=true;leaked=false;finished=true")
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=0;done=0")
        XCTAssertFalse(app.buttons["queue-retry-2"].exists)
        XCTAssertFalse(app.buttons["queue-remove-2"].exists)
    }

    func testDisconnectedRetainedSessionUsesIndexAndMixedBatchGate() {
        let app = launch(noSession: false)
        defer { app.terminate() }
        let first = app.buttons["queue-retry-1"], second = app.buttons["queue-retry-2"]
        let all = app.buttons["queue-retry-all"]
        expectEnabled(first, false); expectEnabled(second, false); expectEnabled(all, false)
        app.buttons["retry-connection"].tap()
        expectEnabled(first, true); expectEnabled(second, true); expectEnabled(all, true)
        app.buttons["retry-connection"].tap()
        expectEnabled(first, false); expectEnabled(second, false); expectEnabled(all, false)
        app.buttons["retry-local-first"].tap()
        expectEnabled(first, true); expectEnabled(second, false); expectEnabled(all, false)
        app.buttons["retry-local-both"].tap()
        expectEnabled(first, true); expectEnabled(second, true); expectEnabled(all, true)
    }

    func testNoSessionCanRetryIndexedOriginalAndFinishOffline() {
        let app = launch(noSession: true)
        defer { app.terminate() }
        let first = app.buttons["queue-retry-1"]
        expectEnabled(first, false)
        app.buttons["retry-local-first"].tap()
        expectEnabled(first, true)
        first.tap()
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=1;done=1")
        XCTAssertFalse(first.exists)
        expectEnabled(app.buttons["queue-retry-2"], false)
        expectEnabled(app.buttons["queue-retry-all"], false)
    }

    private func launch(noSession: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-retry-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if noSession { app.launchArguments.append("--retry-no-session") }
        app.launch()
        expectLabel(app.staticTexts["retry-fixture-state"], "failed=2;done=0")
        return app
    }
    private func expectEnabled(_ element: XCUIElement, _ enabled: Bool) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }
    private func expectLabel(_ element: XCUIElement, _ label: String) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
}
