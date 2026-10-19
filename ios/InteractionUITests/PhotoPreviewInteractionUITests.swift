import XCTest

@MainActor
final class PhotoPreviewInteractionUITests: XCTestCase {
    private struct HoldEvent: Decodable {
        let event: String
        let milliseconds: Int64
    }

    private func launchHoldFixture(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--list-admission-ui-test", "--photo-preview-ui-test", "--photo-hold-trace",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app_language", "en"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "enqueue-day-")).firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func firstGridCenter(_ app: XCUIApplication) -> XCUICoordinate {
        // The thumbnail's Image AX node can report an empty frame while
        // replacing its placeholder. Target the actual first grid square
        // below the measured date row, using the production 3-column grid.
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "enqueue-day-")).firstMatch.frame
        let side = (app.frame.width - 24 - 12) / 3
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12 + side / 2, dy: header.maxY + 10 + side / 2))
    }

    private func readHoldTrace(_ app: XCUIApplication, name: String) throws -> [HoldEvent] {
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let attachment = XCTAttachment(string: json)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return try JSONDecoder().decode([HoldEvent].self, from: Data(json.utf8))
    }

    func testPhotoHoldStartsPreviewBeforeFingerLift() throws {
        continueAfterFailure = false
        for burst in [false, true] {
            let app = launchHoldFixture(burst ? ["--burst-admission"] : [])
            defer { app.terminate() }
            let cell = app.descendants(matching: .any)[burst ? "burst-image-701" : "photo-cell-702"].firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 10))
            let center = firstGridCenter(app)
            app.buttons["clear-trace"].tap()
            center.press(forDuration: 1.2)
            let trace = try readHoldTrace(app, name: burst ? "burst-hold-timing" : "photo-hold-timing")
            let down = try XCTUnwrap(trace.first { $0.event == "touch-down" })
            let up = try XCTUnwrap(trace.first { $0.event == "touch-up" && $0.milliseconds > down.milliseconds })
            let hold = try XCTUnwrap(trace.first { $0.event == "photo-long-press" })
            let appeared = try XCTUnwrap(trace.first { $0.event == "preview-appear" })
            XCTAssertLessThan(hold.milliseconds - down.milliseconds, 350, "Threshold must run from actual touch-down")
            XCTAssertLessThan(appeared.milliseconds - down.milliseconds, 500, "Preview must start without waiting for release")
            XCTAssertLessThan(appeared.milliseconds, up.milliseconds)
            XCTAssertEqual(trace.filter { $0.event == "photo-long-press" }.count, 1)
            XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"), "Releasing a preview hold must not also tap to enqueue")
        }
    }

    func testPhotoTapAndScrollDoNotAlsoRecognizeHold() throws {
        continueAfterFailure = false
        let app = launchHoldFixture(["--defer-admission", "--scroll-hold-fixture"])
        defer { app.terminate() }
        let center = firstGridCenter(app)
        center.tap()
        let queued = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "count=1;waiting=1"), object: app.staticTexts["admission-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [queued], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["preview-state"].exists)
        app.buttons["clear-trace"].tap()
        center.press(forDuration: 0.03, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -150)))
        let trace = try readHoldTrace(app, name: "photo-scroll-cancels-hold")
        XCTAssertFalse(trace.contains { $0.event == "photo-long-press" })
        XCTAssertFalse(app.staticTexts["preview-state"].exists)
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=1;waiting=1"))
        XCTAssertTrue(trace.contains { $0.event == "photo-scroll" }, "The list must actually scroll")
    }

    func testSwappedTapPreviewAndHoldTransferRemainExclusive() throws {
        continueAfterFailure = false
        for hold in [false, true] {
            let app = launchHoldFixture(["--defer-admission", "--preview-admission"])
            defer { app.terminate() }
            let center = firstGridCenter(app)
            app.buttons["clear-trace"].tap()
            if hold { center.press(forDuration: 0.32) } else { center.tap() }
            let trace = try readHoldTrace(app, name: hold ? "photo-hold-transfer" : "photo-tap-preview")
            if hold {
                XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=1;waiting=1"))
                XCTAssertFalse(trace.contains { $0.event == "preview-request" })
                XCTAssertEqual(trace.filter { $0.event == "photo-long-press" }.count, 1)
            } else {
                XCTAssertTrue(app.staticTexts["preview-state"].exists)
                XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
                XCTAssertFalse(trace.contains { $0.event == "photo-long-press" })
                XCTAssertEqual(trace.filter { $0.event == "preview-request" }.count, 1)
            }
        }
    }

    func testEffectsPopupHoldDragAndReturnKeepsPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--photo-preview-ui-test", "--preview-effects-gesture-test",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app_language", "en"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-preview-0"].waitForExistence(timeout: 10))
        app.buttons["open-preview-0"].tap()
        let effects = app.buttons["Edit photo effects"]
        XCTAssertTrue(effects.waitForExistence(timeout: 5))
        effects.tap()
        let intensity = app.buttons["Intensity"]
        XCTAssertTrue(intensity.waitForExistence(timeout: 5))
        XCTAssertEqual(intensity.value as? String, "80%")
        let initialY = intensity.frame.midY
        let start = intensity.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.65, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)))
        XCTAssertNotEqual(intensity.value as? String, "80%", "Holding then dragging must adjust, not scroll the editor")
        XCTAssertEqual(intensity.frame.midY, initialY, accuracy: 1)
        XCTAssertFalse(app.buttons["preview-test-queue"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways
        shot.name = "Preview effects after held intensity drag"; add(shot)
        app.buttons["photo-effects-editor-back"].tap()
        XCTAssertTrue(app.staticTexts["preview-state"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["preview-test-queue"].isHittable)
        effects.tap()
        XCTAssertTrue(intensity.waitForExistence(timeout: 5))
        XCTAssertNotEqual(intensity.value as? String, "80%", "The released choice must persist on reopen")
        // The drag priority must not steal a stationary hold used by the
        // filter chooser, or enable the intensity wheel after turning it off.
        app.buttons["Photo filter"].press(forDuration: 0.65)
        let turnOff = app.buttons["Turn off filter"]
        XCTAssertTrue(turnOff.waitForExistence(timeout: 3))
        turnOff.tap()
        XCTAssertTrue(intensity.waitForExistence(timeout: 3))
        let disabledValue = intensity.value as? String
        let disabledStart = intensity.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        disabledStart.press(forDuration: 0.65, thenDragTo: disabledStart.withOffset(CGVector(dx: 0, dy: -60)))
        XCTAssertEqual(intensity.value as? String, disabledValue)
    }

    func testRealBurstListAndPreviewAdmitOnlyCompleteLocalGroup() {
        continueAfterFailure = false
        for preview in [false, true] {
            for allLocal in [false, true] {
                let app = XCUIApplication()
                app.launchArguments = ["--list-admission-ui-test", "--burst-admission", "--photo-preview-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                if allLocal { app.launchArguments.append("--all-local-admission") }
                app.launch()
                let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "enqueue-burst-")).firstMatch
                XCTAssertTrue(group.waitForExistence(timeout: 10))
                if preview {
                    let cell = app.descendants(matching: .any).matching(identifier: "burst-image-701").firstMatch
                    cell.press(forDuration: 0.8)
                    XCTAssertTrue(app.buttons["Collapse"].waitForExistence(timeout: 5))
                    app.buttons["Collapse"].tap()
                    let transfer = app.buttons["Transfer this group"]
                    XCTAssertTrue(transfer.waitForExistence(timeout: 5))
                    transfer.tap()
                } else { group.tap() }
                if allLocal {
                    let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "count=3;waiting=0;done=3"), object: app.staticTexts["admission-state"])
                    XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
                } else {
                    XCTAssertTrue(app.staticTexts["photo-list-hint"].waitForExistence(timeout: 3))
                    XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
                    XCTAssertEqual(app.staticTexts["admission-flight-state"].label, "flights=0;held=0")
                    if preview { XCTAssertTrue(app.staticTexts["preview-state"].exists) }
                }
                app.terminate()
            }
        }
    }

    func testRealListRejectsMissingAndMixedSourcesThenAcceptsLocalOriginal() {
        let app = XCUIApplication()
        app.launchArguments = ["--list-admission-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let missing = app.descendants(matching: .any).matching(identifier: "photo-cell-702").firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        missing.tap()
        XCTAssertTrue(app.staticTexts["photo-list-hint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
        XCTAssertEqual(app.staticTexts["admission-flight-state"].label, "flights=0;held=0")
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "enqueue-day-")).firstMatch
        XCTAssertTrue(group.exists)
        group.tap()
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
        XCTAssertEqual(app.staticTexts["admission-flight-state"].label, "flights=0;held=0")
        let local = app.descendants(matching: .any).matching(identifier: "photo-cell-701").firstMatch
        local.tap()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "count=1;waiting=0;done=1"), object: app.staticTexts["admission-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
    }

    func testRealListReconnectAllowsDeferredMissingSource() {
        let app = XCUIApplication()
        app.launchArguments = ["--list-admission-ui-test", "--defer-admission"]
        app.launch()
        defer { app.terminate() }
        let missing = app.descendants(matching: .any).matching(identifier: "photo-cell-702").firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        missing.tap()
        XCTAssertTrue(app.staticTexts["photo-list-hint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
        XCTAssertEqual(app.staticTexts["admission-flight-state"].label, "flights=0;held=0")
        app.buttons["admission-connection"].tap()
        missing.tap()
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "count=1;waiting=1;done=0"), object: app.staticTexts["admission-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 10), .completed)
    }

    func testRealListPreviewRejectsWithoutQueueOrFlightAndKeepsPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--list-admission-ui-test", "--preview-admission", "--photo-preview-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let missing = app.descendants(matching: .any).matching(identifier: "photo-cell-702").firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        missing.tap()
        XCTAssertTrue(app.staticTexts["preview-state"].waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["photo-list-hint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
        XCTAssertEqual(app.staticTexts["admission-flight-state"].label, "flights=0;held=0")
        XCTAssertTrue(app.staticTexts["preview-state"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testOfflineRejectionHintIsAbovePreviewAndPreviewStaysOpen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--photo-preview-ui-test", "--preview-offline-admission", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-preview-0"].waitForExistence(timeout: 10))
        app.buttons["open-preview-0"].tap()
        XCTAssertTrue(app.staticTexts["preview-state"].waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
        let hint = app.staticTexts["photo-list-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["preview-state"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: hint)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["preview-state"].exists)
    }

    func testPagingPinchRestoreCloseAndNewOpeningIndex() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--photo-preview-ui-test"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-preview-0"].waitForExistence(timeout: 10))
        app.buttons["open-preview-0"].tap()
        let state = app.staticTexts["preview-state"]
        func expect(_ text: String) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        }
        expect("page=0")
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        right.press(forDuration: 0.05, thenDragTo: left)
        expect("page=1")
        app.pinch(withScale: 2, velocity: 1)
        expect("zoom=1")
        expect("pinch=0")
        right.press(forDuration: 0.05, thenDragTo: left)
        expect("page=1")
        center.doubleTap()
        expect("zoom=0")
        center.tap()
        XCTAssertTrue(app.buttons["open-preview-2"].waitForExistence(timeout: 10))
        app.buttons["open-preview-2"].tap()
        expect("page=2")
        expect("zoom=0")
        center.tap()
        XCTAssertTrue(app.buttons["open-preview-0"].waitForExistence(timeout: 10))
    }
}
