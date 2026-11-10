import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class STAConnectionDiagnosticsTests: XCTestCase {
    #if DEBUG
    func testTraceRecordsElapsedAndDeltaPreservingFirstAndLatest128() {
        let time = STAAtomicBox(Int64(100)), trace = STAConnectionTrace(now: { time.value })
        for i in 0..<300 { time.value += 10; trace.note("command-\(i)") }
        let report = trace.report()
        XCTAssertTrue(report.contains("+10ms Δ10ms command-0\n"))
        XCTAssertTrue(report.contains("command-127\n"))
        XCTAssertFalse(report.contains("command-128\n"))
        XCTAssertTrue(report.contains("中间省略 44 条"))
        XCTAssertTrue(report.hasSuffix("+3000ms Δ10ms command-299"))
        XCTAssertEqual(report.split(separator: "\n").count, 258)
    }
    #endif

    func testTraceOnlyEvaluatesClocksAndMessagesInDebug() {
        let clockReads = STAAtomicBox(0), messages = STAAtomicBox(0)
        let trace = STAConnectionTrace(now: { clockReads.value += 1; return 0 })
        func message() -> String { messages.value += 1; return "command" }
        trace.note(message())
        #if DEBUG
        XCTAssertEqual(clockReads.value, 2)
        XCTAssertEqual(messages.value, 1)
        XCTAssertTrue(trace.report().hasSuffix("command"))
        #else
        XCTAssertEqual(clockReads.value, 0)
        XCTAssertEqual(messages.value, 0)
        XCTAssertEqual(trace.report(), "")
        #endif
    }

    #if !DEBUG
    func testReleaseDiagnosticsDoNotEvaluateMessageLabelReportOrOutcome() {
        var evaluations = 0
        func expensiveReport() -> String { evaluations += 1; return "unused" }
        let id = STAConnectionDiagnostics.begin()
        STAConnectionDiagnostics.note(id, expensiveReport())
        STAConnectionDiagnostics.attempt(id, label: expensiveReport(), report: expensiveReport())
        STAConnectionDiagnostics.finish(id, expensiveReport())
        CameraRuntimeDiagnostics.record(.transportFailure, expensiveReport())
        CameraRuntimeDiagnostics.record(.review, expensiveReport())
        CameraRuntimeDiagnostics.record(.level, expensiveReport())
        XCTAssertEqual(evaluations, 0)
        XCTAssertEqual(id, 0)
    }
    #endif
    func testNewDiscoveryAndClearRejectStaleCallbacks() {
        let history = STADiagnosticHistory(), old = history.begin()
        history.note(old, "old")
        let current = history.begin()
        history.note(old, "stale"); XCTAssertNil(history.finish(old, "wrong"))
        XCTAssertFalse(history.isCurrent(old)); XCTAssertTrue(history.isCurrent(current))
        history.note(current, "current")
        XCTAssertFalse(history.snapshot().contains("stale"))
        XCTAssertFalse(history.snapshot().contains("wrong"))
        XCTAssertTrue(history.snapshot().contains("current"))
        history.clear(); history.note(current, "late"); XCTAssertNil(history.finish(current, "late"))
        XCTAssertFalse(history.isCurrent(current))
        XCTAssertEqual(history.snapshot(), "暂无 STA 连接记录")
    }
    func testCompletionFreezesElapsedAndCannotBeOverwritten() {
        let time = STAAtomicBox(Int64(0)), history = STADiagnosticHistory(now: { time.value })
        let id = history.begin(); time.value = 100
        let finished = history.finish(id, "connected"), snapshot = history.snapshot()
        XCTAssertEqual(finished, snapshot)
        time.value = 9_000
        history.note(id, "late"); history.finish(id, "cancelled")
        XCTAssertEqual(history.snapshot(), snapshot)
        XCTAssertTrue(snapshot.hasSuffix("+100ms result=connected"))
    }
    func testOversizedAttemptDroppedWholeAndNewestBlocksBounded() {
        let history = STADiagnosticHistory(), id = history.begin()
        history.attempt(id, label: "oversized", report: String(repeating: "界", count: 70_000))
        for i in 0..<170 { history.attempt(id, label: "block-\(i)", report: "START\nEND") }
        let snapshot = history.snapshot()
        XCTAssertFalse(snapshot.contains("oversized"))
        XCTAssertFalse(snapshot.contains("attempt [block-9]"))
        XCTAssertTrue(snapshot.contains("attempt [block-10]\nSTART\nEND"))
        XCTAssertTrue(snapshot.contains("attempt [block-169]\nSTART\nEND"))
        XCTAssertTrue(snapshot.contains("省略较早记录 11 块"))
        XCTAssertEqual(snapshot.components(separatedBy: "START\nEND").count - 1, 160)
    }
    func testCharacterBudgetNeverSplitsAttemptOrSurrogatePair() {
        let history = STADiagnosticHistory(), id = history.begin()
        for i in 0..<10 { history.attempt(id, label: "batch-\(i)", report: "BEGIN" + String(repeating: "😀", count: 5_000) + "END") }
        let snapshot = history.snapshot()
        XCTAssertLessThan(snapshot.utf16.count, 66_000)
        XCTAssertFalse(snapshot.contains("batch-0]"))
        XCTAssertTrue(snapshot.contains("batch-9]"))
        XCTAssertEqual(snapshot.components(separatedBy: "BEGIN").count, snapshot.components(separatedBy: "END").count)
    }
    func test201FHintSurvivesBoundedFailureChainAndMissingNeedsExplicitRetry() {
        let state = STAConnectionError.initializationFailed(0x201F)
        let wrapped = STAPairingConfirmationMissing(cause: STAPairingVerificationFailure(cause: state))
        XCTAssertEqual(STAFailurePolicy.messageResource(wrapped, knownCamera: true), "sta_camera_check_photos")
        XCTAssertTrue(STAFailurePolicy.requiresExplicitRetry(STAConnectionFailure(cause: wrapped, knownCamera: true)))
        XCTAssertEqual(STAFailurePolicy.messageResource(STAPairingConfirmationMissing(), knownCamera: false), "sta_pairing_incomplete")
        XCTAssertFalse(STAFailurePolicy.requiresExplicitRetry(STAConnectionError.cameraRefused))
        XCTAssertEqual(STAFailurePolicy.messageResource(STAConnectionError.cameraRefused, knownCamera: true), "sta_camera_refused_retrying")
        XCTAssertNil(STAFailurePolicy.messageResource(PTPSessionError.timeout, knownCamera: false))
    }
}
