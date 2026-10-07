import XCTest
@testable import ZTransfer

final class CropAnimationTimingTests: XCTestCase {
    func testAndroidTimingConstants() {
        XCTAssertEqual(CropAnimationTiming.layoutSeconds, 0.220)
        XCTAssertEqual(CropAnimationTiming.toolsFadeSeconds, 0.180)
        XCTAssertEqual(CropAnimationTiming.queueRise(for: true), 0.105)
        XCTAssertEqual(CropAnimationTiming.queueRise(for: false), 0.155)
    }
    func testGhostAlphaFadesAtBothEnds() {
        XCTAssertEqual(CropAnimationTiming.ghostAlpha(progress: 0), 0)
        XCTAssertEqual(CropAnimationTiming.ghostAlpha(progress: 0.5), 1, accuracy: 0.001)
        XCTAssertEqual(CropAnimationTiming.ghostAlpha(progress: 1), 0, accuracy: 0.001)
    }
}
