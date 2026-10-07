import XCTest

@MainActor
final class PhotoPreviewInteractionUITests: XCTestCase {
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
