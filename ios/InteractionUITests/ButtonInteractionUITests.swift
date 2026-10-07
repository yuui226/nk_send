import XCTest

@MainActor
final class ButtonInteractionUITests: XCTestCase {
    private struct TraceEvent: Decodable {
        let event: String
        let milliseconds: Int64
        let id: Int32
        let scale: Float
        let light: Float
        let pressed: Bool
        let scroll: Bool
    }
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(skin: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--button-motion-ui-test", "-skin_preset", skin]
        app.launch()
        XCTAssertTrue(app.buttons["material-action"].waitForExistence(timeout: 10))
        return app
    }

    func testNativeActionsAndDisabledStateAcrossAllMaterials() {
        for skin in ["FROSTED_GLASS", "TITANIUM", "WOOD", "CAMERA_CONTROLS"] {
            let app = launch(skin: skin)
            let button = app.buttons["material-action"]
            button.tap()
            XCTAssertEqual(app.staticTexts["button-action-count"].label, "1", skin)
            button.tap()
            XCTAssertEqual(app.staticTexts["button-action-count"].label, "2", skin)
            app.buttons["toggle-enabled"].tap()
            XCTAssertFalse(button.isEnabled, skin)
            // Coordinate tapping also verifies the disabled primitive does not
            // accidentally bypass native Button action gating.
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertEqual(app.staticTexts["button-action-count"].label, "2", skin)
            app.buttons["toggle-enabled"].tap()
            XCTAssertTrue(button.isEnabled, skin)
            button.tap()
            XCTAssertEqual(app.staticTexts["button-action-count"].label, "3", skin)
            app.terminate()
        }
    }

    func testScrollWinsOverButtonWithoutDeliveringCancelledAction() {
        let app = launch(skin: "TITANIUM")
        defer { app.terminate() }
        let button = app.buttons["scrollable-action"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertEqual(app.staticTexts["scroll-action-count"].label, "1")
        let row = app.staticTexts["Row 6"]
        let previousRowY = row.frame.minY
        let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -180))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(app.staticTexts["scroll-action-count"].label, "1")
        XCTAssertLessThan(row.frame.minY, previousRowY - 80,
                          "The scroll container must actually move while cancelling the button")
    }

    private func readTrace(_ app: XCUIApplication, name: String) throws -> [TraceEvent] {
        app.buttons["read-trace"].tap()
        let json = try XCTUnwrap(app.staticTexts["interaction-trace"].value as? String)
        let attachment = XCTAttachment(string: json)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return try JSONDecoder().decode([TraceEvent].self, from: Data(json.utf8))
    }

    func testShortActualTouchProducesFramesAndOneSuccessfulRelease() throws {
        let app = launch(skin: "TITANIUM")
        defer { app.terminate() }
        app.buttons["clear-trace"].tap()
        app.buttons["material-action"].press(forDuration: 0.01)
        let trace = try readTrace(app, name: "short-touch-production-trace")
        let down = try XCTUnwrap(trace.first { $0.event == "touch-down" })
        let up = try XCTUnwrap(trace.first { $0.event == "touch-up" })
        let button = trace.filter { $0.id == 1001 }
        let press = try XCTUnwrap(button.first { $0.event == "press-emitted" })
        XCTAssertEqual(button.filter { $0.event == "action" }.count, 1)
        XCTAssertEqual(button.filter { $0.event == "release-emitted" }.count, 1)
        XCTAssertFalse(button.contains { $0.event == "cancel-emitted" })
        XCTAssertLessThanOrEqual(press.milliseconds - down.milliseconds, 70,
                                 "Non-scrolling controls must not acquire a scroll indication delay")
        XCTAssertGreaterThanOrEqual(up.milliseconds, down.milliseconds)
        XCTAssertLessThan(try XCTUnwrap(button.map(\.scale).min()), 0.99,
                          "Observe actual rendered-frame values, not only a logical pressed flag")
        let held = try XCTUnwrap(button.first { $0.event == "hold-ended" })
        XCTAssertGreaterThanOrEqual(held.milliseconds - press.milliseconds, 90)
        XCTAssertEqual(app.staticTexts["button-action-count"].label, "1")
    }

    func testScrollIndicationDelayIsMeasuredFromActualTouchWithoutDoubleDelay() throws {
        let app = launch(skin: "TITANIUM")
        defer { app.terminate() }
        app.buttons["clear-trace"].tap()
        app.buttons["scrollable-action"].press(forDuration: 0.35)
        let trace = try readTrace(app, name: "scroll-hold-production-trace")
        let down = try XCTUnwrap(trace.first { $0.event == "touch-down" })
        let button = trace.filter { $0.id == 1002 }
        let press = try XCTUnwrap(button.first { $0.event == "press-emitted" })
        XCTAssertTrue(press.scroll)
        let delay = press.milliseconds - down.milliseconds
        XCTAssertGreaterThanOrEqual(delay, 95)
        XCTAssertLessThanOrEqual(delay, 140,
                                 "Android's 100ms delay must not be added after another native delay")
        XCTAssertEqual(button.filter { $0.event == "action" }.count, 1)
        XCTAssertEqual(button.filter { $0.event == "press-emitted" }.count, 1)
        XCTAssertEqual(button.filter { $0.event == "release-emitted" }.count, 1)
        XCTAssertEqual(app.staticTexts["scroll-action-count"].label, "1")
    }
}
