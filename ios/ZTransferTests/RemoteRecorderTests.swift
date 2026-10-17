import XCTest
@testable import ZTransfer

final class RemoteRecorderTests: XCTestCase {
    func testActionGatesKeepStopAvailableAndSavedFinalizingButtonsInert() {
        for enabled in [false, true] {
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .recording, enabled: enabled), .stop)
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .paused, enabled: enabled), .stop)
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .saved, enabled: enabled), .none)
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .finalizing, enabled: enabled), .none)
        }
        XCTAssertEqual(RemoteRecorderAction.resolve(phase: .idle, enabled: false), .lockedHint)
        XCTAssertEqual(RemoteRecorderAction.resolve(phase: .idle, enabled: true), .start)
    }

    func testInitialStateAndWidthTargetsMatchBothOrientations() {
        for compact in [false, true] {
            for phase in [RemoteLocalRecordingPhase.idle, .recording, .paused, .finalizing, .saved] {
                let motion = RemoteRecorderMotion(.init(phase: phase, compactSaved: compact), density: 3)
                let expected: Float = phase == .saved ? (compact ? 36 : 88) : phase == .idle ? 36 : 70
                XCTAssertEqual(motion.layoutWidth.value, expected)
                XCTAssertEqual(motion.surfaceWidth.value, expected)
                XCTAssertFalse(motion.needsFrames)
                XCTAssertEqual(motion.savedLabel.retained, phase == .saved && !compact)
                XCTAssertEqual(motion.timer.retained, phase == .recording || phase == .paused)
            }
        }
    }

    func testRecordingWidthUsesBouncySpringAndPauseUses150msTween() {
        var motion = RemoteRecorderMotion(.init(phase: .idle, compactSaved: false), density: 3)
        motion.configure(.init(phase: .recording, compactSaved: false))
        motion.advance(0); motion.advance(150_000_000)
        XCTAssertEqual(motion.pauseAlpha.value, 1)
        let expected = ZTransferAndroidMotion.underdampedSpring(stiffness: 400, dampingRatio: 0.5)
            .animationSample(at: 150_000_000, from: 36, to: 70, velocity: 0).value
        XCTAssertEqual(motion.layoutWidth.value, expected, accuracy: 0.00001)
        XCTAssertEqual(motion.surfaceWidth.value, motion.layoutWidth.value)
        motion.configure(.init(phase: .paused, compactSaved: false))
        XCTAssertEqual(motion.timer.alpha.value, 1)
        XCTAssertEqual(motion.timer.visible, true)
        motion.advance(2_000_000_000)
        XCTAssertFalse(motion.needsFrames)
    }

    func testSavedLabelStartsAfter60msAndIconsKeepOutgoingUntilItsExitCompletes() {
        var motion = RemoteRecorderMotion(.init(phase: .finalizing, compactSaved: false), density: 3)
        motion.configure(.init(phase: .saved, compactSaved: false))
        XCTAssertEqual(motion.icons.count, 2)
        XCTAssertEqual(motion.icons[true]?.scale.value, 0.52)
        motion.advance(0); motion.advance(60_000_000)
        XCTAssertEqual(motion.savedLabel.alpha.value, 0)
        motion.advance(90_000_000)
        XCTAssertEqual(motion.icons[false]?.alpha.value, 0)
        XCTAssertNotNil(motion.icons[false], "The outgoing scale still has 20ms remaining")
        motion.advance(110_000_000)
        XCTAssertNil(motion.icons[false])
        motion.advance(160_000_000)
        XCTAssertEqual(motion.savedLabel.alpha.value, ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
        motion.advance(260_000_000)
        XCTAssertEqual(motion.savedLabel.alpha.value, 1)
    }

    func testFinalizingHidesPauseAndTimerWithoutCollapsingTheCapsule() {
        var motion = RemoteRecorderMotion(.init(phase: .recording, compactSaved: false), density: 3)
        motion.configure(.init(phase: .finalizing, compactSaved: false))
        XCTAssertEqual(motion.layoutWidth.target, 70)
        XCTAssertTrue(motion.timer.retained)
        motion.advance(0); motion.advance(120_000_000)
        XCTAssertEqual(motion.timer.alpha.value, 0)
        XCTAssertTrue(motion.timer.retained)
        motion.advance(130_000_000)
        XCTAssertEqual(motion.timer.scale.value, 0.9)
        XCTAssertEqual(motion.timer.slide.value, 13, "54 physical pixels / 4, integer division")
        XCTAssertFalse(motion.timer.retained)
        motion.advance(150_000_000)
        XCTAssertEqual(motion.pauseAlpha.value, 0)
    }

    func testCompactSavedKeepsCheckAndHidesLabelWhileWidthContinuesFromDisplayedValue() {
        var motion = RemoteRecorderMotion(.init(phase: .saved, compactSaved: false), density: 2)
        motion.configure(.init(phase: .saved, compactSaved: true))
        XCTAssertEqual(motion.layoutWidth.value, 88)
        XCTAssertEqual(motion.layoutWidth.target, 36)
        XCTAssertEqual(motion.icons.count, 1)
        motion.advance(0); motion.advance(120_000_000)
        XCTAssertFalse(motion.savedLabel.retained)
        XCTAssertTrue(motion.icons[true]!.retained)
        let displayed = motion.layoutWidth.value
        motion.configure(.init(phase: .saved, compactSaved: false))
        XCTAssertEqual(motion.layoutWidth.value, displayed)
        XCTAssertEqual(motion.layoutWidth.target, 88)
    }

    func testHintInterruptedFadeReversesFromCurrentValueAndCanReenterAfterDisposal() {
        var hint = RemoteRecorderVisibility(.lockedHint)
        hint.setVisible(true); hint.advance(0); hint.advance(80_000_000)
        let displayed = hint.alpha.value
        hint.setVisible(false)
        XCTAssertEqual(hint.alpha.value, displayed)
        hint.advance(2_000_000_000)
        XCTAssertFalse(hint.retained)
        hint.setVisible(true)
        XCTAssertEqual(hint.alpha.value, 0)
        XCTAssertEqual(hint.scale.value, 0.86)
        hint.advance(3_000_000_000); hint.advance(3_180_000_000)
        XCTAssertEqual(hint.alpha.value, 1)
        XCTAssertEqual(hint.scale.value, 1)
    }
    @MainActor
    func testRepeatedLockedTapRestartsDeadlineAndDisappearanceDiscardsHint() async throws {
        let controller = RemoteRecorderController(.init(phase: .idle, compactSaved: false), density: 3)
        defer { controller.stop() }
        controller.showLockedHint()
        try await Task.sleep(for: .milliseconds(1000))
        controller.showLockedHint()
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(controller.motion.lockedHint.visible, "The first task must not hide the second tap's hint")
        controller.stop()
        XCTAssertFalse(controller.motion.lockedHint.retained)
        XCTAssertFalse(controller.motion.needsFrames)
        controller.showLockedHint()
        try await Task.sleep(for: .milliseconds(1850))
        XCTAssertFalse(controller.motion.lockedHint.visible)
    }

}
