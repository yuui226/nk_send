import XCTest
@testable import ZTransfer

@MainActor
final class RemoteToolDragStateTests: XCTestCase {
    private func withLayout(_ body: (RemoteToolLayout) -> Void) {
        let name = "remote-drag-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in }))
    }

    func testStartsAtAnimatedPositionButReordersUsingDestinationSlots() {
        withLayout { layout in
            let drag = RemoteToolDragState()
            drag.slots[.hd] = CGRect(x: 0, y: 0, width: 36, height: 36)
            drag.slots[.fps] = CGRect(x: 42, y: 0, width: 36, height: 36)
            drag.visualPositions[.hd] = { CGPoint(x: 0, y: 40) }
            // Neighbor is visually overlapping HD, but its destination is on row one.
            drag.visualPositions[.fps] = { CGPoint(x: 0, y: 40) }
            XCTAssertTrue(drag.begin(at: CGPoint(x: 18, y: 58), delta: CGSize(width: 42, height: -40), layout: layout))
            XCTAssertEqual(drag.dragging, .hd)
            XCTAssertEqual(drag.topLeft, CGPoint(x: 42, y: 0))
            XCTAssertEqual(Array(layout.shownTools.prefix(2)), [.fps, .hd])
            XCTAssertTrue(layout.visible(.hd))
            drag.end()
            XCTAssertNil(drag.dragging)
        }
    }

    func testHiddenAndFixedButtonsCannotStartDragAndRightEdgeIsExcluded() {
        withLayout { layout in
            let drag = RemoteToolDragState()
            drag.slots[.hd] = CGRect(x: 0, y: 0, width: 36, height: 36)
            drag.slots[.rotate] = CGRect(x: 42, y: 0, width: 36, height: 36)
            XCTAssertFalse(drag.begin(at: CGPoint(x: 36, y: 18), delta: .zero, layout: layout))
            layout.setVisible(.hd, false)
            XCTAssertFalse(drag.begin(at: CGPoint(x: 18, y: 18), delta: .zero, layout: layout))
            XCTAssertFalse(drag.begin(at: CGPoint(x: 60, y: 18), delta: .zero, layout: layout))
            XCTAssertNil(drag.dragging)
        }
    }

    func testCrossRowMoveOntoLockUsesDisplayedOrderAndDisposalClearsGesture() {
        withLayout { layout in
            let drag = RemoteToolDragState()
            for (index, tool) in layout.shownTools.enumerated() {
                drag.slots[tool] = CGRect(x: index * 42, y: 0, width: 36, height: 36)
            }
            drag.slots[.lock] = CGRect(x: 0, y: 40, width: 36, height: 36)
            XCTAssertTrue(drag.begin(at: CGPoint(x: 18, y: 18), delta: CGSize(width: 0, height: 40), layout: layout))
            XCTAssertFalse(layout.lockStartsSecondRow)
            XCTAssertEqual(layout.shownTools.last, .hd)
            drag.remove(.hd)
            XCTAssertNil(drag.dragging)
            XCTAssertNil(drag.visualBounds(.hd))
        }
    }
}
