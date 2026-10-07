import XCTest
@testable import ZTransfer

final class RemoteHorizonTests: XCTestCase {
    // The two horizon cases from Android ViewfinderViewportTest.
    func testPortraitDirectionAndAlignmentTargets() {
        for axis in [Float(-180), -90, 0, 90, 180, 270] {
            XCTAssertEqual(RemoteHorizon.displayRoll(axis), axis, accuracy: 0.0001)
            XCTAssertTrue(RemoteHorizon.aligned(axis, wasAligned: false))
            XCTAssertFalse(RemoteHorizon.aligned(axis + 2, wasAligned: false))
        }
        XCTAssertEqual(RemoteHorizon.displayRoll(46, previous: 44), 46, accuracy: 0.0001)
        XCTAssertEqual(RemoteHorizon.displayRoll(-179, previous: 179), 181, accuracy: 0.0001)
        XCTAssertEqual(RemoteHorizon.displayRoll(179, previous: -179), -181, accuracy: 0.0001)
        XCTAssertEqual(RemoteHorizon.displayRoll(1, previous: 359), 361, accuracy: 0.0001)
    }

    func testHysteresisAvoidsFlicker() {
        XCTAssertTrue(RemoteHorizon.aligned(0.6, wasAligned: false))
        XCTAssertFalse(RemoteHorizon.aligned(0.9, wasAligned: false))
        XCTAssertTrue(RemoteHorizon.aligned(0.9, wasAligned: true))
        XCTAssertFalse(RemoteHorizon.aligned(1.3, wasAligned: true))
        XCTAssertFalse(RemoteHorizon.aligned(.nan, wasAligned: true))
        for axis in [Float(-180), -90, 90, 180, 270] {
            XCTAssertTrue(RemoteHorizon.aligned(axis, wasAligned: false))
            XCTAssertTrue(RemoteHorizon.aligned(axis - 0.6, wasAligned: false))
            XCTAssertTrue(RemoteHorizon.aligned(axis + 0.6, wasAligned: false))
            XCTAssertFalse(RemoteHorizon.aligned(axis + 0.9, wasAligned: false))
            XCTAssertTrue(RemoteHorizon.aligned(axis + 0.9, wasAligned: true))
            XCTAssertFalse(RemoteHorizon.aligned(axis - 1.3, wasAligned: true))
        }
        XCTAssertFalse(RemoteHorizon.aligned(45, wasAligned: true))
        XCTAssertFalse(RemoteHorizon.aligned(.infinity, wasAligned: true))
    }

    func testPitchIsIndependentAndClampsOnlyItsVisualOffset() {
        XCTAssertTrue(RemoteHorizon.pitchAligned(0.7, wasAligned: false))
        XCTAssertFalse(RemoteHorizon.pitchAligned(0.9, wasAligned: false))
        XCTAssertTrue(RemoteHorizon.pitchAligned(0.9, wasAligned: true))
        XCTAssertFalse(RemoteHorizon.pitchAligned(90, wasAligned: true))
        XCTAssertFalse(RemoteHorizon.pitchAligned(nil, wasAligned: true))
        XCTAssertNil(RemoteHorizon.validPitch(.infinity))
        XCTAssertNil(RemoteHorizon.validPitch(91))
        XCTAssertEqual(RemoteHorizon.pitchOffset(90), 1)
        XCTAssertEqual(RemoteHorizon.pitchOffset(-90), -1)
        XCTAssertEqual(RemoteHorizon.pitchOffset(15), 0.5)
        XCTAssertEqual(RemoteHorizon.pitchOffset(nil), 0)
    }
    func testAnimationDurationsAndIndependentAlignment() {
        var state = RemoteHorizonAnimation(roll: 10, pitch: 10)
        state.update(roll: 0, pitch: 0)
        state.advance(0)
        XCTAssertEqual(state.angle.value, 10)
        XCTAssertTrue(state.rollAligned)
        XCTAssertTrue(state.pitchAligned)
        state.advance(100_000_000)
        XCTAssertEqual(state.angle.value, 0)
        XCTAssertEqual(state.pitchOffset.value, 0)
        XCTAssertTrue(state.tint.isRunning)
        state.advance(160_000_000)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.tint.value, RemoteHorizonAnimation.green)
        state.update(roll: 5, pitch: 0)
        XCTAssertFalse(state.rollAligned)
        XCTAssertTrue(state.pitchAligned)
        XCTAssertFalse(state.aligned)
        state.advance(200_000_000)
        state.advance(360_000_000)
        XCTAssertEqual(state.tint.value, RemoteHorizonAnimation.amber)
        XCTAssertEqual(state.pitchTint.value, RemoteHorizonAnimation.green)
    }

    func testAnimationRetargetUsesUnwrappedTargetAndRetainsDisplayedAngle() {
        var state = RemoteHorizonAnimation(roll: 179, pitch: nil)
        state.update(roll: -179, pitch: nil)
        XCTAssertEqual(state.angle.target, 181)
        state.advance(0)
        state.advance(50_000_000)
        let displayed = state.angle.value
        state.update(roll: 178, pitch: nil)
        XCTAssertEqual(state.angle.value, displayed)
        XCTAssertEqual(state.angle.target, 178)
        state.advance(150_000_000)
        XCTAssertEqual(state.angle.value, 178)
    }

}
