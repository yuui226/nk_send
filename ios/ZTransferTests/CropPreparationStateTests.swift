import XCTest
@testable import ZTransfer

final class CropPreparationStateTests: XCTestCase {
    func testRetryAdvancesAttemptAndSuccessClearsFailure() {
        var state = CropPreparationState.idle
        state.beginRetry(); XCTAssertEqual(state, .loading(attempt: 1))
        state.fail(.previewRead(detail: "timeout")); XCTAssertTrue(state.isRetryable)
        state.beginRetry(); XCTAssertEqual(state.attempt, 1)
        state.succeed(); XCTAssertEqual(state, .ready)
    }
    func testOrientationFailureIsNotRetryable() {
        var state = CropPreparationState.idle
        state.fail(.orientation(detail: "invalid")); XCTAssertFalse(state.isRetryable)
    }
}
