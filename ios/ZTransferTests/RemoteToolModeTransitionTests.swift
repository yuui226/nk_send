import XCTest
@testable import ZTransfer

final class RemoteToolModeTransitionTests: XCTestCase {
    func testInitialModeIsImmediatelyOpaqueWithoutAnimation() {
        for movie in [false, true] {
            let transition = RemoteToolModeTransition(movie: movie)
            XCTAssertEqual(transition.modes, [movie])
            XCTAssertEqual(transition.alpha(movie), 1)
            XCTAssertFalse(transition.isRunning)
        }
    }

    func testModeChangeRetainsBothLayoutsUntilAndroidTweenFinishes() {
        var transition = RemoteToolModeTransition(movie: false)
        transition.setTarget(true)
        transition.advance(frameNanos: 1_000_000_000)
        XCTAssertEqual(transition.modes, [false, true])
        XCTAssertEqual(transition.alpha(false), 1)
        XCTAssertEqual(transition.alpha(true), 0)
        transition.advance(frameNanos: 1_080_000_000)
        // Compose FastOutSlowIn at 0.5, independently pinned expected value.
        XCTAssertEqual(transition.alpha(true), 0.7755613, accuracy: 0.00001)
        XCTAssertEqual(transition.alpha(false), 0.2244387, accuracy: 0.00001)
        transition.advance(frameNanos: 1_159_000_000)
        XCTAssertEqual(transition.modes.count, 2)
        transition.advance(frameNanos: 1_160_000_000)
        XCTAssertEqual(transition.modes, [true])
        XCTAssertFalse(transition.isRunning)
    }

    func testRapidReturnUsesCurrentAlphaAndDoesNotDuplicateOrRemoveActiveLayer() {
        var transition = RemoteToolModeTransition(movie: false)
        transition.setTarget(true)
        transition.advance(frameNanos: 0)
        transition.advance(frameNanos: 80_000_000)
        let photo = transition.alpha(false)
        let movie = transition.alpha(true)
        transition.setTarget(false)
        XCTAssertEqual(transition.alpha(false), photo)
        XCTAssertEqual(transition.alpha(true), movie)
        XCTAssertEqual(transition.modes, [false, true])
        transition.setTarget(false) // Recomposition does not restart the spring.
        transition.advance(frameNanos: 120_000_000)
        XCTAssertGreaterThan(transition.alpha(false), photo)
        transition.advance(frameNanos: 1_000_000_000)
        XCTAssertEqual(transition.modes, [false])
        XCTAssertEqual(transition.alpha(false), 1)
        XCTAssertEqual(transition.alpha(true), 0)
    }
}
