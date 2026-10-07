import XCTest
@testable import ZTransfer

@MainActor final class RemoteLUTMonitorStateTests: XCTestCase {
    private func lut() -> CubeLUT {
        try! CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
    }

    func testOnlyPresentedCandidateReplacesActiveAndFailurePreservesIt() {
        let state = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: UserDefaults(suiteName: "lut-monitor-test")!))
        state.environment(movie: false, available: true, visible: true)
        let first = RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: nil)
        let second = RemoteLUTFile(identifier: "b", name: "b.cube", relativePath: "b.cube", size: nil)
        let id1 = state.beginSelection(first)!; state.loaded(first, lut: lut(), generation: id1)
        XCTAssertNil(state.active); state.presented(generation: id1); XCTAssertEqual(state.active?.file.identifier, "a")
        let id2 = state.beginSelection(second)!; state.failed(generation: id2, reason: "read")
        XCTAssertEqual(state.active?.file.identifier, "a")
    }
}
