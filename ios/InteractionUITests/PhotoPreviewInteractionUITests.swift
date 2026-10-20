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
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-app_language", "en", "-haptics_enabled", "YES"] + arguments
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

    func testWorkspaceQueueRoundTripKeepsScrollAndCapsuleAnchorThenMonitorReturns() throws {
        continueAfterFailure = false
        let app = launchHoldFixture(["--scroll-hold-fixture", "--defer-admission", "--all-local-admission"])
        defer { app.terminate() }
        firstGridCenter(app).tap()
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "count=1;waiting=1"), object: app.staticTexts["admission-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 5), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35)))
        let cell = try XCTUnwrap(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-cell-")).allElementsBoundByIndex.first {
            $0.frame.midY > app.frame.height * 0.4 && $0.frame.midY < app.frame.height * 0.6
        })
        let identifier = cell.identifier, frame = cell.frame
        let pill = app.buttons["workspace-queue-open"]
        let rightEdge = pill.frame.maxX
        for _ in 0..<2 {
            pill.tap()
            XCTAssertTrue(app.buttons["workspace-queue-back"].waitForExistence(timeout: 3))
            XCTAssertEqual(pill.frame.maxX, rightEdge, accuracy: 1)
            app.buttons["workspace-queue-back"].tap()
            XCTAssertTrue(app.buttons["popup-trigger-settings"].waitForExistence(timeout: 3))
            let returned = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertEqual(returned.frame.minY, frame.minY, accuracy: 2)
            XCTAssertEqual(pill.frame.maxX, rightEdge, accuracy: 1)
        }
        // The off-top monitor affordance first expands, then enters monitor.
        func monitorEntry() throws -> XCUIElement {
            try XCTUnwrap(app.buttons.matching(identifier: "workspace-monitor-open").allElementsBoundByIndex.first { $0.isHittable })
        }
        try monitorEntry().tap()
        if !app.buttons["remote-monitor-back"].exists { try monitorEntry().tap() }
        XCTAssertTrue(app.buttons["remote-monitor-back"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace-queue-open"].isHittable)
        let monitor = XCTAttachment(screenshot: app.screenshot())
        monitor.name = "workspace-monitor"; monitor.lifetime = .keepAlways; add(monitor)
        app.buttons["remote-monitor-back"].tap()
        XCTAssertTrue(app.buttons["popup-trigger-settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)[identifier].firstMatch.frame.minY, frame.minY, accuracy: 2)
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "workspace-files-returned"; returned.lifetime = .keepAlways; add(returned)
        let trace = try readHoldTrace(app, name: "workspace-page-updates")
        let starts = trace.enumerated().filter { $0.element.event.hasPrefix("workspace-") &&
            ($0.element.event.hasSuffix("-enter") || $0.element.event.hasSuffix("-exit")) }
        XCTAssertEqual(starts.count, 6)
        for (index, start) in starts {
            let end = try XCTUnwrap(trace[(index + 1)...].firstIndex { $0.event.hasSuffix("-settled") })
            let updates = trace[(index + 1)..<end].filter { $0.event == "files-workspace-body" }.count
            XCTAssertLessThanOrEqual(updates, 6, "\(start.event): global geometry must not rebuild the whole grid every frame (\(updates))")
        }

    }

    func testColdMonitorEntryFrameTimingAndReturnAcrossFreshProcesses() throws {
        continueAfterFailure = false
        for run in 1...3 {
            let app = launchHoldFixture(["--scroll-hold-fixture", "--defer-admission", "--all-local-admission"])
            defer { app.terminate() }
            app.buttons["clear-trace"].tap()
            let entry = try XCTUnwrap(app.buttons.matching(identifier: "workspace-monitor-open")
                .allElementsBoundByIndex.first { $0.isHittable })
            entry.tap()
            XCTAssertTrue(app.buttons["remote-monitor-back"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["workspace-queue-open"].isHittable)
            if run == 1 {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "cold-monitor-controls"; screenshot.lifetime = .keepAlways; add(screenshot)
            }
            app.buttons["remote-monitor-back"].tap()
            XCTAssertTrue(app.buttons["popup-trigger-settings"].waitForExistence(timeout: 5))
            let warmed = try XCTUnwrap(app.buttons.matching(identifier: "workspace-monitor-open")
                .allElementsBoundByIndex.first { $0.isHittable })
            warmed.tap()
            XCTAssertTrue(app.buttons["remote-monitor-back"].waitForExistence(timeout: 5))
            app.buttons["remote-monitor-back"].tap()
            let trace = try readHoldTrace(app, name: "cold-monitor-\(run)")
            XCTAssertEqual(trace.filter { $0.event == "monitor-owner-created" }.count, 2,
                "Exactly one owner per presentation, even when parent/list state refreshes")
            let start = try XCTUnwrap(trace.firstIndex { $0.event == "workspace-monitor-enter" })
            let end = try XCTUnwrap(trace[(start + 1)...].firstIndex { $0.event == "workspace-monitor-settled" })
            let frames = trace[start...end].filter { $0.event == "workspace-monitor-frame" }
            XCTAssertGreaterThan(frames.count, 3, "The real mounted page must render intermediate transition frames")
            let delays = zip([trace[start].milliseconds] + frames.map(\.milliseconds), frames.map(\.milliseconds))
                .map { $1 - $0 }
            let report = XCTAttachment(string: "first=\(try XCTUnwrap(delays.first))ms; gaps=\(delays); total=\(trace[end].milliseconds - trace[start].milliseconds)ms")
            report.name = "cold-monitor-timing-\(run)"; report.lifetime = .keepAlways; add(report)
        }
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
            XCTAssertEqual(trace.filter { $0.event == "haptic-preview" }.count, 1)
            XCTAssertFalse(trace.contains { $0.event == "haptic-holdStarted" }, "Normal preview only confirms at recognition")
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
                XCTAssertEqual(trace.filter { $0.event == "haptic-enqueue" }.count, 1)
                let began = try XCTUnwrap(trace.first { $0.event == "haptic-holdStarted" })
                let confirmed = try XCTUnwrap(trace.first { $0.event == "haptic-enqueue" })
                XCTAssertGreaterThan(confirmed.milliseconds - began.milliseconds, 100, "Anticipation must precede recognition")
                XCTAssertTrue(trace.contains { $0.event == "haptic-holdCancelled" })
                XCTAssertFalse(trace.contains { $0.event == "haptic-holdCompleted" }, "Enqueue is the sole confirmation")
            } else {
                XCTAssertTrue(app.staticTexts["preview-state"].exists)
                XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
                XCTAssertFalse(trace.contains { $0.event == "photo-long-press" })
                XCTAssertEqual(trace.filter { $0.event == "preview-request" }.count, 1)
            }
        }
    }

    func testReversePhotoScrollCancelsHapticHoldWithoutEnqueue() throws {
        continueAfterFailure = false
        let app = launchHoldFixture(["--defer-admission", "--preview-admission", "--scroll-hold-fixture"])
        defer { app.terminate() }
        let center = firstGridCenter(app)
        app.buttons["clear-trace"].tap()
        center.press(forDuration: 0.06, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -150)))
        let trace = try readHoldTrace(app, name: "reverse-scroll-haptic-cancel")
        XCTAssertTrue(trace.contains { $0.event == "haptic-holdStarted" })
        XCTAssertTrue(trace.contains { $0.event == "haptic-holdCancelled" })
        XCTAssertFalse(trace.contains { $0.event == "haptic-enqueue" || $0.event == "haptic-preview" })
        XCTAssertFalse(trace.contains { $0.event == "photo-long-press" })
        XCTAssertTrue(trace.contains { $0.event == "photo-scroll" })
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
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
        // A retired offline catalog intentionally does not scan. Load the real
        // catalog first, then disconnect while its preview remains mounted.
        let app = launchHoldFixture(["--preview-admission"])
        defer { app.terminate() }
        let missing = app.descendants(matching: .any).matching(identifier: "photo-cell-702").firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        missing.tap()
        XCTAssertTrue(app.staticTexts["preview-state"].waitForExistence(timeout: 5))
        app.buttons["admission-connection"].tap()
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

    func testPreviewUpwardDragAcceptsOnceAndKeepsPagerUsable() throws {
        continueAfterFailure = false
        let app = launchHoldFixture(["--preview-admission", "--defer-admission", "--all-local-admission", "--preview-motion-fixture"])
        defer { app.terminate() }
        firstGridCenter(app).tap()
        XCTAssertTrue(app.staticTexts["preview-state"].waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -45)))
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 100)))
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=0"))
        start.press(forDuration: 0.05, thenDragTo: end)
        let trace = try readHoldTrace(app, name: "preview-opening-and-upward")
        let pages = trace.filter { $0.event.hasPrefix("preview-page:") }
        XCTAssertFalse(pages.isEmpty)
        XCTAssertTrue(pages.allSatisfy { $0.event == "preview-page:0:offset=0.0" },
            "Opening and vertical scaling must never be interpreted as horizontal paging: \(pages.map(\.event))")
        let viewports = Set(trace.filter { $0.event.hasPrefix("preview-viewport:") }.map(\.event))
        XCTAssertEqual(viewports.count, 1, "Safe-area sizing must remain fixed through opening, FHD and throw: \(viewports)")
        let fhdTime = try XCTUnwrap(trace.first { $0.event.hasPrefix("preview-image:fhd:") }?.milliseconds)
        let imageFrames = trace.filter { $0.milliseconds < fhdTime && $0.event.hasPrefix("preview-image:thumb:") }
        XCTAssertGreaterThan(imageFrames.count, 3)
        let rects = imageFrames.map { $0.event.split(separator: ":").dropFirst(3).compactMap { Double($0) } }
        let first = try XCTUnwrap(rects.first), last = try XCTUnwrap(rects.last)
        XCTAssertGreaterThan(last[2] - first[2], 40)
        for rect in rects {
            let fraction = (rect[2] - first[2]) / (last[2] - first[2])
            XCTAssertEqual(rect[1], first[1] + (last[1] - first[1]) * fraction, accuracy: 2,
                "Opening must stay on one continuous trajectory regardless of sample timing")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "preview-after-upward-flight"; shot.lifetime = .keepAlways; add(shot)
        let accepted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "count=1;waiting=1"), object: app.staticTexts["admission-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["preview-state"].exists)
        XCTAssertEqual(app.staticTexts["admission-flight-state"].label, "flights=0;held=0")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45)))
        XCTAssertTrue(app.staticTexts["preview-state"].label.contains("page=1"))
        start.press(forDuration: 0.05, thenDragTo: end)
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "count=2;waiting=2"), object: app.staticTexts["admission-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 5), .completed)
    }

    func testUpwardDiagonalLocksPagerAndDoesNotRebuildPreviewPerMove() throws {
        continueAfterFailure = false
        let app = launchHoldFixture(["--preview-admission", "--defer-admission", "--all-local-admission", "--preview-motion-fixture"])
        defer { app.terminate() }
        firstGridCenter(app).tap()
        XCTAssertTrue(app.staticTexts["preview-state"].waitForExistence(timeout: 5))
        app.buttons["clear-trace"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -130, dy: -220)),
                    withVelocity: XCUIGestureVelocity(rawValue: 200), thenHoldForDuration: 0.15)
        let trace = try readHoldTrace(app, name: "upward-diagonal-paging-and-rendering")
        let moves = trace.filter { $0.event.hasPrefix("queue-move:") }
        XCTAssertGreaterThan(moves.count, 5)
        let begin = try XCTUnwrap(moves.dropFirst(3).first?.milliseconds)
        let end = try XCTUnwrap(moves.last?.milliseconds)
        let rebuilds = trace.filter { $0.event == "preview-body" && $0.milliseconds > begin && $0.milliseconds < end }
        XCTAssertLessThanOrEqual(rebuilds.count, 1, "Finger tracking must not rebuild the whole preview: \(rebuilds.count) bodies / \(moves.count) moves")
        let images = trace.filter { $0.event.hasPrefix("preview-image:fhd:") && $0.milliseconds > begin && $0.milliseconds < end }
        let frames = images.map { $0.event.split(separator: ":").dropFirst(3).compactMap { Double($0) } }
        XCTAssertGreaterThan(frames.count, 5)
        for frame in frames {
            XCTAssertEqual(frame[0] + frame[2] / 2, app.frame.width / 2, accuracy: 1,
                "Horizontal finger movement must not move the displayed photo sideways")
        }
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(next[1], previous[1] + 0.1, "The upward image trajectory must not jump back")
            XCTAssertLessThan(previous[1] - next[1], 20, "Slow tracking must not jump between distant positions")
        }
        XCTAssertTrue(app.staticTexts["preview-state"].label.contains("page=0"))
        XCTAssertTrue(app.staticTexts["admission-state"].label.contains("count=1;waiting=1"))
        let pages = trace.filter { $0.event.hasPrefix("preview-page:") }
        XCTAssertTrue(pages.allSatisfy { $0.event == "preview-page:0:offset=0.0" }, "Upward drag must not move the horizontal pager: \(pages.map(\.event))")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45)))
        XCTAssertTrue(app.staticTexts["preview-state"].label.contains("page=1"), "Lift-off must release the pager for the next gesture")
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
