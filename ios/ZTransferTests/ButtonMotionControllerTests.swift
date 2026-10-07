import XCTest
import UIKit
@testable import ZTransfer

@MainActor
final class ButtonMotionControllerTests: XCTestCase {
    private final class Clock { var milliseconds: Int64 = 0 }
    private func make(_ clock: Clock, skin: ZTransferButtonSkin = .titanium,
                      active: Bool = false, panel: Bool = false) -> ZTransferButtonMotionController {
        ZTransferButtonMotionController(skin: skin, panel: panel, active: active, enabled: true,
            automaticallySchedule: false, clock: { clock.milliseconds })
    }

    func testCoalescedSuccessfulClickCreates90msFeedbackWithoutDelayingAction() {
        let clock = Clock()
        // Use one clock for deterministic event and frame scheduling.
        let button = make(clock)
        var clicks = 0
        button.successfulActivation()
        clicks += 1 // The production action invokes configuration.trigger here.
        XCTAssertEqual(clicks, 1)
        XCTAssertTrue(button.motion.press.visualPressed)
        XCTAssertEqual(button.motion.press.releaseDeadline, 90)
        button.advanceFrame(nanos: 0)
        button.advanceFrame(nanos: 80_000_000)
        XCTAssertEqual(button.frame.scale, 0.970)
        XCTAssertGreaterThan(button.frame.light, 0.98)
        clock.milliseconds = 89
        button.advanceHold()
        XCTAssertTrue(button.motion.press.visualPressed)
        clock.milliseconds = 90
        button.advanceHold()
        XCTAssertFalse(button.motion.press.visualPressed)
        // The down-scale tween already completed at 80ms, so its return spring
        // starts on the next delivered frame, not at the hold timer's timestamp.
        button.advanceFrame(nanos: 90_000_000)
        button.advanceFrame(nanos: 400_000_000)
        XCTAssertEqual(button.frame.scale, 1)
        XCTAssertEqual(button.frame.light, 0)
        XCTAssertFalse(button.motion.needsFrames)
    }

    func testScrollTapBeforeIndicationDelayStartsHoldAtSuccessfulRelease() {
        let clock = Clock()
        let owner = make(clock)
        owner.inScrollableContainer = true
        owner.nativePressChanged(true)
        XCTAssertFalse(owner.motion.press.visualPressed)
        clock.milliseconds = 35
        owner.successfulActivation()
        owner.nativePressChanged(false)
        XCTAssertEqual(owner.motion.press.releaseDeadline, 125)
        XCTAssertTrue(owner.motion.press.visualPressed)
    }

    func testScrollCancellationBeforeDelayEmitsNoFeedback() {
        let clock = Clock()
        let owner = make(clock)
        owner.inScrollableContainer = true
        owner.nativePressChanged(true)
        clock.milliseconds = 40
        owner.nativePressChanged(false)
        owner.resolveUnsuccessfulRelease()
        owner.emitDelayedPress()
        XCTAssertFalse(owner.motion.press.visualPressed)
        XCTAssertFalse(owner.motion.needsFrames)
        XCTAssertEqual(owner.frame.scale, 1)
    }

    func testScrollCancellationAfterDelayReleasesImmediatelyWithout90msHold() {
        let clock = Clock()
        let owner = make(clock)
        owner.inScrollableContainer = true
        owner.nativePressChanged(true)
        clock.milliseconds = 100
        owner.emitDelayedPress()
        owner.advanceFrame(nanos: 100_000_000)
        owner.advanceFrame(nanos: 116_000_000)
        clock.milliseconds = 125
        owner.nativePressChanged(false)
        owner.resolveUnsuccessfulRelease()
        XCTAssertFalse(owner.motion.press.visualPressed)
        XCTAssertNil(owner.motion.press.releaseDeadline)
        XCTAssertEqual(owner.motion.light.target, 0)
    }

    func testSuccessfulActionCanArriveBeforeOrAfterNativeFalseEdge() {
        for actionFirst in [true, false] {
            let clock = Clock()
            let owner = make(clock)
            owner.nativePressChanged(true)
            clock.milliseconds = 30
            if actionFirst {
                owner.successfulActivation()
                owner.nativePressChanged(false)
            } else {
                owner.nativePressChanged(false)
                owner.successfulActivation()
            }
            owner.resolveUnsuccessfulRelease()
            XCTAssertTrue(owner.motion.press.visualPressed)
            XCTAssertEqual(owner.motion.press.releaseDeadline, 90)
        }
    }

    func testNewPressSupersedesOldReleaseDeadline() {
        let clock = Clock()
        let owner = make(clock)
        owner.successfulActivation()
        clock.milliseconds = 50
        owner.nativePressChanged(true)
        XCTAssertNil(owner.motion.press.releaseDeadline)
        clock.milliseconds = 90
        owner.advanceHold()
        XCTAssertTrue(owner.motion.press.visualPressed)
        clock.milliseconds = 110
        owner.successfulActivation()
        owner.nativePressChanged(false)
        XCTAssertEqual(owner.motion.press.releaseDeadline, 140)
    }

    func testDisableDropsInputAndHoldWhileActiveChannelRemainsIndependent() {
        let clock = Clock()
        let owner = make(clock)
        owner.nativePressChanged(true)
        owner.advanceFrame(nanos: 0)
        owner.advanceFrame(nanos: 40_000_000)
        owner.configure(skin: .titanium, panel: false, active: true, enabled: false)
        XCTAssertFalse(owner.motion.press.visualPressed)
        XCTAssertNil(owner.motion.press.releaseDeadline)
        XCTAssertEqual(owner.motion.activation.target, 1)
        owner.successfulActivation()
        XCTAssertFalse(owner.motion.press.visualPressed)
        owner.advanceFrame(nanos: 50_000_000)
        owner.advanceFrame(nanos: 400_000_000)
        XCTAssertEqual(owner.frame, .init(scale: 1, light: 0, active: 1))
        owner.configure(skin: .titanium, panel: false, active: true, enabled: true)
        owner.nativePressChanged(true)
        XCTAssertTrue(owner.motion.press.visualPressed)
    }

    func testInitialActiveHasNoEntranceAnimationAndPanelSuppressesActive() {
        let owner = make(Clock(), active: true)
        XCTAssertEqual(owner.frame.active, 1)
        XCTAssertFalse(owner.motion.needsFrames)
        let panel = make(Clock(), active: true, panel: true)
        XCTAssertEqual(panel.frame.active, 0)
        XCTAssertFalse(panel.motion.needsFrames)
    }

    func testCameraScaleAndLightFinishAtIndependent140And220ms() {
        var motion = ZTransferButtonMotion(skin: .cameraControls, panel: false, active: false, enabled: true)
        motion.press(1, at: 0)
        motion.advanceFrame(nanos: 0)
        motion.advanceFrame(nanos: 90_000_000)
        XCTAssertEqual(motion.frame.scale, 0.982)
        XCTAssertEqual(motion.frame.light, 1)
        motion.release(1, at: 100)
        motion.advanceFrame(nanos: 100_000_000)
        motion.advanceFrame(nanos: 240_000_000)
        XCTAssertEqual(motion.frame.scale, 1)
        XCTAssertGreaterThan(motion.frame.light, 0)
        motion.advanceFrame(nanos: 320_000_000)
        XCTAssertEqual(motion.frame.light, 0)
        XCTAssertFalse(motion.needsFrames)
    }

    func testStopDropsAllPendingInputAndMotion() {
        let owner = make(Clock(), active: true)
        owner.nativePressChanged(true)
        owner.advanceFrame(nanos: 0)
        owner.advanceFrame(nanos: 40_000_000)
        owner.stop()
        owner.emitDelayedPress()
        owner.advanceHold()
        owner.advanceFrame(nanos: 1_000_000_000)
        XCTAssertEqual(owner.frame, .init(scale: 1, light: 0, active: 1))
        XCTAssertFalse(owner.motion.needsFrames)
        XCTAssertFalse(owner.motion.press.visualPressed)
    }

    func testScrollProbeReadsRealAncestorAndUpdatesAfterDetach() {
        let host = UIView(), scroll = UIScrollView(), probe = ZTransferButtonScrollContext.Probe()
        var states: [Bool] = []
        probe.changed = { states.append($0) }
        host.addSubview(scroll)
        scroll.addSubview(probe)
        XCTAssertEqual(states.last, true)
        host.addSubview(probe)
        XCTAssertEqual(states.last, false)
    }
}
