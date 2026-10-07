import XCTest
@testable import ZTransfer

@MainActor
final class RemoteLUTStateTests: XCTestCase {
    private func lut(_ value: String) throws -> CubeLUT {
        try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "\(value) 0 0\n", count: 8)).utf8))
    }

    func testFailureKeepsCurrentAndSuccessfulCandidateCommitsAtomically() throws {
        let state = RemoteLUTState()
        let first = try lut("0")
        let second = try lut("1")
        state.begin(); state.loaded(first); state.commitCandidate()
        state.begin(); state.loaded(second); state.fail("GPU")
        XCTAssertEqual(state.current, first)
        XCTAssertNil(state.candidate)
        state.begin(); state.loaded(second); state.commitCandidate()
        XCTAssertEqual(state.current, second)
    }
}
