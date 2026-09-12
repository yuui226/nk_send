import XCTest
@testable import ZTransfer

private actor PhotoEffectsAttemptLog {
    private var attempts: [String: Int] = [:]
    func record(_ id: String) -> Int {
        attempts[id, default: 0] += 1
        return attempts[id]!
    }
    func snapshot() -> [String: Int] { attempts }
}

private actor PhotoEffectsHeldOperation {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(began: XCTestExpectation) async {
        await withCheckedContinuation {
            continuation = $0
            began.fulfill()
        }
    }
    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

final class PhotoEffectsBatchSessionTests: XCTestCase {
    private enum Failure: Error { case render }

    private func asset(_ id: String) -> IOSPhotoEffectAsset {
        IOSPhotoEffectAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id).jpg"), displayName: id)
    }

    @MainActor
    func testSelectionDeduplicatesAndPreviewWraps() {
        let session = PhotoEffectsBatchSession()
        XCTAssertTrue(session.replaceSelection([asset("a"), asset("a"), asset("b"), asset("c")]))
        XCTAssertEqual(session.selectedCount, 3)
        XCTAssertEqual(session.currentAsset?.id, "a")
        session.movePreview(by: -1)
        XCTAssertEqual(session.currentAsset?.id, "c")
        session.movePreview(by: 1)
        XCTAssertEqual(session.currentAsset?.id, "a")
    }

    @MainActor
    func testThrownAndReturnedFailuresRetryWithoutRegeneratingSavedAssets() async {
        let session = PhotoEffectsBatchSession()
        let attempts = PhotoEffectsAttemptLog()
        session.replaceSelection([asset("a"), asset("b"), asset("c")])
        let task = session.generateAndSave { item in
            let count = await attempts.record(item.id)
            if count == 1 && item.id == "b" { throw Failure.render }
            return count != 1 || item.id != "c"
        }
        await task?.value
        XCTAssertEqual(session.selectedCount, 3)
        XCTAssertEqual(session.status, .finished(saved: 1, failed: 2))
        XCTAssertEqual(session.failedAssets.map(\.id), ["b", "c"])
        XCTAssertEqual(session.completedAssets.map(\.id), ["a"])

        await session.retryFailed()?.value
        let calls = await attempts.snapshot()
        XCTAssertEqual(calls, ["a": 1, "b": 2, "c": 2])
        XCTAssertEqual(session.failedAssets, [])
        XCTAssertEqual(session.completedAssets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(session.status, .finished(saved: 3, failed: 0))
        XCTAssertFalse(session.canRetryFailed)
    }

    @MainActor
    func testSelectionAndDuplicateStartAreRejectedWhileGenerating() async {
        let session = PhotoEffectsBatchSession()
        let gate = PhotoEffectsHeldOperation()
        let began = expectation(description: "first asset is held")
        session.replaceSelection([asset("a")])
        let task = session.generateAndSave { _ in
            await gate.wait(began: began)
            return true
        }
        await fulfillment(of: [began], timeout: 3)
        XCTAssertFalse(session.replaceSelection([asset("b")]))
        session.removeCurrent()
        XCTAssertEqual(session.assets.map(\.id), ["a"])
        XCTAssertEqual(session.status, .generating(completed: 0, total: 1))
        XCTAssertNil(session.generateAndSave { _ in XCTFail("second batch"); return true })
        await gate.release()
        await task?.value
        XCTAssertEqual(session.status, .finished(saved: 1, failed: 0))
    }

    @MainActor
    func testLateOldWorkerCannotOverwriteReplacementBatch() async {
        let session = PhotoEffectsBatchSession()
        let gate = PhotoEffectsHeldOperation()
        let began = expectation(description: "old worker is held")
        session.replaceSelection([asset("old")])
        let old = session.generateAndSave { _ in
            await gate.wait(began: began) // Deliberately finishes even after cancellation.
            return true
        }
        await fulfillment(of: [began], timeout: 3)
        session.cancelForDismissal()
        session.replaceSelection([asset("new")])
        await session.generateAndSave { _ in true }?.value
        await gate.release()
        await old?.value
        XCTAssertEqual(session.status, .finished(saved: 1, failed: 0))
        XCTAssertEqual(session.completedAssets.map(\.id), ["new"])
        XCTAssertTrue(session.failedAssets.isEmpty)
    }

    @MainActor
    func testCompletionWaitsForAllProgressAndRemainsTerminal() async {
        let session = PhotoEffectsBatchSession()
        session.replaceSelection((0..<80).map { asset(String($0)) })
        var observed: [IOSPhotoEffectsBatchStatus] = []
        let observation = session.$status.sink { observed.append($0) }
        await session.generateAndSave { _ in true }?.value
        let completed = observed.compactMap { value -> Int? in
            if case let .generating(count, total) = value {
                XCTAssertEqual(total, 80)
                return count
            }
            return nil
        }
        XCTAssertEqual(completed, completed.sorted())
        XCTAssertEqual(completed.last, 80)
        XCTAssertEqual(observed.last, .finished(saved: 80, failed: 0))
        observation.cancel()
    }

    @MainActor
    func testCancellationDoesNotBecomeRetryableFailure() async {
        let session = PhotoEffectsBatchSession()
        session.replaceSelection([asset("a")])
        await session.generateAndSave { _ in throw CancellationError() }?.value
        XCTAssertEqual(session.status, .idle)
        XCTAssertFalse(session.canRetryFailed)
        XCTAssertTrue(session.failedAssets.isEmpty)
    }

    @MainActor
    func testWorkerDoesNotRetainDismissedSession() async {
        var session: PhotoEffectsBatchSession? = PhotoEffectsBatchSession()
        weak var released = session
        let gate = PhotoEffectsHeldOperation()
        let began = expectation(description: "worker holds no session owner")
        session?.replaceSelection([asset("a")])
        let task = session?.generateAndSave { _ in
            await gate.wait(began: began)
            return true
        }
        await fulfillment(of: [began], timeout: 3)
        session = nil
        XCTAssertNil(released)
        await gate.release()
        await task?.value
    }
}
