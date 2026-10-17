import XCTest
@testable import ZTransfer

final class QueuePillVisibilityTests: XCTestCase {
    func testInitialVisibilityIsQuietAndEntryUsesDelayAndPhysicalPixelSlide() {
        var initial = QueuePillVisibilityMotion(visible: true, delay: 60)
        initial.measure(CGSize(width: 100, height: 20), density: 3)
        XCTAssertFalse(initial.isRunning)
        XCTAssertEqual(initial.displayedSize, CGSize(width: 100, height: 20))
        XCTAssertEqual(initial.alpha.value, 1)
        XCTAssertEqual(initial.scale.value, 1)
        XCTAssertEqual(initial.offset, 0)

        for delay in [Int64(60), 80, 150] {
            var motion = QueuePillVisibilityMotion(visible: false, delay: delay)
            XCTAssertFalse(motion.retained)
            motion.setVisible(true)
            motion.measure(CGSize(width: 100, height: 20), density: 3)
            XCTAssertEqual(motion.offset, -8.0 / 3, accuracy: 0.000001)
            XCTAssertEqual(motion.displayedSize, CGSize(width: 0, height: 20))
            motion.advance(0)
            motion.advance(delay * 1_000_000)
            XCTAssertEqual(motion.alpha.value, 0)
            XCTAssertEqual(motion.scale.value, 0.78)
            XCTAssertGreaterThan(motion.displayedSize!.width, 0)
            motion.advance((delay + 200) * 1_000_000)
            XCTAssertEqual(motion.alpha.value, 1)
            XCTAssertEqual(motion.scale.value, 1)
            motion.advance(800_000_000)
            // Explicit Motion.bouncy<IntSize>() does NOT infer a one-pixel
            // threshold. Its .01 threshold keeps a 300px entry alive past 800ms.
            XCTAssertTrue(motion.size.isRunning)
            for frame in 81...200 { motion.advance(Int64(frame) * 10_000_000) }
            XCTAssertFalse(motion.isRunning)
            XCTAssertTrue(motion.retained)
            XCTAssertEqual(motion.displayedSize, CGSize(width: 100, height: 20))
            // A fully visible wrapper does not add a second size animation.
            motion.measure(CGSize(width: 70, height: 20), density: 3)
            XCTAssertFalse(motion.isRunning)
            XCTAssertEqual(motion.displayedSize, CGSize(width: 70, height: 20))
        }
    }

    func testNullableExitShrinksBothAxesAndReverseUsesUndelayedDefaultSpring() {
        var motion = QueuePillVisibilityMotion(visible: true, delay: 150)
        motion.measure(CGSize(width: 100, height: 20), density: 3)
        motion.setVisible(false)
        motion.measure(.zero, density: 3)
        motion.advance(0)
        motion.advance(50_000_000)
        XCTAssertTrue(motion.retained)
        XCTAssertGreaterThan(motion.displayedSize!.height, 0)
        XCTAssertLessThan(motion.displayedSize!.height, 20)
        let alpha = motion.alpha.value, velocity = motion.alpha.velocity
        motion.setVisible(true)
        motion.measure(CGSize(width: 100, height: 20), density: 3)
        XCTAssertEqual(motion.alpha.value, alpha)
        XCTAssertEqual(motion.scale.value, 1) // No second .78 entry scale.
        motion.advance(70_000_000)
        let x = Double(alpha) - 1, v = Double(velocity), time = 0.02
        let expected = 1 + (x + (v + 20 * x) * time) * exp(-20 * time)
        XCTAssertEqual(Double(motion.alpha.value), expected, accuracy: 0.000001)
        for frame in 8...100 { motion.advance(Int64(frame) * 10_000_000) }
        XCTAssertFalse(motion.isRunning)
        motion.setVisible(false)
        motion.measure(.zero, density: 3)
        motion.advance(2_000_000_000)
        motion.advance(2_100_000_000)
        XCTAssertEqual(motion.alpha.value, 0)
        XCTAssertTrue(motion.retained) // Keep the node until size also settles.
        motion.advance(3_000_000_000)
        XCTAssertFalse(motion.retained)
        motion.setVisible(true)
        motion.measure(CGSize(width: 100, height: 20), density: 3)
        XCTAssertEqual(motion.alpha.value, 0)
        XCTAssertEqual(motion.scale.value, 0.78)
        XCTAssertEqual(motion.offset, -8.0 / 3, accuracy: 0.000001)
    }

    func testSizeVectorDoesNotSnapShortAxisBeforeSharedDuration() {
        var motion = QueuePillSizeSpring(.zero)
        motion.retarget(.init(1000, 2),
            spec: .underdampedSpring(stiffness: 400, dampingRatio: 0.5, threshold: 1),
            force: true, origin: nil)
        motion.advance(0)
        motion.advance(100_000_000)
        let frequency = sqrt(300.0), time = 0.1
        let expected = 2 * (1 - exp(-10 * time) *
            (cos(frequency * time) + 10 / frequency * sin(frequency * time)))
        XCTAssertTrue(motion.isRunning)
        XCTAssertEqual(Double(motion.value.y), expected, accuracy: 0.000001)
        XCTAssertNotEqual(motion.value.y, 2)
        let displayed = motion.pixels, velocity = motion.velocity
        motion.retarget(.zero, spec: .criticallyDampedSpring(stiffness: 400, threshold: 1),
                        force: true, origin: 100_000_000)
        XCTAssertEqual(motion.value, displayed)
        XCTAssertEqual(motion.velocity.x, velocity.x, accuracy: 0.001)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.value, .zero)
        XCTAssertFalse(motion.isRunning)
    }
}
