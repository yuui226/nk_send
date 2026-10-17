import XCTest

@MainActor
final class PhotoPreviewInteractionUITests: XCTestCase {
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
