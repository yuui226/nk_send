import XCTest
@testable import ZTransfer

final class PhotoEffectsBatchCoordinatorTests: XCTestCase {
    private actor Probe {
        var active = 0
        var peak = 0
        var calls: [Int] = []

        func begin(_ value: Int) {
            active += 1; peak = max(peak, active); calls.append(value)
        }

        func end() { active -= 1 }
    }

    func testEmptySelectionCompletesWithoutInvokingGenerator() async throws {
        let coordinator = PhotoEffectsBatchCoordinator()
        let result = try await coordinator.process([Int](), onProgress: { _ in }) { _ in
            XCTFail("empty selection must not invoke generator")
            return true
        }
        XCTAssertEqual(result, IOSPhotoEffectsBatchProgress(total: 0, completed: 0, saved: 0))
    }

    func testFailuresContinueAndAtMostTwoGeneratorsRunConcurrently() async throws {
        let coordinator = PhotoEffectsBatchCoordinator()
        let probe = Probe()
        let result = try await coordinator.process(Array(0..<7), onProgress: { _ in }) { value in
            await probe.begin(value)
            try await Task.sleep(nanoseconds: 2_000_000)
            await probe.end()
            return value != 3
        }
        let peak = await probe.peak
        let calls = await probe.calls
        XCTAssertEqual(result.total, 7)
        XCTAssertEqual(result.completed, 7)
        XCTAssertEqual(result.saved, 6)
        XCTAssertEqual(result.failed, 1)
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(Set(calls), Set(0..<7))
    }
}
