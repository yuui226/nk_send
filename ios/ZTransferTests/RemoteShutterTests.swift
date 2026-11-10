import XCTest
@testable import ZTransfer

final class RemoteShutterTests: XCTestCase {
    func testQuickTapAndCancelledTapNeverStartFocus() {
        var gesture = RemoteShutterGesture()
        XCTAssertEqual(gesture.down(at: 0, enabled: false), [])
        XCTAssertEqual(gesture.down(at: 0, enabled: true), [.beginHold])
        XCTAssertEqual(gesture.advance(0.299), [])
        XCTAssertEqual(gesture.end(inside: true), [.cancelHold, .quickTap])
        XCTAssertEqual(gesture.advance(1), [])
        _ = gesture.down(at: 1, enabled: true)
        XCTAssertEqual(gesture.end(inside: false), [.cancelHold])
        XCTAssertEqual(gesture.end(inside: true), [])
    }

    func testLongHoldHasOneFocusAndReleaseOrCancel() {
        for inside in [false, true] {
            var gesture = RemoteShutterGesture()
            _ = gesture.down(at: 0, enabled: true)
            XCTAssertEqual(gesture.advance(0.3), [.focus])
            XCTAssertEqual(gesture.advance(0.9), [])
            XCTAssertEqual(gesture.end(inside: inside), [.cancelHold, .release(inside)])
            XCTAssertFalse(gesture.held)
            XCTAssertEqual(gesture.end(inside: true), [])
        }
    }

    @MainActor
    func testDelayedHoldDoesNotFocusAndCountdownCancelHasNoHalfPressMotion() async throws {
        var feedback: [HapticFeedbackEvent] = []
        let name = "RemoteShutterTimer." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let haptics = ZTransferHaptics(defaults: defaults) { feedback.append($0) }
        var config = RemoteShutterController.Configuration(enabled: true, capturing: false,
            focusing: false, recording: false, diameter: 76, delayedPhoto: true)
        let controller = RemoteShutterController(configuration: config, haptics: haptics)
        defer { controller.stop() }
        var taps = 0, cancels = 0
        controller.onQuickTap = { taps += 1 }
        controller.onFocus = { XCTFail("Delayed shutter must not run the 300ms half press") }
        controller.onCancelTimer = { cancels += 1 }
        controller.down()
        try await Task.sleep(for: .milliseconds(350))
        controller.end(inside: true)
        XCTAssertEqual(taps, 1)
        XCTAssertTrue(feedback.isEmpty)
        XCTAssertEqual(controller.motion.timerAccent.target, 0, "Configured delay alone does not turn the shutter blue")
        config.cancelsTimer = true; config.remainingSeconds = 20
        controller.configure(config)
        controller.down()
        XCTAssertEqual(controller.motion.press.target, 1)
        controller.end(inside: true)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(controller.motion.timerAccent.target, 1)
    }

    func testCountdownAccentAndWidthHaveIndependentFiniteMotion() {
        var motion = RemoteShutterMotion()
        motion.configure(held: false, focusing: false, recording: false, diameter: 76,
                         timerEnabled: true, seconds: 10)
        motion.advance(0); motion.advance(160_000_000)
        XCTAssertEqual(motion.timerAccent.value, 1)
        let wide = motion.countdownWidth!.value
        motion.configure(held: false, focusing: false, recording: false, diameter: 76,
                         timerEnabled: true, seconds: 9)
        XCTAssertEqual(motion.countdownWidth?.value, wide)
        XCTAssertLessThan(motion.countdownWidth!.target, wide)
        for frame in 1...180 { motion.advance(160_000_000 + Int64(frame) * 16_666_667) }
        XCTAssertFalse(motion.needsFrames)
        motion.configure(held: false, focusing: false, recording: false, diameter: 76, movie: true)
        XCTAssertEqual(motion.timerAccent.value, 0)
    }

    func testInitialLandscapeRecordingGeometryDoesNotAnimateFromPortrait() {
        let motion = RemoteShutterMotion(diameter: 60, focusing: true, recording: true)
        XCTAssertEqual(motion.press.value, 0.95)
        XCTAssertEqual(motion.focus.value, 0.8)
        XCTAssertEqual(motion.size.value, 60 * 28 / 76, accuracy: 0.00001)
        XCTAssertEqual(motion.corner.value, 60 * 7 / 76, accuracy: 0.00001)
        XCTAssertFalse(motion.needsFrames)
    }

    func testPressDoesNotPretendTheCameraAcceptedFocusAndMorphChannelsRemainIndependent() {
        var motion = RemoteShutterMotion()
        motion.configure(held: true, focusing: false, recording: false, diameter: 76)
        motion.advance(0); motion.advance(100_000_000)
        XCTAssertEqual(motion.press.value, 0.95)
        XCTAssertEqual(motion.focus.value, 1)
        motion.configure(held: true, focusing: true, recording: true, diameter: 76)
        motion.advance(100_000_000); motion.advance(220_000_000)
        XCTAssertEqual(motion.focus.value, 0.8)
        XCTAssertTrue(motion.size.isRunning)
        motion.advance(260_000_000)
        XCTAssertEqual(motion.size.value, 28)
        XCTAssertEqual(motion.corner.value, 7)
        motion.configure(held: false, focusing: true, recording: true, diameter: 76)
        XCTAssertEqual(motion.press.target, 0.95)
        motion.configure(held: false, focusing: false, recording: true, diameter: 76)
        motion.advance(300_000_000); motion.advance(450_000_000)
        let expected = ZTransferAndroidMotion.underdampedSpring(stiffness: 400, dampingRatio: 0.5)
            .animationSample(at: 150_000_000, from: 0.95, to: 1, velocity: 0).value
        XCTAssertEqual(motion.press.value, expected, accuracy: 0.000001)
    }

    @MainActor
    func testControllerCancelsFiredHoldWhenDisabledAndDoesNotFireAgainOnUp() async throws {
        var events: [HapticFeedbackEvent] = []
        let haptics = ZTransferHaptics(defaults: UserDefaults(suiteName: UUID().uuidString)!) { events.append($0) }
        var config = RemoteShutterController.Configuration(enabled: true, capturing: false,
            focusing: false, recording: false, diameter: 76)
        let controller = RemoteShutterController(configuration: config, haptics: haptics)
        defer { controller.stop() }
        let focus = expectation(description: "300ms focus callback")
        var releases: [Bool] = []
        var taps = 0
        controller.onFocus = { focus.fulfill(); haptics.play(.selection) }
        controller.onRelease = { releases.append($0) }
        controller.onQuickTap = { taps += 1 }
        controller.down()
        await fulfillment(of: [focus], timeout: 2)
        XCTAssertEqual(controller.motion.focus.target, 1, "Model rejection keeps the inner circle full size")
        config.enabled = false
        controller.configure(config)
        controller.end(inside: true)
        XCTAssertEqual(releases, [false]); XCTAssertEqual(taps, 0)
        XCTAssertEqual(events, [.holdStarted, .holdCompleted])
    }

    @MainActor
    func testControllerDisappearanceCancelsTimerAndCapturingBlocksDown() async throws {
        var config = RemoteShutterController.Configuration(enabled: true, capturing: false,
            focusing: false, recording: false, diameter: 76)
        let haptics = ZTransferHaptics(defaults: UserDefaults(suiteName: UUID().uuidString)!) { _ in }
        let controller = RemoteShutterController(configuration: config, haptics: haptics)
        var focus = 0
        controller.onFocus = { focus += 1 }
        controller.down(); controller.stop()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(focus, 0)
        config.capturing = true
        controller.configure(config); controller.down()
        XCTAssertFalse(controller.gesture.held)
        controller.stop()
    }
}
