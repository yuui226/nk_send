import XCTest
@testable import ZTransfer

final class ScalarAnimationTests: XCTestCase {
    func testIntegerConvertedInterruptionStartsAtDisplayedPixelWithoutLosingFrameOrigin() {
        var animation = ZTransferScalarAnimation(value: 228)
        animation.retarget(348, using: .tween(milliseconds: 220))
        animation.advance(frameNanos: 0)
        animation.advance(frameNanos: 110_000_000)
        let displayed = floor(animation.value + 0.5)
        animation.retarget(468, using: .tween(milliseconds: 220), fromDisplayedValue: displayed)
        XCTAssertEqual(animation.value, displayed)
        animation.advance(frameNanos: 330_000_000)
        XCTAssertEqual(animation.value, 468)
        XCTAssertFalse(animation.isRunning)
    }

    func testStartsAtFirstFrameRatherThanInputEventTime() {
        var animation = ZTransferScalarAnimation(value: 1)
        animation.retarget(0.965, using: .tween(milliseconds: 80))
        XCTAssertEqual(animation.value, 1)
        XCTAssertTrue(animation.isRunning)
        animation.advance(frameNanos: 4_000_000_000)
        XCTAssertEqual(animation.value, 1)
        animation.advance(frameNanos: 4_040_000_000)
        // Oracle tween-80, 1 -> .965 at 40ms, from the resolved Android library.
        XCTAssertEqual(animation.value.bitPattern, 0x3f790d0c)
    }

    func testInterruptionKeepsLastDisplayedVelocityAndFrameOrigin() {
        var animation = ZTransferScalarAnimation(value: 1)
        animation.retarget(0.965, using: .tween(milliseconds: 80))
        animation.advance(frameNanos: 1_000_000_000)
        animation.advance(frameNanos: 1_040_000_000)
        let previousValue = animation.value, previousVelocity = animation.velocity
        animation.retarget(1, using: .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
        XCTAssertEqual(animation.value, previousValue)
        XCTAssertEqual(animation.velocity, previousVelocity, accuracy: previousVelocity.ulp)
        animation.advance(frameNanos: 1_056_666_667)
        let expected = ZTransferAndroidMotion.underdampedSpring(stiffness: 400, dampingRatio: 0.5)
            .sample(at: 16_666_667, from: previousValue, to: 1, velocity: previousVelocity)
        XCTAssertEqual(animation.value, expected.value)
        XCTAssertEqual(animation.velocity, expected.velocity)
    }

    func testUnchangedTargetDoesNotRestartOrReplaceSpec() {
        var animation = ZTransferScalarAnimation(value: 0)
        animation.retarget(1, using: .tween(milliseconds: 180))
        animation.advance(frameNanos: 0)
        animation.advance(frameNanos: 80_000_000)
        animation.retarget(1, using: .tween(milliseconds: 220))
        animation.advance(frameNanos: 180_000_000)
        XCTAssertEqual(animation.value, 1)
        XCTAssertFalse(animation.isRunning)
        XCTAssertEqual(animation.velocity, 0)
    }

    func testFinishedMotionResetsClockAndVelocityBeforeNextAnimation() {
        var animation = ZTransferScalarAnimation(value: 1)
        animation.retarget(0.965, using: .tween(milliseconds: 80))
        animation.advance(frameNanos: 0)
        animation.advance(frameNanos: 80_000_000)
        XCTAssertEqual(animation.velocity, 0)
        animation.retarget(1, using: .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
        animation.advance(frameNanos: 2_000_000_000)
        XCTAssertEqual(animation.value, 0.965)
        XCTAssertEqual(animation.velocity, 0, accuracy: 0.000001)
        XCTAssertTrue(animation.isRunning)
        animation.advance(frameNanos: 3_000_000_000)
        XCTAssertEqual(animation.value, 1)
        XCTAssertEqual(animation.velocity, 0)
        XCTAssertFalse(animation.isRunning)
    }

    func testSubthresholdSpringFinishesAtFirstFrame() {
        var animation = ZTransferScalarAnimation(value: 0.999)
        animation.retarget(1, using: .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
        animation.advance(frameNanos: 0)
        XCTAssertEqual(animation.value, 1)
        XCTAssertFalse(animation.isRunning)
    }

    func testResetDropsInFlightMotion() {
        var animation = ZTransferScalarAnimation(value: 0)
        animation.retarget(1, using: .tween(milliseconds: 180))
        animation.advance(frameNanos: 0)
        animation.advance(frameNanos: 80_000_000)
        animation.reset(to: 0)
        animation.advance(frameNanos: 2_000_000_000)
        XCTAssertEqual(animation.value, 0)
        XCTAssertEqual(animation.target, 0)
        XCTAssertEqual(animation.velocity, 0)
        XCTAssertFalse(animation.isRunning)
    }
}
