import XCTest
import SwiftUI
@testable import ZTransfer

final class QueueSummaryTests: XCTestCase {
    private func task(_ id: Int, status: TransferStatus = .completed, generating: Bool = false, start: Int64? = nil) -> TransferQueueItem {
        var value = TransferQueueItem(attemptOrder: UInt64(id),
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            file: CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 20_000_000,
                fileName: "DSC_\(id).JPG", captureDate: nil, isProtected: false), status: status)
        value.isGeneratingFrame = generating; value.frameGenerationStartedAtElapsedMs = start
        return value
    }
    private func finished(_ item: TransferQueueItem, elapsed: Int64 = 1250) -> TransferQueueItem {
        var value = item; value.isGeneratingFrame = false; value.frameGenerationStartedAtElapsedMs = nil
        value.frameGenerationElapsedMs = elapsed; return value
    }
    private func residents(_ rows: [GenerationRowSnapshot]) -> [GenerationRowSnapshot] { rows.filter { !$0.phase.retiring } }

    func testIndependentCountsAndPriorityNeverInventDownloadsOrFutureEffects() {
        let running = task(8, generating: true, start: 1), second = task(9, generating: true, start: 2)
        let waiting = task(3, generating: true), retry = task(20, generating: true)
        let download = task(5, status: .transferring), queued = task(6, status: .waiting)
        let items = [retry, waiting, download, running, task(7), queued, second]
        let state = TransferQueuePresentation(items: items, isTransferring: true)
        XCTAssertEqual(state.generationTasks.map(\.id), [running, second, waiting, retry].map(\.id))
        XCTAssertEqual(state.generationRemaining, 4)
        XCTAssertEqual(state.generationState, .running)
        XCTAssertEqual(state.downloadTask, download)
        XCTAssertEqual(state.downloadRemaining, 2)
        XCTAssertEqual(state.downloadState, .running)
        let gap = TransferQueuePresentation(items: [queued, task(100, status: .waiting)], isTransferring: true)
        XCTAssertNil(gap.downloadTask); XCTAssertEqual(gap.downloadState, .waiting)
        XCTAssertEqual(gap.generationRemaining, 0)
    }

    func testPausedAndTerminalStatesDoNotRetainWrongFileOrClock() {
        let waiting = task(1, status: .waiting), current = task(2, status: .transferring)
        for transferring in [true, false] {
            let active = TransferQueuePresentation(items: [current, waiting], isTransferring: transferring, pauseAfterCurrent: true)
            XCTAssertEqual(active.downloadState, .running)
            XCTAssertEqual(active.downloadTask, current)
            let stopped = TransferQueuePresentation(items: [waiting], isTransferring: transferring, pauseAfterCurrent: true)
            XCTAssertEqual(stopped.downloadState, .paused); XCTAssertEqual(stopped.downloadRemaining, 1)
            for status in [TransferStatus.completed, .cancelled, .failed] {
                var terminal = task(1, status: status); terminal.downloadMBps = 20; terminal.elapsedMs = 10
                XCTAssertEqual(TransferQueuePresentation(items: [terminal], isTransferring: transferring, pauseAfterCurrent: true), .init())
            }
        }
    }

    func testPendingCheckAndLegacyCropProtectionDoNotDoubleCount() {
        for status in [TransferStatus.completed, .transferring, .waiting] {
            var checking = task(1, status: status, generating: true); checking.frameGenerationPendingCheck = true
            XCTAssertEqual(TransferQueuePresentation(items: [checking], isTransferring: true), .init())
            checking.frameGenerationPendingCheck = false
            for start in [nil, Int64(100)] {
                checking.frameGenerationStartedAtElapsedMs = start
                let value = TransferQueuePresentation(items: [checking], excludedIDs: [checking.id])
                XCTAssertEqual(value.generationRemaining, 1); XCTAssertEqual(value.downloadRemaining, 0)
                XCTAssertEqual(value.generationState, start == nil ? .waiting : .running)
            }
        }
        let active = task(1, status: .transferring), waiting = task(2, status: .waiting)
        let value = TransferQueuePresentation(items: [active, waiting], isTransferring: true, excludedIDs: [active.id, waiting.id])
        XCTAssertEqual(value.downloadRemaining, 1); XCTAssertEqual(value.downloadTask, active)
    }

    func testGenerationRowsHoldSuccessfulFirstThenMoveBoundedQueueUp() {
        let tasks = (1...6).map { task($0, generating: true) }
        let initial = generationRowSnapshots(previous: [], tasks: tasks, allTasks: tasks)
        let done = finished(tasks[0])
        let rest = Array(tasks.dropFirst()), history = [done] + rest
        let holding = generationRowSnapshots(previous: initial, tasks: rest, allTasks: history)
        XCTAssertEqual(residents(holding).map(\.id), Array(tasks.prefix(3)).map(\.id))
        XCTAssertEqual(holding[0].phase, .succeeded); XCTAssertEqual(holding[0].task.frameGenerationElapsedMs, 1250)
        let advanced = finishGenerationRowPhase(holding, id: done.id, expected: .succeeded)
        let moving = generationRowSnapshots(previous: advanced, tasks: rest, allTasks: history)
        XCTAssertEqual(residents(moving).map(\.id), Array(rest.prefix(3)).map(\.id))
        XCTAssertEqual(residents(moving).map(\.position), [0, 1, 2])
        XCTAssertEqual(moving.first?.phase, .exitingSuccess)
        XCTAssertEqual(finishGenerationRowPhase(moving, id: done.id, expected: .exitingSuccess).map(\.id), Array(rest.prefix(3)).map(\.id))
    }

    func testSecondRowSuccessNeverDisplacesRunningFirstRow() {
        let tasks = (1...4).map { task($0, generating: true) }
        let initial = generationRowSnapshots(previous: [], tasks: tasks, allTasks: tasks)
        let active = [tasks[0], tasks[2], tasks[3]], done = finished(tasks[1])
        let hold = generationRowSnapshots(previous: initial, tasks: active, allTasks: active + [done])
        XCTAssertEqual(residents(hold).map(\.id), Array(tasks.prefix(3)).map(\.id))
        let advanced = generationRowSnapshots(previous: finishGenerationRowPhase(hold, id: done.id, expected: .succeeded), tasks: active, allTasks: active + [done])
        XCTAssertEqual(residents(advanced).map(\.id), active.map(\.id))
        XCTAssertEqual(advanced.first { $0.id == tasks[0].id }?.position, 0)
    }

    func testGenerationFailureSkipMissingAndRetryNeverReplaySuccess() {
        let running = task(1, generating: true, start: 100)
        let initial = generationRowSnapshots(previous: [], tasks: [running], allTasks: [running])
        var failed = finished(running); failed.frameError = "failed"
        var skipped = finished(running); skipped.frameGenerationSkipped = true
        var cancelled = finished(running); cancelled.status = .cancelled
        for history in [[failed], [skipped], [cancelled], []] {
            let rows = generationRowSnapshots(previous: initial, tasks: [], allTasks: history)
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].phase, .exiting)
            XCTAssertTrue(rows[0].phase.frozen)
        }
        let done = finished(running, elapsed: 750)
        let hold = generationRowSnapshots(previous: initial, tasks: [], allTasks: [done])
        for _ in 0..<10 {
            XCTAssertEqual(generationRowSnapshots(previous: hold, tasks: [], allTasks: [finished(running, elapsed: 999)]), hold)
        }
        for old in [hold, finishGenerationRowPhase(hold, id: done.id, expected: .succeeded)] {
            let retry = generationRowSnapshots(previous: old, tasks: [running], allTasks: [running])
            XCTAssertEqual(retry, initial)
            XCTAssertEqual(finishGenerationRowPhase(retry, id: done.id, expected: old[0].phase), retry)
        }
        var zero = finished(running, elapsed: 0); zero.skipped = true
        XCTAssertTrue(generationReallyCompleted(zero))
    }

    func testFastGenerationHistoryRemainsBoundedAndNeverReplaysInvisibleCompletion() {
        let tasks = (1...1000).map { task($0, generating: true) }
        var rows = generationRowSnapshots(previous: [], tasks: tasks, allTasks: tasks)
        for start in stride(from: 3, to: 100, by: 3) {
            let active = Array(tasks.dropFirst(start))
            let history = tasks.enumerated().map { $0.offset < start ? finished($0.element) : $0.element }
            rows = generationRowSnapshots(previous: rows, tasks: active, allTasks: history)
            XCTAssertLessThanOrEqual(rows.count, 5); XCTAssertLessThanOrEqual(residents(rows).count, 3)
            XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
            XCTAssertFalse(rows.contains { $0.id == tasks[start - 1].id && $0.phase.completed })
            for row in rows where row.phase == .succeeded { rows = finishGenerationRowPhase(rows, id: row.id, expected: row.phase) }
            rows = generationRowSnapshots(previous: rows, tasks: active, allTasks: history)
            XCTAssertEqual(residents(rows).map(\.id), Array(active.prefix(3)).map(\.id))
            for row in rows where row.phase.retiring { rows = finishGenerationRowPhase(rows, id: row.id, expected: row.phase) }
        }
    }

    func testHiddenChecksAndPrefetchedSuccessHaveNoVisibleLifecycle() {
        var checking = task(1, generating: true); checking.frameGenerationPendingCheck = true
        XCTAssertTrue(generationRowSnapshots(previous: [], tasks: [checking], allTasks: [checking]).isEmpty)
        let tasks = (2...5).map { task($0, generating: true) }
        let initial = generationRowSnapshots(previous: [], tasks: tasks, allTasks: tasks)
        let active = [tasks[0], tasks[1], tasks[3]]
        let rows = generationRowSnapshots(previous: initial, tasks: active, allTasks: active + [finished(tasks[2])])
        XCTAssertEqual(rows.map(\.id), active.map(\.id)); XCTAssertTrue(rows.allSatisfy { $0.phase == .active })
        XCTAssertTrue(generationRowSnapshots(previous: [], tasks: [], allTasks: tasks.map { finished($0) }).isEmpty)
    }

    func testGenerationMotionExactTimingsAndLowerExitTravel() {
        var row = GenerationRowMotion(position: 1, height: 46)
        row.update(position: 1, height: 46, phase: .active)
        XCTAssertEqual(row.top.value, 104)
        XCTAssertNil(row.advance(0)); XCTAssertNil(row.advance(180_000_000))
        XCTAssertEqual(row.top.value, 52); XCTAssertEqual(row.alpha.value, 1)
        row.update(position: 1, height: 46, phase: .succeeded)
        XCTAssertNil(row.advance(200_000_000)); XCTAssertNil(row.advance(419_000_000))
        XCTAssertEqual(row.advance(420_000_000), .succeeded)
        XCTAssertNil(row.advance(430_000_000), "Callback fires once")
        row.update(position: 1, height: 46, phase: .exitingSuccess)
        XCTAssertNil(row.advance(440_000_000))
        XCTAssertNil(row.advance(579_000_000))
        XCTAssertEqual(row.advance(580_000_000), .exitingSuccess)
        _ = row.advance(620_000_000)
        XCTAssertEqual(row.top.value, 46, "Second row exits by the gap, never through the live first row")
        XCTAssertEqual(row.alpha.value, 0); XCTAssertFalse(row.isRunning)
    }

    func testDownloadFillHoldConflatesFastOwnersAndUsesFinalStatistics() {
        var one = task(1, status: .transferring); one.progress = 0.4
        var two = task(2, status: .transferring); two.progress = 0.2
        let three = task(3, status: .transferring)
        var motion = QueueDownloadMotion(initialTask: one)
        motion.update(active: one, progress: nil, tasks: [one], animate: true)
        motion.advance(0); motion.advance(1_000_000_000)
        var done = one; done.status = .completed; done.downloadMBps = 12
        motion.update(active: two, progress: nil, tasks: [done, two], animate: true)
        XCTAssertTrue(motion.completing); XCTAssertEqual(motion.task?.id, one.id)
        motion.advance(1_010_000_000)
        motion.update(active: three, progress: nil, tasks: [done, three], animate: true)
        motion.advance(1_130_000_000)
        XCTAssertEqual(motion.progress.value, 1); XCTAssertEqual(motion.task?.downloadMBps, 12)
        motion.advance(1_169_000_000); XCTAssertTrue(motion.completing)
        motion.advance(1_170_000_000)
        XCTAssertEqual(motion.task?.id, three.id); XCTAssertFalse(motion.completing)
        XCTAssertEqual(motion.progress.value, 0)
    }

    func testDownloadNeverBorrowsWrongProgressOrCompletesFailureAndHiddenDisplaySnaps() {
        var one = task(1, status: .transferring); one.progress = 0.7
        let other = task(2, status: .transferring)
        let old = TransferActiveProgress(taskID: other.id, fraction: 0.9, bytesPerSecond: 200, retainedBytesPerSecond: 300)
        XCTAssertEqual(queueDownloadTargetProgress(one, old), 0.7)
        for value in [Double.nan, .infinity, -1] {
            one.progress = value; XCTAssertEqual(queueDownloadTargetProgress(one, nil), 0)
        }
        one.progress = 0.6
        for status in [TransferStatus.failed, .cancelled, .waiting] {
            var motion = QueueDownloadMotion(initialTask: one), failed = one; failed.status = status
            motion.update(active: other, progress: nil, tasks: [failed, other], animate: true)
            XCTAssertEqual(motion.task?.id, other.id); XCTAssertFalse(motion.completing)
        }
        var motion = QueueDownloadMotion(initialTask: one)
        motion.update(active: one, progress: nil, tasks: [one], animate: false)
        XCTAssertEqual(motion.progress.value, 0.6); XCTAssertFalse(motion.isRunning)
        one.progress = 0.1
        motion.update(active: one, progress: nil, tasks: [one], animate: false)
        XCTAssertEqual(motion.progress.value, 0.6)
        var crop = one; crop.isGeneratingFrame = true
        XCTAssertNil(queueDownloadActiveTask(crop))
        XCTAssertEqual(queueDownloadCompletedTask(one.id, active: nil, tasks: [crop])?.id, one.id)
    }

    func testSummarySpeedIdentityRetentionAndIdleClearing() {
        var item = task(1, status: .transferring); item.bytesPerSecond = 80
        let progress = TransferActiveProgress(taskID: item.id, fraction: 0.1, bytesPerSecond: 0, retainedBytesPerSecond: 500)
        XCTAssertEqual(queueSummarySpeed(displayed: item, completed: nil, progress: progress, state: .running), 500)
        XCTAssertEqual(queueSummarySpeed(displayed: nil, completed: nil, progress: progress, state: .waiting), 500)
        for state in [QueueActivityState.idle, .paused] {
            XCTAssertNil(queueSummarySpeed(displayed: nil, completed: nil, progress: progress, state: state))
        }
        var done = item; done.downloadMBps = 2; done.status = .completed
        XCTAssertEqual(queueSummarySpeed(displayed: item, completed: done, progress: progress, state: .running), 2 * 1024 * 1024)
        done.downloadMBps = .nan
        XCTAssertEqual(queueSummarySpeed(displayed: item, completed: done, progress: progress, state: .idle), 80)
    }

    func testStableSummaryGeometryDoesNotUseCountsOrQueueActivity() {
        let narrow = QueueSummaryGeometry(width: 296, compact: false)
        XCTAssertEqual(narrow.padding, 8); XCTAssertTrue(narrow.stackedTime)
        XCTAssertEqual(narrow.height, 114)
        let wide = QueueSummaryGeometry(width: 600, compact: false)
        XCTAssertFalse(wide.stackedTime); XCTAssertEqual(wide.height, 74)
        let large = QueueSummaryGeometry(width: 600, compact: true, fontScale: 2.5)
        XCTAssertTrue(large.stackedTime); XCTAssertEqual(large.padding, 8)
    }
}

extension QueueSummaryTests {
    func testLastGenerationDepartureKeepsRowsAndNewWorkNeverUsesIdleSnapshot() {
        let original = task(1, generating: true, start: 100)
        let initial = generationRowSnapshots(previous: [], tasks: [original], allTasks: [original])
        let done = finished(original, elapsed: 500)
        let holding = generationRowSnapshots(previous: initial, tasks: [], allTasks: [done])
        let exiting = finishGenerationRowPhase(holding, id: original.id, expected: .succeeded)
        XCTAssertEqual(holding.first?.phase, .succeeded)
        XCTAssertEqual(exiting.first?.phase, .exitingSuccess)
        XCTAssertTrue(finishGenerationRowPhase(exiting, id: original.id, expected: .exitingSuccess).isEmpty)
        let next = task(2, generating: true, start: 600)
        for departure in [holding, exiting] {
            let arrived = generationRowSnapshots(previous: departure, tasks: [next], allTasks: [done, next])
            XCTAssertTrue(arrived.contains { $0.id == next.id && $0.phase == .active })
            let after = finishGenerationRowPhase(arrived, id: original.id, expected: departure[0].phase)
            XCTAssertTrue(after.contains { $0.id == next.id && $0.phase == .active })
        }
    }
}
