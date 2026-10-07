import XCTest

@MainActor
final class RemoteToolsInteractionUITests: XCTestCase {
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
