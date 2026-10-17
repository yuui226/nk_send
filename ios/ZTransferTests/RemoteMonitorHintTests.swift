import XCTest
@testable import ZTransfer

@MainActor
final class RemoteMonitorHintTests: XCTestCase {
    private func makeModel() -> RemoteViewModel {
        RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: false))
    }

    func testLatestSourceReplacesEarlierHintWithoutPriorityOrResurfacing() async throws {
        let model = makeModel()
        defer { model.stop() }
        model.showMonitorHint("focus", durationNanoseconds: 100_000_000)
        model.showMonitorHint("recording", source: .localRecording, durationNanoseconds: 300_000_000)
        XCTAssertNil(model.interactionHint)
        XCTAssertEqual(model.localRecordingHint, "recording")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.localRecordingHint, "recording", "The cancelled first deadline must not hide its successor")
        model.showMonitorHint("LUT", source: .lut, durationNanoseconds: 100_000_000)
        XCTAssertNil(model.localRecordingHint)
        XCTAssertEqual(model.monitorHint.text, "LUT")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(model.monitorHint.visible)
        XCTAssertEqual(model.monitorHint.text, "LUT", "Retain the outgoing content for the fade")
        XCTAssertNil(model.interactionHint)
        XCTAssertNil(model.localRecordingHint)
    }

    func testIdenticalMessageRestartsDeadlineAndStopRejectsLateHints() async throws {
        let model = makeModel()
        model.showMonitorHint("same", durationNanoseconds: 200_000_000)
        let first = model.monitorHint.nonce
        try await Task.sleep(for: .milliseconds(120))
        model.showMonitorHint("same", durationNanoseconds: 200_000_000)
        XCTAssertEqual(model.monitorHint.nonce, first + 1)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(model.monitorHint.visible)
        model.stop()
        XCTAssertFalse(model.monitorHint.visible)
        let stopped = model.monitorHint
        model.showMonitorHint("late")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(model.monitorHint, stopped)
    }

    func testRecordingErrorTextAndDurationsMatchAndroidWithoutDiagnosticPayload() {
        let result = RemoteMovieStartResult(responseCode: 0xA004, prohibitCondition: 1 << 14)
        let start = RemoteRecordingHint.startFailed(result)
        XCTAssertEqual(start.message, AppLocalized.resource("remote_rec_start_failed"))
        XCTAssertEqual(start.durationNanoseconds, 12_000_000_000)
        XCTAssertEqual(start.diagnostic, result.diagnosticSummary)
        let stop = RemoteRecordingHint.stopFailed(responseCode: 0x2019)
        XCTAssertEqual(stop.message, AppLocalized.resource("remote_rec_stop_failed"))
        XCTAssertEqual(stop.durationNanoseconds, 6_000_000_000)
        XCTAssertEqual(stop.diagnostic, "stop=0x2019")
    }

    func testLUTAcceptedNoticesReachSameHostAndStaleFailureCannotReplaceIt() {
        let model = makeModel()
        defer { model.stop() }
        let name = "RemoteMonitorHintTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let lut = RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults))
        lut.onNotice = { model.showMonitorHint(AppLocalized.resource($0), source: .lut) }
        lut.environment(movie: false, available: true, visible: true)
        let file = RemoteLUTFile(identifier: "test", name: "test.cube", relativePath: "test.cube", size: nil)
        let stale = lut.beginSelection(file)!
        let current = lut.beginSelection(file)!
        model.showRotationLockHint(true)
        let before = model.monitorHint
        lut.failed(generation: stale, reason: "read")
        XCTAssertEqual(model.monitorHint, before)
        lut.failed(generation: current, reason: "read")
        XCTAssertEqual(model.monitorHint.text, AppLocalized.resource("lut_read_failed"))
        XCTAssertNil(model.interactionHint)
        let nonce = model.monitorHint.nonce
        lut.scanFailed(.denied)
        lut.scanFailed(.denied)
        XCTAssertEqual(model.monitorHint.nonce, nonce + 2)
        XCTAssertEqual(model.monitorHint.text, AppLocalized.resource("lut_folder_denied"))
    }
}
