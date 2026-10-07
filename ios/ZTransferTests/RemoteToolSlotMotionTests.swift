import XCTest
@testable import ZTransfer

final class RemoteToolSlotMotionTests: XCTestCase {
    @MainActor
    func testFixedSlotsFollowReflowSnapOnExitAndRemoveDetachedSlots() {
        let motion = RemoteToolEditorMotion()
        defer { motion.stop() }
        func configure(_ slots: [String: CGRect], editing: Bool) {
            motion.configure(slots: [:], fixedSlots: slots, editing: editing,
                             visible: [], dragging: nil, topLeft: .zero, scale: 3)
        }
        let first = CGRect(x: 42, y: 40, width: 36, height: 36)
        let moved = CGRect(x: 126, y: 80, width: 36, height: 36)
        configure(["manage": first, "rotate": moved], editing: true)
        XCTAssertEqual(motion.fixedPosition("manage"), first.origin)
        XCTAssertFalse(motion.fixedPositions["manage"]!.isRunning)
        configure(["manage": moved, "rotate": first], editing: true)
        XCTAssertEqual(motion.fixedPosition("manage"), first.origin)
        XCTAssertEqual(motion.fixedPositions["manage"]!.target, CGPoint(x: 378, y: 240))
        XCTAssertTrue(motion.fixedPositions["manage"]!.isRunning)
        XCTAssertTrue(motion.states.isEmpty) // Fixed controls never acquire lift or wiggle state.
        configure(["manage": moved, "rotate": first], editing: false)
        XCTAssertEqual(motion.fixedPosition("manage"), moved.origin)
        XCTAssertFalse(motion.fixedPositions["manage"]!.isRunning)
        configure(["rotate": first], editing: false)
        XCTAssertNil(motion.fixedPosition("manage"))
    }

    func testEditorHeightFirstMeasurementAndExitAreImmediate() {
        var motion = RemoteToolHeightMotion()
        motion.measure(36, scale: 3)
        XCTAssertNil(motion.height)
        motion.setEditing(true)
        motion.measure(76, scale: 3)
        XCTAssertEqual(motion.height, 76)
        XCTAssertFalse(motion.isRunning)
        motion.measure(116, scale: 3)
        motion.advance(0)
        XCTAssertEqual(motion.height, 76)
        motion.advance(110_000_000)
        XCTAssertEqual(motion.height!, 107, accuracy: 1.0 / 3)
        motion.advance(220_000_000)
        XCTAssertEqual(motion.height, 116)
        motion.setEditing(false)
        XCTAssertNil(motion.height)
        motion.setEditing(true)
        motion.measure(36, scale: 3)
        XCTAssertEqual(motion.height, 36)
        XCTAssertFalse(motion.isRunning)
    }

    func testWiggleDelayReverseAndDragRestart() {
        var slot = RemoteToolSlotMotion(tool: .fps, position: .zero, visible: true)
        slot.configure(position: .zero, editing: true, visible: true, dragging: false)
        slot.advance(0)
        slot.advance(55_000_000)
        XCTAssertEqual(slot.angle, -1.3)
        slot.advance(135_000_000)
        XCTAssertEqual(slot.angle, 0, accuracy: 0.00001)
        slot.advance(215_000_000)
        XCTAssertEqual(slot.angle, 1.3, accuracy: 0.00001)
        slot.advance(295_000_000)
        XCTAssertEqual(slot.angle, 0, accuracy: 0.00001)
        slot.configure(position: CGPoint(x: 80, y: 40), editing: true, visible: true, dragging: true)
        XCTAssertEqual(slot.angle, 0)
        XCTAssertEqual(slot.position.value, CGPoint(x: 80, y: 40))
        slot.advance(300_000_000)
        slot.advance(420_000_000)
        XCTAssertEqual(slot.lift.value, 1.1)
        slot.configure(position: .zero, editing: true, visible: true, dragging: false)
        XCTAssertEqual(slot.angle, -1.3)
        XCTAssertTrue(slot.position.isRunning)
    }

    func testHiddenIconFadesWithoutWigglingAndLeavingEditSnapsPosition() {
        var slot = RemoteToolSlotMotion(tool: .hd, position: .zero, visible: true)
        slot.configure(position: CGPoint(x: 126, y: 40), editing: true, visible: false, dragging: false)
        slot.advance(0)
        XCTAssertEqual(slot.iconOpacity.value, 1)
        XCTAssertEqual(slot.angle, 0)
        slot.advance(180_000_000)
        XCTAssertEqual(slot.iconOpacity.value, 0.38)
        slot.configure(position: CGPoint(x: 42, y: 0), editing: false, visible: false, dragging: false)
        XCTAssertEqual(slot.position.value, CGPoint(x: 42, y: 0))
        XCTAssertFalse(slot.position.isRunning)
        XCTAssertFalse(slot.wiggles)
    }

    func testRetargetedPositionDoesNotJumpAndBothAxesFinishTogether() {
        var motion = RemoteToolPositionMotion(.zero)
        motion.setTarget(CGPoint(x: 300, y: 1), snap: false)
        motion.advance(0)
        motion.advance(100_000_000)
        let intermediate = motion.value
        XCTAssertGreaterThan(intermediate.x, 0)
        XCTAssertLessThan(intermediate.x, 300)
        motion.setTarget(CGPoint(x: 42, y: 40), snap: false)
        XCTAssertEqual(motion.value, intermediate)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.value, CGPoint(x: 42, y: 40))
        XCTAssertFalse(motion.isRunning)
    }
}
