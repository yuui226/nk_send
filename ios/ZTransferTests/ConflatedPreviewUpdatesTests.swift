import XCTest
@testable import ZTransfer

@MainActor
final class ConflatedPreviewUpdatesTests: XCTestCase {
    func testAcceptedTransitionCompletesAndOnlyLatestPendingIsConsumed() async throws {
        let queue = ConflatedPreviewUpdates<Int>()
        let started = expectation(description: "first started")
        let finished = expectation(description: "latest completed")
        var seen: [Int] = []
        var release: CheckedContinuation<Void, Never>?
        let operation: @MainActor (Int, @escaping @MainActor () -> Int) async -> Void = { value, latest in
            seen.append(value)
            if value == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
                XCTAssertFalse(Task.isCancelled)
                XCTAssertEqual(latest(), 3)
            } else { finished.fulfill() }
        }
        queue.submit(1, operation: operation)
        await fulfillment(of: [started], timeout: 2)
        queue.submit(2, operation: operation); queue.submit(3, operation: operation)
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(seen, [1, 3])
        queue.close()
    }

    func testLeavingCancelsCurrentAndDropsPendingButReentryWorks() async {
        let queue = ConflatedPreviewUpdates<Int>()
        let started = expectation(description: "started"), cancelled = expectation(description: "cancelled")
        let next = expectation(description: "new lifecycle")
        queue.submit(1) { _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)); XCTFail() }
            catch { cancelled.fulfill() }
        }
        await fulfillment(of: [started], timeout: 2)
        queue.submit(2) { _, _ in XCTFail("pending old lifecycle") }
        queue.close()
        queue.submit(3) { value, _ in XCTAssertEqual(value, 3); next.fulfill() }
        await fulfillment(of: [cancelled, next], timeout: 2)
        queue.close()
    }
}
