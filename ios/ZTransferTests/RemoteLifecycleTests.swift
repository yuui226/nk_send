import XCTest
import Combine
import SwiftUI
import UIKit
import ImageIO
@preconcurrency import AVFoundation
@testable import ZTransfer

@MainActor
final class RemoteDiagnosticPerformanceTests: XCTestCase {
    func testInactiveAndRepeatedReportsDoNotPublishMonitorChanges() async {
        let model = RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: false))
        var pageUpdates = 0, reportUpdates = 0
        let page = model.objectWillChange.sink { pageUpdates += 1 }
        let reports = model.focusDiagnosticOutput.objectWillChange.sink { reportUpdates += 1 }
        defer { page.cancel(); reports.cancel() }
        for _ in 0..<120 { model.displayFocusDiagnostic("ignored"); model.markFocusDiagnostic("ignored"); model.stopFocusDiagnostic() }
        XCTAssertEqual(pageUpdates, 0); XCTAssertEqual(reportUpdates, 0)
        model.startFocusDiagnostic(description: "host")
        XCTAssertTrue(model.focusDiagnosticRunning)
        let runningUpdates = pageUpdates
        model.displayFocusDiagnostic("drawn age=1ms")
        let first = reportUpdates
        for _ in 0..<120 { model.displayFocusDiagnostic("drawn age=1ms") }
        XCTAssertEqual(reportUpdates, first)
        for index in 0..<120 { model.displayFocusDiagnostic("drawn age=\(index + 2)ms") }
        XCTAssertEqual(reportUpdates, first + 120, "Every different visible diagnostic state is retained")
        XCTAssertEqual(pageUpdates, runningUpdates, "Only the diagnostic leaf observes changing reports")
        model.markFocusDiagnostic("mark")
        XCTAssertTrue(model.focusDiagnosticReport.contains("UI=drawn age=121ms"))
        model.stopFocusDiagnostic()
        let stopped = model.focusDiagnosticReport
        let finalPage = pageUpdates, finalReports = reportUpdates
        for _ in 0..<120 { model.displayFocusDiagnostic("ignored"); model.markFocusDiagnostic("ignored"); model.stopFocusDiagnostic() }
        XCTAssertEqual(model.focusDiagnosticReport, stopped)
        XCTAssertEqual(pageUpdates, finalPage); XCTAssertEqual(reportUpdates, finalReports)
        await model.stopAndWait()
    }

    func testCachedReportInvalidatesOnlyWhenVisibleContentChanges() {
        let log = RemoteLiveViewFocusDiagnostic()
        XCTAssertEqual(log.report(), "")
        for _ in 0..<120 { _ = log.report() }
        XCTAssertEqual(log.reportBuildCount, 1)
        log.start(nowMs: 0, description: "Z30")
        _ = log.report()
        let bytes = Data(repeating: 0, count: 515)
        func sample(_ time: Double) {
            log.sample(packet: RemoteLiveViewPacket(bytes: bytes, jpegOffset: 512,
                operation: PTPConstants.getLiveViewImageEx, receivedAtUptime: time), metadata: nil, context: "photo")
        }
        sample(0)
        let baseline = log.report(), built = log.reportBuildCount
        for index in 1...120 { sample(Double(index) * 0.2); XCTAssertEqual(log.report(), baseline) }
        XCTAssertEqual(log.reportBuildCount, built)
        log.display("drawn boxPx=20x30")
        let display = log.report(), displayBuilds = log.reportBuildCount
        for _ in 0..<120 { log.display("drawn boxPx=20x30"); XCTAssertEqual(log.report(), display) }
        XCTAssertEqual(log.reportBuildCount, displayBuilds)
        log.display("drawn boxPx=21x30")
        XCTAssertNotEqual(log.report(), display)
        XCTAssertEqual(log.report().components(separatedBy: "\n").filter { $0.hasPrefix("UI ") }.count, 1)
        log.mark(nowMs: 24_500, text: "step")
        XCTAssertTrue(log.report().contains("mark +24500 step"))
        sample(60)
        XCTAssertFalse(log.running)
        XCTAssertTrue(log.report().contains("end=60s samples=121 changes=1"))
        let stopped = log.report(), stoppedBuilds = log.reportBuildCount
        for _ in 0..<120 { sample(61); log.display("ignored"); log.mark(nowMs: 61_000, text: "ignored"); log.stop(); XCTAssertEqual(log.report(), stopped) }
        XCTAssertEqual(log.reportBuildCount, stoppedBuilds)
        log.start(nowMs: 70_000, description: "new")
        XCTAssertFalse(log.report().contains("Z30"))
    }

    func testLargeJPEGDoesNotChangeHeaderDiagnosticOrBoundsHandling() {
        var header = Data(repeating: 0, count: 1024)
        header[44] = 96; header[45] = 95
        for (offset, value) in zip([808, 810, 812, 814], [30, 20, 100, 80]) {
            header[offset] = 0; header[offset + 1] = UInt8(value)
        }
        var full = header
        full.append(Data(repeating: 0xC7, count: 8 * 1024 * 1024))
        func report(_ bytes: Data, offset: Int) -> String {
            let log = RemoteLiveViewFocusDiagnostic()
            log.start(nowMs: 0, description: "bounded")
            log.sample(packet: RemoteLiveViewPacket(bytes: bytes, jpegOffset: offset,
                operation: PTPConstants.getLiveViewImageEx, receivedAtUptime: 0), metadata: nil, context: "photo")
            return log.report()
        }
        XCTAssertEqual(report(header, offset: 1024), report(full, offset: 1024))
        XCTAssertTrue(report(full, offset: 1024).contains("rawWHXY=30,20,100,80"))
        XCTAssertTrue(report(Data([1]), offset: 0).contains("unsupported-header"))
        XCTAssertTrue(report(Data(), offset: -1).contains("rawWHXY=none"))
    }

    func testHostedDiagnosticLeafAndPersistenceUpdateWithoutRefreshingMonitor() async throws {
        let suite = "DiagnosticLeaf.\(UUID())", counts = Counts()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: false))
        let host = UIHostingController(rootView: Harness(model: model, defaults: defaults, counts: counts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(60))
        model.startFocusDiagnostic(description: "host")
        try await Task.sleep(for: .milliseconds(50))
        let initial = counts.parent
        for index in 0..<30 {
            model.displayFocusDiagnostic("drawn age=\(index)ms")
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counts.parent, initial)
        XCTAssertTrue(counts.displayed.contains("UI=drawn age=29ms"))
        XCTAssertEqual(defaults.string(forKey: "focus_report_v1"), model.focusDiagnosticReport)
        let writes = counts.writes
        for _ in 0..<120 { model.displayFocusDiagnostic("drawn age=29ms") }
        XCTAssertEqual(counts.writes, writes)
        model.stopFocusDiagnostic()
        await model.stopAndWait()
    }

    func testReportProjectionReusesRowsAndPreservesIndependentCopyScopes() {
        let cache = RemoteDeveloperReportCache()
        let value = cache.resolve(log: ["video", "", "control"], recording: "record\nfailed",
            focus: "focus\n", pictureControl: "np3")
        XCTAssertEqual(value.lines, ["video", "", "control", "record", "failed", "focus", "", "np3"])
        XCTAssertEqual(value.copyText, "video\ncontrol\nrecord\nfailed\nfocus\n\nnp3")
        for _ in 0..<120 {
            XCTAssertTrue(cache.resolve(log: ["video", "", "control"], recording: "record\nfailed",
                focus: "focus\n", pictureControl: "np3") === value)
        }
        let changed = cache.resolve(log: ["video", "", "control"], recording: "record\nfailed",
            focus: "new", pictureControl: "np3")
        XCTAssertFalse(changed === value)
        XCTAssertTrue(changed.copyText.hasSuffix("new\nnp3"))
        XCTAssertEqual(value.lines[5], "focus", "Previous row snapshot remains immutable")
    }

    func testRatingDiagnosticBudgetAndSnapshotCachePreserveExactUnicodeOutput() {
        PhotoRatingDiagnostics.setEnabled(true)
        PhotoRatingDiagnostics.clear()
        defer { PhotoRatingDiagnostics.setEnabled(false) }
        var expected: [String] = []
        for index in 0..<240 {
            let raw = "\(index) \t " + String(repeating: index.isMultiple(of: 2) ? "中🙂e\u{301}" : "abc ", count: 110) + "\n end"
            let normalized = String(raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(260))
            expected.append(normalized)
            while expected.count > 48 || expected.reduce(0, { $0 + $1.count + 1 }) > 8_000 { expected.removeFirst() }
            PhotoRatingDiagnostics.note(raw)
            XCTAssertEqual(PhotoRatingDiagnostics.snapshot(), "ZTransfer 评级筛选诊断\n" + expected.joined(separator: "\n"))
        }
        let report = PhotoRatingDiagnostics.snapshot()
        for _ in 0..<120 { XCTAssertEqual(PhotoRatingDiagnostics.snapshot(), report) }
        let previous = PhotoRatingDiagnostics.beginProbe(keepExisting: true)
        PhotoRatingDiagnostics.detail("probe")
        PhotoRatingDiagnostics.restore(previous, preserveEntries: true)
        XCTAssertTrue(PhotoRatingDiagnostics.snapshot().hasSuffix("probe"))
        PhotoRatingDiagnostics.clear()
        XCTAssertEqual(PhotoRatingDiagnostics.snapshot(), "评级筛选：暂无诊断记录")
        PhotoRatingDiagnostics.note("after clear")
        XCTAssertEqual(PhotoRatingDiagnostics.snapshot(), "ZTransfer 评级筛选诊断\nafter clear")
    }

    func testLogListPositionsLastRowReusesCellsAndOnlyFollowsNearTail() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = LogState(), probe = LogProbe()
        let host = UIHostingController(rootView: LogHarness(state: state, probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        let table = try XCTUnwrap(findTable(host.view))
        XCTAssertTrue(table.indexPathsForVisibleRows?.contains(IndexPath(row: 2999, section: 0)) == true)
        XCTAssertLessThan(probe.rows.count, 180)
        table.scrollToRow(at: IndexPath(row: 1_000, section: 0), at: .top, animated: false)
        try await Task.sleep(for: .milliseconds(80))
        let anchor = try XCTUnwrap(table.indexPathsForVisibleRows?.min())
        let y = table.rectForRow(at: anchor).minY - table.contentOffset.y
        state.lines.append("new diagnostic")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(table.indexPathsForVisibleRows?.min(), anchor)
        XCTAssertEqual(table.rectForRow(at: anchor).minY - table.contentOffset.y, y, accuracy: 1)
        table.scrollToRow(at: IndexPath(row: 3_000, section: 0), at: .bottom, animated: false)
        try await Task.sleep(for: .milliseconds(80))
        state.lines.append("next diagnostic")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(table.indexPathsForVisibleRows?.contains(IndexPath(row: 3001, section: 0)) == true)
        XCTAssertLessThan(probe.rows.count, 220, "Distant log positions must not instantiate the full report")
        print("DIAGNOSTIC_ROWS built=\(probe.rows.count) total=\(state.lines.count)")
    }

    @MainActor private final class LogState: ObservableObject {
        @Published var lines = (0..<3_000).map { "diagnostic \($0)" }
    }
    @MainActor private final class LogProbe { var rows = Set<Int>() }
    private struct LogHarness: View {
        @ObservedObject var state: LogState
        let probe: LogProbe
        var body: some View {
            PhotoEffectChooserList(items: Array(state.lines.indices), id: \.self,
                initialID: state.lines.indices.last, followTailChange: state.lines.last) { index in
                let _ = { probe.rows.insert(index) }()
                Text(state.lines[index]).font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, index == 0 ? 6 : 0)
                    .padding(.bottom, index == state.lines.count - 1 ? 6 : 0)
            }.frame(height: 170)
        }
    }
    private func findTable(_ view: UIView) -> UITableView? {
        (view as? UITableView) ?? view.subviews.lazy.compactMap { self.findTable($0) }.first
    }

    @MainActor private final class Counts { var parent = 0; var writes = 0; var displayed = "" }
    private struct Harness: View {
        @ObservedObject var model: RemoteViewModel
        let defaults: UserDefaults
        let counts: Counts
        var body: some View {
            counts.parent += 1
            return RemoteDiagnosticReportReader(output: model.focusDiagnosticOutput) { text in
                let _ = { counts.displayed = text }()
                Text(text).font(.system(size: 10, design: .monospaced))
            }.onReceive(model.focusDiagnosticOutput.$text.dropFirst()) { text in
                guard !text.isEmpty else { return }
                counts.writes += 1
                defaults.set(text, forKey: "focus_report_v1")
            }
        }
    }
}

@MainActor
final class RemoteLifecycleTests: XCTestCase {
    func testReviewPausesFramesAndHiddenEventPollingButKeepsLinkAlive() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.liveViewStable }
        model.setPhotoReviewActive(true)
        model.reviewFrames.pause()
        try await model.reviewFrames.awaitIdle()
        // Allow a previously admitted event iteration to finish.
        try await Task.sleep(for: .milliseconds(100))
        let before = await camera.log
        try await waitFor(timeout: 2) { await camera.log.contains("keepalive") }
        let paused = await camera.log
        XCTAssertEqual(paused.filter { $0 == "frame" }.count, before.filter { $0 == "frame" }.count)
        XCTAssertEqual(paused.filter { $0 == "events" }.count, before.filter { $0 == "events" }.count)
        XCTAssertFalse(model.reviewAllowed)
        model.setPhotoReviewActive(false)
        model.reviewFrames.resume()
        try await waitFor { await camera.log.filter { $0 == "frame" }.count > paused.filter { $0 == "frame" }.count }
        await model.stopAndWait()
        let finished = await camera.log
        XCTAssertFalse(finished.contains("cancelled-frame"))
    }

    /// Each test owns its natural-day ledger. Sharing .standard makes unrelated
    /// camera tests exhaust the 180s trial and fail later in the same simulator.
    private func makeModel(camera: any RemoteCameraControlling,
                           onTransportLost: (() -> Void)? = nil,
                           haptics: ZTransferHaptics = .shared,
                           entitlements: PremiumEntitlementStore = .shared,
                           freeUsage: FreeUsageStore? = nil) -> RemoteViewModel {
        let name = "RemoteLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let model = RemoteViewModel(camera: camera, onTransportLost: onTransportLost,
            haptics: haptics, entitlements: entitlements, freeUsage: freeUsage ?? FreeUsageStore(defaults: defaults))
        addTeardownBlock {
            await model.stopAndWait()
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return model
    }

    func testFocusHandoffSharesVisibilityAndRejectsObsoleteCompletion() {
        var handoff = RemoteFocusHandoff()
        let locked = RemoteFocusHandoff.Input(nonce: 1, phase: .locked, eligible: true, hasCameraFrames: true)
        handoff.update(locked)
        XCTAssertTrue(handoff.visibility(for: locked).tap)
        XCTAssertFalse(handoff.visibility(for: locked).camera)
        handoff.complete(locked)
        XCTAssertFalse(handoff.visibility(for: locked).tap)
        XCTAssertTrue(handoff.visibility(for: locked).camera)
        let gap = RemoteFocusHandoff.Input(nonce: 1, phase: .locked, eligible: true, hasCameraFrames: false)
        handoff.update(gap)
        XCTAssertFalse(handoff.visibility(for: gap).tap, "Packet gaps must not revive the old tap")
        XCTAssertFalse(handoff.visibility(for: gap).camera)
        let next = RemoteFocusHandoff.Input(nonce: 2, phase: .focusing, eligible: true, hasCameraFrames: true)
        XCTAssertTrue(handoff.visibility(for: next).tap, "New requests reset synchronously before task execution")
        handoff.update(next)
        handoff.complete(locked)
        XCTAssertTrue(handoff.visibility(for: next).tap)
        XCTAssertFalse(handoff.visibility(for: next).camera)
        let early = RemoteFocusHandoff.Input(nonce: 2, phase: .locked, eligible: false, hasCameraFrames: true)
        handoff.update(early)
        handoff.complete(early)
        XCTAssertTrue(handoff.visibility(for: early).tap)
        XCTAssertFalse(handoff.visibility(for: early).camera)
        let idle = RemoteFocusHandoff.Input(nonce: 2, phase: .idle, eligible: false, hasCameraFrames: false)
        handoff.update(idle)
        XCTAssertFalse(handoff.visibility(for: idle).tap)
        XCTAssertFalse(handoff.visibility(for: idle).camera)
    }

    func testConfirmedFocusFallbackExcludesTrackingAndExpires() {
        let point = RemoteFocusPoint(x: 0.2, y: 0.8)
        let ordinary = RemoteConfirmedFocusMarker(fallbackPoint: point, confirmedAtUptime: 100,
                                                  subjectTracking: false, nonce: 1)
        let tracking = RemoteConfirmedFocusMarker(fallbackPoint: point, confirmedAtUptime: 100,
                                                  subjectTracking: true, nonce: 2)
        for age in [0.0, 0.12, 0.5, 2.999] {
            XCTAssertEqual(ordinary.fallbackPoint(at: 100 + age), point)
            XCTAssertNil(tracking.fallbackPoint(at: 100 + age))
        }
        XCTAssertNil(ordinary.fallbackPoint(at: 103))
        XCTAssertNil(ordinary.fallbackPoint(at: 104))
    }

    func testUSBFirstImageDoesNotReleasePollingBeforeEightSuccessfulFrames() async throws {
        let camera = RemoteLifecycleCamera(isUSB: true)
        await camera.limitSuccessfulFrames(to: 1)
        await camera.setProperty(.init(property: .nikonAutoISO, writable: true, current: 1, values: [0, 1]))
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        XCTAssertEqual(model.state.session, .ready)
        XCTAssertFalse(model.state.liveViewStable)
        // Keep returning Busy across a complete polling interval. A decoded
        // first image must not release events or periodic battery refresh.
        try await Task.sleep(for: .milliseconds(750))
        let first = await camera.log
        XCTAssertTrue(model.autoISOEnabled)
        XCTAssertFalse(first.contains("refresh:nikonISOControlSensitivity"))
        XCTAssertFalse(first.contains("events"))
        XCTAssertFalse(first.contains("refresh:batteryLevel"))
        await camera.limitSuccessfulFrames(to: 7)
        try await waitFor { await camera.successfulFrameCount == 7 }
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertFalse(model.state.liveViewStable)
        let seventh = await camera.log
        XCTAssertFalse(seventh.contains("refresh:nikonISOControlSensitivity"))
        XCTAssertFalse(seventh.contains("events"))
        await camera.limitSuccessfulFrames(to: 8)
        try await waitFor { model.state.liveViewStable }
        try await waitFor { await camera.log.contains("refresh:nikonISOControlSensitivity") }
        try await waitFor { await camera.log.contains("events") }
        await model.stopAndWait()
        XCTAssertFalse(model.state.liveViewStable)
    }

    func testFocusFrameExpiresWithoutNewFramesAndRecoversOnArrival() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        XCTAssertFalse(model.focusFrameExpired)
        try await waitFor(timeout: 1) { model.focusFrameExpired }
        XCTAssertNotNil(model.frameImage)
        await camera.limitSuccessfulFrames(to: 2)
        try await waitFor { !model.focusFrameExpired }
        await model.stopAndWait()
    }

    func testFocusPropertyEventsInvalidateRetainedImageBeforeNextFrame() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        for property: UInt32 in [0x501C, 0xD05D, 0xD1F8] {
            let previous = model.focusValidAfterUptime
            await camera.queueEvents([.init(code: 0x4006, handle: property)])
            try await waitFor { model.focusValidAfterUptime > previous }
            XCTAssertLessThanOrEqual(model.frameReceivedAtUptime, model.focusValidAfterUptime)
        }
        await camera.limitSuccessfulFrames(to: 2)
        try await waitFor { model.frameReceivedAtUptime > model.focusValidAfterUptime }
        XCTAssertFalse(model.focusFrameExpired)
    }

    func testEquivalentFocusLabelAcrossPropertiesPreservesCutoff() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: true,
                                       current: 0, values: [0, 1]))
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil && model.focusModeDescriptor?.property == .stillFocusMode }
        let cutoff = model.focusValidAfterUptime
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: true,
                                       current: 0x8010, values: [0x8010, 0x8011]))
        await camera.queueEvents([.init(code: 0x4006, handle: UInt32(RemoteProperty.focusMode.rawValue))])
        try await waitFor { model.focusModeDescriptor?.property == .focusMode }
        XCTAssertEqual(model.focusValidAfterUptime, cutoff, "Both encodings mean AF-S")
    }

    func testSameRawFocusPropertyTransitionInvalidatesRetainedFrame() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: true,
                                       current: 1, values: [0, 1]))
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil && model.focusModeDescriptor?.property == .stillFocusMode }
        let image = model.frameImage
        let cutoff = model.focusValidAfterUptime
        XCTAssertFalse(model.state.focus.manual)
        // Raw 1 means AF-C for D061, but MF for standard 500A. This event
        // is not one of the three area properties that invalidate directly.
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: true,
                                       current: 1, values: [1, 2]))
        await camera.queueEvents([.init(code: 0x4006, handle: UInt32(RemoteProperty.focusMode.rawValue))])
        try await waitFor { model.focusModeDescriptor?.property == .focusMode }
        XCTAssertEqual(model.focusModeDescriptor?.current, 1)
        XCTAssertTrue(model.state.focus.manual)
        XCTAssertGreaterThan(model.focusValidAfterUptime, cutoff)
        XCTAssertLessThanOrEqual(model.frameReceivedAtUptime, model.focusValidAfterUptime)
        XCTAssertTrue(model.frameImage === image)
        await camera.limitSuccessfulFrames(to: 2)
        try await waitFor { model.frameReceivedAtUptime > model.focusValidAfterUptime }
        XCTAssertFalse(model.focusFrameExpired)
    }

    func testSuccessfulToolWriteInvalidatesFocusExceptWhiteBalance() async throws {
        for tool: RemoteCameraTool in [.whiteBalance, .focusArea] {
            let camera = RemoteLifecycleCamera()
            let property: RemoteProperty = tool == .whiteBalance ? .whiteBalance : .focusArea
            let values: [UInt64] = tool == .whiteBalance ? [2, 4] : [0x8010, 0x8011]
            await camera.setProperty(.init(property: property, dataType: 4, writable: true,
                                           current: values[0], values: values))
            await camera.acceptWrites(property)
            await camera.limitSuccessfulFrames(to: 1)
            let model = makeModel(camera: camera)
            model.start()
            try await waitFor { model.frameImage != nil }
            let image = model.frameImage
            let cutoff = model.focusValidAfterUptime
            model.openCameraTool(tool)
            let panel = try XCTUnwrap(model.cameraToolPanel)
            try await waitFor { !panel.loading }
            panel.select(values[1])
            try await waitFor { !panel.busy }
            XCTAssertEqual(panel.descriptor?.current, values[1])
            XCTAssertTrue(panel.closeRequested)
            XCTAssertTrue(model.frameImage === image)
            if tool == .whiteBalance {
                XCTAssertEqual(model.focusValidAfterUptime, cutoff)
            } else {
                XCTAssertGreaterThan(model.focusValidAfterUptime, cutoff)
                XCTAssertLessThanOrEqual(model.frameReceivedAtUptime, model.focusValidAfterUptime)
            }
            await model.stopAndWait()
        }
    }

    func testMeterRejectsLateReadAcrossReopenSlowResponseAndNewBusyState() async throws {
        for scenario in 0..<3 {
            let camera = RemoteLifecycleCamera()
            await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1, writable: false, current: 12, values: []))
            let barrier = FramePublicationBarrier()
            await camera.holdNextMeterRefresh { await barrier.waitOnce() }
            let model = makeModel(camera: camera)
            model.setExposureMeterVisible(true)
            model.start()
            try await waitFor { await barrier.reached }
            XCTAssertNil(model.exposureMeterEV)
            if scenario == 0 {
                model.setExposureMeterVisible(false)
                await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1, writable: false, current: 24, values: []))
                model.setExposureMeterVisible(true)
                try await waitFor { model.exposureMeterEV == 2 }
            } else if scenario == 1 {
                try await Task.sleep(for: .milliseconds(1600))
            } else {
                model.beginHalfPress()
                XCTAssertTrue(model.halfPressVisualActive)
            }
            await barrier.release()
            try await Task.sleep(for: .milliseconds(100))
            if scenario == 0 {
                XCTAssertEqual(model.exposureMeterEV, 2, "Old result and cleanup must not overwrite the new generation")
            } else {
                XCTAssertNil(model.exposureMeterEV, "Late or newly busy result must not publish")
            }
            if scenario == 2 { model.endHalfPress(fire: false) }
            if scenario != 0 { try await waitFor { model.exposureMeterEV == 1 } }
            await model.stopAndWait()
        }
    }

    func testMeterPreservesReadingDuringHeldFocusBeyondExpiryWindow() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1, writable: false, current: 12, values: []))
        let model = makeModel(camera: camera)
        model.setExposureMeterVisible(true)
        model.start()
        try await waitFor { model.exposureMeterEV == 1 }
        model.beginHalfPress()
        try await waitFor { model.state.focus.phase == .locked }
        let baseline = await camera.log.filter { $0 == "refresh:nikonLightMeter" }.count
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(model.exposureMeterEV, 1)
        let after = await camera.log.filter { $0 == "refresh:nikonLightMeter" }.count
        XCTAssertEqual(after, baseline)
        model.endHalfPress(fire: false)
    }

    func testMeterExpiresWhileReadIsSuspendedAndCloseRejectsLateResult() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1, writable: false, current: 12, values: []))
        let model = makeModel(camera: camera)
        model.setExposureMeterVisible(true)
        model.start()
        try await waitFor { model.exposureMeterEV == 1 }
        let barrier = FramePublicationBarrier()
        await camera.holdNextMeterRefresh { await barrier.waitOnce() }
        try await waitFor { await barrier.reached }
        try await waitFor(timeout: 4) { model.exposureMeterEV == nil }
        model.setExposureMeterVisible(false)
        await barrier.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.exposureMeterEV)
    }

    func testMeterClearsAfterThreeFailedReads() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1, writable: false, current: 12, values: []))
        let model = makeModel(camera: camera)
        model.setExposureMeterVisible(true)
        model.start()
        try await waitFor { model.exposureMeterEV == 1 }
        let baseline = await camera.log.filter { $0 == "refresh:nikonLightMeter" }.count
        await camera.failRefresh(.nikonLightMeter)
        try await waitFor { model.exposureMeterEV == nil }
        let completed = await camera.log.filter { $0 == "refresh:nikonLightMeter" }.count
        XCTAssertEqual(completed - baseline, 3)
    }

    func testMeterReprobesAfterModeChangeAndHDSession() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1, writable: false, current: 12, values: []))
        let model = makeModel(camera: camera)
        model.setExposureMeterVisible(true)
        model.start()
        try await waitFor { model.exposureMeterEV == 1 }
        await camera.changeMovieMode(true)
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.liveViewSelector.rawValue)])
        try await waitFor { model.movieMode && model.exposureMeterEV == 1 }
        try await waitFor { await camera.log.filter { $0 == "property:nikonLightMeter" }.count == 2 }
        model.setHDLiveView(true)
        try await waitFor { await camera.log.filter { $0 == "start" }.count == 2 }
        try await waitFor { model.exposureMeterEV == 1 }
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "property:nikonLightMeter" }.count, 3)
    }

    func testMeterDefersProbeDuringExposureAndAutoISOWrites() async throws {
        for autoISO in [false, true] {
            let camera = RemoteLifecycleCamera()
            let property: RemoteProperty = autoISO ? .nikonAutoISO : .iso
            await camera.setProperty(.init(property: property, writable: true,
                current: autoISO ? 0 : 100, values: autoISO ? [0, 1] : [100, 200]))
            await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1,
                writable: false, current: 12, values: []))
            await camera.acceptWrites(property)
            await camera.delayWrites(milliseconds: 650)
            let model = makeModel(camera: camera)
            model.start()
            try await waitFor { model.state.liveViewStable }
            if autoISO { model.setAutoISO(true) } else { model.setExposure(.iso, value: 200) }
            try await waitFor { await camera.log.contains { $0.hasPrefix("write:\(property):") } }
            model.setExposureMeterVisible(true)
            try await Task.sleep(for: .milliseconds(300))
            let blocked = await camera.log
            XCTAssertFalse(blocked.contains("property:nikonLightMeter"))
            try await waitFor { model.exposureMeterEV == 1 }
            await model.stopAndWait()
        }
    }

    func testMeterWaitsForUSBStabilityAndReprobesAfterForeground() async throws {
        let camera = RemoteLifecycleCamera(isUSB: true)
        await camera.limitSuccessfulFrames(to: 1)
        await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1,
            writable: false, current: 12, values: []))
        let model = makeModel(camera: camera)
        model.setExposureMeterVisible(true)
        model.start()
        try await waitFor { model.frameImage != nil }
        try await Task.sleep(for: .milliseconds(300))
        let before = await camera.log
        XCTAssertFalse(before.contains("property:nikonLightMeter"))
        await camera.limitSuccessfulFrames(to: 8)
        try await waitFor { model.exposureMeterEV == 1 }
        model.setExposureMeterForeground(false)
        XCTAssertNil(model.exposureMeterEV)
        model.setExposureMeterForeground(true)
        try await waitFor { model.exposureMeterEV == 1 }
        let after = await camera.log
        XCTAssertEqual(after.filter { $0 == "property:nikonLightMeter" }.count, 2)
    }

    func testMeterProbeWaitsForHeldHalfPressAndPollsDuringStableRecording() async throws {
        for movie in [false, true] {
            let camera = RemoteLifecycleCamera(movie: movie)
            await camera.setProperty(.init(property: .nikonLightMeter, dataType: 1,
                writable: false, current: 12, values: []))
            let model = makeModel(camera: camera)
            model.start()
            try await waitFor { model.state.liveViewStable }
            if movie {
                model.toggleRecording()
                try await waitFor { model.state.capture == .recording && !model.recordingBusy }
            } else {
                model.beginHalfPress()
                try await waitFor { model.state.focus.phase == .locked }
            }
            model.setExposureMeterVisible(true)
            if !movie {
                try await Task.sleep(for: .milliseconds(550))
                let blocked = await camera.log
                XCTAssertFalse(blocked.contains("property:nikonLightMeter"))
                model.endHalfPress(fire: false)
            }
            try await waitFor { model.exposureMeterEV == 1 }
            if movie { XCTAssertEqual(model.state.capture, .recording) }
            model.setExposureMeterVisible(false)
            await model.stopAndWait()
        }
    }

    func testMeterRetriesMissingPrimaryButFallsBackImmediatelyForInvalidDescriptor() async throws {
        for missing in [true, false] {
            let camera = RemoteLifecycleCamera()
            if missing { await camera.markUnsupported(.nikonLightMeter) }
            // Default stub descriptor is writable UINT32: invalid for read-only metering.
            await camera.setProperty(.init(property: .nikonExposureIndicate, dataType: 1,
                writable: false, current: UInt64(bitPattern: -3), values: []))
            let model = makeModel(camera: camera)
            model.start()
            try await waitFor { model.state.liveViewStable }
            let start = ContinuousClock.now
            model.setExposureMeterVisible(true)
            try await waitFor(timeout: 4) { model.exposureMeterEV == -1 }
            let elapsed = start.duration(to: .now)
            let calls = await camera.log
            XCTAssertEqual(calls.filter { $0 == "property:nikonLightMeter" }.count, missing ? 3 : 1)
            XCTAssertEqual(calls.filter { $0 == "property:nikonExposureIndicate" }.count, 1)
            if missing { XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(2100)) }
            model.setExposureMeterVisible(false)
            await model.stopAndWait()
        }
    }

    func testPersistedAnalysisSelectionSurvivesErrorAndMovieCompatibilityRecovery() async throws {
        let name = "analysis-recovery-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let saved = RemoteToolPreferences(defaults: defaults)
        saved.histogram = .rgb
        saved.waveform = .rgb
        saved.exposure = .falseColor
        for compatibility in [false, true] {
            let restored = RemoteToolPreferences(defaults: defaults)
            let camera = RemoteLifecycleCamera(movie: compatibility)
            await camera.limitSuccessfulFrames(to: 1)
            let model = makeModel(camera: camera)
            model.setFrameAnalysis(histogram: restored.histogram != .off, zebra: restored.exposure == .zebra,
                waveform: restored.waveform, falseColor: restored.exposure == .falseColor,
                histogramRGB: restored.histogram == .rgb)
            model.start()
            try await waitFor { model.frameFalseColorPixels != nil && model.frameWaveform?.count == 3 }
            let oldImage = model.frameImage
            if compatibility {
                await camera.queueMovieStarts([
                    .init(responseCode: 0xA004, prohibitCondition: 1 << 14),
                    .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
                ])
                model.toggleRecording()
                try await waitFor(timeout: 5) { model.state.capture == .recording && !model.recordingBusy }
            } else {
                await camera.failNextFrames(3)
            }
            try await waitFor(timeout: 5) { await camera.log.filter { $0 == "start" }.count == 2 }
            await camera.limitSuccessfulFrames(to: 2)
            try await waitFor { model.frameImage !== oldImage }
            XCTAssertEqual(model.frameHistogramRGB?.count, 3)
            XCTAssertEqual(model.frameWaveform?.count, 3)
            XCTAssertNotNil(model.frameFalseColorPixels)
            XCTAssertNil(model.frameZebraMask)
            await model.stopAndWait()
        }
    }

    func testAnalysisSelectionSurvivesInitialStartAndHDRestart() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.setFrameAnalysis(histogram: true, zebra: true, waveform: .rgb, falseColor: true, histogramRGB: true)
        model.start()
        try await waitFor {
            model.frameHistogramRGB?.count == 3 && model.frameWaveform?.count == 3 &&
                model.frameFalseColorPixels != nil && model.frameZebraMask != nil
        }
        model.setHDLiveView(true)
        try await waitFor { await camera.log.filter { $0 == "start" }.count == 2 }
        try await waitFor {
            model.frameHistogramRGB?.count == 3 && model.frameWaveform?.count == 3 &&
                model.frameFalseColorPixels != nil && model.frameZebraMask != nil
        }
        XCTAssertNotNil(model.frameHistogram)
    }

    func testHDSessionClearsOldImageWhileReplacementFramesAreBusy() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        model.setHDLiveView(true)
        try await waitFor { await camera.log.filter { $0 == "start" }.count == 2 }
        XCTAssertNil(model.frameImage)
        XCTAssertNil(model.frameData)
        XCTAssertNil(model.frameMetadata)
        XCTAssertEqual(model.frameReceivedAtUptime, 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.frameImage, "An obsolete decode cannot republish the cleared image")
        await camera.limitSuccessfulFrames(to: 2)
        try await waitFor { model.frameImage != nil }
        XCTAssertNotNil(model.frameData)
    }

    func testMovieCompatibilityRestartRetainsImageUntilReplacementArrives() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        await camera.limitSuccessfulFrames(to: 1)
        await camera.queueMovieStarts([
            .init(responseCode: 0xA004, prohibitCondition: 1 << 14),
            .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
        ])
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        let image = model.frameImage
        let focusCutoff = model.focusValidAfterUptime
        model.toggleRecording()
        try await waitFor(timeout: 5) { model.state.capture == .recording && !model.recordingBusy }
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 2)
        XCTAssertGreaterThan(model.focusValidAfterUptime, focusCutoff)
        XCTAssertLessThanOrEqual(model.frameReceivedAtUptime, model.focusValidAfterUptime)
        XCTAssertTrue(model.frameImage === image)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.frameImage === image)
        await camera.limitSuccessfulFrames(to: 2)
        try await waitFor { model.frameImage !== image }
        XCTAssertNotNil(model.frameImage)
        XCTAssertGreaterThan(model.frameReceivedAtUptime, model.focusValidAfterUptime)
    }

    func testAcquisitionErrorRetryRetainsImageLikeAndroidInnerLoop() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        let image = model.frameImage
        let focusCutoff = model.focusValidAfterUptime
        await camera.failNextFrames(3)
        try await waitFor(timeout: 5) { await camera.log.filter { $0 == "start" }.count == 2 }
        XCTAssertTrue(model.frameImage === image)
        XCTAssertNotNil(model.frameData)
        XCTAssertEqual(model.focusValidAfterUptime, focusCutoff,
                       "Android inner acquisition retries retain the focus cutoff")
    }

    func testWiFiFirstImageRetainsImmediateStability() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        XCTAssertTrue(model.state.liveViewStable)
        try await waitFor { await camera.log.contains("events") }
    }

    func testZoomedTapCoordinatesReachCameraAndConfirmedMarker() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        var viewport = RemoteViewfinderViewport()
        viewport.resize(CGSize(width: 1000, height: 600), aspect: 5 / 3)
        viewport.transform(centroid: CGPoint(x: 500, y: 300), pan: CGSize(width: 100, height: -50), zoom: 2, aspect: 5 / 3)
        let point = try XCTUnwrap(viewport.focusPoint(at: CGPoint(x: 700, y: 400), aspect: 5 / 3))
        model.focus(at: point, coordinateSize: CGSize(width: 2000, height: 1200))
        try await waitFor { model.confirmedFocusMarker != nil }
        let coordinates = await camera.lastFocusCoordinates
        XCTAssertEqual(coordinates, [1099, 749, 1099, 749])
        XCTAssertEqual(model.confirmedFocusMarker?.fallbackPoint, point)
    }

    func testFocusAreaWriteRequiresTrackingReleaseAndClearsConfirmedFocusOnlyOnSuccess() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusArea, dataType: 4, writable: true,
                                       current: 0x8010, values: [0x8010, 0x8011]))
        await camera.acceptWrites(.focusArea)
        await camera.queueFocusResults([.init(trackingStarted: true, polls: 0, timedOut: false)])
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.focus(at: .init(x: 0.4, y: 0.6))
        try await waitFor { model.state.focus.tracking && model.confirmedFocusMarker != nil }
        model.openCameraTool(.focusArea)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        await camera.setTrackingReleaseResponse(PTPConstants.deviceBusy)
        panel.select(0x8011)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_failed")
        XCTAssertTrue(model.state.focus.tracking)
        XCTAssertNotNil(model.confirmedFocusMarker)
        let refused = await camera.log
        XCTAssertFalse(refused.contains("write:focusArea:32785"))
        // Android accepts invalid-status as an already-ended tracking session.
        await camera.setTrackingReleaseResponse(0xA004)
        panel.select(0x8011)
        try await waitFor { !panel.busy }
        XCTAssertFalse(model.state.focus.tracking)
        XCTAssertNil(model.confirmedFocusMarker)
        XCTAssertEqual(model.state.focus.phase, .idle)
        XCTAssertTrue(panel.closeRequested)
        XCTAssertEqual(panel.descriptor?.current, 0x8011)
        let completed = await camera.log
        XCTAssertEqual(completed.filter { $0 == "end-tracking-tool" }.count, 2)
        XCTAssertEqual(completed.filter { $0 == "write:focusArea:32785" }.count, 1)
        XCTAssertTrue(completed.suffix(4).contains("focus"))
    }

    func testCameraToolLaterReadFailureKeepsRowsButUnavailableReadClearsThem() async throws {
        let camera = RemoteLifecycleCamera()
        var unavailable = 0
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: { unavailable += 1 }, onDismiss: {}, pollInterval: .milliseconds(20))
        panel.start()
        try await waitFor { !panel.loading }
        let first = panel.descriptor
        await camera.failProperty(.whiteBalance, error: .timeout)
        try await waitFor { await camera.log.filter { $0 == "property:whiteBalance" }.count >= 3 }
        XCTAssertEqual(panel.descriptor, first)
        XCTAssertEqual(unavailable, 0)
        await camera.failProperty(.whiteBalance, error: .responseCode(0x200A))
        try await waitFor { panel.descriptor == nil }
        XCTAssertTrue(panel.active)
        XCTAssertFalse(panel.loading)
        XCTAssertEqual(unavailable, 0)
        panel.dismiss()
        await panel.drain()
    }

    func testCameraToolLoadingCloseNeverPublishesLateRowsOrCancelsWireRead() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.delayProperty(.whiteBalance, milliseconds: 120)
        var unavailable = 0
        var dismissed = 0
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: { unavailable += 1 }, onDismiss: { dismissed += 1 })
        panel.start()
        try await waitFor { await camera.log.contains("property:whiteBalance") }
        panel.requestClose()
        XCTAssertFalse(panel.active)
        await panel.drain()
        XCTAssertNil(panel.descriptor)
        XCTAssertEqual(unavailable, 0)
        XCTAssertEqual(dismissed, 1)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:whiteBalance"])
    }

    func testCameraToolPanelRechecksChangedOptionsWithoutWriting() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 5]))
        panel.select(4)
        XCTAssertEqual(panel.pendingValue, 4)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_changed")
        XCTAssertEqual(panel.descriptor?.values, [2, 5])
        XCTAssertFalse(panel.closeRequested)
        let calls = await camera.log
        XCTAssertFalse(calls.contains { $0.hasPrefix("write:whiteBalance:") })
        await model.stopAndWait()
    }

    func testCameraToolPanelRejectsPhysicalModeChangeBeforeWriting() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        await camera.setProperty(.init(property: .liveViewSelector, writable: false, current: 1, values: []))
        panel.select(4)
        try await waitFor { !panel.busy }
        let calls = await camera.log
        XCTAssertFalse(calls.contains { $0.hasPrefix("write:whiteBalance:") })
        XCTAssertTrue(!panel.active || panel.errorResource == "remote_camera_tool_changed")
        await model.stopAndWait()
    }

    func testCameraToolRechecksOwnershipAfterSuspendedBeforeWrite() async throws {
        for change in 0..<5 {
            let camera = RemoteLifecycleCamera()
            await camera.acceptWrites(.whiteBalance)
            var current = true
            var writable = true
            var movie = false
            var release: CheckedContinuation<Bool, Never>?
            var applied = 0
            let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
                isCurrent: { current }, currentMovie: { movie }, canWrite: { writable },
                beforeWrite: { await withCheckedContinuation { release = $0 } },
                onApplied: { applied += 1 }, onUnavailable: {}, onDismiss: {})
            panel.start()
            try await waitFor { !panel.loading }
            panel.select(1)
            try await waitFor { release != nil }
            switch change {
            case 0: panel.dismiss()
            case 1: panel.requestClose()
            case 2: current = false
            case 3: movie = true
            default: writable = false
            }
            release?.resume(returning: true)
            release = nil
            try await waitFor { !panel.busy }
            panel.dismiss()
            await panel.drain()
            let calls = await camera.log
            XCTAssertFalse(calls.contains { $0.hasPrefix("write:whiteBalance:") }, "Change \(change)")
            XCTAssertEqual(applied, 0)
            XCTAssertNil(panel.pendingValue)
        }
    }

    func testCameraToolWriteDrainsAfterMonitorExitWithoutLatePopup() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        await camera.acceptWrites(.whiteBalance)
        await camera.delayWrites(milliseconds: 180)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(4)
        try await waitFor { await camera.log.contains("write:whiteBalance:4") }
        await model.stopAndWait()
        XCTAssertNil(model.cameraToolPanel)
        XCTAssertFalse(panel.busy)
        XCTAssertFalse(panel.active)
        let actual = await camera.current(.whiteBalance)
        XCTAssertEqual(actual, 4)
        let calls = await camera.log
        XCTAssertTrue(calls.contains("refresh:whiteBalance"))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "refresh:whiteBalance")),
                          try XCTUnwrap(calls.firstIndex(of: "gate:false")))
    }

    func testCameraToolSelectionClosesOnlyAfterConfirmedReadback() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        await camera.acceptWrites(.whiteBalance)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(99)
        XCTAssertFalse(panel.busy)
        panel.select(4)
        panel.select(2) // Busy admission ignores a second tap.
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 4)
        XCTAssertTrue(panel.closeRequested)
        XCTAssertNil(panel.errorResource)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0.hasPrefix("write:whiteBalance:") }, ["write:whiteBalance:4"])
        await model.stopAndWait()
    }

    func testCameraToolFirstReadTimeoutDismissesButDrainsUncancelledTransaction() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.delayProperty(.whiteBalance, milliseconds: 180)
        var unavailable = 0
        var dismissed = 0
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: { unavailable += 1 }, onDismiss: { dismissed += 1 },
            readTimeout: .milliseconds(20))
        panel.start()
        try await waitFor { !panel.active }
        XCTAssertTrue(panel.loading)
        XCTAssertEqual(unavailable, 1)
        XCTAssertEqual(dismissed, 1)
        await panel.drain()
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:whiteBalance"])
        XCTAssertNil(panel.descriptor)
    }

    func testCameraToolFailedWriteRetainsActualValueAndAllowsRetry() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        let panel = RemoteCameraToolController(camera: camera, tool: .whiteBalance, movie: false,
            isCurrent: { true }, currentMovie: { false }, canWrite: { true }, beforeWrite: { true },
            onApplied: {}, onUnavailable: {}, onDismiss: {})
        panel.start()
        try await waitFor { !panel.loading }
        panel.select(4)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 2)
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_failed")
        XCTAssertFalse(panel.closeRequested)
        await camera.acceptWrites(.whiteBalance)
        panel.select(4)
        XCTAssertNil(panel.errorResource)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 4)
        XCTAssertTrue(panel.closeRequested)
        panel.dismiss()
        await panel.drain()
    }

    func testCameraToolQueriesActualCandidatesAndPrefersWritableDomain() async throws {
        let camera = RemoteLifecycleCamera()
        let readOnly = RemotePropertyDescriptor(property: .focusArea, writable: false, current: 2, values: [2])
        let live = RemotePropertyDescriptor(property: .liveViewFocusArea, dataType: 2, writable: true, current: 1, values: [0, 1, 2])
        await camera.setProperty(readOnly)
        await camera.setProperty(live)
        let chosen = try await camera.remoteCameraTool(.focusArea, movie: false)
        XCTAssertEqual(chosen, live)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:focusArea", "property:liveViewFocusArea"])
        await camera.markUnsupported(.liveViewFocusArea)
        let fallback = try await camera.remoteCameraTool(.focusArea, movie: false)
        XCTAssertEqual(fallback, readOnly)
    }

    func testFocusModeQueriesStandardThenVendorWithTypeValidation() async throws {
        let camera = RemoteLifecycleCamera()
        let locked = RemotePropertyDescriptor(property: .focusMode, dataType: 2, writable: false,
                                               current: 1, values: [1])
        let vendor = RemotePropertyDescriptor(property: .stillFocusMode, dataType: 2, writable: true,
                                              current: 0, values: [0, 1, 3, 4])
        await camera.setProperty(locked)
        await camera.setProperty(vendor)
        let chosen = try await camera.remoteCameraTool(.focusMode, movie: false)
        XCTAssertEqual(chosen, vendor)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:focusMode", "property:stillFocusMode"])
    }

    func testFocusModeWriteRefreshesManualStateAndFixedVendorModeBlocksTapFocus() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: true,
                                       current: 2, values: [1, 2]))
        await camera.acceptWrites(.focusMode)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        XCTAssertFalse(model.state.focus.manual)
        model.openCameraTool(.focusMode)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(1)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.descriptor?.current, 1)
        XCTAssertTrue(model.state.focus.manual)

        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: false,
                                       current: 3, values: [3]))
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: false,
                                       current: 99, values: []))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.focusMode.rawValue)])
        try await waitFor { model.state.focus.manual }
        model.focus(at: .init(x: 0.5, y: 0.5))
        XCTAssertEqual(model.interactionHint, AppLocalized.resource("remote_tap_focus_manual"))
    }

    func testStillFocusModeEventRefreshesManualState() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: true,
                                       current: 0, values: [0, 1, 3, 4]))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        XCTAssertEqual(model.focusModeDescriptor?.property, .stillFocusMode)
        XCTAssertFalse(model.state.focus.manual)

        await camera.setProperty(.init(property: .stillFocusMode, dataType: 2, writable: true,
                                       current: 4, values: [0, 1, 3, 4]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.stillFocusMode.rawValue)])
        try await waitFor { model.focusModeDescriptor?.current == 4 && model.state.focus.manual }
        XCTAssertTrue(model.state.focus.manual)
    }

    func testFocusModeWriteFailureStillRefreshesMode() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusMode, dataType: 4, writable: true,
                                       current: 2, values: [1, 2]))
        await camera.setWriteResponses(.focusMode, [0x2019, 0x2019, 0x2019])
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.focusMode)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        let beforeRefresh = await camera.log.filter { $0 == "focus" }.count
        panel.select(1)
        try await waitFor { !panel.busy }
        XCTAssertEqual(panel.errorResource, "remote_camera_tool_failed")
        try await waitFor { await camera.log.filter { $0 == "focus" }.count > beforeRefresh }
        XCTAssertFalse(model.state.focus.manual)
    }

    func testCameraToolWriteBlocksFocusAndShutterCommands() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, writable: true, current: 2, values: [2, 4]))
        await camera.acceptWrites(.whiteBalance)
        await camera.delayWrites(milliseconds: 300)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.openCameraTool(.whiteBalance)
        let panel = try XCTUnwrap(model.cameraToolPanel)
        try await waitFor { !panel.loading }
        panel.select(4)
        try await waitFor { model.cameraToolWriting }
        model.focus(at: .init(x: 0.5, y: 0.5))
        model.beginHalfPress()
        model.capture()
        XCTAssertEqual(model.state.capture, .idle)
        let duringWrite = await camera.log
        XCTAssertFalse(duringWrite.contains("tapfocus:start"))
        XCTAssertFalse(duringWrite.contains("halfpress:start"))
        XCTAssertFalse(duringWrite.contains("capture"))
        try await waitFor { !panel.busy }
    }

    func testMovieCameraToolNeverFallsBackToPhotoProperty() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.movieWhiteBalance)
        let alternative = RemotePropertyDescriptor(property: .movieWhiteBalanceAlternate, writable: true, current: 2, values: [2, 4])
        await camera.setProperty(alternative)
        let whiteBalance = try await camera.remoteCameraTool(.whiteBalance, movie: true)
        XCTAssertEqual(whiteBalance, alternative)
        await camera.markUnsupported(.movieFocusArea)
        let focus = try await camera.remoteCameraTool(.focusArea, movie: true)
        XCTAssertNil(focus)
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:movieWhiteBalance", "property:movieWhiteBalanceAlternate", "property:movieFocusArea"])
    }

    func testCameraToolUnsupportedResponseFallsBackButTransportFailureDoesNot() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.failProperty(.focusArea, error: .responseCode(0x200A))
        let fallback = try await camera.remoteCameraTool(.focusArea, movie: false)
        XCTAssertEqual(fallback?.property, .liveViewFocusArea)
        await camera.failProperty(.movieWhiteBalance, error: .timeout)
        do {
            _ = try await camera.remoteCameraTool(.whiteBalance, movie: true)
            XCTFail("Transport timeout must propagate")
        } catch PTPSessionError.timeout { }
        let calls = await camera.log
        XCTAssertEqual(calls, ["property:focusArea", "property:liveViewFocusArea", "property:movieWhiteBalance"])
    }

    func testFirstWritableCameraToolStopsQueryAndUsesVerifiedWrite() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .focusArea, dataType: 4, writable: true,
                                                   current: 0x8010, values: [0x8010, 0x8011])
        await camera.setProperty(descriptor)
        let queried = try await camera.remoteCameraTool(.focusArea, movie: false)
        let selected = try XCTUnwrap(queried)
        let reads = await camera.log
        XCTAssertEqual(reads, ["property:focusArea"])
        await camera.acceptWrites(.focusArea)
        let result = try await camera.setRemotePropertyVerified(selected, value: 0x8011)
        XCTAssertTrue(result.confirmed)
        XCTAssertEqual(result.actual?.current, 0x8011)
    }

    func testConcurrentTrialAndPageExitShareOneCleanup() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("frame") }
        async let trial: Void = model.stopAndWait()
        async let page: Void = model.stopAndWait()
        _ = await (trial, page)
        await model.stopAndWait()
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "gate:false" }.count, 1)
    }

    func testCameraElapsedUpdatesItsLeafWithoutRebuildingMonitor() {
        let model = makeModel(camera: RemoteLifecycleCamera())
        var pageUpdates = 0, cameraUpdates = 0
        let page = model.objectWillChange.sink { pageUpdates += 1 }
        let camera = model.cameraRecordingElapsed.objectWillChange.sink { cameraUpdates += 1 }
        for n in 1...120 { model.cameraRecordingElapsed.set(n) }
        XCTAssertEqual(pageUpdates, 0); XCTAssertEqual(cameraUpdates, 120)
        XCTAssertEqual(model.recordingSeconds, 120)
        page.cancel(); camera.cancel()
    }

    func testCameraRecordingElapsedResetsAfterStopAndIgnoresCancelledTimer() async throws {
        let model = makeModel(camera: RemoteLifecycleCamera(movie: true))
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy }
        try await waitFor { model.recordingSeconds >= 1 }
        XCTAssertEqual(model.cameraRecordingElapsed.seconds, model.recordingSeconds)
        model.toggleRecording()
        try await waitFor { model.state.capture == .idle && !model.recordingBusy }
        XCTAssertEqual(model.recordingSeconds, 0)
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertEqual(model.recordingSeconds, 0)
        await model.stopAndWait()
    }

    func testEntryGatesBeforeParametersAndSelectsMovieExposureBeforeLiveView() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("frame") }
        let calls = await camera.log
        XCTAssertEqual(calls.first, "gate:true")
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "selector")),
                          try XCTUnwrap(calls.firstIndex(of: "property:movieISO")))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "property:batteryLevel")),
                          try XCTUnwrap(calls.firstIndex(of: "start")))
        XCTAssertFalse(calls.contains("property:iso"))
        XCTAssertTrue(model.movieMode)
        await model.stopAndWait()
        let stopped = await camera.log
        XCTAssertEqual(stopped.last, "gate:false")
        XCTAssertLessThan(try XCTUnwrap(stopped.lastIndex(of: "end")), stopped.count - 1)
    }

    func testStopInterruptsMovieFormatIdleTimerAndReleasesGateOnce() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.filter { $0 == "property:movieFormat" }.count >= 2 }
        // The second read is the poller's first read; it now waits ten seconds.
        try await Task.sleep(for: .milliseconds(80))
        let started = ContinuousClock.now
        async let first: Void = model.stopAndWait()
        async let second: Void = model.stopAndWait()
        _ = await (first, second)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "gate:false" }.count, 1)
        XCTAssertEqual(calls.last, "gate:false")
    }

    func testStopDrainsMovieFormatReadWithoutCancellingWireRequest() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayProperty(.movieFormat, milliseconds: 350)
        let before = await camera.log.filter { $0 == "property:movieFormat" }.count
        model.setMovieFormatMonitoring(true)
        try await waitFor { await camera.log.filter { $0 == "property:movieFormat" }.count > before }
        let started = ContinuousClock.now
        await model.stopAndWait()
        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThan(elapsed, .milliseconds(250))
        XCTAssertLessThan(elapsed, .seconds(2))
        let calls = await camera.log
        XCTAssertFalse(calls.contains("cancelled-property:movieFormat"))
        XCTAssertEqual(calls.last, "gate:false")
    }

    func testMovieFormatRetainsDescriptorAcrossMissingScalar() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        await camera.setProperty(.init(property: .movieFormat, dataType: 8, writable: false,
                                       current: (1920 << 48) | (1080 << 32) | (60 << 16), values: []))
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.movieFormatLabel == "1080 60p" }
        // Let the entry monitor resolve its own descriptor before event refreshes.
        try await Task.sleep(for: .milliseconds(100))
        let reads = await camera.log.filter { $0 == "property:movieFormat" }.count
        await camera.failRefresh(.movieFormat)
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.movieFormat.rawValue)])
        try await waitFor { model.movieFormatLabel == nil }
        await camera.restoreRefresh(.movieFormat)
        await camera.setProperty(.init(property: .movieFormat, dataType: 8, writable: false,
                                       current: (1920 << 48) | (1080 << 32) | (30 << 16), values: []))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.movieFormat.rawValue)])
        try await waitFor { model.movieFormatLabel == "1080 30p" }
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "property:movieFormat" }.count, reads)
        XCTAssertGreaterThanOrEqual(calls.filter { $0 == "refresh:movieFormat" }.count, 2)
        await model.stopAndWait()
    }

    func testMovieFormatRejectsHeldReadAcrossModeRoundTrip() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        await camera.setProperty(.init(property: .movieFormat, dataType: 8, writable: false,
                                       current: (1920 << 48) | (1080 << 32) | (60 << 16), values: []))
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.movieFormatLabel == "1080 60p" }
        let barrier = FramePublicationBarrier()
        await camera.holdNextProperty(.movieFormat) { await barrier.waitOnce() }
        model.setMovieFormatMonitoring(true)
        try await waitFor { await barrier.reached }
        await camera.changeMovieMode(false)
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.liveViewSelector.rawValue)])
        try await waitFor { !model.movieMode }
        XCTAssertNil(model.movieFormatLabel)
        await camera.setProperty(.init(property: .movieFormat, dataType: 8, writable: false,
                                       current: (1920 << 48) | (1080 << 32) | (30 << 16), values: []))
        await camera.changeMovieMode(true)
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.liveViewSelector.rawValue)])
        try await waitFor { model.movieMode && model.movieFormatLabel == "1080 30p" }
        await barrier.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.movieFormatLabel, "1080 30p")
        await model.stopAndWait()
    }

    func testMovieFormatRejectsOldReadAfterHideAndReopen() async throws {
        for reopen in [false, true] {
            let camera = RemoteLifecycleCamera(movie: true)
            await camera.setProperty(.init(property: .movieFormat, dataType: 0x0008, writable: false,
                                           current: (1920 << 48) | (1080 << 32) | (60 << 16), values: []))
            let model = makeModel(camera: camera)
            model.start()
            try await waitFor { model.movieFormatLabel == "1080 60p" }
            let barrier = FramePublicationBarrier()
            await camera.holdNextProperty(.movieFormat) { await barrier.waitOnce() }
            model.setMovieFormatMonitoring(true)
            try await waitFor { await barrier.reached }
            model.setMovieFormatMonitoring(false)
            if reopen {
                await camera.setProperty(.init(property: .movieFormat, dataType: 0x0008, writable: false,
                                               current: (1920 << 48) | (1080 << 32) | (30 << 16), values: []))
                model.setMovieFormatMonitoring(true)
                try await waitFor { model.movieFormatLabel == "1080 30p" }
            }
            await barrier.release()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.movieFormatLabel, reopen ? "1080 30p" : nil)
            await model.stopAndWait()
        }
    }

    func testMovieFormatIsReadOnEntryAndInvalidValueIsHidden() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        await camera.setProperty(.init(property: .movieFormat, dataType: 0x0008, writable: false,
                                       current: (1920 << 48) | (1080 << 32) | (60 << 16), values: []))
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.movieFormatLabel == "1080 60p" }
        await camera.setProperty(.init(property: .movieFormat, dataType: 0x0008, writable: false,
                                       current: (2560 << 48) | (1440 << 32) | (60 << 16), values: []))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.movieFormat.rawValue)])
        try await waitFor { model.movieFormatLabel == nil }
        await model.stopAndWait()
    }

    func testBatteryUsesEventsInsteadOfSixHundredMillisecondPolling() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("events") }
        try await Task.sleep(for: .milliseconds(1300))
        let before = await camera.log
        XCTAssertEqual(before.filter { $0 == "property:batteryLevel" }.count, 1)
        XCTAssertFalse(before.contains("refresh:batteryLevel"))
        await camera.emitBatteryEvent()
        try await waitFor { await camera.log.contains("refresh:batteryLevel") }
        await model.stopAndWait()
        let after = await camera.log
        try await Task.sleep(for: .milliseconds(150))
        let final = await camera.log
        XCTAssertEqual(after, final, "No polling commands may survive page disposal")
    }

    func testHDChangeEndsOldLiveViewWithoutReleasingPageGate() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { await camera.log.contains("frame") }
        model.setHDLiveView(true)
        try await waitFor { await camera.log.filter { $0 == "start" }.count == 2 }
        let calls = await camera.log
        let starts = calls.indices.filter { calls[$0] == "start" }
        XCTAssertTrue(calls[starts[0]..<starts[1]].contains("end"))
        XCTAssertFalse(calls.contains("gate:false"))
        XCTAssertFalse(calls.contains("cancelled-frame"))
        await model.stopAndWait()
    }

    func testRepeatedNonBusyFrameErrorsRestartLiveView() async throws {
        let camera = RemoteLifecycleCamera(failingFrames: 3)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor(timeout: 5) { await camera.log.filter { $0 == "start" }.count == 2 }
        let calls = await camera.log
        XCTAssertTrue(calls.contains("end"))
        XCTAssertFalse(calls.contains("gate:false"))
        await model.stopAndWait()
    }

    func testTransportFailureUsesGlobalRecoveryOnceInsteadOfRestartingDeadLiveView() async throws {
        let camera = RemoteLifecycleCamera(transportFailure: true)
        var losses = 0
        let model = makeModel(camera: camera, onTransportLost: { losses += 1 })
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { losses == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.transportLossWasNotified)
        XCTAssertEqual(losses, 1)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1)
    }

    func testBatteryBecomesUnknownInsteadOfKeepingOldPercent() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .batteryLevel, dataType: 2, writable: false, current: 67, values: []))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.batteryPercent == 67 }
        await camera.setProperty(.init(property: .batteryLevel, dataType: 2, writable: false, current: 255, values: []))
        await camera.emitBatteryEvent()
        try await waitFor { model.batteryPercent == nil }
    }

    func testCompatibleExposureUsesWritableFallbackAndRefreshesItsValueDomain() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .iso, writable: false, current: 100, values: [100]))
        await camera.setProperty(.init(property: .nikonISOEx, writable: true, current: 200, values: [100, 200]))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        XCTAssertEqual(model.exposureDescriptors[.iso]?.property, .nikonISOEx)
        await camera.setProperty(.init(property: .nikonISOEx, writable: false, current: 400, values: [400, 800]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.iso.rawValue),
                                  .init(code: 0x4006, handle: RemoteProperty.nikonISOEx.rawValue)])
        // Both descriptors are now read-only: Android retains the first readable
        // property and refreshes its complete description rather than stale enum.
        try await waitFor { model.exposureDescriptors[.iso]?.property == .iso }
        XCTAssertEqual(model.exposureDescriptors[.iso]?.values, [100])
        XCTAssertEqual(model.exposureDescriptors[.iso]?.writable, false)
    }

    func testInactiveMovieExposureEventRefreshesItsOwnCacheWithoutReplacingPhotoUI() async throws {
        let camera = RemoteLifecycleCamera(movie: false)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        let before = await camera.log.filter { $0 == "property:movieISO" }.count
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.movieISO.rawValue)])
        try await waitFor {
            await camera.log.filter { $0 == "property:movieISO" }.count > before
        }
        XCTAssertFalse(model.movieMode)
        XCTAssertEqual(model.exposureDescriptors[.iso]?.property, .iso)
    }

    func testPhysicalSelectorRefreshesIndependentExposureAndClearsPhotoApplicationWithoutRestarting() async throws {
        let camera = RemoteLifecycleCamera(movie: false)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        let starts = await camera.log.filter { $0 == "start" }.count
        await camera.setProperty(.init(property: .liveViewSelector, writable: false, current: 1, values: [0, 1]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.liveViewSelector.rawValue)])
        try await waitFor { model.movieMode && model.exposureDescriptors[.iso]?.property == .movieISO }
        // The selector is intentionally not polled while recording. This is
        // stale application state after a completed/failed attempt in standby.
        await camera.ensureMovieApplicationMode()
        await camera.setProperty(.init(property: .liveViewSelector, writable: false, current: 0, values: [0, 1]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.liveViewSelector.rawValue)])
        try await waitFor { !model.movieMode && model.state.capture == .idle && model.exposureDescriptors[.iso]?.property == .iso }
        let application = await camera.hasMovieApplicationMode()
        let log = await camera.log
        XCTAssertFalse(application)
        XCTAssertEqual(log.filter { $0 == "start" }.count, starts)
        XCTAssertFalse(log.contains("end"))
        XCTAssertTrue(log.contains("app:off:false"))
    }

    func testPhotoSelectorDoesNotSplitUSBManualControlOwnership() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        _ = try await camera.setRemoteDiagnosticControlMode(true)
        await camera.ensureMovieApplicationMode()
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.preferredComputerControl = true
        model.start()
        try await waitFor { model.state.session == .ready && model.computerControlEnabled }
        await camera.ensureMovieApplicationMode()
        let starts = await camera.log.filter { $0 == "start" }.count
        await camera.setProperty(.init(property: .liveViewSelector, writable: false, current: 0, values: [0, 1]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.liveViewSelector.rawValue)])
        try await waitFor { !model.movieMode && model.exposureDescriptors[.iso]?.property == .iso }
        let application = await camera.hasMovieApplicationMode()
        let control = await camera.hasRemoteDiagnosticControlMode()
        let actualStarts = await camera.log.filter { $0 == "start" }.count
        XCTAssertTrue(application)
        XCTAssertTrue(control)
        XCTAssertTrue(model.computerControlEnabled)
        XCTAssertEqual(actualStarts, starts)
    }

    func testFreshDualAxisHeaderSuspendsPropertyPollingAndStaleHeaderFallsBack() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setAttitudeFrame(roll: 12.5, pitch: -3.2)
        await camera.setProperty(.init(property: .angleLevel, dataType: 5, writable: false,
                                       current: 23_514_322, values: []))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.frameMetadata?.attitude != nil }
        model.setLevelVisible(true)
        try await waitFor { model.levelPitch != nil }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), 12.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(model.levelPitch), -3.2, accuracy: 0.01)
        let headerCalls = await camera.log
        XCTAssertFalse(headerCalls.contains("property:angleLevel"))
        await camera.setAttitudeFrame(roll: 12.5, pitch: -3.2, age: 2)
        try await waitFor { model.levelPitch == nil && model.levelRoll != nil }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), -1.2, accuracy: 0.01)
        let fallbackCalls = await camera.log
        XCTAssertTrue(fallbackCalls.contains("property:angleLevel"))
    }

    func testDualAxisHeaderRecoversAfterPropertyDeclaredUnavailable() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.angleLevel)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        model.setLevelVisible(true)
        try await waitFor { await camera.log.filter { $0 == "property:angleLevel" }.count == 3 }
        await camera.setAttitudeFrame(roll: 7.5, pitch: 2)
        try await waitFor { model.levelPitch == 2 }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), 7.5, accuracy: 0.01)
        XCTAssertTrue(model.levelVisible)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "property:angleLevel" }.count, 3)
        model.setLevelVisible(false)
        XCTAssertNil(model.levelRoll)
        XCTAssertNil(model.levelPitch)
    }

    func testLevelDescribesOnDemandAndKeepsSwitchOnAfterThreeReadFailures() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .angleLevel, dataType: 5, writable: false,
                                       current: 23_514_322, values: []))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        let before = await camera.log
        XCTAssertFalse(before.contains("property:angleLevel"))
        await camera.failRefresh(.angleLevel)
        model.setLevelVisible(true)
        try await waitFor { model.levelRoll != nil }
        XCTAssertEqual(try XCTUnwrap(model.levelRoll), -1.2, accuracy: 0.01)
        await camera.markUnsupported(.angleLevel)
        try await waitFor { model.levelRoll == nil }
        XCTAssertTrue(model.levelVisible)
        let stopped = await camera.log.filter { $0 == "refresh:angleLevel" }.count
        XCTAssertEqual(stopped, 1) // Failed refresh is followed by fresh descriptors.
        let descriptions = await camera.log.filter { $0 == "property:angleLevel" }.count
        XCTAssertEqual(descriptions, 3) // Initial success plus two failed re-describes.
        try await Task.sleep(for: .milliseconds(300))
        let after = await camera.log.filter { $0 == "refresh:angleLevel" }.count
        XCTAssertEqual(after, stopped)
        model.setLevelVisible(false)
        XCTAssertFalse(model.levelVisible)
    }

    func testUnsupportedLevelKeepsPreferenceAndStopsOnlyPropertyPolling() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.angleLevel)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        model.setLevelVisible(true)
        try await waitFor { await camera.log.filter { $0 == "property:angleLevel" }.count == 3 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.levelVisible)
        XCTAssertNil(model.levelRoll)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "property:angleLevel" }.count, 3)
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "property:batteryLevel")),
                          try XCTUnwrap(calls.firstIndex(of: "property:angleLevel")))
        XCTAssertFalse(calls.contains("refresh:angleLevel"))
    }

    func testTapFocusInManualModeShowsAndroidHintWithoutSendingAF() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .focusMode, dataType: 0x0002,
                                       writable: false, current: 1, values: []))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }

        model.focus(at: .init(x: 0.5, y: 0.5))

        XCTAssertEqual(model.interactionHint, AppLocalized.resource("remote_tap_focus_manual"))
        let calls = await camera.log
        XCTAssertFalse(calls.contains("tapfocus:start"))
    }

    func testInvalidTrackingModeShowsAndroidGuidance() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.queueFocusResults([
            .init(trackingStarted: false, polls: 0, timedOut: false,
                  responseCode: 0xA004, trackingResponseCode: 0xA004)
        ])
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }

        model.focus(at: .init(x: 0.5, y: 0.5))

        try await waitFor {
            model.interactionHint == AppLocalized.resource("remote_tap_focus_area_retry")
        }
        XCTAssertEqual(model.state.focus.phase, .failed)
    }

    func testMoveAreaFailureShowsAndroidAreaRetryHint() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.queueFocusResults([
            .init(trackingStarted: false, polls: 0, timedOut: false,
                  responseCode: 0x2019, moveResponseCode: 0x2019)
        ])
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.focus(at: .init(x: 0.5, y: 0.5))
        try await waitFor {
            model.interactionHint == AppLocalized.resource("remote_tap_focus_area_retry")
        }
        XCTAssertEqual(model.state.focus.phase, .failed)
    }

    func testZSeriesUnsupportedFocusAreaShowsAndroidGuidanceWithoutSendingAF() async throws {
        let camera = RemoteLifecycleCamera(model: "Z 30")
        await camera.setProperty(.init(property: .focusArea, dataType: 2, writable: true,
                                       current: 0x801C, values: [0x801C]))
        let area = try await camera.remoteCameraTool(.focusArea, movie: false)
        let modelName = await camera.remoteDeviceModel()
        XCTAssertEqual(modelName, "Z 30")
        XCTAssertEqual(area?.property, .focusArea)
        XCTAssertEqual(area?.current, 0x801C)
        XCTAssertEqual(rcTapFocusPath(area, model: modelName), .unsupported)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.focus(at: .init(x: 0.5, y: 0.5))
        try await waitFor {
            model.interactionHint == AppLocalized.resource("remote_tap_focus_area_unsupported")
        }
        XCTAssertEqual(model.state.focus.phase, .failed)
        let calls = await camera.log
        XCTAssertFalse(calls.contains("tapfocus:start"))
    }

    func testTapFocusSeparatesTransientFeedbackFromThreeSecondConfirmedMarker() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }

        model.focus(at: .init(x: 0.25, y: 0.75))

        try await waitFor { model.confirmedFocusMarker != nil }
        XCTAssertEqual(model.state.focus.phase, .locked)
        XCTAssertEqual(model.confirmedFocusMarker?.fallbackPoint, .init(x: 0.25, y: 0.75))
        try await waitFor(timeout: 2.2) { model.state.focus.phase == .idle }
        XCTAssertNotNil(model.confirmedFocusMarker,
                        "Android keeps the confirmed marker after the 1.8-second feedback ends")
        try await waitFor(timeout: 1.6) { model.confirmedFocusMarker == nil }
    }

    func testHalfPressHandoffAndQuietFallbackExpiry() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.limitSuccessfulFrames(to: 1)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.frameImage != nil }
        await camera.delayFocus(milliseconds: 80)
        model.beginHalfPress()
        let firstNonce = model.state.focus.nonce
        XCTAssertTrue(model.halfPressVisualActive)
        XCTAssertEqual(model.state.focus.phase, .focusing)
        try await waitFor { model.state.focus.phase == .locked }
        let marker = try XCTUnwrap(model.confirmedFocusMarker)
        XCTAssertNotNil(marker.fallbackPoint(at: ProcessInfo.processInfo.systemUptime))
        var handoff = RemoteFocusHandoff()
        let stale = RemoteFocusHandoff.Input(nonce: firstNonce, phase: model.state.focus.phase,
            eligible: model.frameReceivedAtUptime >= marker.confirmedAtUptime, hasCameraFrames: true)
        handoff.update(stale)
        XCTAssertFalse(stale.eligible, "Held old image cannot accept half-press handoff")
        XCTAssertTrue(handoff.visibility(for: stale).tap)
        XCTAssertFalse(handoff.visibility(for: stale).camera)
        model.endHalfPress(fire: false)
        XCTAssertEqual(model.state.focus.phase, .idle)
        XCTAssertFalse(model.halfPressVisualActive)
        XCTAssertEqual(model.confirmedFocusMarker, marker)
        try await waitFor(timeout: 4) {
            marker.fallbackPoint(at: ProcessInfo.processInfo.systemUptime) == nil
        }
        model.beginHalfPress()
        XCTAssertGreaterThan(model.state.focus.nonce, firstNonce)
        XCTAssertNil(model.confirmedFocusMarker)
        let next = RemoteFocusHandoff.Input(nonce: model.state.focus.nonce, phase: model.state.focus.phase,
                                           eligible: false, hasCameraFrames: true)
        handoff.update(next)
        handoff.complete(stale)
        XCTAssertTrue(handoff.visibility(for: next).tap)
        XCTAssertFalse(handoff.visibility(for: next).camera)
        await model.stopAndWait()
        XCTAssertNil(model.confirmedFocusMarker)
        XCTAssertFalse(model.halfPressVisualActive)
    }

    func testHalfPressUsesLastFocusAreaAndKeepsLateConfirmedMarkerAfterRelease() async throws {
        let camera = RemoteLifecycleCamera()
        var feedback: [HapticFeedbackEvent] = []
        let haptics = ZTransferHaptics(defaults: UserDefaults(suiteName: UUID().uuidString)!) { feedback.append($0) }
        let model = makeModel(camera: camera, haptics: haptics)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayFocus(milliseconds: 120)

        model.beginHalfPress()

        XCTAssertTrue(model.halfPressVisualActive)
        XCTAssertEqual(model.state.focus.phase, .focusing)
        XCTAssertEqual(model.state.focus.point, .init(x: 0.5, y: 0.5))
        model.endHalfPress(fire: false)
        XCTAssertFalse(model.halfPressVisualActive)
        XCTAssertEqual(model.state.focus.phase, .idle)
        try await waitFor { model.confirmedFocusMarker != nil }
        XCTAssertEqual(model.confirmedFocusMarker?.fallbackPoint, .init(x: 0.5, y: 0.5))
        XCTAssertEqual(feedback, [.feedback(.focusStarted)], "Late AF success after release stays silent")
        model.beginHalfPress()
        try await waitFor { model.state.focus.phase == .locked }
        XCTAssertEqual(feedback, [.feedback(.focusStarted), .feedback(.focusStarted), .feedback(.focusLocked)])
        model.endHalfPress(fire: false)
    }

    func testShutterWaitsForObjectAddedAndCommandFailureDoesNotFailLiveView() async throws {
        let camera = RemoteLifecycleCamera()
        var feedback: [HapticFeedbackEvent] = []
        let haptics = ZTransferHaptics(defaults: UserDefaults(suiteName: UUID().uuidString)!) { feedback.append($0) }
        let model = makeModel(camera: camera, haptics: haptics)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.capture()
        try await waitFor { await camera.log.contains("capture") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.state.capture, .capturing)
        await camera.queueEvents([.init(code: 0xC101, handle: 17)])
        try await waitFor { model.state.capture == .idle }
        XCTAssertEqual(feedback, [.feedback(.shutter)], "Camera result/polling must not repeat the shutter pulse")
        await camera.failCapture()
        model.capture()
        try await waitFor { model.state.capture == .idle }
        XCTAssertEqual(model.state.session, .ready)
        XCTAssertEqual(feedback, [.feedback(.shutter), .feedback(.shutter)])
    }

    func testMovieEventsSynchronizeCameraStateAndIgnoreLateStartAfterLocalStop() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.queueEvents([.init(code: 0xC10A, handle: 0)])
        try await waitFor { model.state.capture == .recording }
        await camera.queueEvents([.init(code: 0xC105, handle: 0)])
        try await waitFor { model.state.capture == .idle }
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy }
        model.toggleRecording()
        try await waitFor { model.state.capture == .idle && !model.recordingBusy }
        await camera.queueEvents([.init(code: 0xC10A, handle: 0)])
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(model.state.capture, .idle)
    }

    func testMonitorStoragePollsSortedUsableCardsAndPublishesDecimalFreeBytes() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setMonitorStorage(
            ids: [.max, 0, 7, 7, 3],
            free: [3: 2_000_000_000, 7: 1_000_000_000])
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.setStorageMonitoring(true)
        model.start()
        try await waitFor(timeout: 5) { model.monitorStorageFreeBytes.count == 2 }
        XCTAssertEqual(model.monitorStorageFreeBytes[3], 2_000_000_000)
        XCTAssertEqual(model.monitorStorageFreeBytes[7], 1_000_000_000)
        XCTAssertEqual(model.monitorStorageSlotCount, 2)
        XCTAssertEqual(model.monitorStorageSlotByID, [3: 1, 7: 2])
        let firstLog = await camera.log
        XCTAssertEqual(firstLog.filter { $0 == "storage:ids" }.count, 1)
    }

    func testMonitorStorageStopsAfterUnsupportedAndKeepsEarlierCardsInCycle() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setMonitorStorage(
            ids: [3, 7],
            free: [3: 2_000_000_000],
            errors: [7: .responseCode(0x2005)])
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.setStorageMonitoring(true)
        model.start()
        try await waitFor(timeout: 5) { await camera.log.contains("storage:free:7") }
        XCTAssertEqual(model.monitorStorageFreeBytes, [3: 2_000_000_000])
        XCTAssertEqual(model.monitorStorageSlotCount, 2)
        let firstPollCount = await camera.log.filter { $0.hasPrefix("storage:free:") }.count
        try await Task.sleep(for: .milliseconds(350))
        let secondPollCount = await camera.log.filter { $0.hasPrefix("storage:free:") }.count
        XCTAssertEqual(secondPollCount, firstPollCount)
    }

    func testMonitorStorageKeepsPublishedValuesWhileQueuedAndOnCancellation() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setMonitorStorage(ids: [3], free: [3: 111])
        let model = makeModel(camera: camera)
        model.setStorageMonitoring(true); model.start()
        try await waitFor { model.monitorStorageFreeBytes == [3: 111] }
        let queued = GateTestLatch(), release = GateTestLatch()
        await camera.setMonitorAdmissionProbe { await queued.signal(); await release.wait() }
        let poll = Task { await model.refreshMonitorStorage() }
        await queued.wait()
        XCTAssertEqual(model.monitorStorageFreeBytes, [3: 111], "Waiting for the download must not publish an empty cycle")
        poll.cancel()
        await release.signal(); await poll.value
        XCTAssertEqual(model.monitorStorageFreeBytes, [3: 111])
        let reads = await camera.log.filter { $0 == "storage:free:3" }.count
        XCTAssertEqual(reads, 1)
    }

    func testMonitorStorageRechecksRecordingStateAtAdmission() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        await camera.setMonitorStorage(ids: [3], free: [3: 111])
        let model = makeModel(camera: camera)
        model.setStorageMonitoring(true); model.start()
        try await waitFor { model.monitorStorageFreeBytes == [3: 111] }
        let queued = GateTestLatch(), release = GateTestLatch()
        await camera.setMonitorAdmissionProbe { await queued.signal(); await release.wait() }
        let poll = Task { await model.refreshMonitorStorage() }
        await queued.wait()
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy }
        await release.signal(); await poll.value
        let reads = await camera.log.filter { $0 == "storage:free:3" }.count
        XCTAssertEqual(reads, 1, "No storage PTP command is sent after recording began while waiting")
    }

    func testOldStorageFailureCannotDisableNewCameraDispGeneration() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setMonitorStorage(ids: [3], free: [3: 111])
        let model = makeModel(camera: camera)
        model.setStorageMonitoring(true); model.start()
        try await waitFor { model.monitorStorageFreeBytes == [3: 111] }
        let responseReady = GateTestLatch(), release = GateTestLatch()
        await camera.setMonitorStorage(ids: [3], free: [:], errors: [3: .responseCode(0x2005)])
        await camera.setMonitorResponseProbe { await responseReady.signal(); await release.wait() }
        let old = Task { await model.refreshMonitorStorage() }
        await responseReady.wait()
        model.setStorageMonitoring(false)
        await camera.setMonitorStorage(ids: [7], free: [7: 222])
        model.setStorageMonitoring(true)
        try await waitFor { model.monitorStorageFreeBytes == [7: 222] }
        await release.signal(); await old.value
        XCTAssertEqual(model.monitorStorageFreeBytes, [7: 222])
        await camera.setMonitorStorage(ids: [7], free: [7: 333])
        await model.refreshMonitorStorage()
        XCTAssertEqual(model.monitorStorageFreeBytes, [7: 333], "Late 0x2005 must not latch unsupported on the new generation")
    }

    func testCameraDispRestartsOnModeChangeWithoutViewCallback() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, dataType: 2, writable: true, current: 2, values: [2, 4]))
        let model = makeModel(camera: camera)
        model.setDisplayDetailsMonitoring(true)
        model.start()
        try await waitFor { model.displayWhiteBalanceLabel != nil }
        let first = model.displayWhiteBalanceLabel
        let barrier = FramePublicationBarrier()
        await camera.holdNextRefresh(.whiteBalance) { await barrier.waitOnce() }
        try await waitFor { await barrier.reached }
        await camera.setProperty(.init(property: .movieWhiteBalance, dataType: 2, writable: true, current: 4, values: [2, 4]))
        await camera.changeMovieMode(true)
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.liveViewSelector.rawValue)])
        try await waitFor { model.movieMode && model.displayWhiteBalanceLabel != nil && model.displayWhiteBalanceLabel != first }
        let replacement = model.displayWhiteBalanceLabel
        await barrier.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.displayWhiteBalanceLabel, replacement)
        await model.stopAndWait()
    }

    func testCameraDispRejectsSuspendedScalarAndDeviceModelAfterReopen() async throws {
        for deviceModelRead in [false, true] {
            let camera = RemoteLifecycleCamera()
            await camera.setProperty(.init(property: .whiteBalance, dataType: 2, writable: true, current: 2, values: [2, 4]))
            let model = makeModel(camera: camera)
            model.start()
            try await waitFor { model.state.session == .ready }
            model.setDisplayDetailsMonitoring(true)
            try await waitFor { model.displayWhiteBalanceLabel != nil }
            let first = model.displayWhiteBalanceLabel
            let barrier = FramePublicationBarrier()
            if deviceModelRead {
                await camera.holdNextDeviceModel { await barrier.waitOnce() }
            } else {
                await camera.holdNextRefresh(.whiteBalance) { await barrier.waitOnce() }
            }
            try await waitFor { await barrier.reached }
            model.setDisplayDetailsMonitoring(false)
            XCTAssertNil(model.displayWhiteBalanceLabel)
            await camera.setProperty(.init(property: .whiteBalance, dataType: 2, writable: true, current: 4, values: [2, 4]))
            model.setDisplayDetailsMonitoring(true)
            try await waitFor { model.displayWhiteBalanceLabel != nil && model.displayWhiteBalanceLabel != first }
            let replacement = model.displayWhiteBalanceLabel
            await barrier.release()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.displayWhiteBalanceLabel, replacement)
            await model.stopAndWait()
        }
    }

    func testCameraDispRecoversAfterNilScalarWithoutLosingDescriptor() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, dataType: 2, writable: true, current: 2, values: [2, 4]))
        let model = makeModel(camera: camera)
        model.setDisplayDetailsMonitoring(true)
        model.start()
        try await waitFor { model.displayWhiteBalanceLabel != nil }
        let first = model.displayWhiteBalanceLabel
        await camera.failRefresh(.whiteBalance)
        try await waitFor { model.displayWhiteBalanceLabel == nil }
        await camera.setProperty(.init(property: .whiteBalance, dataType: 2, writable: true, current: 4, values: [2, 4]))
        await camera.restoreRefresh(.whiteBalance)
        try await waitFor { model.displayWhiteBalanceLabel != nil && model.displayWhiteBalanceLabel != first }
        let calls = await camera.log
        XCTAssertGreaterThanOrEqual(calls.filter { $0 == "refresh:whiteBalance" }.count, 2)
    }

    func testCameraDispRefreshesWhiteBalanceDetailsAndClearsWhenDisabled() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .whiteBalance, dataType: 2, writable: true,
                                       current: 2, values: [1, 2, 4]))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.setDisplayDetailsMonitoring(true)
        model.start()
        try await waitFor(timeout: 5) { model.displayWhiteBalanceLabel != nil }
        XCTAssertNotNil(model.displayWhiteBalanceLabel)
        model.setDisplayDetailsMonitoring(false)
        XCTAssertNil(model.displayWhiteBalanceLabel)
    }

    func testUSBMovieStopFailureRetainsModesAndCanRetry() async throws {
        for throwsError in [false, true] {
            let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
            let model = makeModel(camera: camera)
            model.start()
            try await waitFor { model.state.session == .ready }
            model.toggleRecording()
            try await waitFor { model.state.capture == .recording && !model.recordingBusy }
            let baseline = await camera.log.count
            await camera.configureMovieStop(error: throwsError ? .responseCode(0x2002) : nil,
                                            response: 0x2002)
            model.toggleRecording()
            try await waitFor { !model.recordingBusy && model.state.recordingHint != nil }
            XCTAssertEqual(model.state.capture, .recording)
            let application = await camera.hasMovieApplicationMode()
            let control = await camera.hasRemoteControlMode()
            XCTAssertTrue(application)
            XCTAssertTrue(control)
            let failed = await camera.log
            XCTAssertFalse(failed.dropFirst(baseline).contains { $0.hasPrefix("app:off") || $0 == "control:off" })
            await camera.configureMovieStop()
            model.toggleRecording()
            try await waitFor { await camera.log.filter { $0 == "movie:end" }.count == 2 }
            await camera.queueEvents([.init(code: 0xC108, handle: 0)])
            try await waitFor { !model.recordingBusy && model.state.capture == .idle }
            let released = await camera.hasMovieApplicationMode()
            XCTAssertFalse(released)
            await model.stopAndWait()
        }
    }

    func testMovieStopTransportFailureUsesGlobalDisconnectWithoutStopHint() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        var losses = 0
        let model = makeModel(camera: camera, onTransportLost: { losses += 1 })
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy }
        await camera.configureMovieStop(error: .timeout)
        model.toggleRecording()
        try await waitFor { losses == 1 && !model.recordingBusy }
        XCTAssertNil(model.state.recordingHint)
        XCTAssertNil(model.frameImage)
        await model.stopAndWait()
        XCTAssertEqual(losses, 1)
    }

    func testWiFiMovieRecoveryRestartsLiveViewOnceAndWaitsForCompletionBeforeCleanup() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        await camera.queueMovieStarts([
            .init(responseCode: 0xA004, prohibitCondition: 1 << 14),
            .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
        ])
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor(timeout: 5) { model.state.capture == .recording && !model.recordingBusy }
        try await waitFor { model.state.session == .ready }

        let started = await camera.log
        let movieStarts = started.indices.filter { started[$0] == "movie:start" }
        XCTAssertEqual(movieStarts.count, 2)
        let recovery = Array(started[movieStarts[0]...movieStarts[1]])
        XCTAssertTrue(recovery.contains("end"))
        XCTAssertTrue(recovery.contains("app:on"))
        XCTAssertTrue(recovery.contains("set:liveViewImageSize"))
        XCTAssertTrue(recovery.contains("start"))

        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:end") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.recordingBusy, "application-mode stop waits for the completion event")
        let beforeEvent = await camera.log
        XCTAssertFalse(beforeEvent.contains("app:off:false"))
        await camera.queueEvents([.init(code: 0xC108, handle: 0)])
        try await waitFor(timeout: 3) { !model.recordingBusy }
        let stopped = await camera.log
        XCTAssertLessThan(try XCTUnwrap(stopped.firstIndex(of: "movie:end")),
                          try XCTUnwrap(stopped.firstIndex(of: "app:off:false")))
    }

    func testUSBMoviePreparesExistingSessionAndReturnsToOrdinaryLiveViewAfterStop() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor(timeout: 5) { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor(timeout: 5) {
            model.state.capture == .recording && !model.recordingBusy && model.state.session == .ready
        }
        let started = await camera.log
        let refresh = try XCTUnwrap(started.firstIndex(of: "usb:refresh"))
        XCTAssertLessThan(try XCTUnwrap(started[..<refresh].lastIndex(of: "end")), refresh)
        XCTAssertLessThan(refresh, try XCTUnwrap(started.firstIndex(of: "control:on")))
        XCTAssertLessThan(try XCTUnwrap(started.firstIndex(of: "control:on")),
                          try XCTUnwrap(started.firstIndex(of: "movie:prepared")))

        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:end") }
        await camera.queueEvents([.init(code: 0xC105, handle: 0)])
        try await waitFor(timeout: 3) { !model.recordingBusy && model.state.session == .ready }
        let stopped = await camera.log
        XCTAssertLessThan(try XCTUnwrap(stopped.firstIndex(of: "app:off:true")),
                          try XCTUnwrap(stopped.firstIndex(of: "control:off")))
        XCTAssertLessThan(try XCTUnwrap(stopped.firstIndex(of: "control:off")),
                          try XCTUnwrap(stopped.lastIndex(of: "start")))
    }

    func testUSBStandbyRetriesFailedReleaseBeforeRestartingLiveView() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy && model.state.session == .ready }
        await camera.configureControlResponses([0x2019, 0x2019, 0x2019, PTPConstants.responseOK])
        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:end") }
        await camera.queueEvents([.init(code: 0xC105, handle: 0)])
        try await waitFor(timeout: 6) {
            let released = await camera.log.filter { $0 == "control:off" }.count >= 4
            return released && model.state.session == .ready && !model.recordingBusy
        }
        let log = await camera.log
        let releases = log.indices.filter { log[$0] == "control:off" }
        XCTAssertEqual(releases.count, 4)
        let first = try XCTUnwrap(releases.first), last = try XCTUnwrap(releases.last)
        XCTAssertFalse(log[first..<last].contains("start"), "Do not restart LV while ControlMode release is still failing")
        XCTAssertTrue(log[(last + 1)...].contains("start"))
    }

    func testWiFiCompletionClearsApplicationWithoutRestartingOrReleasingManualControl() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        _ = try await camera.setRemoteDiagnosticControlMode(true)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready && model.computerControlEnabled }
        await camera.ensureMovieApplicationMode()
        await camera.queueEvents([.init(code: 0xC10A, handle: 0)])
        try await waitFor { model.state.capture == .recording }
        await camera.queueEvents([.init(code: 0xC105, handle: 0)])
        try await waitFor {
            let application = await camera.hasMovieApplicationMode()
            return model.state.capture == .idle && !application
        }
        let control = await camera.hasRemoteDiagnosticControlMode()
        let log = await camera.log
        XCTAssertTrue(control)
        XCTAssertTrue(model.computerControlEnabled)
        XCTAssertFalse(log.contains("end"))
        XCTAssertFalse(log.contains("control:off"))
        XCTAssertEqual(log.filter { $0 == "start" }.count, 1)
        XCTAssertTrue(log.contains("app:off:false"))
    }

    func testLeavingDuringUSBMovieStartStopsLateCameraRecordingWithoutDisconnecting() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        await camera.delayPreparedMovieStart(milliseconds: 250)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor(timeout: 5) { model.state.session == .ready }

        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:prepared") }
        await model.stopAndWait()

        let calls = await camera.log
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "movie:prepared")),
                          try XCTUnwrap(calls.firstIndex(of: "movie:end")))
        XCTAssertEqual(calls.last, "gate:false")
    }

    func testExposureStepsUseNearestAnchorAndLatestOptimisticValue() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .iso, writable: true, current: 300, values: [100, 200, 400, 800]))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.acceptWrites(.iso)
        model.stepExposure(.iso, delta: 1)
        XCTAssertEqual(model.exposureDescriptors[.iso]?.current, 400)
        model.stepExposure(.iso, delta: 1)
        XCTAssertEqual(model.exposureDescriptors[.iso]?.current, 800)
        try await waitFor { await camera.log.contains("write:iso:800") }
        let writes = await camera.log.filter { $0.hasPrefix("write:iso:") }
        XCTAssertEqual(writes, ["write:iso:800"])
    }

    func testExposureFallbackStepsUseAndroidLogicalPropertyAnchor() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.markUnsupported(.nikonShutter)
        await camera.setProperty(.init(property: .exposureTimeStandard, writable: true, current: 300, values: [100, 200, 400]))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.acceptWrites(.exposureTimeStandard)
        XCTAssertEqual(model.exposureDescriptors[.shutter]?.property, .exposureTimeStandard)
        // Android stepParam uses logical D100 for the off-enum anchor even
        // when the readable/writable fallback is 500D; do not invent a change.
        model.stepExposure(.shutter, delta: 1)
        XCTAssertEqual(model.exposureDescriptors[.shutter]?.current, 200)
        try await waitFor { await camera.log.contains("write:exposureTimeStandard:200") }
    }

    func testExposureWritesCoalesceAndOldInFlightResultCannotReplaceNewValue() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .iso, writable: true, current: 100, values: [100, 200, 400, 800]))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.acceptWrites(.iso)
        model.setExposure(.iso, value: 200, immediate: false)
        model.setExposure(.iso, value: 400, immediate: false)
        model.setExposure(.iso, value: 800, immediate: false)
        try await waitFor { await camera.log.contains("write:iso:800") }
        try await Task.sleep(for: .milliseconds(100))
        let writes = await camera.log.filter { $0.hasPrefix("write:iso:") }
        XCTAssertEqual(writes, ["write:iso:800"])
        await camera.delayWrites(milliseconds: 350)
        model.setExposure(.iso, value: 200)
        try await waitFor { await camera.log.contains("write:iso:200") }
        model.setExposure(.iso, value: 400)
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.iso.rawValue)])
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(model.exposureDescriptors[.iso]?.current, 400)
        try await waitFor { await camera.current(.iso) == 400 }
        await model.stopAndWait()
        let stopped = await camera.log
        try await Task.sleep(for: .milliseconds(200))
        let final = await camera.log
        XCTAssertEqual(stopped, final)
    }

    func testVerifiedWriteRetriesBusyAndConfirmsActualValue() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 100, values: [100, 200])
        await camera.setProperty(descriptor)
        await camera.acceptWrites(.iso)
        await camera.setWriteResponses(.iso, [0x2019, 0x2019, 0x2001])
        let result = try await camera.setRemotePropertyVerified(descriptor, value: 200)
        XCTAssertTrue(result.confirmed)
        XCTAssertEqual(result.actual?.current, 200)
        let writes = await camera.log.filter { $0 == "write:iso:200" }
        XCTAssertEqual(writes.count, 3)
    }

    func testAcceptedButUnadoptedValueIsNotConfirmedAndOnlyResentOnce() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 100, values: [100, 200])
        await camera.setProperty(descriptor)
        let result = try await camera.setRemotePropertyVerified(descriptor, value: 200)
        XCTAssertFalse(result.confirmed)
        XCTAssertEqual(result.actual?.current, 100)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "write:iso:200" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "refresh:iso" }.count, 5)
    }

    func testUnreadableWriteIsNotBlindlyResent() async throws {
        let camera = RemoteLifecycleCamera()
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 100, values: [100, 200])
        await camera.setProperty(descriptor)
        await camera.failRefresh(.iso)
        let result = try await camera.setRemotePropertyVerified(descriptor, value: 200)
        XCTAssertFalse(result.confirmed)
        XCTAssertNil(result.actual)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "write:iso:200" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "refresh:iso" }.count, 3)
    }

    func testMovieAutoISOFallsBackUsesNonzeroEnumAndIgnoresRepeatedTap() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        for property in [RemoteProperty.movieAutoISO, .nikonAutoISOAlternate] {
            await camera.setProperty(.init(property: property, dataType: 2, writable: true, current: 0, values: [0, 2]))
        }
        await camera.acceptWrites(.nikonAutoISOAlternate)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.setAutoISO(true)
        model.setAutoISO(false)
        XCTAssertTrue(model.autoISOBusy)
        try await waitFor { !model.autoISOBusy }
        XCTAssertEqual(model.autoISODescriptor?.property, .nikonAutoISOAlternate)
        XCTAssertEqual(model.autoISODescriptor?.current, 2)
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "write:movieAutoISO:2" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "write:nikonAutoISOAlternate:2" }.count, 1)
        XCTAssertFalse(calls.contains("write:movieAutoISO:0"))
    }

    func testAutoISOReadsEffectiveSensitivityAndStopsPollingWhenDisabled() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.setProperty(.init(property: .nikonAutoISO, dataType: 2, writable: true, current: 1, values: [0, 1]))
        await camera.setProperty(.init(property: .nikonISOControlSensitivity, writable: false, current: 640, values: []))
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.effectiveISO?.current == 640 }
        await camera.setProperty(.init(property: .nikonISOControlSensitivity, writable: false, current: 800, values: []))
        try await waitFor { model.effectiveISO?.current == 800 }
        await camera.setProperty(.init(property: .nikonAutoISO, dataType: 2, writable: true, current: 0, values: [0, 1]))
        await camera.queueEvents([.init(code: 0x4006, handle: RemoteProperty.nikonAutoISO.rawValue)])
        try await waitFor { !model.autoISOEnabled }
        XCTAssertNil(model.effectiveISO)
        let count = await camera.log.filter { $0 == "refresh:nikonISOControlSensitivity" }.count
        try await Task.sleep(for: .milliseconds(650))
        let later = await camera.log.filter { $0 == "refresh:nikonISOControlSensitivity" }.count
        XCTAssertEqual(count, later)
    }


    func testHalfPressAndCaptureWorkBeforeFirstLiveViewFrame() async throws {
        let camera = RemoteLifecycleCamera(failingFrames: 100)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { await camera.log.contains("frame") }
        XCTAssertNotEqual(model.state.session, .ready)
        model.beginHalfPress()
        XCTAssertTrue(model.halfPressVisualActive)
        model.endHalfPress(fire: true)
        try await waitFor { await camera.log.contains("capture") }
        let calls = await camera.log
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "halfpress:end")),
                          try XCTUnwrap(calls.firstIndex(of: "capture")))
    }

    func testRecordingHalfPressCanFocusAndReleaseToStop() async throws {
        let camera = RemoteLifecycleCamera(movie: true)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy }
        await camera.delayFocus(milliseconds: 120)
        model.beginHalfPress()
        XCTAssertTrue(model.halfPressVisualActive)
        XCTAssertEqual(model.state.capture, .recording)
        model.endHalfPress(fire: true)
        try await waitFor { await camera.log.contains("movie:end") }
        let calls = await camera.log
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "halfpress:end")),
                          try XCTUnwrap(calls.firstIndex(of: "movie:end")))
    }

    func testReleaseWaitsForAlreadyRunningTapFocusWhenHalfPressWasRejected() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayFocus(milliseconds: 300)
        model.focus(at: .init(x: 0.5, y: 0.5))
        try await waitFor { await camera.log.contains("tapfocus:start") }
        model.beginHalfPress()
        XCTAssertFalse(model.halfPressVisualActive)
        model.endHalfPress(fire: true)
        try await waitFor { await camera.log.contains("capture") }
        let calls = await camera.log
        XCTAssertFalse(calls.contains("halfpress:start"))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "tapfocus:end")),
                          try XCTUnwrap(calls.firstIndex(of: "capture")))
    }

    func testLeavingDuringHalfPressDrainsAFWithoutCancellingOrLateCapture() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayFocus(milliseconds: 300)
        model.beginHalfPress()
        try await waitFor { await camera.log.contains("halfpress:start") }
        model.endHalfPress(fire: true)
        XCTAssertEqual(model.state.capture, .capturing, "Busy starts immediately while AF drains")
        await model.stopAndWait()
        let calls = await camera.log
        XCTAssertTrue(calls.contains("halfpress:end"))
        XCTAssertFalse(calls.contains("halfpress:cancelled"))
        XCTAssertFalse(calls.contains("capture"))
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "halfpress:end")),
                          try XCTUnwrap(calls.firstIndex(of: "gate:false")))
    }

    func testLeavingDuringTapFocusWaitsForTransactionAndDiscardsLateUIResult() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.delayFocus(milliseconds: 300)
        model.focus(at: .init(x: 0.5, y: 0.5))
        try await waitFor { await camera.log.contains("tapfocus:start") }
        await model.stopAndWait()
        let calls = await camera.log
        XCTAssertTrue(calls.contains("tapfocus:end"))
        XCTAssertFalse(calls.contains("tapfocus:cancelled"))
        XCTAssertEqual(model.state.session, .idle)
        XCTAssertEqual(model.state.focus.phase, .idle)
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "tapfocus:end")),
                          try XCTUnwrap(calls.firstIndex(of: "gate:false")))
    }

    func testDiagnosticControlModeOwnsControlAndIsReleasedOnModelStop() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleComputerControl()
        try await waitFor { model.computerControlEnabled }
        let enabledDiagnostic = await camera.hasRemoteDiagnosticControlMode()
        let enabledControl = await camera.hasRemoteControlMode()
        XCTAssertTrue(enabledDiagnostic)
        XCTAssertTrue(enabledControl)
        let enabledLog = await camera.log
        XCTAssertTrue(enabledLog.contains("diagnostic:on"))

        await model.stopAndWait()
        let stoppedDiagnostic = await camera.hasRemoteDiagnosticControlMode()
        let stoppedControl = await camera.hasRemoteControlMode()
        XCTAssertFalse(stoppedDiagnostic)
        XCTAssertFalse(stoppedControl)
        let stoppedLog = await camera.log
        XCTAssertTrue(stoppedLog.contains("control:off"))
    }

    func testComputerControlStopsFramesRetainsImageAndRejectsDuplicateClicks() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.configureDiagnostic(delay: 150)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleComputerControl()
        model.toggleComputerControl()
        try await waitFor { await camera.log.contains("diagnostic:on") }
        let image = model.frameImage
        XCTAssertNotNil(image)
        XCTAssertTrue(model.computerControlBusy)
        XCTAssertFalse(model.computerControlToggleAllowed)
        let during = await camera.log
        let command = try XCTUnwrap(during.firstIndex(of: "diagnostic:on"))
        XCTAssertLessThan(try XCTUnwrap(during[..<command].lastIndex(of: "end")), command)
        XCTAssertEqual(during.filter { $0 == "diagnostic:on" }.count, 1)
        try await waitFor { model.computerControlEnabled && !model.computerControlBusy }
        XCTAssertNotNil(model.frameImage)
        try await waitFor { model.state.session == .ready }
        let after = await camera.log
        let accepted = try XCTUnwrap(after.firstIndex(of: "diagnostic:accepted:on"))
        XCTAssertFalse(after[command..<accepted].contains("frame"))
        XCTAssertLessThan(accepted, try XCTUnwrap(after.lastIndex(of: "start")))
    }

    func testComputerControlRefusalKeepsOwnerAndRestartsLiveView() async throws {
        let camera = RemoteLifecycleCamera()
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        await camera.configureDiagnostic(responses: [0xA004])
        model.toggleComputerControl()
        try await waitFor { !model.computerControlBusy && model.state.session == .ready }
        XCTAssertFalse(model.computerControlEnabled)
        model.toggleComputerControl()
        try await waitFor { model.computerControlEnabled && model.state.session == .ready }
        await camera.configureDiagnostic(responses: [0xA004])
        model.toggleComputerControl()
        try await waitFor { !model.computerControlBusy && model.state.session == .ready }
        XCTAssertTrue(model.computerControlEnabled)
        let physical = await camera.hasRemoteControlMode()
        let diagnostic = await camera.hasRemoteDiagnosticControlMode()
        XCTAssertTrue(physical)
        XCTAssertTrue(diagnostic)
    }

    func testCancelledReplacementNeverReleasesActiveMonitorCamera() async throws {
        let camera = RemoteLifecycleCamera()
        let first = makeModel(camera: camera)
        addTeardownBlock { await first.stopAndWait() }
        first.start()
        try await waitFor { first.state.session == .ready }
        let second = makeModel(camera: camera)
        second.start()
        await Task.yield()
        await second.stopAndWait()
        let calls = await camera.log
        XCTAssertEqual(calls.filter { $0 == "gate:true" }.count, 1)
        XCTAssertFalse(calls.contains("gate:false"))
        XCTAssertEqual(first.state.session, .ready)
        await first.stopAndWait()
    }

    func testReplacementMonitorWaitsForPreviousAcceptedControlAndCleanup() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.configureDiagnostic(delay: 200)
        let first = makeModel(camera: camera)
        first.start()
        try await waitFor { first.state.session == .ready }
        first.toggleComputerControl()
        try await waitFor { await camera.log.contains("diagnostic:on") }
        let stopping = Task { await first.stopAndWait() }
        let second = makeModel(camera: camera)
        addTeardownBlock { await second.stopAndWait() }
        second.start()
        await stopping.value
        try await waitFor { second.state.session == .ready }
        let calls = await camera.log
        let release = try XCTUnwrap(calls.firstIndex(of: "gate:false"))
        let acquired = try XCTUnwrap(calls.lastIndex(of: "gate:true"))
        XCTAssertLessThan(release, acquired)
        XCTAssertFalse(second.computerControlEnabled)
        await second.stopAndWait()
    }

    func testLeavingDuringComputerControlWaitsForAcceptedCommandBeforeReleasing() async throws {
        let camera = RemoteLifecycleCamera()
        await camera.configureDiagnostic(delay: 200)
        let model = makeModel(camera: camera)
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleComputerControl()
        try await waitFor { await camera.log.contains("diagnostic:on") }
        await model.stopAndWait()
        let calls = await camera.log
        let accepted = try XCTUnwrap(calls.firstIndex(of: "diagnostic:accepted:on"))
        let release = try XCTUnwrap(calls.firstIndex(of: "control:off"))
        XCTAssertLessThan(accepted, release)
        XCTAssertFalse(calls[accepted...].contains("start"))
        XCTAssertEqual(calls.last, "gate:false")
        XCTAssertFalse(model.computerControlEnabled)
        XCTAssertFalse(model.computerControlBusy)
        let diagnostic = await camera.hasRemoteDiagnosticControlMode()
        XCTAssertFalse(diagnostic)
    }

    func testUSBMovieReusesManualControlAndKeepsItUntilPageExit() async throws {
        let camera = RemoteLifecycleCamera(movie: true, isUSB: true)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.start()
        try await waitFor { model.state.session == .ready }
        model.toggleComputerControl()
        try await waitFor { model.computerControlEnabled && model.state.session == .ready }
        model.toggleRecording()
        try await waitFor { model.state.capture == .recording && !model.recordingBusy }
        XCTAssertFalse(model.computerControlToggleAllowed)
        let started = await camera.log
        XCTAssertTrue(started.contains("movie:prepared"))
        XCTAssertFalse(started.contains("usb:refresh"))
        model.toggleRecording()
        try await waitFor { await camera.log.contains("movie:end") }
        await camera.queueEvents([.init(code: 0xC105, handle: 0)])
        try await waitFor { !model.recordingBusy && model.state.capture == .idle }
        XCTAssertTrue(model.computerControlEnabled)
        let retained = await camera.hasRemoteDiagnosticControlMode()
        XCTAssertTrue(retained)
        let beforeExit = await camera.log
        XCTAssertFalse(beforeExit.contains("control:off"))
        // The Android page-exit fallback retries the release three times.
        await camera.configureControlResponses([0xA004, 0xA004, PTPConstants.responseOK])
        await model.stopAndWait()
        let ended = await camera.log
        XCTAssertEqual(ended.filter { $0 == "control:off" }.count, 3)
        XCTAssertLessThan(try XCTUnwrap(ended.firstIndex(of: "app:off:true")),
                          try XCTUnwrap(ended.firstIndex(of: "control:off")))
        let physical = await camera.hasRemoteControlMode()
        let diagnostic = await camera.hasRemoteDiagnosticControlMode()
        XCTAssertFalse(physical)
        XCTAssertFalse(diagnostic)
    }

    func testEntryRestoresManualControlAndHiddenToolCanReleaseBeforeFirstFrame() async throws {
        let camera = RemoteLifecycleCamera(isUSB: true)
        _ = try await camera.setRemoteDiagnosticControlMode(true)
        let model = makeModel(camera: camera)
        addTeardownBlock { await model.stopAndWait() }
        model.preferredComputerControl = true
        model.start()
        try await waitFor { model.computerControlEnabled }
        model.setComputerControl(false)
        try await waitFor { !model.computerControlEnabled && !model.computerControlBusy }
        try await waitFor { model.state.session == .ready }
        let calls = await camera.log
        XCTAssertTrue(calls.contains("diagnostic:off"))
        XCTAssertFalse(calls.contains("usb:refresh"))
    }

    private func waitFor(timeout: Double = 3, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for camera operation", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class RemoteMovieRulesTests: XCTestCase {
    func testLiveViewRestartMatchesAndroidProhibitMasks() {
        XCTAssertFalse(RemoteMovieStartResult(responseCode: PTPConstants.responseOK,
                                               prohibitCondition: nil).needsLiveViewRestart)
        for bit in [0, 1, 2, 3, 9, 10, 11] {
            XCTAssertFalse(RemoteMovieStartResult(responseCode: 0xA004,
                                                   prohibitCondition: 1 << bit).needsLiveViewRestart,
                           "bit \(bit) must not rebuild Live View")
        }
        for bit in [12, 14] {
            XCTAssertTrue(RemoteMovieStartResult(responseCode: 0xA004,
                                                  prohibitCondition: 1 << bit).needsLiveViewRestart,
                          "bit \(bit) requires the Android recovery path")
        }
        XCTAssertFalse(RemoteMovieStartResult(responseCode: 0xA004,
                                               prohibitCondition: 1 << 8).needsLiveViewRestart)
        XCTAssertTrue(RemoteMovieStartResult(responseCode: 0xA004,
                                              prohibitCondition: nil).needsLiveViewRestart)
        XCTAssertTrue(RemoteMovieStartResult(responseCode: PTPConstants.deviceBusy,
                                              prohibitCondition: 0).needsLiveViewRestart)
    }
}

@MainActor
private final class RemoteDecodedFrameCollector {
    var frames: [RemoteDecodedFrame] = []
}

private actor FramePublicationBarrier {
    private(set) var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func waitOnce() async {
        guard !reached else { return }
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class FrameAnalysisTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var milliseconds = 0
    func set(_ value: Int) { lock.lock(); defer { lock.unlock() }; milliseconds = value }
    func now() -> ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return origin.advanced(by: .milliseconds(milliseconds))
    }
}

final class RemoteFrameImageDecoderTests: XCTestCase {
    private func fixture(width: Int, height: Int, orientation: Int = 1,
                         colorSpace: CFString = CGColorSpace.sRGB) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(truncatingIfNeeded: x * 3 + y)
                pixels[i + 1] = UInt8(truncatingIfNeeded: x + y * 5)
                pixels[i + 2] = UInt8(truncatingIfNeeded: (x ^ y) * 7)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: colorSpace)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testPreparedJPEGPreservesEveryOrientationColorProfileAndPixel() throws {
        for color in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            for orientation in 1...8 {
                let data = try fixture(width: 96, height: 64, orientation: orientation, colorSpace: color)
                let reference = try XCTUnwrap(UIImage(data: data))
                let prepared = try XCTUnwrap(RemoteFrameImageDecoder.decode(data))
                let oldPixels = try XCTUnwrap(reference.cgImage), newPixels = try XCTUnwrap(prepared.cgImage)
                XCTAssertEqual(prepared.imageOrientation, reference.imageOrientation)
                XCTAssertEqual(prepared.size, reference.size)
                XCTAssertEqual(newPixels.colorSpace?.name, oldPixels.colorSpace?.name)
                XCTAssertEqual(try pixels(newPixels), try pixels(oldPixels))
            }
        }
    }

    func testNormalAndHDPreserveFullResolutionAndRejectInvalidPayload() throws {
        for size in [(640, 424), (1280, 720), (1920, 1080)] {
            let data = try fixture(width: size.0, height: size.1)
            let image = try XCTUnwrap(RemoteFrameImageDecoder.decode(data)?.cgImage)
            XCTAssertEqual(image.width, size.0); XCTAssertEqual(image.height, size.1)
            XCTAssertEqual(try pixels(image), try pixels(XCTUnwrap(UIImage(data: data)?.cgImage)))
        }
        XCTAssertNil(RemoteFrameImageDecoder.decode(Data()))
        XCTAssertNil(RemoteFrameImageDecoder.decode(Data([0xff, 0xd8, 0xff, 0x00])))
    }

    /// Diagnostic timings, not a device FPS assertion: include the first draw,
    /// since constructor timing alone incorrectly makes deferred decode look fast.
    func testFirstDrawCostBeforeAndAfterPreparingPixels() throws {
        for size in [(640, 424), (1920, 1080)] {
            let data = try fixture(width: size.0, height: size.1)
            let context = try XCTUnwrap(CGContext(data: nil, width: size.0, height: size.1,
                bitsPerComponent: 8, bytesPerRow: size.0 * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for prepared in [false, true] {
                var decodeSeconds = 0.0, drawSeconds = 0.0
                for _ in 0..<20 {
                    try autoreleasepool {
                        let begin = CACurrentMediaTime()
                        let image = try XCTUnwrap((prepared ? RemoteFrameImageDecoder.decode(data) : UIImage(data: data))?.cgImage)
                        let decoded = CACurrentMediaTime()
                        context.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
                        decodeSeconds += decoded - begin
                        drawSeconds += CACurrentMediaTime() - decoded
                    }
                }
                print("MONITOR_DECODE \(size.0)x\(size.1) prepared=\(prepared) prepare_ms=\(decodeSeconds * 50) first_draw_ms=\(drawSeconds * 50)")
            }
        }
    }
}

final class RemoteFrameDecodePipelineTests: XCTestCase {
    @MainActor
    func testWorkerBitmapsReuseWaveformUntil125msAndInvalidateOnModeSizeAndSession() async throws {
        let clock = FrameAnalysisTestClock(), collector = RemoteDecodedFrameCollector()
        let pipeline = RemoteFrameDecodePipeline(clock: { clock.now() }) { collector.frames.append($0) }
        var generation: UInt64 = 1
        await pipeline.reset(generation: generation)
        await pipeline.setAnalysis(histogram: false, zebra: false, waveform: true, falseColor: true)
        func feed(_ time: Int, side: Int = 8) async throws -> RemoteDecodedFrame {
            clock.set(time)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
            await pipeline.submit(.init(packet: .init(bytes: try XCTUnwrap(image.pngData()), jpegOffset: 0,
                operation: PTPConstants.getLiveViewImage), fps: 30, generation: generation))
            await pipeline.waitUntilIdle()
            return try XCTUnwrap(collector.frames.last)
        }
        let initial = try await feed(0)
        let first = try XCTUnwrap(initial.waveformImage)
        let firstFalse = try XCTUnwrap(initial.falseColorImage)
        XCTAssertEqual(first.width, 256); XCTAssertEqual(first.height, 128)
        XCTAssertEqual(firstFalse.width, 8); XCTAssertEqual(firstFalse.height, 8)
        let expected = RemoteExposureAnalysis.waveformPixels(channels: try XCTUnwrap(initial.waveform), sampleHeight: 8)
        let bitmap = try XCTUnwrap(RemoteExposureAnalysis.image(pixels: expected, width: 256, height: 128))
        XCTAssertEqual(first.dataProvider?.data, bitmap.dataProvider?.data)
        let early = try await feed(124)
        XCTAssertTrue(early.waveformImage === first)
        XCTAssertFalse(early.falseColorImage === firstFalse, "False color still follows each decoded frame")
        let next = try await feed(125)
        XCTAssertFalse(next.waveformImage === first)
        await pipeline.setAnalysis(histogram: false, zebra: false, waveform: true, waveformRGB: true, falseColor: true)
        let rgb = try await feed(125)
        XCTAssertEqual(rgb.waveform?.count, 3)
        XCTAssertFalse(rgb.waveformImage === next.waveformImage)
        let resized = try await feed(125, side: 12)
        XCTAssertFalse(resized.waveformImage === rgb.waveformImage)
        XCTAssertEqual(resized.falseColorImage?.width, 12)
        generation = 2
        await pipeline.reset(generation: generation)
        let reset = try await feed(125, side: 12)
        XCTAssertFalse(reset.waveformImage === resized.waveformImage)
        await pipeline.setAnalysis(histogram: false, zebra: false)
        let disabled = try await feed(125)
        XCTAssertNil(disabled.falseColorImage); XCTAssertNil(disabled.waveformImage)
        XCTAssertNil(disabled.falseColorPixels); XCTAssertNil(disabled.waveform)
    }

    @MainActor
    func testPipelinePublicationRejectsMultipleModeChangesAndSessionReset() async throws {
        for resetSession in [false, true] {
            let barrier = FramePublicationBarrier()
            let collector = RemoteDecodedFrameCollector()
            let pipeline = RemoteFrameDecodePipeline(beforePublication: { await barrier.waitOnce() }) {
                collector.frames.append($0)
            }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let data = try XCTUnwrap(image.pngData())
            func request(_ generation: UInt64) -> RemoteFrameDecodePipeline.Request {
                .init(packet: .init(bytes: data, jpegOffset: 0, operation: PTPConstants.getLiveViewImage),
                      fps: 1, generation: generation)
            }
            await pipeline.reset(generation: 1)
            await pipeline.setAnalysis(histogram: true, zebra: true, waveform: true)
            await pipeline.submit(request(1))
            let deadline = ContinuousClock.now + .seconds(2)
            while !(await barrier.reached), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            let reached = await barrier.reached
            XCTAssertTrue(reached)
            XCTAssertTrue(collector.frames.isEmpty)
            await pipeline.setAnalysis(histogram: false, zebra: false)
            await pipeline.setAnalysis(histogram: true, zebra: false, waveform: true, waveformRGB: true, histogramRGB: true)
            await pipeline.setAnalysis(histogram: true, zebra: false, waveform: true)
            await pipeline.setAnalysis(histogram: true, zebra: false, waveform: true, waveformRGB: true, histogramRGB: true)
            if resetSession {
                await pipeline.reset(generation: 2)
                await pipeline.submit(request(2))
            }
            await barrier.release()
            await pipeline.waitUntilIdle()
            XCTAssertEqual(collector.frames.count, 1)
            let frame = try XCTUnwrap(collector.frames.first)
            XCTAssertEqual(frame.generation, resetSession ? 2 : 1)
            XCTAssertEqual(frame.waveform?.count, 3)
            XCTAssertEqual(frame.histogramRGB?.count, 3)
            XCTAssertNil(frame.zebraMask)
        }
    }

    @MainActor
    func testQueuedPublicationCannotOutliveInvalidation() async {
        let obsolete = RemoteFramePublicationPermit()
        var values: [Int] = []
        let queued = Task { @MainActor in obsolete.deliver { values.append(1) } }
        // The child cannot run on this actor until this method suspends.
        obsolete.invalidate()
        let delivered = await queued.value
        XCTAssertFalse(delivered)
        XCTAssertTrue(values.isEmpty)
        let current = RemoteFramePublicationPermit()
        XCTAssertTrue(current.deliver { values.append(2) })
        current.invalidate()
        XCTAssertFalse(current.deliver { values.append(3) })
        XCTAssertEqual(values, [2])
    }

    @MainActor
    func testAnalysisCacheInvalidatesForDimensionsAndSessionAtSameTime() async throws {
        let clock = FrameAnalysisTestClock()
        let collector = RemoteDecodedFrameCollector()
        let pipeline = RemoteFrameDecodePipeline(clock: { clock.now() }) { collector.frames.append($0) }
        await pipeline.reset(generation: 1)
        await pipeline.setAnalysis(histogram: true, zebra: true, waveform: true, histogramRGB: true)
        func feed(_ side: Int, white: Bool, generation: UInt64) async throws -> RemoteDecodedFrame {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
                (white ? UIColor.white : UIColor.black).setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
            await pipeline.submit(.init(packet: .init(bytes: try XCTUnwrap(image.pngData()), jpegOffset: 0,
                operation: PTPConstants.getLiveViewImage), fps: 1, generation: generation))
            await pipeline.waitUntilIdle()
            return try XCTUnwrap(collector.frames.last)
        }
        _ = try await feed(8, white: false, generation: 1)
        let resized = try await feed(12, white: true, generation: 1)
        XCTAssertEqual(resized.histogram?[255], 144)
        XCTAssertEqual(resized.histogramRGB?.map { $0[255] }, [144, 144, 144])
        XCTAssertEqual(resized.waveform?.first?.prefix(256).reduce(0, +), 144)
        XCTAssertTrue(try XCTUnwrap(resized.zebraMask).cells.allSatisfy { $0 })
        await pipeline.reset(generation: 2)
        let reset = try await feed(12, white: false, generation: 2)
        XCTAssertEqual(reset.histogram?[0], 144)
        XCTAssertEqual(reset.histogramRGB?.map { $0[0] }, [144, 144, 144])
        XCTAssertEqual(reset.waveform?.first?.suffix(256).reduce(0, +), 144)
        XCTAssertTrue(try XCTUnwrap(reset.zebraMask).cells.allSatisfy { !$0 })
    }

    @MainActor
    func testInFlightWaveformModeChangeRejectsOldAnalysisAndReprocessesLatestFrame() async throws {
        let collector = RemoteDecodedFrameCollector()
        let pipeline = RemoteFrameDecodePipeline(decodeDelayNanoseconds: 100_000_000) { collector.frames.append($0) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        await pipeline.reset(generation: 1)
        await pipeline.setAnalysis(histogram: false, zebra: false, waveform: true)
        await pipeline.submit(.init(packet: .init(bytes: try XCTUnwrap(image.pngData()), jpegOffset: 0,
            operation: PTPConstants.getLiveViewImage), fps: 1, generation: 1))
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await pipeline.isDecoding), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let decoding = await pipeline.isDecoding
        XCTAssertTrue(decoding)
        await pipeline.setAnalysis(histogram: false, zebra: false, waveform: true, waveformRGB: true)
        await pipeline.waitUntilIdle()
        XCTAssertEqual(collector.frames.count, 1)
        XCTAssertEqual(collector.frames.first?.waveform?.count, 3)
    }

    @MainActor
    func testExactAnalysisCadenceAndHistogramModeSwitches() async throws {
        let clock = FrameAnalysisTestClock()
        let collector = RemoteDecodedFrameCollector()
        let pipeline = RemoteFrameDecodePipeline(clock: { clock.now() }) { collector.frames.append($0) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func encoded(_ white: Bool) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
                (white ? UIColor.white : UIColor.black).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            return try XCTUnwrap(image.pngData())
        }
        let black = try encoded(false), white = try encoded(true)
        func feed(_ time: Int, _ data: Data) async throws -> RemoteDecodedFrame {
            clock.set(time)
            await pipeline.submit(.init(packet: .init(bytes: data, jpegOffset: 0,
                operation: PTPConstants.getLiveViewImage), fps: 1, generation: 1))
            await pipeline.waitUntilIdle()
            return try XCTUnwrap(collector.frames.last)
        }
        await pipeline.reset(generation: 1)
        await pipeline.setAnalysis(histogram: true, zebra: true, histogramRGB: true)
        _ = try await feed(0, black)
        let beforeZebra = try await feed(49, white)
        XCTAssertTrue(try XCTUnwrap(beforeZebra.zebraMask).cells.allSatisfy { !$0 })
        let zebra = try await feed(50, white)
        XCTAssertTrue(try XCTUnwrap(zebra.zebraMask).cells.allSatisfy { $0 })
        let beforeHistogram = try await feed(249, white)
        XCTAssertEqual(beforeHistogram.histogram?[0], 64)
        XCTAssertEqual(beforeHistogram.histogramRGB?.map { $0[0] }, [64, 64, 64])
        let histogram = try await feed(250, white)
        XCTAssertEqual(histogram.histogram?[255], 64)
        XCTAssertEqual(histogram.histogramRGB?.map { $0[255] }, [64, 64, 64])
        await pipeline.setAnalysis(histogram: true, zebra: true, histogramRGB: false)
        let luma = try await feed(251, black)
        XCTAssertEqual(luma.histogram?[255], 64)
        XCTAssertNil(luma.histogramRGB)
        await pipeline.setAnalysis(histogram: false, zebra: true)
        _ = try await feed(252, black)
        await pipeline.setAnalysis(histogram: true, zebra: true)
        _ = try await feed(253, black)
        await pipeline.setAnalysis(histogram: true, zebra: true, histogramRGB: true)
        let rgb = try await feed(254, white)
        XCTAssertEqual(rgb.histogram?[255], 64, "Missing RGB forces both channels to refresh immediately")
        XCTAssertEqual(rgb.histogramRGB?.map { $0[255] }, [64, 64, 64])
    }

    @MainActor
    func testZebraRefreshesBeforeSharedRGBHistogram() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let black = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let white = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let collector = RemoteDecodedFrameCollector()
        let pipeline = RemoteFrameDecodePipeline { collector.frames.append($0) }
        await pipeline.reset(generation: 1)
        await pipeline.setAnalysis(histogram: true, zebra: true, histogramRGB: true)
        func submit(_ image: UIImage) async throws {
            await pipeline.submit(.init(packet: .init(bytes: try XCTUnwrap(image.pngData()), jpegOffset: 0,
                operation: PTPConstants.getLiveViewImage), fps: 1, generation: 1))
            await pipeline.waitUntilIdle()
        }
        try await submit(black)
        try await Task.sleep(for: .milliseconds(70))
        try await submit(white)
        let early = try XCTUnwrap(collector.frames.last)
        XCTAssertTrue(try XCTUnwrap(early.zebraMask).cells.allSatisfy { $0 })
        XCTAssertEqual(early.histogram?[0], 64)
        XCTAssertEqual(early.histogramRGB?.map { $0[0] }, [64, 64, 64])
        try await Task.sleep(for: .milliseconds(260))
        try await submit(white)
        let late = try XCTUnwrap(collector.frames.last)
        XCTAssertEqual(late.histogram?[255], 64)
        XCTAssertEqual(late.histogramRGB?.map { $0[255] }, [64, 64, 64])
    }

    @MainActor
    func testNonuniformAnalysisUsesScaledPixelCenters() async throws {
        let width = 319, height = 241
        func bright(_ x: Int, _ y: Int) -> Bool { (x / 7 + y / 11) % 2 == 0 }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = bright(x, y) ? 255 : 0
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = value }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let collector = RemoteDecodedFrameCollector()
        let pipeline = RemoteFrameDecodePipeline { collector.frames.append($0) }
        await pipeline.reset(generation: 1)
        await pipeline.setAnalysis(histogram: true, zebra: true, waveform: true, falseColor: true)
        await pipeline.submit(.init(packet: .init(bytes: try XCTUnwrap(UIImage(cgImage: cg).pngData()), jpegOffset: 0,
            operation: PTPConstants.getLiveViewImage), fps: 1, generation: 1))
        await pipeline.waitUntilIdle()
        let frame = try XCTUnwrap(collector.frames.last)
        let zebra = try XCTUnwrap(frame.zebraMask)
        func expected(_ cols: Int, _ rows: Int) -> [Bool] {
            (0..<rows).flatMap { y in
                (0..<cols).map { x in
                    bright((2 * x + 1) * width / (2 * cols), (2 * y + 1) * height / (2 * rows))
                }
            }
        }
        XCTAssertEqual(zebra.cells, expected(zebra.cols, zebra.rows))
        let monitor = expected(256, 192)
        XCTAssertEqual(frame.falseColorPixels, monitor.map { $0 ? UInt32(0xFFF14D4D) : UInt32(0xFF6B39B8) })
        let waveform = try XCTUnwrap(frame.waveform?.first)
        for x in 0..<256 {
            let whites = (0..<192).filter { monitor[$0 * 256 + x] }.count
            XCTAssertEqual(waveform[x], whites)
            XCTAssertEqual(waveform[127 * 256 + x], 192 - whites)
        }
        let whites = stride(from: 0, to: height, by: 2).reduce(0) { total, y in
            total + stride(from: 0, to: width, by: 2).filter { bright($0, y) }.count
        }
        XCTAssertEqual(frame.histogram?[255], whites)
        XCTAssertEqual(frame.histogram?[0], 19360 - whites)
    }

    @MainActor
    func testMonitorAnalysisSharesBoundedDimensionsForLargeAndNarrowFrames() async throws {
        for (width, height, sampledWidth, sampledHeight) in [(1920, 1080, 256, 192), (319, 241, 256, 192), (17, 300, 17, 192)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            let collector = RemoteDecodedFrameCollector()
            let pipeline = RemoteFrameDecodePipeline { collector.frames.append($0) }
            await pipeline.reset(generation: 1)
            await pipeline.setAnalysis(histogram: false, zebra: false, waveform: true, falseColor: true)
            await pipeline.submit(.init(packet: .init(bytes: try XCTUnwrap(image.pngData()), jpegOffset: 0,
                operation: PTPConstants.getLiveViewImage), fps: 1, generation: 1))
            await pipeline.waitUntilIdle()
            let frame = try XCTUnwrap(collector.frames.last)
            XCTAssertEqual(frame.falseColorWidth, sampledWidth)
            XCTAssertEqual(frame.falseColorHeight, sampledHeight)
            XCTAssertEqual(frame.falseColorPixels, Array(repeating: 0xFF50555B, count: sampledWidth * sampledHeight))
            XCTAssertEqual(frame.waveform?.first?.reduce(0, +), sampledWidth * sampledHeight)
            XCTAssertEqual(frame.image.cgImage?.width, width)
            XCTAssertEqual(frame.image.cgImage?.height, height)
        }
    }

    @MainActor
    func testHistogramSamplesBothAxesAtFullHDAndNondivisibleDimensions() async throws {
        for (width, height, expected) in [(1920, 1080, 20736), (319, 241, 19360)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            let collector = RemoteDecodedFrameCollector()
            let pipeline = RemoteFrameDecodePipeline { collector.frames.append($0) }
            await pipeline.reset(generation: 1)
            await pipeline.setAnalysis(histogram: true, zebra: false, histogramRGB: true)
            await pipeline.submit(.init(packet: .init(bytes: try XCTUnwrap(image.pngData()), jpegOffset: 0,
                operation: PTPConstants.getLiveViewImage), fps: 1, generation: 1))
            await pipeline.waitUntilIdle()
            let frame = try XCTUnwrap(collector.frames.last)
            XCTAssertEqual(frame.histogram?.reduce(0, +), expected)
            XCTAssertEqual(frame.histogram?[53], expected)
            XCTAssertEqual(frame.histogramRGB?.map { $0.reduce(0, +) }, [expected, expected, expected])
            XCTAssertEqual(frame.histogramRGB?[0][255], expected)
            XCTAssertEqual(frame.histogramRGB?[1][0], expected)
            XCTAssertEqual(frame.histogramRGB?[2][0], expected)
        }
    }

    @MainActor
    func testDecodedPrimaryColorsUseMonitorWeightsWithoutChangingHistogram() async throws {
        for (color, row, histogramBin, falseColor): (UIColor, Int, Int, UInt32) in [
            (.red, 90, 53, 0xFF50555B), (.green, 53, 182, 0xFFB9BDC2), (.blue, 114, 18, 0xFF2874D7)
        ] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            // Lossless encoded input isolates analysis from JPEG quantization.
            let encoded = try XCTUnwrap(image.pngData())
            let collector = RemoteDecodedFrameCollector()
            let pipeline = RemoteFrameDecodePipeline { collector.frames.append($0) }
            await pipeline.reset(generation: 1)
            await pipeline.setAnalysis(histogram: true, zebra: true, waveform: true, falseColor: true)
            await pipeline.submit(.init(packet: .init(bytes: encoded, jpegOffset: 0,
                operation: PTPConstants.getLiveViewImage), fps: 1, generation: 1))
            await pipeline.waitUntilIdle()
            let frame = try XCTUnwrap(collector.frames.last)
            XCTAssertEqual(frame.falseColorPixels, Array(repeating: falseColor, count: 64))
            let waveform = try XCTUnwrap(frame.waveform?.first)
            XCTAssertEqual(waveform.reduce(0, +), 64)
            for column in stride(from: 0, to: 256, by: 32) {
                XCTAssertEqual(waveform[row * 256 + column], 8)
            }
            XCTAssertEqual(frame.histogram?[histogramBin], 64)
            XCTAssertEqual(frame.histogram?.reduce(0, +), 64)
        }
    }

    func testPipelineConflatesPendingFramesRunsAnalysisOffMainAndRejectsOldGeneration() async throws {
        let collector = await MainActor.run { RemoteDecodedFrameCollector() }
        let pipeline = RemoteFrameDecodePipeline(decodeDelayNanoseconds: 80_000_000) { frame in
            collector.frames.append(frame)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        func request(_ fps: Double, generation: UInt64) -> RemoteFrameDecodePipeline.Request {
            .init(packet: .init(bytes: jpeg, jpegOffset: 0,
                                operation: PTPConstants.getLiveViewImage),
                  fps: fps, generation: generation)
        }

        await pipeline.reset(generation: 1)
        await pipeline.setAnalysis(histogram: true, zebra: true, falseColor: true)
        await pipeline.submit(request(1, generation: 1))
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await pipeline.isDecoding), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        await pipeline.submit(request(2, generation: 1))
        await pipeline.submit(request(3, generation: 1))
        await pipeline.submit(request(4, generation: 1))
        await pipeline.waitUntilIdle()
        var frames = await MainActor.run { collector.frames }
        XCTAssertEqual(frames.map(\.fps), [1, 4])
        XCTAssertEqual(frames.last?.histogram?.count, 256)
        XCTAssertNotNil(frames.last?.zebraMask)
        XCTAssertEqual(frames.last?.falseColorPixels?.count, 72 * 48)
        XCTAssertEqual(frames.last?.falseColorWidth, 72)
        XCTAssertEqual(frames.last?.falseColorHeight, 48)

        await pipeline.submit(request(5, generation: 1))
        while !(await pipeline.isDecoding), ContinuousClock.now < deadline + .seconds(1) {
            try await Task.sleep(for: .milliseconds(1))
        }
        await pipeline.reset(generation: 2)
        await pipeline.setAnalysis(histogram: false, zebra: false, falseColor: false)
        await pipeline.submit(request(6, generation: 2))
        await pipeline.waitUntilIdle()
        frames = await MainActor.run { collector.frames }
        XCTAssertEqual(frames.map(\.fps), [1, 4, 6])
        XCTAssertNil(frames.last?.histogram)
        XCTAssertNil(frames.last?.zebraMask)
        XCTAssertNil(frames.last?.falseColorPixels)
    }
}

private actor RemoteLifecycleCamera: RemoteCameraControlling {
    nonisolated let isUSB: Bool
    private(set) var log: [String] = []
    private var movie: Bool
    private let model: String?
    private var failingFrames: Int
    func failNextFrames(_ count: Int) { failingFrames = count }
    private var successfulFrameLimit: Int?
    private(set) var successfulFrameCount = 0
    func limitSuccessfulFrames(to count: Int) { successfulFrameLimit = count }
    private var transportFailure: Bool
    private var batteryEvent = false
    private var overrides: [RemoteProperty: RemotePropertyDescriptor] = [:]
    private var unsupported = Set<RemoteProperty>()
    private var propertyErrors: [RemoteProperty: PTPSessionError] = [:]
    private var propertyDelays: [RemoteProperty: Int] = [:]
    private var refreshFailures = Set<RemoteProperty>()
    private var deviceModelProbe: (@Sendable () async -> Void)?
    private var refreshResponseProbes: [RemoteProperty: @Sendable () async -> Void] = [:]
    private var propertyResponseProbes: [RemoteProperty: @Sendable () async -> Void] = [:]
    private var meterRefreshProbe: (@Sendable () async -> Void)?
    private var queuedEvents: [STAEvent] = []
    private var captureFails = false
    private var acceptedWrites = Set<RemoteProperty>()
    private var writeResponses: [RemoteProperty: [UInt16]] = [:]
    private var writeDelay = 0
    private var focusDelay = 0
    private var focusResults: [RemoteFocusResult] = []
    private var trackingReleaseResponse: UInt16? = nil
    private var movieStarts: [RemoteMovieStartResult] = []
    private var preparedMovieStartDelay = 0
    private var remoteControlMode = false
    private var remoteDiagnosticControlMode = false
    private var diagnosticDelay = 0
    private var diagnosticResponses: [UInt16] = []
    private var controlResponses: [UInt16] = []
    private var applicationMode = false
    private var monitorIDs: [UInt32] = []
    private var monitorFreeBytes: [UInt32: Int64] = [:]
    private var monitorErrors: [UInt32: PTPSessionError] = [:]
    private var monitorIDsError: PTPSessionError?
    private var monitorAdmissionProbe: (@Sendable () async -> Void)?
    private var monitorResponseProbe: (@Sendable () async -> Void)?
    func setMonitorAdmissionProbe(_ probe: @escaping @Sendable () async -> Void) { monitorAdmissionProbe = probe }
    func setMonitorResponseProbe(_ probe: @escaping @Sendable () async -> Void) { monitorResponseProbe = probe }
    private var frame: Data
    func replaceFrame(data: Data) { frame = data; enhancedFrame = nil }
    func replaceFrame(size: CGSize) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        frame = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.5)!
    }
    init(movie: Bool = false, failingFrames: Int = 0, isUSB: Bool = false,
         model: String? = nil,
         transportFailure: Bool = false, frameSize: CGSize = CGSize(width: 8, height: 8)) {
        self.movie = movie
        self.model = model
        self.failingFrames = failingFrames
        self.isUSB = isUSB
        self.transportFailure = transportFailure
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        self.frame = UIGraphicsImageRenderer(size: frameSize, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: frameSize))
        }.jpegData(compressionQuality: 0.5)!
    }
    func setRemoteActive(_ active: Bool) { log.append("gate:\(active)") }
    func startLiveView() { log.append("start") }
    func endLiveView() { log.append("end") }
    func liveViewFrame() async throws -> RemoteLiveViewPacket {
        log.append("frame")
        do { try await Task.sleep(for: .milliseconds(20)) }
        catch { log.append("cancelled-frame"); throw error }
        if transportFailure { transportFailure = false; throw PTPSessionError.timeout }
        if failingFrames > 0 { failingFrames -= 1; throw PTPSessionError.responseCode(0xA004) }
        if let successfulFrameLimit, successfulFrameCount >= successfulFrameLimit {
            throw PTPSessionError.responseCode(PTPConstants.deviceBusy)
        }
        successfulFrameCount += 1
        if let enhancedFrame {
            return .init(bytes: enhancedFrame, jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx,
                         receivedAtUptime: ProcessInfo.processInfo.systemUptime - frameAge)
        }
        return .init(bytes: frame, jpegOffset: 0, operation: PTPConstants.getLiveViewImage)
    }
    private var enhancedFrame: Data?
    private var frameAge: TimeInterval = 0
    func setAttitudeFrame(roll: Float, pitch: Float, age: TimeInterval = 0) {
        var bytes = [UInt8](repeating: 0, count: 512)
        func put16(_ offset: Int, _ value: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
        }
        func put32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> (24-i*8)) }
        }
        put16(0, 1); put32(8, 512); put32(12, UInt32(frame.count))
        put16(16, 2000); put16(18, 1200); put16(28, 200); put16(30, 120)
        put32(404, UInt32((roll < 0 ? roll + 360 : roll) * 65536))
        put32(408, UInt32((pitch < 0 ? pitch + 360 : pitch) * 65536))
        enhancedFrame = Data(bytes) + frame
        frameAge = age
    }
    func remoteDeviceModel() async -> String? {
        if let probe = deviceModelProbe { deviceModelProbe = nil; await probe() }
        return model
    }
    func holdNextDeviceModel(_ probe: @escaping @Sendable () async -> Void) { deviceModelProbe = probe }
    func holdNextRefresh(_ property: RemoteProperty, _ probe: @escaping @Sendable () async -> Void) {
        refreshResponseProbes[property] = probe
    }
    func remoteMovieMode() -> Bool? {
        log.append("selector")
        return overrides[.liveViewSelector].map { $0.current != 0 } ?? movie
    }
    func monitorStorageIDs() throws -> [UInt32] {
        log.append("storage:ids")
        if let monitorIDsError { throw monitorIDsError }
        return monitorIDs
    }
    func monitorFreeBytes(storageID: UInt32, allowed: @escaping @Sendable () async -> Bool) async throws -> Int64? {
        if let probe = monitorAdmissionProbe { monitorAdmissionProbe = nil; await probe() }
        guard await allowed() else { return nil }
        log.append("storage:free:\(storageID)")
        let error = monitorErrors[storageID], value = monitorFreeBytes[storageID]
        if let probe = monitorResponseProbe { monitorResponseProbe = nil; await probe() }
        if let error { throw error }
        return value
    }
    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? {
        log.append("property:\(property)")
        if let probe = propertyResponseProbes.removeValue(forKey: property) {
            let captured = overrides[property]
            await probe()
            return captured
        }
        if let delay = propertyDelays[property] {
            do { try await Task.sleep(for: .milliseconds(delay)) }
            catch { log.append("cancelled-property:\(property)"); throw error }
        }
        if let error = propertyErrors[property] { throw error }
        if unsupported.contains(property) { return nil }
        if let descriptor = overrides[property] { return descriptor }
        return .init(property: property, dataType: property == .batteryLevel ? 0x0002 : 0x0006, writable: true,
                     current: property == .liveViewSelector ? (movie ? 1 : 0) : 0, values: [0, 1])
    }
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) async -> RemotePropertyDescriptor? {
        if let probe = refreshResponseProbes.removeValue(forKey: descriptor.property) {
            let captured = overrides[descriptor.property] ?? descriptor
            await probe()
            return captured
        }
        if descriptor.property == .nikonLightMeter, let probe = meterRefreshProbe {
            meterRefreshProbe = nil
            let captured = overrides[descriptor.property] ?? descriptor
            await probe()
            return captured
        }
        log.append("refresh:\(descriptor.property)")
        if refreshFailures.contains(descriptor.property) { return nil }
        return overrides[descriptor.property] ?? descriptor
    }
    func remoteFocusMode() -> RemotePropertyDescriptor? {
        log.append("focus")
        if let standard = overrides[.focusMode],
           RemoteFocusMode.label(property: .focusMode, value: standard.current) != nil {
            return standard
        }
        if let still = overrides[.stillFocusMode],
           RemoteFocusMode.label(property: .stillFocusMode, value: still.current) != nil {
            return still
        }
        if let vendor = overrides[.nikonAFMode],
           RemoteFocusMode.label(property: .nikonAFMode, value: vendor.current) != nil {
            return vendor
        }
        return nil
    }
    func emitBatteryEvent() { batteryEvent = true }
    func setProperty(_ descriptor: RemotePropertyDescriptor) { overrides[descriptor.property] = descriptor }
    func setMonitorStorage(ids: [UInt32], free: [UInt32: Int64], errors: [UInt32: PTPSessionError] = [:], idsError: PTPSessionError? = nil) {
        monitorIDs = ids
        monitorFreeBytes = free
        monitorErrors = errors
        monitorIDsError = idsError
    }
    func holdNextProperty(_ property: RemoteProperty, _ probe: @escaping @Sendable () async -> Void) {
        propertyResponseProbes[property] = probe
    }
    func delayProperty(_ property: RemoteProperty, milliseconds: Int) { propertyDelays[property] = milliseconds }
    func failProperty(_ property: RemoteProperty, error: PTPSessionError) { propertyErrors[property] = error }
    func markUnsupported(_ property: RemoteProperty) { unsupported.insert(property) }
    func holdNextMeterRefresh(_ probe: @escaping @Sendable () async -> Void) { meterRefreshProbe = probe }
    func restoreRefresh(_ property: RemoteProperty) { refreshFailures.remove(property) }
    func failRefresh(_ property: RemoteProperty) { refreshFailures.insert(property) }
    func queueEvents(_ events: [STAEvent]) { queuedEvents += events }
    func changeMovieMode(_ value: Bool) { movie = value }
    func queueMovieStarts(_ results: [RemoteMovieStartResult]) { movieStarts += results }
    func failCapture() { captureFails = true }
    func acceptWrites(_ property: RemoteProperty) { acceptedWrites.insert(property) }
    func setWriteResponses(_ property: RemoteProperty, _ codes: [UInt16]) { writeResponses[property] = codes }
    func delayFocus(milliseconds: Int) { focusDelay = milliseconds }
    func queueFocusResults(_ results: [RemoteFocusResult]) { focusResults += results }
    func delayWrites(milliseconds: Int) { writeDelay = milliseconds }
    func delayPreparedMovieStart(milliseconds: Int) { preparedMovieStartDelay = milliseconds }
    func current(_ property: RemoteProperty) -> UInt64? { overrides[property]?.current }
    func remoteEvents() -> [STAEvent] {
        log.append("events")
        defer { batteryEvent = false; queuedEvents = [] }
        return queuedEvents + (batteryEvent ? [.init(code: 0x4006, handle: RemoteProperty.batteryLevel.rawValue)] : [])
    }
    func remoteKeepalive() { log.append("keepalive") }
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws {
        log.append("set:\(descriptor.property)")
        log.append("write:\(descriptor.property):\(value)")
        if writeDelay > 0 { try await Task.sleep(for: .milliseconds(writeDelay)) }
        if let code = writeResponses[descriptor.property]?.first {
            writeResponses[descriptor.property]?.removeFirst()
            if code != 0x2001 { throw PTPSessionError.responseCode(code) }
        }
        if acceptedWrites.contains(descriptor.property) {
            var actual = descriptor
            actual.current = value
            overrides[descriptor.property] = actual
        }
    }
    func capturePhoto() throws {
        log.append("capture")
        if captureFails { throw PTPSessionError.responseCode(0xA004) }
    }
    private(set) var lastFocusCoordinates: [UInt32]?
    func focusAt(trackingX: UInt32, trackingY: UInt32, focusX: UInt32, focusY: UInt32) async throws -> RemoteFocusResult {
        lastFocusCoordinates = [trackingX, trackingY, focusX, focusY]
        return try await finishFocus("tapfocus")
    }
    func halfPressFocus() async throws -> RemoteFocusResult { try await finishFocus("halfpress") }
    private func finishFocus(_ prefix: String) async throws -> RemoteFocusResult {
        log.append("\(prefix):start")
        do { if focusDelay > 0 { try await Task.sleep(for: .milliseconds(focusDelay)) } }
        catch { log.append("\(prefix):cancelled"); throw error }
        log.append("\(prefix):end")
        if !focusResults.isEmpty { return focusResults.removeFirst() }
        return .init(trackingStarted: false, polls: 0, timedOut: false)
    }
    func endSubjectTracking() {}
    func setTrackingReleaseResponse(_ response: UInt16?) { trackingReleaseResponse = response }
    func endSubjectTrackingForTool() -> UInt16? {
        log.append("end-tracking-tool")
        return trackingReleaseResponse
    }
    func startMovieRecording() -> RemoteMovieStartResult {
        log.append("movie:start")
        guard !movieStarts.isEmpty else {
            return .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
        }
        return movieStarts.removeFirst()
    }
    private var movieStopError: PTPSessionError?
    private var movieStopResponse = PTPConstants.responseOK
    func configureMovieStop(error: PTPSessionError? = nil, response: UInt16 = PTPConstants.responseOK) {
        movieStopError = error
        movieStopResponse = response
    }
    func endMovieRecording() throws -> UInt16 {
        log.append("movie:end")
        if let movieStopError { throw movieStopError }
        return movieStopResponse
    }
    func refreshUSBRemoteSession() async throws -> String {
        log.append("usb:refresh")
        remoteControlMode = false
        remoteDiagnosticControlMode = false
        applicationMode = false
        return "refreshed"
    }
    func configureDiagnostic(delay: Int = 0, responses: [UInt16] = []) {
        diagnosticDelay = delay
        diagnosticResponses = responses
    }
    func configureControlResponses(_ responses: [UInt16]) { controlResponses = responses }
    func setRemoteControlMode(_ enabled: Bool) async throws -> UInt16 {
        log.append("control:\(enabled ? "on" : "off")")
        let response = controlResponses.isEmpty ? PTPConstants.responseOK : controlResponses.removeFirst()
        if response == PTPConstants.responseOK {
            remoteControlMode = enabled
            if !enabled { remoteDiagnosticControlMode = false }
        }
        return response
    }
    func hasRemoteControlMode() async -> Bool { remoteControlMode }
    func setRemoteDiagnosticControlMode(_ enabled: Bool) async throws -> UInt16 {
        log.append("diagnostic:\(enabled ? "on" : "off")")
        if diagnosticDelay > 0 { try await Task.sleep(for: .milliseconds(diagnosticDelay)) }
        let response = diagnosticResponses.isEmpty ? PTPConstants.responseOK : diagnosticResponses.removeFirst()
        if response == PTPConstants.responseOK {
            remoteDiagnosticControlMode = enabled
            remoteControlMode = enabled
            log.append("diagnostic:accepted:\(enabled ? "on" : "off")")
        }
        return response
    }
    func hasRemoteDiagnosticControlMode() async -> Bool { remoteDiagnosticControlMode }
    func hasMovieApplicationMode() async -> Bool { applicationMode }
    func ensureMovieApplicationMode() async {
        log.append("app:on")
        applicationMode = true
    }
    func clearMovieApplicationMode(force: Bool) {
        log.append("app:off:\(force)")
        if isUSB && remoteControlMode && !force { return }
        applicationMode = false
    }
    func startPreparedUSBMovieRecording() async -> RemoteMovieStartResult {
        log.append("movie:prepared")
        if preparedMovieStartDelay > 0 {
            try? await Task.sleep(for: .milliseconds(preparedMovieStartDelay))
        }
        applicationMode = true
        return .init(responseCode: PTPConstants.responseOK, prohibitCondition: nil)
    }
}

/// Replay the wire responses, including capability fallback and malformed frames.
/// These exercise CameraRepository, not a mock of its frame selection policy.
final class RemoteFrameProtocolTests: XCTestCase {
    func testMeterRefreshRequiresExactSignedByteThroughProductionRepository() async throws {
        for property: RemoteProperty in [.nikonLightMeter, .nikonExposureIndicate] {
            for payload in [Data([0xFD]), Data(), Data([0xFD, 0]), Data([1, 2, 3, 4])] {
                let wire = RemoteWireReplay([.init(PTPConstants.getDevicePropValue,
                    parameters: [property.rawValue], payload: payload)])
                let camera = repository(wire)
                let descriptor = RemotePropertyDescriptor(property: property, dataType: 1,
                    writable: false, current: 0, values: [])
                let result = try await camera.refreshRemoteProperty(descriptor)
                if payload.count == 1 {
                    XCTAssertEqual(result.map { Int64(bitPattern: $0.current) }, -3)
                } else {
                    XCTAssertNil(result)
                }
                let remaining = await wire.remaining
                XCTAssertEqual(remaining, 0)
            }
        }
    }

    private let standard = PTPConstants.getLiveViewImage
    private let enhanced = PTPConstants.getLiveViewImageEx
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    func testUnadvertisedEnhancedOperationIsNeverProbed() async throws {
        let wire = RemoteWireReplay([.init(0x9201), .init(0x90C8), .init(standard, payload: jpeg)])
        let camera = repository(wire, enhanced: false)
        try await camera.startLiveView()
        let frame = try await camera.liveViewFrame()
        XCTAssertEqual(frame.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testUnsupportedEnhancedImmediatelyFallsBackAndRemembersAcrossRestart() async throws {
        let wire = RemoteWireReplay([
            .init(0x9201), .init(0x90C8), .init(enhanced, code: 0x2005), .init(standard, payload: jpeg),
            .init(0x9201), .init(0x90C8), .init(standard, payload: jpeg)
        ])
        let camera = repository(wire)
        try await camera.startLiveView()
        let first = try await camera.liveViewFrame()
        try await camera.startLiveView()
        let second = try await camera.liveViewFrame()
        XCTAssertEqual(first.operation, standard)
        XCTAssertEqual(second.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testBadEnhancedFrameNeedsTwoFailuresAndSuccessResetsCounter() async throws {
        let wire = RemoteWireReplay([
            .init(0x9201), .init(0x90C8), .init(enhanced, payload: Data([1, 2, 3])),
            .init(enhanced, payload: jpeg), .init(enhanced), .init(enhanced, code: 0xA004),
            .init(standard, payload: jpeg)
        ])
        let camera = repository(wire)
        try await camera.startLiveView()
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        let success = try await camera.liveViewFrame()
        XCTAssertEqual(success.operation, enhanced)
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        let fallback = try await camera.liveViewFrame()
        XCTAssertEqual(fallback.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testBusyAndNotLiveViewDoNotDowngradeOrEraseAnEarlierFailure() async throws {
        let wire = RemoteWireReplay([
            .init(0x9201), .init(0x90C8), .init(enhanced),
            .init(enhanced, code: 0x2019), .init(enhanced, code: 0xA00B),
            .init(enhanced), .init(standard, payload: jpeg)
        ])
        let camera = repository(wire)
        try await camera.startLiveView()
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        await expectFailure(camera, error: PTPSessionError.responseCode(0x2019))
        await expectFailure(camera, error: PTPSessionError.responseCode(0xA00B))
        let fallback = try await camera.liveViewFrame()
        XCTAssertEqual(fallback.operation, standard)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testDirectFrameReadDoesNotFetchDeviceInfoAndRequiresThreeByteSOI() async throws {
        let wire = RemoteWireReplay([
            .init(standard, payload: Data([0xFF, 0xD8, 0x01])),
            .init(standard, payload: Data([0, 0xFF, 0xD8, 0xFF, 0x01]))
        ])
        let camera = repository(wire)
        await expectFailure(camera, error: CameraRepositoryError.invalidDataset)
        let frame = try await camera.liveViewFrame()
        XCTAssertEqual(frame.jpegOffset, 1)
        XCTAssertEqual(frame.operation, standard)
    }

    func testSelectorReadsFirstByteWithoutRequiringDescription() async throws {
        let wire = RemoteWireReplay([
            .init(0x1015, parameters: [0xD1A6], payload: Data([2, 0])),
            .init(0x1015, parameters: [0xD1A6], payload: Data([0])),
            .init(0x1015, parameters: [0xD1A6], code: 0x2005)
        ])
        let camera = repository(wire)
        let movie = try await camera.remoteMovieMode()
        let photo = try await camera.remoteMovieMode()
        let unknown = try await camera.remoteMovieMode()
        XCTAssertEqual(movie, true)
        XCTAssertEqual(photo, false)
        XCTAssertNil(unknown)
    }

    func testCaptureUsesNoAutofocusCardParametersAndBusyRetry() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.captureInMedia, parameters: [.max, 0], code: 0x2019),
            .init(PTPConstants.captureInMedia, parameters: [.max, 0])
        ])
        try await repository(wire).capturePhoto()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testNonBusyDeviceReadyResponseStillAllowsFrameAttempt() async throws {
        let wire = RemoteWireReplay([.init(0x9201), .init(0x90C8, code: 0x2005), .init(enhanced, payload: jpeg)])
        let camera = repository(wire)
        try await camera.startLiveView()
        _ = try await camera.liveViewFrame()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testUnsupportedTrackingIsRememberedAndUsesIndependentAFCoordinates() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600], code: 0x2005),
            .init(0x9205, parameters: [90, 60]), .init(0x90C1), .init(0x90C8),
            .init(0x9205, parameters: [30, 20]), .init(0x90C1), .init(0x90C8)
        ])
        let camera = repository(wire)
        let first = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        let second = try await camera.focusAt(trackingX: 300, trackingY: 200, focusX: 30, focusY: 20)
        XCTAssertFalse(first.trackingStarted)
        XCTAssertFalse(second.trackingStarted)
        XCTAssertEqual(first.polls, 1)
        XCTAssertEqual(second.responseCode, 0x2001)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testTrackingBusyDoesNotFallBackToAF() async throws {
        let wire = RemoteWireReplay([.init(0x9424, parameters: [900, 600], code: 0x2019)])
        let result = try await repository(wire).focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        XCTAssertFalse(result.trackingStarted)
        XCTAssertEqual(result.responseCode, 0x2019)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9424])
    }

    func testExplicitMoveAreaPathSkipsTrackingProbeAndUsesFullFocusCoordinates() async throws {
        let wire = RemoteWireReplay([
            .init(0x9205, parameters: [901, 601]), .init(0x90C1), .init(0x90C8)
        ])
        let result = try await repository(wire).focusAt(trackingX: 100, trackingY: 200,
                                                         focusX: 901, focusY: 601,
                                                         tapPath: .moveArea)
        XCTAssertFalse(result.trackingStarted)
        XCTAssertEqual(result.moveResponseCode, PTPConstants.responseOK)
        XCTAssertEqual(result.afStartResponseCode, PTPConstants.responseOK)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9205, 0x90C1, 0x90C8])
    }

    func testExplicitTrackingPathUsesTrackingCoordinatesAndDoesNotFallbackOnBusy() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [901, 601]), .init(0x90C1), .init(0x90C8)
        ])
        let result = try await repository(wire).focusAt(trackingX: 901, trackingY: 601,
                                                         focusX: 31, focusY: 21,
                                                         tapPath: .tracking)
        XCTAssertTrue(result.trackingStarted)
        XCTAssertEqual(result.trackingResponseCode, PTPConstants.responseOK)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9424, 0x90C1, 0x90C8])

        let busy = RemoteWireReplay([.init(0x9424, parameters: [1, 2], code: 0x2019)])
        let failure = try await repository(busy).focusAt(trackingX: 1, trackingY: 2,
                                                          focusX: 3, focusY: 4,
                                                          tapPath: .tracking)
        XCTAssertEqual(failure.responseCode, 0x2019)
        let busyOperations = await busy.operations
        XCTAssertEqual(busyOperations, [0x9424])
    }

    func testFailedEndTrackingPreventsNewTargetButEndLiveViewStillCloses() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1), .init(0x90C8),
            .init(0x9425, code: 0x2019), .init(0x9425, code: 0x2019), .init(0x9202)
        ])
        let camera = repository(wire)
        _ = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        let second = try await camera.focusAt(trackingX: 300, trackingY: 200, focusX: 30, focusY: 20)
        XCTAssertFalse(second.trackingStarted)
        XCTAssertEqual(second.responseCode, 0x2019)
        await camera.endLiveView()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHalfPressEndsTrackingBeforeAFAndNegativeReadyIsNotSuccess() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1), .init(0x90C8),
            .init(0x9425, code: 0xA004), .init(0x90C1), .init(0x90C8, code: 0xA002),
            .init(0x9202)
        ])
        let camera = repository(wire)
        _ = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        let halfPress = try await camera.halfPressFocus()
        XCTAssertEqual(halfPress.responseCode, 0xA002)
        XCTAssertFalse(halfPress.timedOut)
        await camera.endLiveView()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testTrackingRemainsActiveAfterOutOfFocusAndIsClosedWithLiveView() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1), .init(0x90C8, code: 0xA002),
            .init(0x9425), .init(0x9202)
        ])
        let camera = repository(wire)
        let result = try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60)
        XCTAssertTrue(result.trackingStarted)
        XCTAssertEqual(result.responseCode, 0xA002)
        await camera.endLiveView()
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testFramesCannotInterruptTrackingSettlingButMayRunBeforeReadyPoll() async throws {
        let wire = RemoteWireReplay([
            .init(0x9424, parameters: [900, 600]), .init(0x90C1),
            .init(standard, payload: jpeg), .init(0x90C8)
        ])
        let camera = repository(wire)
        let focus = Task { try await camera.focusAt(trackingX: 900, trackingY: 600, focusX: 90, focusY: 60) }
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await wire.operations.contains(0x9424)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let frame = Task { try await camera.liveViewFrame() }
        let result = try await focus.value
        _ = try await frame.value
        XCTAssertEqual(result.responseCode, 0x2001)
        let operations = await wire.operations
        XCTAssertEqual(operations, [0x9424, 0x90C1, standard, 0x90C8])
    }

    func testPreparedUSBSideEffectsSurviveLaterFailureAndRespectInvalidation() async throws {
        for propertyFallback in [false, true] {
            for failureKind in 0..<3 {
                let failure: any Error
                switch failureKind {
                case 0: failure = PTPSessionError.responseCode(0x2002)
                case 1: failure = CancellationError()
                default: failure = PTPSessionError.timeout
                }
                var steps: [RemoteWireReplay.Step] = [
                    .init(PTPConstants.getDevicePropValueEx, parameters: [0xD0A4]),
                    .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(1 << 14)),
                    .init(PTPConstants.nikonChangeApplicationMode, parameters: [1],
                          code: propertyFallback ? PTPConstants.operationNotSupported : PTPConstants.responseOK)
                ]
                if propertyFallback {
                    steps.append(.init(PTPConstants.setDevicePropValue,
                                       parameters: [RemoteProperty.applicationMode.rawValue], sentData: Data([1])))
                    steps.append(.init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], failure: failure))
                    steps.append(.init(PTPConstants.setDevicePropValue,
                                       parameters: [RemoteProperty.applicationMode.rawValue], sentData: Data([0])))
                } else {
                    steps.append(.init(PTPConstants.startMovieRecording, failure: failure))
                    steps.append(.init(PTPConstants.nikonChangeApplicationMode, parameters: [0]))
                }
                let wire = RemoteWireReplay(steps, managesTimeouts: true)
                let camera = repository(wire, usb: true)
                do { _ = try await camera.startPreparedUSBMovieRecording(); XCTFail("Expected injected failure") }
                catch { }
                let active = await camera.hasMovieApplicationMode()
                XCTAssertTrue(active, "Acknowledged side effect must survive subsequent failure")
                await camera.clearMovieApplicationMode(force: true)
                let retained = await camera.hasMovieApplicationMode()
                let remaining = await wire.remaining
                // A timeout poisons the PTP session: no cleanup command is sent
                // on that channel and ownership is not falsely marked cleared.
                XCTAssertEqual(retained, failureKind == 2)
                XCTAssertEqual(remaining, failureKind == 2 ? 1 : 0)
            }
        }
    }

    func testConcurrentApplicationCleanupSharesBusyRetryAndClearsOnlyAcknowledgedFlags() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue], sentData: Data([1])),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [1]),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [0], code: PTPConstants.deviceBusy),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [0], code: PTPConstants.deviceBusy),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [0]),
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue], sentData: Data([0]))
        ])
        let camera = repository(wire, usb: true)
        try await camera.ensureMovieApplicationMode()
        async let first: Void = camera.clearMovieApplicationMode(force: true)
        async let second: Void = camera.clearMovieApplicationMode(force: true)
        _ = await (first, second)
        let retained = await camera.hasMovieApplicationMode()
        let remaining = await wire.remaining
        XCTAssertFalse(retained)
        XCTAssertEqual(remaining, 0)
    }

    func testWireShutterRangesAndLongEnumerationReachRepository() async throws {
        func description(_ property: RemoteProperty, form: UInt8, values: [Int64]) -> Data {
            var data = Data([UInt8(truncatingIfNeeded: property.rawValue), UInt8(truncatingIfNeeded: property.rawValue >> 8), 6, 0, 1])
            data += RemotePropertyCodec.encode(0, dataType: 6)!
            data += RemotePropertyCodec.encode(10, dataType: 6)!
            data.append(form)
            if form == 2 {
                data.append(UInt8(truncatingIfNeeded: values.count))
                data.append(UInt8(truncatingIfNeeded: values.count >> 8))
            }
            for value in values { data += RemotePropertyCodec.encode(value, dataType: 6)! }
            return data
        }
        let shutter = try XCTUnwrap(RemoteProperty(rawValue: 0xD100))
        let standard = try XCTUnwrap(RemoteProperty(rawValue: 0x500D))
        for property in [shutter, standard] {
            let payload = description(property, form: 1, values: [10, 3010, 3])
            let wire = RemoteWireReplay([.init(PTPConstants.getDevicePropDesc, parameters: [property.rawValue], payload: payload)])
            let parsed = try await repository(wire).remoteProperty(property)
            // 1001 declared values -> stride4 -> 251 entries, all step-aligned.
            XCTAssertEqual(parsed?.values, (0...250).map { UInt64(10 + $0 * 12) })
            XCTAssertTrue(parsed?.writable == true)
        }
        XCTAssertEqual(RemotePropertyCodec.parseDescription(description(shutter, form: 1, values: [10, 19, 3]))?.values,
                       [10, 13, 16, 19])
        XCTAssertEqual(RemotePropertyCodec.parseDescription(description(shutter, form: 1, values: [0, 255, 1]))?.values.count, 256)
        XCTAssertEqual(RemotePropertyCodec.parseDescription(description(shutter, form: 1, values: [0, 256, 1]))?.values,
                       stride(from: Int64(0), through: 256, by: 2).map { $0 })
        XCTAssertEqual(RemotePropertyCodec.parseDescription(description(.iso, form: 1, values: [0, 1, 1]))?.values, [0, 1])
        let ordinary = description(.iso, form: 1, values: [100, 6400, 100])
        XCTAssertEqual(RemotePropertyCodec.parseDescription(ordinary)?.values, [])
        let longValues = (0..<600).map(Int64.init)
        let payload = description(shutter, form: 2, values: longValues)
        let wire = RemoteWireReplay([.init(PTPConstants.getDevicePropDesc, parameters: [shutter.rawValue], payload: payload)])
        let parsed = try await repository(wire).remoteProperty(shutter)
        XCTAssertEqual(parsed?.values, longValues.map(UInt64.init))
        XCTAssertNil(RemotePropertyCodec.parseDescription(payload.dropLast()))
        for values: [Int64] in [[10, 0, 1], [0, 100, 0]] {
            XCTAssertEqual(RemotePropertyCodec.parseDescription(description(shutter, form: 1, values: values))?.values, [])
        }
    }

    func testPreparedUSBMovieStartsDirectlyWhenApplicationModeIsNotRequired() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.getDevicePropValueEx, parameters: [0xD0A4]),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(0)),
            .init(PTPConstants.startMovieRecording)
        ])
        let result = try await repository(wire, usb: true).startPreparedUSBMovieRecording()
        XCTAssertTrue(result.indicatesRecording)
        XCTAssertEqual(result.prohibitExtendedResponse, PTPConstants.responseOK)
        XCTAssertNil(result.applicationModeResponse)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testPreparedUSBMovieEnablesApplicationOperationInsideOneSequence() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.getDevicePropValueEx, parameters: [0xD0A4]),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(1 << 14)),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [1]),
            .init(PTPConstants.startMovieRecording)
        ])
        let camera = repository(wire, usb: true)
        let result = try await camera.startPreparedUSBMovieRecording()
        XCTAssertEqual(result.applicationModeResponse, PTPConstants.responseOK)
        let active = await camera.hasMovieApplicationMode()
        let remaining = await wire.remaining
        XCTAssertTrue(active)
        XCTAssertEqual(remaining, 0)
    }

    func testPreparedUSBMovieFallsBackToApplicationPropertyWhenOperationIsUnsupported() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.getDevicePropValueEx, parameters: [0xD0A4]),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(1 << 14)),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [1], code: PTPConstants.operationNotSupported),
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue],
                  sentData: Data([1])),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A4], payload: littleEndian(0)),
            .init(PTPConstants.startMovieRecording)
        ])
        let result = try await repository(wire, usb: true).startPreparedUSBMovieRecording()
        XCTAssertEqual(result.applicationModeResponse, PTPConstants.operationNotSupported)
        XCTAssertEqual(result.applicationModePropertyResponse, PTPConstants.responseOK)
        XCTAssertTrue(result.indicatesRecording)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testControlModeBusyRetryAndApplicationCleanupFollowAndroidOrder() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.setControlMode, parameters: [1], code: PTPConstants.deviceBusy),
            .init(PTPConstants.setControlMode, parameters: [1], code: PTPConstants.deviceBusy),
            .init(PTPConstants.setControlMode, parameters: [1]),
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue],
                  sentData: Data([1])),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [1]),
            .init(PTPConstants.nikonChangeApplicationMode, parameters: [0]),
            .init(PTPConstants.setDevicePropValue, parameters: [RemoteProperty.applicationMode.rawValue],
                  sentData: Data([0])),
            .init(PTPConstants.setControlMode, parameters: [0])
        ])
        let camera = repository(wire, usb: true)
        let enter = try await camera.setRemoteControlMode(true)
        XCTAssertEqual(enter, PTPConstants.responseOK)
        try await camera.ensureMovieApplicationMode()
        await camera.clearMovieApplicationMode(force: true)
        let leave = try await camera.setRemoteControlMode(false)
        let controlActive = await camera.hasRemoteControlMode()
        let applicationActive = await camera.hasMovieApplicationMode()
        let remaining = await wire.remaining
        XCTAssertEqual(leave, PTPConstants.responseOK)
        XCTAssertFalse(controlActive)
        XCTAssertFalse(applicationActive)
        XCTAssertEqual(remaining, 0)
    }

    func testLegacyVideoDiagnosticOnlyInterpretsFixedJPEGLayout() async throws {
        var payload = Data(repeating: 0, count: 512)
        payload[64] = 0x00; payload[65] = 0x01
        payload[66] = 0x00; payload[67] = 0x2A
        payload[68] = 1
        payload[384] = 0xFF; payload[385] = 0xD8; payload[386] = 0xFF
        let wire = RemoteWireReplay([.init(PTPConstants.getLiveViewImage, payload: payload)])
        let result = try await repository(wire).probeLegacyVideoTime()
        XCTAssertFalse(result.contains("unsupported layout"))
        XCTAssertTrue(result.contains("video[64..68]=0001002A01"))
        XCTAssertTrue(result.contains("remainingMs=null"))
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testMovieFormatDiagnosticReadsD0A0AndD0A7WithoutWrites() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.getDevicePropDesc, parameters: [0xD0A0], payload: Data([0xA0, 0xD0, 0x08, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A0], payload: Data([0, 0, 0, 0, 0, 0, 0, 0])),
            .init(PTPConstants.getDevicePropDesc, parameters: [0xD0A7], payload: Data()),
            .init(PTPConstants.getDevicePropValue, parameters: [0xD0A7], payload: Data([0]))
        ])
        let result = try await repository(wire).probeMovieFormat()
        XCTAssertTrue(result.contains("0xD0A0 desc=0x2001"))
        XCTAssertTrue(result.contains("0xD0A7 value=0x2001"))
        XCTAssertTrue(result.contains("no property writes"))
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testManualControlReusesPhysicalModeAndReleaseClearsBothOwners() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.setControlMode, parameters: [1]),
            .init(PTPConstants.setControlMode, parameters: [0])
        ])
        let camera = repository(wire, usb: true)
        let ordinary = try await camera.setRemoteControlMode(true)
        let manual = try await camera.setRemoteDiagnosticControlMode(true)
        XCTAssertEqual(ordinary, PTPConstants.responseOK)
        XCTAssertEqual(manual, PTPConstants.responseOK)
        let held = await camera.hasRemoteDiagnosticControlMode()
        XCTAssertTrue(held)
        let released = try await camera.setRemoteControlMode(false)
        XCTAssertEqual(released, PTPConstants.responseOK)
        let diagnostic = await camera.hasRemoteDiagnosticControlMode()
        let physical = await camera.hasRemoteControlMode()
        let remaining = await wire.remaining
        XCTAssertFalse(diagnostic)
        XCTAssertFalse(physical)
        XCTAssertEqual(remaining, 0)
    }

    func testManualControlFailureDoesNotPublishAnUnconfirmedMode() async throws {
        let wire = RemoteWireReplay([
            .init(PTPConstants.setControlMode, parameters: [1], code: 0x200F),
            .init(PTPConstants.setControlMode, parameters: [1]),
            .init(PTPConstants.setControlMode, parameters: [0], code: 0x200F),
            .init(PTPConstants.setControlMode, parameters: [0])
        ])
        let camera = repository(wire)
        let refused = try await camera.setRemoteDiagnosticControlMode(true)
        XCTAssertEqual(refused, 0x200F)
        let inactive = await camera.hasRemoteDiagnosticControlMode()
        XCTAssertFalse(inactive)
        _ = try await camera.setRemoteDiagnosticControlMode(true)
        let refusedRelease = try await camera.setRemoteDiagnosticControlMode(false)
        XCTAssertEqual(refusedRelease, 0x200F)
        let diagnostic = await camera.hasRemoteDiagnosticControlMode()
        let physical = await camera.hasRemoteControlMode()
        XCTAssertTrue(diagnostic)
        XCTAssertTrue(physical)
        _ = try await camera.setRemoteDiagnosticControlMode(false)
        let released = await camera.hasRemoteDiagnosticControlMode()
        let remaining = await wire.remaining
        XCTAssertFalse(released)
        XCTAssertEqual(remaining, 0)
    }

    private func repository(_ wire: RemoteWireReplay, enhanced: Bool = true,
                            usb: Bool = false) -> CameraRepository {
        let info = PTPDeviceInfo(standardVersion: 100, vendorExtensionID: 10, vendorExtensionVersion: 100,
            vendorExtensionDescription: "", functionalMode: 0, manufacturer: "Nikon", model: "Z30",
            version: "", serialNumber: "", operations: enhanced ? [standard, self.enhanced] : [standard],
            events: [], properties: [], captureFormats: [], imageFormats: [])
        return CameraRepository(session: PTPSession(transport: wire), isUSBConnection: usb, deviceInfo: info)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        var raw = value.littleEndian
        return Data(bytes: &raw, count: MemoryLayout<UInt32>.size)
    }

    private func expectFailure<E: Error & Equatable>(_ camera: CameraRepository, error expected: E) async {
        do { _ = try await camera.liveViewFrame(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? E, expected) }
    }
}

private actor RemoteWireReplay: PTPCommandTransport {
    nonisolated let managesCommandTimeouts: Bool
    struct Step: Sendable {
        let operation: UInt16
        let parameters: [UInt32]
        let code: UInt16
        let payload: Data
        let sentData: Data?
        let failure: (any Error)?
        init(_ operation: UInt16, parameters: [UInt32] = [], code: UInt16 = 0x2001,
             payload: Data = Data(), sentData: Data? = nil, failure: (any Error)? = nil) {
            self.operation = operation; self.parameters = parameters; self.code = code
            self.payload = payload; self.sentData = sentData; self.failure = failure
        }
    }
    private var steps: [Step]
    private(set) var operations: [UInt16] = []
    var remaining: Int { steps.count }
    init(_ steps: [Step], managesTimeouts: Bool = false) {
        self.steps = steps
        managesCommandTimeouts = managesTimeouts
    }
    func sendPTP(command: Data, data: Data?) throws -> (response: Data, payload: Data) {
        let packet = try PTPCodec.decode(command)
        operations.append(packet.code)
        guard !steps.isEmpty else { throw CocoaError(.coderInvalidValue) }
        let expected = steps.removeFirst()
        var reader = PTPDataReader(packet.payload)
        var parameters: [UInt32] = []
        while let value = reader.readUInt32() { parameters.append(value) }
        guard packet.code == expected.operation, parameters == expected.parameters,
              expected.sentData == nil || data == expected.sentData else {
            throw CocoaError(.coderInvalidValue)
        }
        if let failure = expected.failure { throw failure }
        return (PTPCodec.encode(type: .response, code: expected.code, transactionID: packet.transactionID), expected.payload)
    }
}

@MainActor
final class RemoteFramePresentationTests: XCTestCase {
    func testProductionMonitorKeepsChangingPixelsWithStableLayoutInNormalAndHDScopes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        for hd in [false, true] {
            let suite = "monitor-live-pixels-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let preferences = RemoteToolPreferences(defaults: defaults)
            preferences.hd = hd; preferences.disp = .clean; preferences.level = false
            preferences.histogram = hd ? .rgb : .off
            preferences.waveform = hd ? .rgb : .off
            let size = hd ? CGSize(width: 1920, height: 1080) : CGSize(width: 640, height: 424)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let images = [UIColor.red, UIColor.green].map { color in
                UIGraphicsImageRenderer(size: size, format: format).image { context in
                    color.setFill(); context.fill(CGRect(origin: .zero, size: size))
                }.jpegData(compressionQuality: 0.9)!
            }
            let camera = RemoteLifecycleCamera(isUSB: true, frameSize: size)
            await camera.replaceFrame(data: images[0])
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            let host = UIHostingController(rootView: RemoteView(session: nil, presentationMode: .usb,
                toolDefaults: defaults, remoteCamera: camera, freeUsage: FreeUsageStore(defaults: defaults)))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                previousKey?.makeKey(); defaults.removePersistentDomain(forName: suite)
            }
            host.view.layoutIfNeeded()
            let readyDeadline = ContinuousClock.now + .seconds(5)
            while await camera.successfulFrameCount < 12, ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let received = await camera.successfulFrameCount
            XCTAssertGreaterThanOrEqual(received, 12)
            func surface(in view: UIView) -> RemoteViewfinderInput.Surface? {
                if let value = view as? RemoteViewfinderInput.Surface { return value }
                return view.subviews.lazy.compactMap { surface(in: $0) }.first
            }
            // Receiving packets does not mean the initial image has been
            // decoded and laid out. Establish the actual viewport before
            // testing updates with otherwise stable geometry.
            let visibleDeadline = ContinuousClock.now + .seconds(5)
            while surface(in: host.view) == nil, ContinuousClock.now < visibleDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let input = try XCTUnwrap(surface(in: host.view))
            let viewport = input.convert(input.bounds, to: host.view)
            // Keep >30,000 actual image pixels, outside the scope charts and
            // rounded corners. Reading/scanning the entire controls hierarchy
            // between frames needlessly stalls the main actor under test.
            let sample = CGRect(x: viewport.minX + 24, y: viewport.minY + 30,
                width: viewport.width - 48, height: min(110, viewport.height - 60)).integral
            XCTAssertGreaterThan(sample.width * sample.height, 30_000)
            var samplingMilliseconds: [Int] = []
            // Change only the JPEG, never layout, properties, tools or orientation.
            // The full production view must display each new color through its
            // frame observer, both geometry readers and (for HD) cached scopes.
            for index in [1, 0, 1, 0, 1, 0] {
                await camera.replaceFrame(data: images[index])
                try await Task.sleep(for: .milliseconds(150))
                let samplingStarted = ContinuousClock.now
                let snapshot = UIGraphicsImageRenderer(size: sample.size, format: format).image { context in
                    context.cgContext.translateBy(x: -sample.minX, y: -sample.minY)
                    // drawHierarchy(afterScreenUpdates:) took 211–991ms per
                    // sample on this simulator, blocking the publishing actor
                    // it was meant to verify. Read the committed presentation
                    // layer at the same 150ms point, without forcing updates.
                    (host.view.layer.presentation() ?? host.view.layer).render(in: context.cgContext)
                }
                let bitmap = try XCTUnwrap(snapshot.cgImage)
                var rgba = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
                try rgba.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: bitmap.width,
                        height: bitmap.height, bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
                }
                let correct = stride(from: 0, to: rgba.count, by: 4).filter {
                    rgba[$0 + index] > 235 && rgba[$0 + (1 - index)] < 20 && rgba[$0 + 2] < 20
                }.count
                let elapsed = samplingStarted.duration(to: .now).components
                samplingMilliseconds.append(Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000))
                if correct <= 30_000 {
                    let attachment = XCTAttachment(image: snapshot)
                    attachment.name = "monitor-pixel-failure-hd-\(hd)-color-\(index)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let opposite = stride(from: 0, to: rgba.count, by: 4).filter {
                        rgba[$0 + (1 - index)] > 235 && rgba[$0 + index] < 20 && rgba[$0 + 2] < 20
                    }.count
                    print("monitor-pixel-evidence expected=\(correct) opposite=\(opposite) received=\(await camera.successfulFrameCount)")
                }
                XCTAssertGreaterThan(correct, 30_000, "Production monitor stale pixels: hd=\(hd), color=\(index)")
            }
            print("monitor-image-sampling hd=\(hd) milliseconds=\(samplingMilliseconds)")
            window.isHidden = true; window.rootViewController = nil
            let stoppedDeadline = ContinuousClock.now + .seconds(2)
            while !(await camera.log.contains("gate:false")), ContinuousClock.now < stoppedDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let stopped = await camera.log.contains("gate:false")
            XCTAssertTrue(stopped, "Removing the actual monitor still drains its camera session")
        }
    }

    func testLevelSamplesOnlyNotifyViewfinderOncePerChangedPair() async {
        let model = RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: false))
        var pageUpdates = 0, frameUpdates = 0
        let page = model.objectWillChange.sink { pageUpdates += 1 }
        let frames = model.frameUpdates.objectWillChange.sink { frameUpdates += 1 }
        defer { page.cancel(); frames.cancel() }
        model.updateLevel(roll: 12.5, pitch: -3.2)
        XCTAssertEqual(frameUpdates, 1)
        for _ in 0..<120 { model.updateLevel(roll: 12.5, pitch: -3.2) }
        XCTAssertEqual(frameUpdates, 1)
        XCTAssertEqual(model.levelRoll, 12.5)
        XCTAssertEqual(model.levelPitch, -3.2)
        model.updateLevel(roll: -1.2, pitch: nil)
        XCTAssertEqual(frameUpdates, 2)
        XCTAssertNil(model.levelPitch)
        model.updateLevel(roll: nil, pitch: nil)
        XCTAssertEqual(frameUpdates, 3)
        XCTAssertNil(model.levelRoll)
        XCTAssertEqual(pageUpdates, 0)
        await model.stopAndWait()
    }

    private func image(_ size: CGSize = CGSize(width: 64, height: 48)) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func frame(_ image: UIImage, sequence: Int = 1, generation: UInt64 = 0,
                       age: TimeInterval = 0) -> RemoteDecodedFrame {
        let jpeg = image.jpegData(compressionQuality: 0.6)!
        return .init(image: image, jpeg: jpeg, rawBytes: jpeg, jpegOffset: 0,
            operation: PTPConstants.getLiveViewImage, metadata: nil,
            histogram: [sequence], histogramRGB: [[sequence, 2, 3]],
            waveform: [[sequence]], falseColorPixels: [UInt32(sequence)],
            falseColorWidth: 1, falseColorHeight: 1, falseColorImage: image.cgImage,
            waveformImage: image.cgImage, zebraMask: nil,
            fps: Double(sequence), generation: generation,
            receivedAtUptime: ProcessInfo.processInfo.systemUptime - age)
    }

    func testFramesPublishOnceToViewfinderAndDoNotInvalidateControls() async throws {
        let model = RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: false))
        let image = image()
        var pageUpdates = 0, frameUpdates = 0
        let page = model.objectWillChange.sink { pageUpdates += 1 }
        let frames = model.frameUpdates.objectWillChange.sink { frameUpdates += 1 }
        defer { page.cancel(); frames.cancel() }
        model.acceptDecodedFrame(frame(image))
        XCTAssertGreaterThan(pageUpdates, 0, "First image/session readiness must update controls")
        XCTAssertEqual(frameUpdates, 1)
        pageUpdates = 0; frameUpdates = 0
        for step in 2...121 {
            // New UIImage identity each time, with stable size like decoded camera frames.
            let next = UIImage(cgImage: try XCTUnwrap(image.cgImage))
            model.acceptDecodedFrame(frame(next, sequence: step))
            XCTAssertTrue(model.frameImage === next)
            XCTAssertEqual(model.frameHistogram, [step])
            XCTAssertEqual(model.frameHistogramRGB, [[step, 2, 3]])
            XCTAssertEqual(model.frameWaveform, [[step]])
            XCTAssertTrue(model.frameWaveformImage === next.cgImage)
            XCTAssertTrue(model.frameFalseColorImage === next.cgImage)
            XCTAssertEqual(model.frameFalseColorPixels, [UInt32(step)])
        }
        XCTAssertEqual(pageUpdates, 0)
        XCTAssertEqual(frameUpdates, 120)
        XCTAssertEqual(model.state.frameSequence, 121)
        XCTAssertEqual(model.state.fps, 121)
        model.acceptDecodedFrame(frame(image, generation: 999))
        XCTAssertEqual(frameUpdates, 120, "Late obsolete generation must remain rejected")
        XCTAssertEqual(model.state.frameSequence, 121)
        model.acceptDecodedFrame(frame(self.image(CGSize(width: 80, height: 40))))
        XCTAssertGreaterThan(pageUpdates, 0, "New image aspect must update outer layout")
        pageUpdates = 0; frameUpdates = 0
        model.setFrameAnalysis(histogram: false, zebra: false)
        XCTAssertEqual(pageUpdates, 0)
        XCTAssertEqual(frameUpdates, 1)
        XCTAssertNil(model.frameHistogram)
        XCTAssertNil(model.frameHistogramRGB)
        XCTAssertNil(model.frameWaveform)
        XCTAssertNil(model.frameWaveformImage)
        XCTAssertNil(model.frameFalseColorImage)
        XCTAssertNil(model.frameFalseColorPixels)
        await model.stopAndWait()
        XCTAssertGreaterThan(pageUpdates, 0, "Clearing frame/ending session must update controls")
        XCTAssertNil(model.frameImage)
        XCTAssertNil(model.frameData)
        let updatesAfterStop = frameUpdates
        model.acceptDecodedFrame(frame(image))
        XCTAssertEqual(frameUpdates, updatesAfterStop)
        XCTAssertEqual(model.state.session, .idle)
    }

    func testFocusExpiryStillRefreshesViewfinderWithoutAnotherFrameOrWholePage() async throws {
        let model = RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: false))
        model.acceptDecodedFrame(frame(image(), age: 0.4))
        XCTAssertFalse(model.focusFrameExpired)
        var pageUpdates = 0, frameUpdates = 0
        let page = model.objectWillChange.sink { pageUpdates += 1 }
        let frames = model.frameUpdates.objectWillChange.sink { frameUpdates += 1 }
        defer { page.cancel(); frames.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.focusFrameExpired)
        XCTAssertEqual(frameUpdates, 1)
        XCTAssertEqual(pageUpdates, 0)
        model.acceptDecodedFrame(frame(image()))
        XCTAssertFalse(model.focusFrameExpired)
        XCTAssertEqual(frameUpdates, 2)
        XCTAssertEqual(pageUpdates, 0)
        await model.stopAndWait()
    }

    private final class Probe {
        var parentBodies = 0
        var frameBodies = 0
        var displayedImage: UIImage?
        var displayedSequence: UInt64 = 0
    }
    private struct Harness: View {
        @ObservedObject var model: RemoteViewModel
        let probe: Probe
        var body: some View {
            let _ = { probe.parentBodies += 1 }()
            VStack {
                Text("Controls")
                RemoteFrameScope(updates: model.frameUpdates) {
                    let _ = {
                        probe.frameBodies += 1
                        probe.displayedImage = model.frameImage
                        probe.displayedSequence = model.state.frameSequence
                    }()
                    if let image = model.frameImage { Image(uiImage: image) }
                }
            }
        }
    }

    private struct GeometryHarness: View {
        @ObservedObject var model: RemoteViewModel
        let probe: Probe
        var body: some View {
            let _ = { probe.parentBodies += 1 }()
            RemoteViewfinderFrameScope(updates: model.frameUpdates) { size in
                let _ = {
                    probe.frameBodies += 1
                    probe.displayedImage = model.frameImage
                    probe.displayedSequence = model.state.frameSequence
                }()
                if let image = model.frameImage {
                    RemoteZoomableViewfinder(aspect: 4.0 / 3, imageSize: image.size,
                        metadata: model.frameMetadata, onFocus: { _ in }) {
                        RemoteViewfinderImage(image: image, aspect: 4.0 / 3,
                                              size: size)
                    }
                }
            }
            .frame(width: 320, height: 240)
        }
    }

    func testFixedGeometryViewfinderConsumesNewImagesWithoutControlChanges() async throws {
        let model = RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: true))
        let initialImage = image(), probe = Probe()
        model.acceptDecodedFrame(frame(initialImage))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: GeometryHarness(model: model, probe: probe))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let initialParents = probe.parentBodies, initialFrames = probe.frameBodies
        XCTAssertGreaterThan(initialFrames, 0)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let green = UIGraphicsImageRenderer(size: initialImage.size, format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(origin: .zero, size: initialImage.size))
        }
        var latest = initialImage
        for sequence in 2...16 {
            latest = UIImage(cgImage: try XCTUnwrap((sequence == 16 ? green : initialImage).cgImage))
            model.acceptDecodedFrame(frame(latest, sequence: sequence))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.parentBodies, initialParents)
        XCTAssertGreaterThan(probe.frameBodies, initialFrames + 5,
            "Stable GeometryReader must not suppress the frame subscription")
        XCTAssertTrue(probe.displayedImage === latest)
        XCTAssertEqual(probe.displayedSequence, 16)
        // Verify actual rendered pixels through the nested zoom GeometryReader,
        // not just that the outer observer evaluated a closure.
        let snapshot = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let bitmap = try XCTUnwrap(snapshot.cgImage)
        var rgba = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: bitmap.width,
                height: bitmap.height, bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }
        let greenPixels = stride(from: 0, to: rgba.count, by: 4).filter {
            rgba[$0] < 20 && rgba[$0 + 1] > 235 && rgba[$0 + 2] < 20
        }.count
        XCTAssertGreaterThan(greenPixels, 60_000, "The final source must really reach the screen surface")
        print("MONITOR_GEOMETRY parent=\(probe.parentBodies - initialParents) frames=\(probe.frameBodies - initialFrames) latest=\(probe.displayedSequence)")
        await model.stopAndWait()
    }

    func testHostedFrameScopeReadsLatestImageWhileParentStaysStill() async throws {
        let model = RemoteViewModel(camera: DisconnectedRemoteCamera(isUSB: false))
        let image = image(), probe = Probe()
        model.acceptDecodedFrame(frame(image))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: Harness(model: model, probe: probe))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let initial = probe.parentBodies, initialFrames = probe.frameBodies
        XCTAssertGreaterThan(initial, 0)
        var latest = image
        for step in 2...31 {
            latest = UIImage(cgImage: try XCTUnwrap(image.cgImage))
            model.acceptDecodedFrame(frame(latest, sequence: step))
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.parentBodies, initial)
        XCTAssertGreaterThan(probe.frameBodies, initialFrames)
        XCTAssertTrue(probe.displayedImage === latest, "The closure must not capture an obsolete image")
        XCTAssertEqual(probe.displayedSequence, 31)
        await model.stopAndWait()
    }
}
