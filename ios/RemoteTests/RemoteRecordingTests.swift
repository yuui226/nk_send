import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferRemote
#else
@testable import ZTransfer
#endif

@MainActor
final class RemoteRecordingTests: XCTestCase {
    func testPendingStartAndFailureDoNotDisplayRECOrFailLiveView() {
        var state = RemoteState().applying(.frameReceived(fps: 30))
        state.movieMode = true
        state = state.applying(.captureRequested)
        XCTAssertEqual(state.capture, .idle)
        state = state.applying(.recordingFailed(.startFailed(nil)))
        XCTAssertEqual(state.capture, .idle)
        XCTAssertEqual(state.session, .ready)
        XCTAssertEqual(state.recordingHint?.message, "无法开始录像")
        XCTAssertNil(state.errorMessage)
    }

    func testFailedStopPreservesRECAndHintSurvivesNewFrames() {
        var state = RemoteState().applying(.frameReceived(fps: 30))
        state = state.applying(.recordingStarted)
        let hint = RemoteRecordingHint.stopFailed(responseCode: 0x2019)
        state = state.applying(.recordingFailed(hint))
        state = state.applying(.frameReceived(fps: 29))
        XCTAssertEqual(state.capture, .recording)
        XCTAssertEqual(state.recordingHint, hint)
        state = state.applying(.recordingStopped)
        XCTAssertEqual(state.capture, .idle)
    }

    func testCameraAlreadyRecordingBitIsAdoptedButOtherProhibitsAreNot() {
        XCTAssertTrue(RemoteMovieStartResult(responseCode: 0x2001, prohibitCondition: nil).indicatesRecording)
        XCTAssertTrue(RemoteMovieStartResult(responseCode: 0xA004, prohibitCondition: 1 << 10).indicatesRecording)
        for bit in [0, 1, 2, 3, 9, 11, 12, 13, 14] {
            XCTAssertFalse(RemoteMovieStartResult(responseCode: 0xA004,
                                                  prohibitCondition: 1 << bit).indicatesRecording)
        }
        XCTAssertFalse(RemoteMovieStartResult(responseCode: 0xA004, prohibitCondition: nil).indicatesRecording)
    }

    func testFailureDiagnosticsAndDurationsMatchAndroid() {
        let result = RemoteMovieStartResult(responseCode: 0xA004, prohibitCondition: (1 << 14) | (1 << 18))
        let start = RemoteRecordingHint.startFailed(result)
        XCTAssertEqual(start.message, "无法开始录像\nresult=0xA004 startOp=0xA004 prohibit=0x00044000")
        XCTAssertEqual(start.durationNanoseconds, 12_000_000_000)
        let stop = RemoteRecordingHint.stopFailed(responseCode: 0x2019)
        XCTAssertEqual(stop.message, "无法停止录像，请检查相机后重试\nstop=0x2019")
        XCTAssertEqual(stop.durationNanoseconds, 6_000_000_000)
        XCTAssertEqual(RemoteRecordingHint.stopFailed().message,
                       "无法停止录像，请检查相机后重试\nstop=0xFFFF")
    }

    func testLeavingInvalidatesLateCommandWithoutReleasingNextCommand() throws {
        var gate = RemoteRecordingOperationGate()
        let old = try XCTUnwrap(gate.begin(.start))
        XCTAssertNil(gate.begin(.start))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(old))
        let current = try XCTUnwrap(gate.begin(.stop))
        XCTAssertFalse(gate.complete(old))
        XCTAssertTrue(gate.isBusy)
        XCTAssertTrue(gate.accepts(current))
        XCTAssertTrue(gate.complete(current))
        XCTAssertFalse(gate.isBusy)
    }

    func testBusyRetryStopsAtSuccessAndDoesNotRetryOtherResponses() async throws {
        let busyThenReady = MovieCommandScript([0x2019, 0x2019, 0x2001])
        let response = try await RemoteMovieCommandRetry.execute(
            command: { await busyThenReady.send() }, pause: { await busyThenReady.pause() })
        let counts = await busyThenReady.counts
        XCTAssertEqual(response, 0x2001)
        XCTAssertEqual(counts.commands, 3)
        XCTAssertEqual(counts.pauses, 2)

        let unsupported = MovieCommandScript([0x2005, 0x2001])
        let unsupportedResponse = try await RemoteMovieCommandRetry.execute(
            command: { await unsupported.send() }, pause: { await unsupported.pause() })
        let unsupportedCounts = await unsupported.counts
        XCTAssertEqual(unsupportedResponse, 0x2005)
        XCTAssertEqual(unsupportedCounts.commands, 1)
        XCTAssertEqual(unsupportedCounts.pauses, 0)
    }

    func testPersistentBusyHasExactlyFiveRetries() async throws {
        let script = MovieCommandScript(Array(repeating: 0x2019, count: 7))
        let response = try await RemoteMovieCommandRetry.execute(
            command: { await script.send() }, pause: { await script.pause() })
        let counts = await script.counts
        XCTAssertEqual(response, 0x2019)
        XCTAssertEqual(counts.commands, 6)
        XCTAssertEqual(counts.pauses, 5)
    }

    func testCancellationDuringBackoffSendsNoFurtherCommand() async throws {
        let script = MovieCommandScript([0x2019, 0x2001])
        do {
            _ = try await RemoteMovieCommandRetry.execute(command: { await script.send() },
                                                          pause: { throw CancellationError() })
            XCTFail("Cancellation must end the recording request")
        } catch is CancellationError {
        }
        let counts = await script.counts
        XCTAssertEqual(counts.commands, 1)
    }
}

private actor MovieCommandScript {
    private let responses: [UInt16]
    private var commands = 0
    private var pauses = 0
    init(_ responses: [UInt16]) { self.responses = responses }
    var counts: (commands: Int, pauses: Int) { (commands, pauses) }
    func send() -> UInt16 {
        defer { commands += 1 }
        return responses[min(commands, responses.count - 1)]
    }
    func pause() { pauses += 1 }
}
