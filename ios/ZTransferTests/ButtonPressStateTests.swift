import XCTest
@testable import ZTransfer

final class ButtonPressStateTests: XCTestCase {
    func testSameFrameQuickTapRemainsVisibleUntilNinetyMilliseconds() {
        var state = ZTransferButtonPressState()
        state.press(1, at: 1000)
        state.release(1, at: 1000)
        XCTAssertTrue(state.visualPressed)
        XCTAssertEqual(state.releaseDeadline, 1090)
        state.advance(to: 1089)
        XCTAssertTrue(state.visualPressed)
        state.advance(to: 1090)
        XCTAssertFalse(state.visualPressed)
        XCTAssertNil(state.releaseDeadline)
    }

    func testLongPressReleasesImmediatelyAndUnknownReleaseDoesNothing() {
        var state = ZTransferButtonPressState()
        state.press(1, at: 0)
        state.release(2, at: 120)
        XCTAssertTrue(state.visualPressed)
        state.release(1, at: 120)
        XCTAssertFalse(state.visualPressed)
        XCTAssertNil(state.releaseDeadline)
    }

    func testOverlappingPressesAndFastRetapCancelOldReleaseDeadline() {
        var state = ZTransferButtonPressState()
        state.press(1, at: 0)
        state.press(2, at: 10)
        state.release(1, at: 20)
        XCTAssertNil(state.releaseDeadline)
        XCTAssertTrue(state.visualPressed)
        state.release(2, at: 30)
        XCTAssertEqual(state.releaseDeadline, 90)
        state.press(3, at: 50)
        state.advance(to: 90)
        XCTAssertTrue(state.visualPressed)
        state.release(3, at: 91)
        XCTAssertEqual(state.releaseDeadline, 140)
        state.advance(to: 140)
        XCTAssertFalse(state.visualPressed)
    }

    func testCancelDoesNotHoldButDoesNotCancelAnotherActivePress() {
        var state = ZTransferButtonPressState()
        state.press(1, at: 0)
        state.press(2, at: 1)
        state.cancel(1)
        XCTAssertTrue(state.visualPressed)
        state.cancel(2)
        XCTAssertFalse(state.visualPressed)
        XCTAssertNil(state.releaseDeadline)
    }

    func testDisableAndDisposalClearPendingReleaseAndIgnoreDisabledPresses() {
        var state = ZTransferButtonPressState()
        state.press(1, at: 0)
        state.release(1, at: 1)
        state.setEnabled(false)
        state.press(2, at: 2)
        XCTAssertFalse(state.visualPressed)
        XCTAssertNil(state.releaseDeadline)
        state.setEnabled(true)
        state.press(3, at: 3)
        state.reset()
        state.advance(to: 100)
        XCTAssertFalse(state.visualPressed)
        XCTAssertNil(state.releaseDeadline)
    }
}
