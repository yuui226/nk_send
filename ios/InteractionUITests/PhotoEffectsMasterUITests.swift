import XCTest

@MainActor
final class PhotoEffectsMasterUITests: XCTestCase {
    private struct Event: Decodable { let event: String; let milliseconds: Int64 }
    func testEffectComparisonHoldRestoresOnReleaseWithoutOpening() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit-ui-test"]
        app.launch(); defer { app.terminate() }
        let state = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "ready=")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "ready=1"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        app.buttons["clear-trace"].tap()
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: 170)).press(forDuration: 0.6)
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let attachment = XCTAttachment(string: json); attachment.name = "effects-comparison-hold"
        attachment.lifetime = .keepAlways; add(attachment)
        let trace = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
        let down = try XCTUnwrap(trace.first { $0.event == "touch-down" })
        let on = try XCTUnwrap(trace.first { $0.event == "comparison-on" })
        let up = try XCTUnwrap(trace.first { $0.event == "touch-up" && $0.milliseconds > down.milliseconds })
        let off = try XCTUnwrap(trace.first { $0.event == "comparison-off" })
        XCTAssertGreaterThanOrEqual(on.milliseconds - down.milliseconds, 480)
        XCTAssertLessThan(on.milliseconds - down.milliseconds, 650)
        XCTAssertGreaterThanOrEqual(off.milliseconds, up.milliseconds - 20)
        XCTAssertFalse(trace.contains { $0.event == "effects-open" })
        XCTAssertTrue(state.label.contains("comparison=0"))
    }

    func testWheelHoldRecognizesBeforeReleaseAndDoesNotCommit() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit-ui-test", "--audit-wheel"]
        app.launch(); defer { app.terminate() }
        let wheel = app.buttons["Audit wheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 10))
        app.buttons["clear-trace"].tap()
        wheel.press(forDuration: 1.1)
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let trace = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
        let evidence = XCTAttachment(string: json); evidence.name = "wheel-hold-timing"
        evidence.lifetime = .keepAlways; add(evidence)
        let down = try XCTUnwrap(trace.first { $0.event == "touch-down" })
        let hold = try XCTUnwrap(trace.first { $0.event == "wheel-hold" })
        XCTAssertGreaterThanOrEqual(hold.milliseconds - down.milliseconds, 430)
        XCTAssertLessThan(hold.milliseconds - down.milliseconds, 620)
        XCTAssertFalse(trace.contains { $0.event == "wheel-commit" })
        XCTAssertEqual(wheel.value as? String, "5")
    }

    func testWheelDragCommitsOnceWithoutHoldOrTap() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit-ui-test", "--audit-wheel"]
        app.launch(); defer { app.terminate() }
        let wheel = app.buttons["Audit wheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 10))
        app.buttons["clear-trace"].tap()
        let start = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -54)),
                    withVelocity: .slow, thenHoldForDuration: 0.6)
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let trace = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
        XCTAssertEqual(trace.filter { $0.event == "wheel-commit" }.count, 1)
        XCTAssertFalse(trace.contains { $0.event == "wheel-hold" })
        XCTAssertNotEqual(wheel.value as? String, "5")
    }

    func testSmallFingerDriftDoesNotCancelWheelHold() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit-ui-test", "--audit-wheel"]
        app.launch(); defer { app.terminate() }
        let wheel = app.buttons["Audit wheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 10))
        app.buttons["clear-trace"].tap()
        let start = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 3)),
                    withVelocity: .fast, thenHoldForDuration: 0.7)
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let trace = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
        XCTAssertEqual(trace.filter { $0.event == "wheel-hold" }.count, 1)
        XCTAssertFalse(trace.contains { $0.event == "wheel-commit" })
    }

    func testSharedWheelThresholdKeepsShortListsClickableAndLongListsDraggable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--effects-master-ui-test", "--reset-effects-master",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let columns = app.buttons["Items per row"]
        XCTAssertTrue(columns.waitForExistence(timeout: 10))
        let beforeTap = columns.value as? String
        columns.tap()
        let accepted = columns.value as? String
        XCTAssertNotEqual(accepted, beforeTap)
        let start = columns.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -54)))
        XCTAssertEqual(columns.value as? String, accepted, "Three choices use taps; dragging must not change them")
        let range = app.buttons["Photo range"]
        XCTAssertTrue(range.isHittable)
        let beforeDrag = range.value as? String
        let rangeY = range.frame.midY
        let rangeStart = range.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // General app preferences survive this effects-only fixture's reset.
        // Always drag away from the first detent when an earlier run saved it.
        let delta: CGFloat = beforeDrag?.hasPrefix("1 ") == true ? -54 : 54
        rangeStart.press(forDuration: 0.6, thenDragTo: rangeStart.withOffset(CGVector(dx: 0, dy: delta)))
        XCTAssertNotEqual(range.value as? String, beforeDrag)
        XCTAssertEqual(range.frame.midY, rangeY, accuracy: 1)
    }

    func testWorkbenchComparisonWaitsForHoldAndCancelsForScroll() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit-ui-test", "--audit-comparison"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["clear-trace"].waitForExistence(timeout: 10))
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: 170))
        func read() throws -> [Event] {
            app.buttons["read-trace"].tap()
            let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
            return try JSONDecoder().decode([Event].self, from: Data(json.utf8))
        }
        app.buttons["clear-trace"].tap()
        point.press(forDuration: 0.1)
        var trace = try read()
        XCTAssertEqual(trace.filter { $0.event == "comparison-tap" }.count, 1)
        XCTAssertFalse(trace.contains { $0.event == "comparison-on" })
        app.buttons["clear-trace"].tap()
        // Release just after the hold threshold, before the tap recognizer's
        // timeout: a long 1.1s hold alone cannot prove mutual exclusion.
        point.press(forDuration: 0.6)
        trace = try read()
        let down = try XCTUnwrap(trace.first { $0.event == "touch-down" })
        let on = try XCTUnwrap(trace.first { $0.event == "comparison-on" })
        XCTAssertGreaterThanOrEqual(on.milliseconds - down.milliseconds, 480)
        XCTAssertLessThan(on.milliseconds - down.milliseconds, 650)
        XCTAssertTrue(trace.contains { $0.event == "comparison-off" })
        XCTAssertFalse(trace.contains { $0.event == "comparison-tap" })
        app.buttons["clear-trace"].tap()
        point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: -140, dy: 0)))
        trace = try read()
        XCTAssertTrue(trace.contains { $0.event == "comparison-page-1" })
        XCTAssertFalse(trace.contains { $0.event == "comparison-on" || $0.event == "comparison-tap" })
        app.buttons["clear-trace"].tap()
        let rowY = app.staticTexts["Row 5"].frame.minY
        point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: 0, dy: -90)))
        trace = try read()
        XCTAssertFalse(trace.contains { $0.event == "comparison-on" || $0.event == "comparison-tap" })
        XCTAssertLessThan(app.staticTexts["Row 5"].frame.minY, rowY - 40)
    }

    func testEffectsImageDoubleTapExpandZoomHoldAndCloseStayExclusive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit-ui-test"]
        app.launch(); defer { app.terminate() }
        let state = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "ready=")).firstMatch
        func expect(_ node: XCUIElement, _ text: String) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: node)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        }
        expect(state, "ready=1")
        let thumbnail = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: 170))
        thumbnail.doubleTap()
        expect(state, "rotation=1")
        expect(state, "ready=1")
        thumbnail.tap()
        let expanded = app.staticTexts["expanded-gesture-state"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        expect(expanded, "zoom=2.50")
        let beforePan = expanded.label
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -60, dy: 0)))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", beforePan), object: expanded)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 3), .completed)
        center.doubleTap()
        expect(expanded, "zoom=1.00")
        center.press(forDuration: 0.6)
        XCTAssertTrue(expanded.exists, "A completed comparison hold must not also tap to close")
        expect(expanded, "comparison=0")
        center.tap()
        expect(state, "expanded=0")
    }

    func testGPSHoldDisablesBeforeReleaseWithoutReenablingAndNextTapWorks() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--gps-gesture-ui-test"]
        app.launch(); defer { app.terminate() }
        let button = app.buttons["gps-status-control"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["gps-enabled"].label, "1")
        button.press(forDuration: 0.3)
        XCTAssertEqual(app.staticTexts["gps-enabled"].label, "1")
        app.buttons["clear-trace"].tap()
        button.press(forDuration: 1.1)
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let attachment = XCTAttachment(string: json)
        attachment.name = "gps-hold-trace"; attachment.lifetime = .keepAlways; add(attachment)
        let trace = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
        let down = try XCTUnwrap(trace.first { $0.event == "touch-down" })
        let off = try XCTUnwrap(trace.first { $0.event == "gps-off" })
        XCTAssertGreaterThanOrEqual(off.milliseconds - down.milliseconds, 780)
        XCTAssertLessThan(off.milliseconds - down.milliseconds, 950)
        XCTAssertFalse(trace.contains { $0.event == "gps-on" })
        XCTAssertEqual(app.staticTexts["gps-enabled"].label, "0")
        button.tap()
        XCTAssertEqual(app.staticTexts["gps-enabled"].label, "1")
    }

    func testFilterPopupScrollAndWheelKeepIndependentOwnership() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--filter-gesture-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        app.buttons["Filter"].tap()
        let wheel = app.buttons["Range"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 10))
        // The long extension list forces the real popup's inner ScrollView.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        for _ in 0..<4 where !wheel.isHittable {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        }
        XCTAssertTrue(wheel.isHittable)
        let before = wheel.value as? String
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.6, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 28)))
        XCTAssertNotEqual(wheel.value as? String, before)
        XCTAssertTrue(app.buttons["Date"].isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: wheel)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

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
