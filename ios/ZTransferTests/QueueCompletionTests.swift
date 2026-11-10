import XCTest
@testable import ZTransfer

final class QueueCompletionTests: XCTestCase {
    private func task(_ status: TransferStatus = .waiting) -> TransferQueueItem {
        .init(id: UUID(), file: .init(id: 1, storageID: 1, format: 0x3801, size: 100,
            fileName: "1.JPG", captureDate: nil, isProtected: false), status: status)
    }
    private func success(_ task: TransferQueueItem, real: Bool = true) -> TransferQueueItem {
        var result = task; result.status = .completed; result.isGeneratingFrame = false
        result.progress = 1; result.elapsedMs = real ? 20 : nil
        return result
    }
    private func observe(_ items: [TransferQueueItem]) -> QueueCompletionState {
        queueCompletionUpdate(previous: .init(), items: items).state
    }
    private func assertReset(_ update: QueueCompletionUpdate, ids: Set<UUID>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(update.state, .init(knownTaskIDs: ids), file: file, line: line)
    }
    func testInitialTerminalHistoryAndLaterIdleUpdatesNeverEmit() {
        var frameFailure = task(.completed); frameFailure.frameError = "failed"
        for items in [[], [task(.completed)], [task(.cancelled), task(.failed)], [frameFailure]] {
            let update = queueCompletionUpdate(previous: .init(), items: items)
            XCTAssertNil(update.feedback); assertReset(update, ids: Set(items.map(\.id)))
            let added = task(.failed)
            let next = queueCompletionUpdate(previous: update.state, items: [added])
            XCTAssertNil(next.feedback); assertReset(next, ids: [added.id])
        }
    }
    func testSuccessfulDownloadEmitsOnceAndSkippedOnlyDoesNotCelebrate() {
        for real in [true, false] {
            let waiting = task(); let done = success(waiting, real: real)
            let next = queueCompletionUpdate(previous: observe([waiting]), items: [done])
            XCTAssertEqual(next.feedback, .init(showDone: true, celebrate: real))
            assertReset(next, ids: [waiting.id])
            for _ in 0..<3 { XCTAssertNil(queueCompletionUpdate(previous: next.state, items: [done]).feedback) }
        }
    }
    func testGenerationSkipPendingCheckAndActualOutputEvidence() {
        for pending in [true, false] {
            for started in [true, false] {
                var generating = task(.completed); generating.isGeneratingFrame = true
                generating.frameGenerationPendingCheck = pending
                generating.frameGenerationStartedAtElapsedMs = started ? 100 : nil
                for saved in [true, false] {
                    var done = success(generating, real: false)
                    done.frameGenerationElapsedMs = saved ? 0 : nil
                    let result = queueCompletionUpdate(previous: observe([generating]), items: [done])
                    XCTAssertEqual(result.feedback, .init(showDone: true, celebrate: saved))
                }
                var downloaded = success(generating); downloaded.frameGenerationSkipped = true
                XCTAssertEqual(queueCompletionUpdate(previous: observe([generating]), items: [downloaded]).feedback,
                               .init(showDone: true, celebrate: true))
            }
        }
    }
    func testFailedDownloadOrEffectsCannotCelebrateEvenAfterSuccessfulDownload() {
        let active = task(.transferring)
        for status in [TransferStatus.failed, .cancelled, .completed] {
            var done = success(active); done.status = status
            if status == .completed { done.frameError = "save failed" }
            XCTAssertEqual(queueCompletionUpdate(previous: observe([active]), items: [done]).feedback,
                           .init(showDone: false, celebrate: false))
        }
    }
    func testRemovedFailureAndMissingWorkRemainUnsuccessful() {
        let active = task(.transferring), other = task()
        for status in [TransferStatus.failed, .cancelled] {
            var failed = other; failed.status = status
            let resolved = queueCompletionUpdate(previous: observe([active, other]), items: [failed, active])
            XCTAssertNil(resolved.feedback); XCTAssertTrue(resolved.state.hadUnsuccessfulResult)
            let cleared = queueCompletionUpdate(previous: resolved.state, items: [active])
            XCTAssertEqual(queueCompletionUpdate(previous: cleared.state, items: [success(active)]).feedback,
                           .init(showDone: false, celebrate: false))
        }
        let missing = queueCompletionUpdate(previous: observe([active, other]), items: [active])
        XCTAssertTrue(missing.state.hadUnsuccessfulResult)
        XCTAssertEqual(queueCompletionUpdate(previous: missing.state, items: [success(active)]).feedback,
                       .init(showDone: false, celebrate: false))
        let empty = queueCompletionUpdate(previous: observe([other]), items: [])
        XCTAssertEqual(empty.feedback, .init(showDone: false, celebrate: false)); assertReset(empty, ids: [])
    }
    func testRemovedSuccessfulWorkIsRetainedButNextBatchResets() {
        let active = task(.transferring), waiting = task()
        let first = queueCompletionUpdate(previous: observe([active, waiting]), items: [success(active), waiting])
        XCTAssertTrue(first.state.didRealWork)
        let cleared = queueCompletionUpdate(previous: first.state, items: [waiting])
        let finish = queueCompletionUpdate(previous: cleared.state, items: [success(waiting, real: false)])
        XCTAssertEqual(finish.feedback, .init(showDone: true, celebrate: true))
        let new = task()
        let next = queueCompletionUpdate(previous: finish.state, items: [new])
        XCTAssertFalse(next.state.didRealWork); XCTAssertFalse(next.state.hadUnsuccessfulResult)
        XCTAssertEqual(queueCompletionUpdate(previous: next.state, items: [success(new, real: false)]).feedback,
                       .init(showDone: true, celebrate: false))
    }
    func testHistoricalFailuresDoNotPoisonLaterBatchAndPauseHandoffDoesNotFinish() {
        let history = [task(.failed), task(.cancelled)], waiting = task()
        let first = observe(history + [waiting])
        XCTAssertEqual(queueCompletionUpdate(previous: first, items: history + [waiting]).state, first)
        var generation = success(waiting); generation.isGeneratingFrame = true
        let handoff = queueCompletionUpdate(previous: first, items: history + [generation])
        XCTAssertNil(handoff.feedback)
        let next = task()
        let joined = queueCompletionUpdate(previous: handoff.state, items: history + [success(generation), next])
        XCTAssertNil(joined.feedback); XCTAssertTrue(joined.state.didRealWork)
        XCTAssertEqual(queueCompletionUpdate(previous: joined.state, items: history + [success(next)]).feedback,
                       .init(showDone: true, celebrate: true))
    }
    func testCoalescedNewTerminalFailuresCountRegardlessOfOrderingAndRemoval() {
        let active = task(.transferring), old = task(.failed), new = task()
        for terminal in [task(.failed), task(.cancelled)] {
            let first = observe([old, active])
            for items in [[terminal, success(active), new], [new, success(active), terminal]] {
                let joined = queueCompletionUpdate(previous: first, items: [old] + items)
                XCTAssertTrue(joined.state.hadUnsuccessfulResult); XCTAssertNil(joined.feedback)
                XCTAssertEqual(queueCompletionUpdate(previous: joined.state, items: [success(new)]).feedback,
                               .init(showDone: false, celebrate: false))
            }
            XCTAssertEqual(queueCompletionUpdate(previous: first, items: [old, success(active), terminal]).feedback,
                           .init(showDone: false, celebrate: false))
            // A new batch can first appear alongside an already failed task.
            let started = queueCompletionUpdate(previous: observe([]), items: [active, terminal])
            XCTAssertTrue(started.state.hadUnsuccessfulResult)
        }
    }
    func testCoalescedSuccessSuppliesRealEvidenceIncludingZeroGenerationTime() {
        let waiting = task()
        for generationOnly in [true, false] {
            var extra = task(.completed)
            if generationOnly { extra.frameGenerationElapsedMs = 0 } else { extra.elapsedMs = 20 }
            let result = queueCompletionUpdate(previous: observe([waiting]), items: [success(waiting, real: false), extra])
            XCTAssertEqual(result.feedback, .init(showDone: true, celebrate: true))
        }
    }
    func testSnapshotMemoKeepsOneEventAcrossDisplayRecompositions() {
        let tracker = QueueCompletionTracker(), waiting = task()
        let started = tracker.observe([waiting])
        for _ in 0..<100 { XCTAssertEqual(tracker.observe([waiting]), started) }
        let done = success(waiting), ended = tracker.observe([done])
        XCTAssertEqual(ended.update.feedback, .init(showDone: true, celebrate: true))
        for _ in 0..<100 { XCTAssertEqual(tracker.observe([done]), ended) }
        var metadata = done; metadata.downloadMBps = 12
        XCTAssertNil(tracker.observe([metadata]).update.feedback)
    }
    func testWidthVisibilityReversesSameSpringAndFeatherOnlyAppliesToVisibility() {
        var motion = QueueTopPillWidthMotion()
        motion.update(width: 120, scale: 3); motion.update(width: 0, scale: 3)
        motion.advance(0); motion.advance(80_000_000)
        let width = motion.width!
        XCTAssertGreaterThan(width, 0); XCTAssertLessThan(width, 120)
        motion.update(width: 180, scale: 3)
        XCTAssertEqual(motion.width, width)
        motion.advance(2_000_000_000); XCTAssertEqual(motion.width, 180)
        motion.update(width: 0, scale: 3); motion.advance(3_000_000_000); motion.advance(5_000_000_000)
        XCTAssertEqual(motion.width, 0); XCTAssertFalse(motion.isRunning)
        XCTAssertEqual(queuePillVisibilityFeather(width: 20, naturalWidth: 120, transitioning: false), 0)
        XCTAssertEqual(queuePillVisibilityFeather(width: 120, naturalWidth: 120, transitioning: true), 0)
        XCTAssertEqual(queuePillVisibilityFeather(width: 0, naturalWidth: 120, transitioning: true), 1)
        XCTAssertEqual(queuePillVisibilityFeather(width: 109.2, naturalWidth: 120, transitioning: true), 0.5, accuracy: 0.0001)
    }
}
