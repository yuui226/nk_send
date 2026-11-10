import XCTest

@MainActor
final class PhotoEffectsMasterUITests: XCTestCase {
    private struct Event: Decodable { let event: String; let milliseconds: Int64 }
    func testSettingsPopupCanOpenAndCloseRepeatedlyWithNativeGlass() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--effects-master-ui-test", "--reset-effects-master", "--effects-popup-motion",
            "-skin_preset", "LIQUID_GLASS", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let open = app.buttons["photo-effects-test-popup-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            open.tap()
            let close = app.buttons.matching(NSPredicate(format: "label == %@", "Close")).firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertTrue(close.isHittable)
            close.tap()
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in open.isHittable }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        }
    }

    func testModuleVisibilityRestoresThroughRealPopupAndLocalWorkbench() throws {
        continueAfterFailure = false
        for local in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--effects-master-ui-test", "--reset-effects-master",
                local ? "--effects-np3-local" : "--effects-popup-motion",
                "-skin_preset", "LIQUID_GLASS", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            if !local {
                let open = app.buttons["photo-effects-test-popup-open"]
                XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
                let entry = app.buttons["photo-effects-open-editor"]
                XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            }
            let menu = app.buttons["photo-effect-modules"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
            let first = app.buttons["photo-effect-module-1"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            let origin = menu.frame
            for id in [1, 2, 16, 4, 8, 8, 4, 16, 2, 1] {
                let chip = app.buttons["photo-effect-module-\(id)"]
                XCTAssertTrue(chip.isHittable); chip.tap()
                XCTAssertTrue(first.isHittable, "Management remains open while content shrinks")
                XCTAssertEqual(menu.frame.minY, origin.minY, accuracy: 1, "Header must stay anchored")
                XCTAssertEqual(menu.frame.maxX, origin.maxX, accuracy: 1)
            }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = local ? "module-workbench-restored" : "module-popup-restored"
            shot.lifetime = .keepAlways; add(shot)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45)).tap()
            let closedMenu = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: first)
            XCTAssertEqual(XCTWaiter.wait(for: [closedMenu], timeout: 5), .completed)
            let header = XCTAttachment(screenshot: app.screenshot()); header.name = local ? "workbench-native-glass-header" : "popup-native-glass-header"
            header.lifetime = .keepAlways; add(header)
            app.buttons[local ? "tip-trigger-localEffects" : "tip-trigger-photoEffects"].tap()
            let closeHelp = app.buttons.matching(NSPredicate(format: "label == %@", "Close")).firstMatch
            XCTAssertTrue(closeHelp.waitForExistence(timeout: 5)); closeHelp.tap()
            let details = app.buttons["photo-frame-settings"]
            if !details.isHittable { app.swipeUp() }
            XCTAssertTrue(details.isHittable); details.tap()
            let expanded = XCTAttachment(screenshot: app.screenshot()); expanded.name = local ? "workbench-expanded-frame" : "popup-expanded-frame"
            expanded.lifetime = .keepAlways; add(expanded)
            if !local {
                let back = app.buttons["photo-effects-editor-back"]
                if !back.isHittable { app.swipeDown() }
                back.tap()
                XCTAssertTrue(app.buttons["photo-effects-open-editor"].waitForExistence(timeout: 5))
                app.buttons.matching(NSPredicate(format: "label == %@", "Close")).firstMatch.tap()
                let open = app.buttons["photo-effects-test-popup-open"]
                let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in open.isHittable }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
            }
            app.terminate()
        }
    }

    func testModuleMenuUsesCompactChipsAndRemainsOpenWhenChangingModules() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--effects-master-ui-test", "--reset-effects-master",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["photo-effects-open-editor"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        let menu = app.buttons["photo-effect-modules"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let filter = app.buttons["photo-effect-module-1"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in filter.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 5), .completed)
        let lut = app.buttons["photo-effect-module-2"]
        let frame = app.buttons["photo-effect-module-4"]
        let watermark = app.buttons["photo-effect-module-8"]
        XCTAssertEqual(filter.frame.height, 34, accuracy: 1)
        XCTAssertEqual(lut.frame.minY - filter.frame.maxY, 8, accuracy: 1)
        XCTAssertLessThanOrEqual(filter.frame.width, 132.5)
        XCTAssertGreaterThan(filter.frame.minY, menu.frame.maxY)
        filter.tap()
        XCTAssertTrue(lut.isHittable, "Toggling a module leaves the same menu open")
        filter.tap()
        XCTAssertTrue(frame.isHittable); XCTAssertTrue(watermark.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Photo effect module compact chips"; shot.lifetime = .keepAlways; add(shot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: filter)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        menu.tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        XCTAssertTrue(lut.isHittable)
    }

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
        let feedback = trace.filter { $0.event.hasPrefix("haptic-") }
        XCTAssertEqual(feedback.map(\.event), ["haptic-holdConfirmed"])
        XCTAssertGreaterThanOrEqual(feedback[0].milliseconds - down.milliseconds, 430)
    }

    func testWheelDragCommitsOnceWithoutHoldOrTap() throws {
        try verifyWheelDrag(holdAction: true)
    }

    func testWheelWithoutLongPressActionStillOwnsVerticalDrag() throws {
        try verifyWheelDrag(holdAction: false)
    }

    func testWheelCanDragAfterAStationaryHoldWithoutLongPressAction() throws {
        try verifyWheelDrag(holdAction: false, holdDuration: 0.8)
    }

    func testWheelBecomesDraggableWhenOptionsArrive() throws {
        try verifyWheelDrag(holdAction: false, loadsOptions: true)
    }

    private func verifyWheelDrag(holdAction: Bool, holdDuration: TimeInterval = 0.1, loadsOptions: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--gesture-audit-ui-test", "--audit-wheel"]
        if !holdAction { app.launchArguments.append("--audit-wheel-no-hold") }
        if loadsOptions { app.launchArguments.append("--audit-wheel-load-options") }
        app.launch(); defer { app.terminate() }
        let wheel = app.buttons["Audit wheel"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 10))
        if loadsOptions { app.buttons["load-wheel-options"].tap() }
        app.buttons["clear-trace"].tap()
        let start = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: holdDuration, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -54)),
                    withVelocity: .slow, thenHoldForDuration: 0.6)
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let trace = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
        XCTAssertEqual(trace.filter { $0.event == "wheel-commit" }.count, 1)
        XCTAssertFalse(trace.contains { $0.event == "wheel-hold" })
        XCTAssertNotEqual(wheel.value as? String, "5")
        let feedback = trace.filter { $0.event.hasPrefix("haptic-") }
        XCTAssertFalse(feedback.isEmpty, "Crossing actual detents still gives feedback")
        XCTAssertTrue(feedback.allSatisfy { $0.event == "haptic-selection" })
    }

    func testEmptyAndClampedWheelDragsDoNotVibrate() throws {
        for argument in ["--audit-wheel-load-options", "--audit-wheel-at-end"] {
            let app = XCUIApplication()
            app.launchArguments = ["--gesture-audit-ui-test", "--audit-wheel", argument]
            app.launch(); defer { app.terminate() }
            let wheel = app.buttons["Audit wheel"]
            XCTAssertTrue(wheel.waitForExistence(timeout: 10))
            let original = wheel.value as? String
            app.buttons["clear-trace"].tap()
            let start = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -54)),
                        withVelocity: .fast, thenHoldForDuration: 0.6)
            app.buttons["read-trace"].tap()
            let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
            let trace = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
            XCTAssertFalse(trace.contains { $0.event.hasPrefix("haptic-") }, json)
            XCTAssertFalse(trace.contains { $0.event == "wheel-commit" || $0.event == "wheel-hold" }, json)
            XCTAssertEqual(wheel.value as? String, original)
        }
    }

    func testInitialPhotoFilterEntryOpensFolderPickerAndCancelKeepsSetupLabel() {
        continueAfterFailure = false
        for local in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--effects-master-ui-test", "--reset-effects-master", "--effects-np3-fixture",
                                   "--effects-np3-fixture-no-folder", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if local { app.launchArguments.append("--effects-np3-local") }
            app.launch(); defer { app.terminate() }
            if !local {
                let entry = app.buttons["photo-effects-open-editor"]
                XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
            }
            let name = app.buttons["photo-np3-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertEqual(name.value as? String, "Set NP3 folder")
            name.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), "A tap must present the system directory picker")
            cancel.tap()
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertEqual(name.value as? String, "Set NP3 folder")
        }
    }

    func testPhotoEffectsNameAndIntensityDragInRealEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--effects-master-ui-test", "--reset-effects-master", "--effects-np3-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["photo-effects-open-editor"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        let name = app.buttons["photo-np3-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        var lastFrame = CGRect.zero
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = name.frame; defer { lastFrame = frame }
            return name.isHittable && frame == lastFrame
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 5), .completed)
        let previous = name.value as? String
        let start = name.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -45)))
        XCTAssertNotEqual(name.value as? String, previous)
        app.buttons["photo-np3-adjust"].tap()
        let intensity = app.buttons["Intensity"].firstMatch
        XCTAssertTrue(intensity.waitForExistence(timeout: 5))
        let value = intensity.value as? String
        let center = intensity.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.7, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 36)))
        XCTAssertNotEqual(intensity.value as? String, value)
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

    func testGPSColdLaunchWithOldEnabledFlagStaysOffBeforeAndAfterLocationGrant() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--gps-permission-ui-test", "--gps-legacy-enabled-ui-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addTeardownBlock {
            await MainActor.run { app.terminate(); app.resetAuthorizationStatus(for: .location) }
        }
        let status = app.staticTexts["gps-permission-status"]
        let button = app.buttons["gps-status-control"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for launch in 0..<2 {
            app.launch()
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertEqual(status.label, "OFF")
            let coldStart = XCTAttachment(screenshot: app.screenshot())
            coldStart.name = "gps-cold-launch-\(launch)"; coldStart.lifetime = .keepAlways; add(coldStart)
            XCTAssertTrue(["Enable GPS", "开启GPS", "開啟GPS"].contains(button.label), button.debugDescription)
            XCTAssertFalse(app.staticTexts["gps-permission-guidance"].exists)
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
            button.tap()
            if launch == 0 {
                let alert = springboard.alerts.firstMatch
                XCTAssertTrue(alert.waitForExistence(timeout: 5))
                alert.buttons.matching(NSPredicate(format: "label CONTAINS 'While Using' OR label CONTAINS '使用'"))
                    .firstMatch.tap()
            }
            let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "SEARCHING"), object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed)
            app.terminate()
        }
    }

    func testGPSFirstUseNativeLocationPromptCanEnableTransport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--gps-permission-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock {
            await MainActor.run { app.terminate(); app.resetAuthorizationStatus(for: .location) }
        }
        let button = app.buttons["gps-status-control"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "First use must show the actual system prompt")
        let prompt = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        prompt.name = "gps-native-location-request"; prompt.lifetime = .keepAlways; add(prompt)
        alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "While Using", "使用")).firstMatch.tap()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "SEARCHING"),
            object: app.staticTexts["gps-permission-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["gps-permission-guidance"].exists)
        XCTAssertEqual(app.staticTexts["gps-location-authorization"].label, "4")
    }

    func testGPSDeniedNativePermissionOpensSettingsAndKeepsGuidanceOnReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--gps-permission-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock {
            await MainActor.run { app.terminate(); app.resetAuthorizationStatus(for: .location) }
        }
        let button = app.buttons["gps-status-control"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允许", "不允許"])).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["gps-permission-guidance"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gps-permission-status"].label, "ERROR")
        let denied = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        denied.name = "gps-native-denied-guidance"; denied.lifetime = .keepAlways; add(denied)
        button.tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 5))
        let settingsEntry = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        settingsEntry.name = "gps-native-settings-entry"; settingsEntry.lifetime = .keepAlways; add(settingsEntry)
        // Do not make app tests depend on Simulator Settings' inconsistent row
        // navigation. Grant-and-return is covered by coordinator state tests;
        // this native test verifies denial, actual Settings launch and return.
        app.activate()
        XCTAssertTrue(app.staticTexts["gps-permission-guidance"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["gps-permission-status"].label, "ERROR")
        XCTAssertEqual(app.staticTexts["gps-location-authorization"].label, "2")
        let returned = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        returned.name = "gps-native-denied-return"; returned.lifetime = .keepAlways; add(returned)
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
        let material = XCTAttachment(screenshot: app.screenshot())
        material.name = "gps-enable-button-material"; material.lifetime = .keepAlways; add(material)
        button.tap()
        XCTAssertEqual(app.staticTexts["gps-enabled"].label, "1")
    }

    func testFilterResetKeepsPanelOpenAndQuickRepeatedTapsHavePressFeedback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--filter-gesture-ui-test", "--filter-compact", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        app.buttons["Filter"].tap()
        let reset = app.buttons["photo-filter-reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
        reset.tap(); reset.tap()
        XCTAssertTrue(reset.isHittable)
        XCTAssertTrue(app.staticTexts["filter-audit-state"].label.contains("date=nil:nil"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["filter-audit-trace"].value as? String)
        let events = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["event"] as? String == "action" }.count, 2)
        XCTAssertTrue(events.contains { ($0["event"] as? String) == "frame" && ($0["scale"] as? Double ?? 1) < 0.999 })
        let attachment = XCTAttachment(string: json); attachment.name = "filter-reset-press"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFilterDateButtonsFillRowsAndBackDiscardsOnlyDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--filter-gesture-ui-test", "--filter-compact", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        app.buttons["Filter"].tap()
        let date = app.buttons["photo-filter-date"]
        XCTAssertTrue(date.waitForExistence(timeout: 10)); date.tap()
        let clear = app.buttons["photo-filter-date-clear"], done = app.buttons["photo-filter-date-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        // AX bounds include the styled button's full interaction surface.
        // Assert matching usable rows, not equality with the 40pt label alone.
        XCTAssertGreaterThanOrEqual(done.frame.height, 40)
        XCTAssertLessThanOrEqual(done.frame.height, 44)
        XCTAssertEqual(clear.frame.height, done.frame.height, accuracy: 1)
        XCTAssertGreaterThan(done.frame.width, 100)
        XCTAssertEqual(clear.frame.width, done.frame.width, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "filter-date-buttons"; shot.lifetime = .keepAlways; add(shot)
        let months = app.buttons.matching(NSPredicate(format: "label == %@", "Month"))
        XCTAssertEqual(months.count, 2)
        XCTAssertEqual(months.element(boundBy: 0).value as? String, "03")
        months.element(boundBy: 0).tap()
        app.buttons["photo-filter-date-back"].tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5)); date.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(months.element(boundBy: 0).value as? String, "03")
        months.element(boundBy: 0).tap(); done.tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["filter-audit-state"].label.contains("date=20240201:20240415"))
        date.tap(); XCTAssertTrue(clear.waitForExistence(timeout: 5)); clear.tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["filter-audit-state"].label.contains("date=nil:nil"))
        date.tap(); XCTAssertTrue(done.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        app.buttons["Filter"].tap()
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertFalse(done.exists)
    }

    func testFilterPopupScrollAndWheelKeepIndependentOwnership() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--filter-gesture-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        app.buttons["Filter"].tap()
        let wheel = app.buttons["Rating load range"]
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
