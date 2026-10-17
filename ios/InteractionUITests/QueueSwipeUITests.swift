import XCTest

@MainActor
final class QueueSwipeUITests: XCTestCase {
    func testInsertionMovesExistingProductionCardThroughIntermediatePositions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-swipe-ui-test", "--queue-placement-test",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        expect(app.staticTexts["queue-swipe-count"], label: "count=12")
        app.buttons["queue-placement-insert"].tap()
        let result = app.staticTexts["queue-placement-result"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            result.label.hasPrefix("done;")
        }, object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
        let values = result.label.split(separator: ";").dropFirst().compactMap {
            Int($0.split(separator: "=").last ?? "")
        }
        XCTAssertEqual(values.count, 2)
        guard values.count == 2 else { return }
        XCTAssertGreaterThan(values[0], 40)
        XCTAssertGreaterThan(values[1], 3)
        expect(app.staticTexts["queue-swipe-count"], label: "count=13")
        let attachment = XCTAttachment(string: result.label)
        attachment.name = "Existing card window-coordinate insertion samples"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCardBecomingBusyDuringRealDragReturnsWithoutRemoval() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-swipe-ui-test", "--queue-swipe-busy",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let count = app.staticTexts["queue-swipe-count"]
        expect(count, label: "count=1")
        let card = app.staticTexts["SWIPE_1.JPG"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let original = card.frame
        app.buttons["queue-swipe-arm-busy"].tap()
        // The host starts the real worker only after observing >=30pt of
        // actual card movement. No fixed-delay race can pass without a drag.
        drag(app, y: original.midY, delta: 180)
        expect(app.staticTexts["queue-swipe-busy-state"], label: "drag=true;busy=true")
        expect(count, label: "count=1")
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            card.exists && abs(card.frame.minX - original.minX) < 1
        }, object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["queue-remove-1"].exists)
        drag(app, y: card.frame.midY, delta: -180)
        expect(count, label: "count=1")
        XCTAssertEqual(card.frame.minX, original.minX, accuracy: 1)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Busy card restored and protected"; image.lifetime = .keepAlways; add(image)
    }

    func testProductionCardsSwipeBothWaysRestoreShortDragAndKeepScrollingAndButtons() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--queue-swipe-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let count = app.staticTexts["queue-swipe-count"]
        expect(count, label: "count=12")
        let top = app.staticTexts["SWIPE_12.JPG"]
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        let original = top.frame
        app.scrollViews.firstMatch.swipeUp()
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !top.isHittable || abs(top.frame.minY - original.minY) > 10
        }, object: top)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed)
        expect(count, label: "count=12")
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(top.isHittable)
        let restoredTop = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(top.frame.minY - original.minY) < 1
        }, object: top)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredTop], timeout: 5), .completed)
        drag(app, y: original.midY, delta: 70)
        expect(count, label: "count=12")
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(top.frame.minX - original.minX) < 1
        }, object: top)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        drag(app, y: top.frame.midY, delta: -180)
        expect(count, label: "count=11")
        XCTAssertFalse(top.exists)
        let next = app.staticTexts["SWIPE_11.JPG"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        drag(app, y: next.frame.midY, delta: 180)
        expect(count, label: "count=10")
        app.buttons["queue-remove-10"].tap()
        expect(count, label: "count=9")
        let last = app.staticTexts["SWIPE_1.JPG"]
        for _ in 0..<4 where !last.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(last.isHittable)
        expect(count, label: "count=9")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Production queue after swipes and vertical scroll"
        image.lifetime = .keepAlways
        add(image)
    }
    private func drag(_ app: XCUIApplication, y: CGFloat, delta: CGFloat) {
        let x = app.frame.midX
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: x, dy: y))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: x + delta, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func expect(_ element: XCUIElement, label: String) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
}
