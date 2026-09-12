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

    private actor Gate {
        private var held: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait(began: XCTestExpectation) async {
            if open { return }
            await withCheckedContinuation {
                held.append($0)
                began.fulfill()
            }
        }
        func release() {
            open = true
            let waiting = held
            held.removeAll()
            waiting.forEach { $0.resume() }
        }
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

    func testOverlappingCallsKeepIndependentCursorsAndProgress() async throws {
        let coordinator = PhotoEffectsBatchCoordinator()
        let gate = Gate()
        let began = expectation(description: "both invocations have two workers")
        began.expectedFulfillmentCount = 4
        async let first = coordinator.process(Array(0..<5), onProgress: { _ in }) { _ in
            await gate.wait(began: began)
            return true
        }
        async let second = coordinator.process(Array(10..<17), onProgress: { _ in }) { _ in
            await gate.wait(began: began)
            return false
        }
        await fulfillment(of: [began], timeout: 3)
        await gate.release()
        let results = try await (first, second)
        XCTAssertEqual(results.0, IOSPhotoEffectsBatchProgress(total: 5, completed: 5, saved: 5))
        XCTAssertEqual(results.1, IOSPhotoEffectsBatchProgress(total: 7, completed: 7, saved: 0))
    }

    func testCancellationDoesNotAdmitAnotherAsset() async {
        let coordinator = PhotoEffectsBatchCoordinator()
        let calls = Probe()
        let task = Task {
            try await coordinator.process(Array(0..<20), onProgress: { _ in }) { value in
                await calls.begin(value)
                throw CancellationError()
            }
        }
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let started = await calls.calls
        XCTAssertLessThanOrEqual(started.count, 2)
    }
}
