import XCTest

@MainActor
final class RemoteToolsInteractionUITests: XCTestCase {

    func testMonitorHintUsesHeaderAndRotatedViewfinderAnchorsWithoutTouchThrough() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test", "--remote-hint-ui-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let input = app.otherElements["remote-viewfinder-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let hint = app.staticTexts["remote-monitor-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 4))
        XCTAssertEqual(hint.label, "Switch the camera to autofocus to use tap focus")
        XCTAssertLessThan(hint.frame.maxY, input.frame.minY)
        XCTAssertLessThan(hint.frame.maxX, app.buttons["remote-monitor-back"].frame.minX)
        XCTAssertLessThanOrEqual(hint.frame.width, 264)
        XCTAssertEqual(hint.frame.height, 26, accuracy: 1)
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "Monitor hint portrait header"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["remote-tool-rotate"].tap()
        XCTAssertTrue(app.buttons["remote-landscape-dock"].waitForExistence(timeout: 8))
        input.tap()
        XCTAssertTrue(hint.waitForExistence(timeout: 4))
        // A +90° local canvas maps its 20%-height anchor to the right side
        // of the still-portrait host. The 40pt slot is centered at +20pt.
        let image = input.frame, bubble = hint.frame
        XCTAssertEqual(bubble.midY, image.midY, accuracy: 2)
        XCTAssertEqual(bubble.midX, image.maxX - image.width * 0.20 - 20, accuracy: 2)
        XCTAssertLessThanOrEqual(bubble.height, 256)
        let before = input.value as? String
        hint.tap()
        XCTAssertEqual(input.value as? String, before, "Surface blocks taps from reaching the viewfinder")
        input.tap()
        XCTAssertNotEqual(input.value as? String, before, "The rest of the image remains interactive")
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Monitor hint landscape image anchor"; landscape.lifetime = .keepAlways; add(landscape)
    }

    func testProductionRecorderTimerPausesRotatesAndSaves() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test", "--remote-recording-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let start = app.buttons["remote-record-start-stop"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let timer = app.staticTexts["remote-record-elapsed"]
        XCTAssertTrue(timer.waitForExistence(timeout: 8), "Deny microphone access on the test simulator before running")
        let tick = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", " 0:00"), object: timer)
        XCTAssertEqual(XCTWaiter.wait(for: [tick], timeout: 5), .completed)
        XCTAssertLessThan(timer.frame.maxY, start.frame.minY)
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "Production recorder timer portrait"; portrait.lifetime = .keepAlways; add(portrait)

        let pause = app.buttons["remote-record-pause-resume"]
        let pauseLabel = pause.label
        pause.tap()
        XCTAssertNotEqual(pause.label, pauseLabel)
        let pausedTime = timer.label
        let noTick = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", pausedTime), object: timer)
        noTick.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noTick], timeout: 1.5), .completed)
        app.buttons["remote-tool-rotate"].tap()
        XCTAssertTrue(app.buttons["remote-landscape-dock"].waitForExistence(timeout: 8))
        XCTAssertEqual(timer.label, pausedTime, "Rotation must preserve the same paused recorder")
        XCTAssertFalse(timer.frame.intersects(start.frame))
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Production recorder timer paused landscape"; landscape.lifetime = .keepAlways; add(landscape)
        pause.tap()
        XCTAssertEqual(pause.label, pauseLabel)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", pausedTime), object: timer)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
        start.tap()
        // The saved state lasts 1800ms. Check both conditions together instead
        // of spending a polling interval on each and missing the short feedback.
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                ["录制已保存", "Recording saved", "錄製已儲存"].contains(start.label) && !timer.exists
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 4), .completed)
        let savedImage = XCTAttachment(screenshot: app.screenshot())
        savedImage.name = "Production recorder saved landscape"; savedImage.lifetime = .keepAlways; add(savedImage)
    }

    func testRecorderLockedHintFollowsProductionToolbarRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let start = app.buttons["remote-record-start-stop"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let hint = app.staticTexts["remote-record-locked-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 2))
        XCTAssertLessThan(hint.frame.maxY, start.frame.minY)
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "Portrait recorder locked hint"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["remote-tool-rotate"].tap()
        XCTAssertTrue(app.buttons["remote-landscape-dock"].waitForExistence(timeout: 8))
        XCTAssertTrue(start.isHittable)
        start.tap()
        XCTAssertTrue(hint.waitForExistence(timeout: 2))
        XCTAssertFalse(hint.frame.intersects(start.frame))
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Landscape recorder locked hint"; landscape.lifetime = .keepAlways; add(landscape)
    }

    func testRecorderLockedHintAndRecordPauseFinalizeSavedActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-recorder-ui-test"]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["remote-record-start-stop"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let hint = app.staticTexts["remote-record-locked-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 3))
        XCTAssertLessThan(hint.frame.maxY, start.frame.minY)
        let state = app.staticTexts["test-recorder-state"]
        XCTAssertEqual(state.label, "phase=idle starts=0 stops=0")
        app.buttons["test-recorder-premium"].tap()
        start.tap()
        XCTAssertEqual(state.label, "phase=recording starts=1 stops=0")
        let pause = app.buttons["remote-record-pause-resume"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        pause.tap()
        XCTAssertEqual(state.label, "phase=paused starts=1 stops=0")
        pause.tap()
        XCTAssertEqual(state.label, "phase=recording starts=1 stops=0")
        app.buttons["test-recorder-premium"].tap() // losing Pro never disables stop
        start.tap()
        XCTAssertEqual(state.label, "phase=finalizing starts=1 stops=1")
        start.tap()
        XCTAssertEqual(state.label, "phase=finalizing starts=1 stops=1")
        app.buttons["test-recorder-saved"].tap()
        start.tap()
        XCTAssertEqual(state.label, "phase=saved starts=1 stops=1")
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "Recorder saved capsule"; saved.lifetime = .keepAlways; add(saved)
        app.buttons["test-recorder-compact"].tap()
        XCTAssertTrue(start.isHittable)
        let compact = XCTAttachment(screenshot: app.screenshot())
        compact.name = "Recorder compact saved"; compact.lifetime = .keepAlways; add(compact)
    }

    func testShutterQuickTapHoldCancelAndLandscapeReleaseUseProductionInput() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test", "--remote-shutter-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let shutter = app.buttons["remote-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        let events = app.staticTexts["test-shutter-events"]
        func expect(_ label: String) {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: events)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed, events.label)
        }
        shutter.tap()
        expect("focus=0 finished=0 capture=1")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        let center = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.4, thenDragTo: center.withOffset(CGVector(dx: 100, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        expect("focus=1 finished=1 capture=1")
        shutter.press(forDuration: 0.4)
        expect("focus=2 finished=2 capture=2")
        app.buttons["remote-tool-rotate"].tap()
        XCTAssertTrue(app.buttons["remote-landscape-dock"].waitForExistence(timeout: 8))
        shutter.press(forDuration: 0.4)
        expect("focus=3 finished=3 capture=3")
    }

    func testParameterLongListStartsThreeRowsBeforeCurrentValue() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test", "--remote-exposure-ui-test", "--remote-exposure-long-list-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let iso = app.buttons["remote-parameter-iso"]
        XCTAssertTrue(iso.waitForExistence(timeout: 10))
        iso.tap()
        let selected = app.buttons["remote-parameter-choice-2000"]
        XCTAssertTrue(selected.waitForExistence(timeout: 8))
        XCTAssertTrue(selected.isHittable)
        let first = app.buttons["remote-parameter-choice-1700"]
        XCTAssertTrue(first.isHittable)
        XCTAssertFalse(app.buttons["remote-parameter-choice-100"].isHittable)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Parameter list initial offset"
        image.lifetime = .keepAlways
        add(image)
        first.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1700"), object: iso)
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 8), .completed)
    }

    func testParameterValueListAnchorsSelectsAndClosesInBothOrientations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test", "--remote-exposure-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let iso = app.buttons["remote-parameter-iso"]
        XCTAssertTrue(iso.waitForExistence(timeout: 10))
        iso.tap()
        let option = app.buttons["remote-parameter-choice-200"]
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        XCTAssertEqual(option.label, "200")
        XCTAssertGreaterThanOrEqual(option.frame.minY, iso.frame.maxY)
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "Portrait parameter anchored list"
        portrait.lifetime = .keepAlways
        add(portrait)
        option.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "200"), object: iso)
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 8), .completed)
        app.buttons["remote-tool-rotate"].tap()
        XCTAssertTrue(app.buttons["remote-landscape-dock"].waitForExistence(timeout: 8))
        iso.tap()
        let next = app.buttons["remote-parameter-choice-800"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        XCTAssertFalse(next.frame.intersects(iso.frame))
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Landscape parameter list beside tile"
        landscape.lifetime = .keepAlways
        add(landscape)
        next.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
    }

    func testParameterAutoCornerDragAndLandscapeRemainIndependent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test", "--remote-exposure-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let iso = app.descendants(matching: .any).matching(identifier: "remote-parameter-iso").firstMatch
        let auto = app.buttons["remote-parameter-iso-auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10))
        func expect(_ element: XCUIElement, _ value: String) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
        }
        expect(iso, "400"); expect(auto, "0")
        // Begin inside the AUTO hit region; exceeding vertical slop must use
        // the camera wheel and must not trigger the corner toggle on release.
        let start = auto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 26)), withVelocity: .slow, thenHoldForDuration: 0.1)
        expect(iso, "800"); expect(auto, "0")
        auto.tap()
        expect(auto, "1"); expect(iso, "640")
        let readOnly = XCTAttachment(screenshot: app.screenshot())
        readOnly.name = "Parameter tiles with AUTO and read-only shutter"
        readOnly.lifetime = .keepAlways
        add(readOnly)
        auto.tap()
        expect(auto, "0"); expect(iso, "800")
        app.buttons["remote-tool-rotate"].tap()
        XCTAssertTrue(app.buttons["remote-landscape-dock"].waitForExistence(timeout: 8))
        XCTAssertTrue(auto.isHittable)
        auto.tap()
        expect(auto, "1"); expect(iso, "640")
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Landscape parameter tiles"
        landscape.lifetime = .keepAlways
        add(landscape)
    }

    func testLandscapeShellAndDockWorkBeforeCameraHasLoaded() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let rotate = app.buttons["remote-tool-rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        rotate.tap()
        let dock = app.buttons["remote-landscape-dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 8))
        let disp = app.buttons["remote-tool-disp"]
        XCTAssertTrue(disp.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["remote-tools-manage"].exists)
        let trial = app.staticTexts["remote-trial-countdown"]
        if trial.exists {
            XCTAssertFalse(trial.frame.intersects(app.buttons["remote-monitor-back"].frame))
            XCTAssertNotNil(trial.label.range(of: "^[0-9]+:[0-9]{2}$", options: .regularExpression))
        }
        let shell = XCTAttachment(screenshot: app.screenshot())
        shell.name = "Landscape shell before first frame"
        shell.lifetime = .keepAlways
        add(shell)
        dock.tap()
        let hd = app.buttons["remote-tool-hd"]
        XCTAssertTrue(hd.waitForExistence(timeout: 8))
        let outgoing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: disp)
        XCTAssertEqual(XCTWaiter.wait(for: [outgoing], timeout: 8), .completed)
        XCTAssertTrue(hd.isHittable)
        let drawer = XCTAttachment(screenshot: app.screenshot())
        drawer.name = "Landscape Dock before first frame"
        drawer.lifetime = .keepAlways
        add(drawer)
        // The label below GRID must execute the same action as its icon.
        let grid = app.buttons["remote-tool-grid"]
        if !grid.isHittable { app.swipeUp() }
        XCTAssertTrue(grid.isHittable)
        app.buttons["remote-dock-label-grid"].tap()
        let choice = app.buttons["remote-grid-choice-OFF"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        choice.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: choice)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        dock.tap()
        XCTAssertTrue(disp.waitForExistence(timeout: 8))
        XCTAssertTrue(rotate.isHittable)
        app.buttons["remote-monitor-back"].tap()
        XCTAssertTrue(app.buttons["open-monitor"].waitForExistence(timeout: 8))
    }

    func testHorizonSwitchesBetweenLiveFrameAndSingleAxisAndHides() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test", "--remote-level-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let level = app.buttons["remote-tool-level"]
        XCTAssertTrue(level.waitForExistence(timeout: 10))
        level.tap()
        let state = app.staticTexts["remote-horizon-state"]
        func expect(_ label: String) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, state.exists ? state.label : "Horizon missing")
        }
        expect("dual=true;angle=12.5")
        app.buttons["test-level-single"].tap()
        expect("dual=false;angle=45.0")
        app.buttons["test-level-dual"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "dual=true;"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 8), .completed, state.exists ? state.label : "Horizon missing")
        app.buttons["remote-tools-manage"].tap()
        level.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 8), .completed)
    }

    func testViewfinderPinchPanDoubleTapAndDesqueezeReset() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let input = app.otherElements["remote-viewfinder-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let state = app.staticTexts["remote-viewport-state"]
        func expectReset() {
            let reset = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "scale=1.0;x=0.0;y=0.0"), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 8), .completed, state.label + " " + String(describing: input.value))
        }
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        expectReset()
        input.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(Float(state.label.split(separator: ";")[0].dropFirst(6)) ?? 0, 1.1, state.label)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: input.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6)))
        XCTAssertFalse(state.label.contains("x=0.0;y=0.0"))
        // XCTest doubleTap has effectively zero up-to-next-down delay (~13µs),
        // below Compose's 40ms minimum. Its third tap starts >40ms after first up:
        // Android ignores the too-early second down, then accepts this valid pair.
        input.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        expectReset()
        input.pinch(withScale: 2, velocity: 1)
        XCTAssertGreaterThan(Float(state.label.split(separator: ";")[0].dropFirst(6)) ?? 0, 1.1, state.label)
        app.buttons["remote-tool-desqueeze"].tap()
        expectReset()
    }

    func testGridMenuSelectionPersistsAndHiddenToolResetsGrid() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let grid = app.buttons["remote-tool-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        func closeExpectation(_ element: XCUIElement) {
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        }
        grid.tap()
        let golden = app.buttons["remote-grid-choice-GOLDEN"]
        XCTAssertTrue(golden.waitForExistence(timeout: 8))
        let firstRow = app.buttons["remote-grid-choice-OFF"]
        XCTAssertEqual(firstRow.frame.height, 36, accuracy: 1)
        golden.tap()
        closeExpectation(golden)
        grid.tap()
        XCTAssertTrue(golden.waitForExistence(timeout: 8))
        XCTAssertTrue(golden.isSelected)
        golden.tap()
        closeExpectation(golden)
        app.buttons["remote-monitor-back"].tap()
        XCTAssertTrue(app.buttons["open-monitor"].waitForExistence(timeout: 8))
        app.buttons["open-monitor"].tap()
        grid.tap()
        XCTAssertTrue(golden.waitForExistence(timeout: 8))
        XCTAssertTrue(golden.isSelected)
        app.buttons["remote-monitor-back"].tap()
        closeExpectation(golden)
        let manage = app.buttons["remote-tools-manage"]
        manage.tap()
        grid.tap() // Hide disables and persists OFF.
        grid.tap() // Restore must not restore the previous active mode.
        manage.tap()
        grid.tap()
        let off = app.buttons["remote-grid-choice-OFF"]
        XCTAssertTrue(off.waitForExistence(timeout: 8))
        XCTAssertTrue(off.isSelected)
        off.tap()
        closeExpectation(off)
    }

    func testCameraToolMenusUseActualRowsWriteAndCloseThenRestoreSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test", "--remote-camera-tools-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let wb = app.buttons["remote-tool-white_balance"]
        XCTAssertTrue(wb.waitForExistence(timeout: 10))
        wb.tap()
        let auto = app.buttons["remote-camera-choice-2"]
        let sunlight = app.buttons["remote-camera-choice-4"]
        let fluorescent = app.buttons["remote-camera-choice-5"]
        XCTAssertTrue(sunlight.waitForExistence(timeout: 8))
        XCTAssertEqual(auto.frame.midY, sunlight.frame.midY, accuracy: 2)
        XCTAssertEqual(sunlight.frame.midY, fluorescent.frame.midY, accuracy: 2)
        sunlight.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sunlight)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        wb.tap()
        XCTAssertTrue(sunlight.waitForExistence(timeout: 8))
        XCTAssertTrue(sunlight.isSelected)
        sunlight.tap() // Selecting the current value only closes the menu.
        let reclosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sunlight)
        XCTAssertEqual(XCTWaiter.wait(for: [reclosed], timeout: 8), .completed)
        app.buttons["remote-tool-focus_area"].tap()
        let single = app.buttons["remote-camera-choice-32784"]
        let dynamic25 = app.buttons["remote-camera-choice-2"]
        let dynamic72 = app.buttons["remote-camera-choice-32787"]
        XCTAssertTrue(dynamic72.waitForExistence(timeout: 8))
        XCTAssertLessThan(single.frame.midY, dynamic25.frame.midY)
        XCTAssertLessThan(dynamic25.frame.midY, dynamic72.frame.midY)
        XCTAssertTrue(dynamic25.label.contains("25"))
        XCTAssertTrue(dynamic72.label.contains("72"))
        XCTAssertTrue(app.buttons["remote-camera-choice-99999"].exists)
        dynamic25.tap()
        let focusClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dynamic25)
        XCTAssertEqual(XCTWaiter.wait(for: [focusClosed], timeout: 8), .completed)
        app.buttons["remote-tool-focus_area"].tap()
        XCTAssertTrue(dynamic25.waitForExistence(timeout: 8))
        XCTAssertTrue(dynamic25.isSelected)
        app.swipeDown() // Backdrop/scroll drag must not activate a choice.
        app.buttons["remote-monitor-back"].tap()
        let backClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dynamic25)
        XCTAssertEqual(XCTWaiter.wait(for: [backClosed], timeout: 8), .completed)
        XCTAssertTrue(app.buttons["remote-tools-manage"].isHittable)
        wb.doubleTap() // Close while the initial descriptor is still loading.
        let loadingClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sunlight)
        XCTAssertEqual(XCTWaiter.wait(for: [loadingClosed], timeout: 8), .completed)
        app.buttons["remote-tools-manage"].tap()
        XCTAssertTrue(app.buttons["remote-tool-white_balance"].isHittable)
    }

    func testProductionEditorHidesRestoresAndDragsWithoutDropClick() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let manage = app.buttons["remote-tools-manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.tap()
        let state = app.staticTexts["remote-tool-state"]
        func expect(_ text: String) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
        }
        let hd = app.buttons["remote-tool-hd"]
        let fps = app.buttons["remote-tool-fps"]
        XCTAssertTrue(hd.waitForExistence(timeout: 5))
        hd.tap()
        expect("hidden=hd")
        hd.tap()
        expect("hidden=")
        XCTAssertFalse(state.label.contains("hidden=hd"))
        // Restored HD is now on the final row, then dragged back onto FPS.
        hd.press(forDuration: 0.05, thenDragTo: fps)
        expect("order=hd,fps")
        XCTAssertFalse(state.label.contains("hidden=hd"))
        hd.tap()
        expect("hidden=hd")
        hd.press(forDuration: 0.05, thenDragTo: fps)
        expect("hidden=hd")
        manage.tap()
        XCTAssertFalse(hd.exists)
        manage.tap()
        XCTAssertTrue(hd.exists)
        for id in ["fps", "histogram", "grid", "exposure", "desqueeze", "level", "record", "white_balance", "focus_area", "lock"] {
            app.buttons["remote-tool-\(id)"].tap()
        }
        manage.tap()
        XCTAssertTrue(manage.isHittable)
        XCTAssertFalse(fps.exists)
        manage.tap()
        XCTAssertTrue(fps.exists)
        app.buttons["remote-monitor-back"].tap()
        XCTAssertTrue(manage.exists)
        XCTAssertFalse(hd.exists)
        app.buttons["remote-monitor-back"].tap()
        XCTAssertTrue(app.buttons["open-monitor"].waitForExistence(timeout: 5))
    }
    func testLockRestoresAcrossOpeningAndHideUnlocksWithoutReattachingDefaultSlot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--remote-tools-ui-test"]
        app.launch()
        defer { app.terminate() }
        app.buttons["open-monitor"].tap()
        let lock = app.buttons["remote-tool-lock"]
        let rotate = app.buttons["remote-tool-rotate"]
        let manage = app.buttons["remote-tools-manage"]
        XCTAssertTrue(lock.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(lock.frame.midY, rotate.frame.midY)
        XCTAssertEqual(lock.frame.midX, app.buttons["remote-tool-hd"].frame.midX, accuracy: 2)
        lock.tap()
        XCTAssertFalse(rotate.isEnabled)
        app.buttons["remote-monitor-back"].tap()
        app.buttons["open-monitor"].tap()
        XCTAssertTrue(lock.waitForExistence(timeout: 10))
        XCTAssertFalse(rotate.isEnabled)
        manage.tap()
        lock.tap() // Hiding the tool must also unlock the persisted direction.
        manage.tap()
        XCTAssertFalse(lock.exists)
        XCTAssertTrue(rotate.isEnabled)
        manage.tap()
        lock.tap() // Restore to visible tail, retaining unlocked state.
        let state = app.staticTexts["remote-tool-state"]
        XCTAssertTrue(state.label.contains("lock;hidden="))
        lock.press(forDuration: 0.05, thenDragTo: app.buttons["remote-tool-hd"])
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "order=lock,hd"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 8), .completed)
        manage.tap()
        XCTAssertTrue(rotate.isEnabled)
    }

}
