import XCTest
import SwiftUI
import Combine
@testable import ZTransfer

@MainActor
final class PictureControlPanelModelTests: XCTestCase {
    func testLateInitialReadFailureCannotDismissReplacementPanel() async throws {
        let entered = GateTestLatch(), release = GateTestLatch()
        var shown = "old", notices: [String] = []
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true },
            busy: { _ in true }, readOverview: { _ in
                await entered.signal(); await release.wait()
                throw PTPSessionError.invalidResponse
            }, change: { _, _, _ in XCTFail("Read-only opening must not write") })
        model.notice = { notices.append($0) }
        model.dismiss = { shown = "none" }
        model.open()
        await entered.wait()
        model.close(); shown = "replacement"
        await release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.loading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.loadFailed)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertEqual(shown, "replacement")
    }

    func testOldCameraReadFailureDoesNotPublishIntoCurrentSession() async {
        let entered = GateTestLatch(), release = GateTestLatch()
        var current = true, notices: [String] = []
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { current }, allowed: { true },
            busy: { _ in true }, readOverview: { _ in
                await entered.signal(); await release.wait(); throw PTPSessionError.invalidResponse
            }, change: { _, _, _ in })
        model.notice = { notices.append($0) }
        let reading = Task { await model.refresh() }
        await entered.wait(); current = false; await release.signal(); await reading.value
        XCTAssertTrue(notices.isEmpty); XCTAssertFalse(model.loadFailed)
        model.close()
    }
    func testEmptySlotCannotActivateOrClearAndExplicitWriteDoesNotChooseAnotherSlot() async throws {
        var changes: [Int] = [], busy = false
        let overview = PictureControlOverview(slots: [.init(slot: 201, availability: .empty), .init(slot: 209, availability: .occupied, name: "Old")], selected: 209, canActivate: true, canEdit: true)
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true },
            busy: { busy = $0; return true }, readOverview: { _ in overview }, change: { slot, _, _ in changes.append(slot) })
        await model.refresh()
        model.act(.activate(201)); model.act(.clear(201)); model.act(.activate(202))
        XCTAssertTrue(changes.isEmpty); XCTAssertFalse(busy)
        model.act(.activate(209))
        XCTAssertTrue(busy)
        model.act(.clear(209))
        await drain(model)
        XCTAssertEqual(changes, [209]); XCTAssertFalse(busy)
    }
    func testSuccessfulMutationFollowedByReadFailureDoesNotBecomeWriteFailure() async throws {
        var readFails = false, messages: [String] = []
        let overview = PictureControlOverview(slots: [.init(slot: 209, availability: .occupied)], selected: 1, canActivate: true, canEdit: true)
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { _ in true }, readOverview: { _ in
            if readFails { throw PTPSessionError.invalidResponse }; return overview
        }, change: { _, _, _ in readFails = true })
        model.notice = { messages.append($0) }
        await model.refresh(); model.editingSlot = 209; model.act(.activate(209)); await drain(model)
        XCTAssertNil(model.editingSlot); XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(messages, [AppLocalized.resource("picture_control_slots_read_failed")])
    }
    func testModeFailureNoticeSurvivesRefreshFailureAndBusyIsReleased() async throws {
        var fail = false, busy = false, messages: [String] = []
        let overview = PictureControlOverview(slots: [.init(slot: 201, availability: .occupied)], selected: 1, canActivate: true, canEdit: true)
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { busy = $0; return true }, readOverview: { _ in
            if fail { throw PTPSessionError.invalidResponse }; return overview
        }, change: { _, _, _ in fail = true; throw PictureControlExposureModeError(program: 0, userMode: nil) })
        model.notice = { messages.append($0) }
        await model.refresh(); model.act(.activate(201)); await drain(model)
        XCTAssertFalse(busy); XCTAssertEqual(messages, [AppLocalized.resource("picture_control_exposure_mode_required")])
    }
    func testClosingPanelKeepsWriteBusyUntilAcceptedOperationReturns() async throws {
        let entered = GateTestLatch(), release = GateTestLatch()
        var busy = false, reads = 0
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { busy = $0; return true }, readOverview: { _ in
            reads += 1
            return .init(slots: [.init(slot: 201, availability: .occupied)], selected: 1, canActivate: true, canEdit: true)
        }, change: { _, _, _ in await entered.signal(); await release.wait() })
        model.notice = { _ in XCTFail("Closed panel published notice") }
        await model.refresh(); model.act(.activate(201)); await entered.wait()
        model.close(); XCTAssertTrue(busy)
        await release.signal(); await drain(model)
        XCTAssertFalse(busy); XCTAssertEqual(reads, 1)
    }

    func testRepeatedRefreshStillReadsCameraButDoesNotPublishUnchangedOverview() async {
        var reads = 0
        var overview = PictureControlOverview(slots: [.init(slot: 201, availability: .occupied, name: "Original")],
            selected: 201, canActivate: true, canEdit: true)
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true },
            allowed: { true }, busy: { _ in true }, readOverview: { _ in reads += 1; return overview },
            change: { _, _, _ in XCTFail("Refresh must not write a slot") })
        defer { model.close() }
        await model.refresh()
        var overviews = 0, failures = 0, loading: [Bool] = []
        let subscriptions = [model.$overview.dropFirst().sink { _ in overviews += 1 },
            model.$loadFailed.dropFirst().sink { _ in failures += 1 },
            model.$loading.dropFirst().sink { loading.append($0) }]
        defer { subscriptions.forEach { $0.cancel() } }
        for _ in 0..<120 { await model.refresh() }
        XCTAssertEqual(reads, 121)
        XCTAssertEqual(overviews, 0); XCTAssertEqual(failures, 0)
        XCTAssertEqual(loading.count, 240)
        XCTAssertTrue(stride(from: 0, to: loading.count, by: 2).allSatisfy { loading[$0] && !loading[$0 + 1] })
        overview = .init(slots: [.init(slot: 201, availability: .occupied, name: "Camera changed")],
                         selected: 1, canActivate: true, canEdit: true)
        await model.refresh()
        XCTAssertEqual(overviews, 1)
        XCTAssertEqual(model.overview?.slots.first?.name, "Camera changed")
        XCTAssertEqual(model.overview?.selected, 1)
    }

    func testActualPanelFolderNoticeDoesNotRetainDismissedModel() async throws {
        let folders = PictureControlFolderState()
        defer { folders.close() }
        var notices: [String] = []
        var model: PictureControlPanelModel? = PictureControlPanelModel(folders: folders, current: { true },
            allowed: { true }, busy: { _ in true }, readOverview: { _ in
                .init(slots: [.init(slot: 201, availability: .empty)], selected: 1, canActivate: true, canEdit: true)
            }, change: { _, _, _ in XCTFail("Mounting must not write the camera") })
        weak var weakModel = model
        model?.notice = { notices.append($0) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var host: UIHostingController<RemotePictureControlPanel>? = UIHostingController(rootView:
            RemotePictureControlPanel(model: try XCTUnwrap(model), folders: folders, dismiss: {}, chooseFolder: { _ in XCTFail("Unexpected picker") }))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; weakModel?.close() }
        for _ in 0..<100 {
            if model?.overview != nil && model?.loading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model?.overview)
        XCTAssertFalse(model?.loading ?? true)
        folders.onNotice("picture_control_read_timeout")
        XCTAssertEqual(notices, [AppLocalized.resource("picture_control_read_timeout")])
        window.isHidden = true; window.rootViewController = nil
        host = nil; model = nil
        for _ in 0..<30 {
            if weakModel == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakModel, "The retained folder callback must not own the dismissed model/View")
        folders.onNotice("lut_folder_denied")
        XCTAssertEqual(notices.count, 1)
    }

    private func drain(_ model: PictureControlPanelModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.pending != nil && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(model.pending)
    }
}

@MainActor final class PictureControlReportHistoryTests: XCTestCase {
    func testIndependentGenerationsRetainFailuresAndRejectLateReadsAndRestore() {
        let history = PictureControlReportHistory()
        let op = history.begin(.operation), old = history.begin(.overview), fresh = history.begin(.overview)
        history.restore([.operation: "disk operation", .overview: "disk read"])
        XCTAssertEqual(history.text, "")
        history.finish(fresh, text: "new read")
        history.finish(old, text: "cancelled old read")
        history.finish(op, text: "FAILED rollback completed")
        XCTAssertEqual(history.text, "FAILED rollback completed\n\nnew read")
        history.finish(history.begin(.overview), text: "second read")
        XCTAssertEqual(history.text, "FAILED rollback completed\n\nsecond read")
        history.restore([.operation: "stale", .overview: "stale"])
        history.finish(history.begin(.operation), text: "   ")
        XCTAssertEqual(history.text, "FAILED rollback completed\n\nsecond read")
        history.finish(history.begin(.operation), text: "new success")
        XCTAssertEqual(history.text, "new success\n\nsecond read")
    }
    func testDiskRestorationAndAppendOnlyJournalsKeepBothKindsAndExcludeShares() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, content) in [("PictureControl-100-old.txt", "old operation"), ("PictureControl-200-overview-old.txt", "old read"),
            ("PictureControl-300-overview-new.txt", "new read"), ("PictureControl-400-operation-empty.txt", ""),
            ("Shared-PictureControl-999.txt", "share must not restore")] {
            try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try PictureControlReportJournal.latestByKind(directory: root), [.operation: "old operation", .overview: "new read"])
        let operation = PictureControlReportJournal(kind: .operation, directory: root)
        let overview = PictureControlReportJournal(kind: .overview, directory: root)
        operation.append("FAILED"); overview.append("read completed")
        let shared = try PictureControlReportJournal.share(operation.text)
        defer { try? FileManager.default.removeItem(at: shared) }
        operation.append("rollback completed")
        // Numeric legacy fixture names sort lexically just as on Android;
        // remove them before verifying current timestamp runs.
        for name in ["PictureControl-200-overview-old.txt", "PictureControl-300-overview-new.txt"] { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        XCTAssertEqual(try PictureControlReportJournal.latestByKind(directory: root), [.operation: operation.text, .overview: overview.text])
        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "FAILED\n")
        let bad = root.appendingPathComponent("not-a-directory"); try Data([1]).write(to: bad)
        let journal = PictureControlReportJournal(kind: .overview, directory: bad)
        journal.append("READ FAILED")
        XCTAssertTrue(journal.failed); XCTAssertEqual(journal.text, "READ FAILED\n")
    }
    func testDebugOpeningFailureRetainsReadableDiagnosticAndSpecificMovieReason() async throws {
        for error in [NikonPictureControlError.movieBankUnsupported, .invalid("broken response")] {
            let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true },
                busy: { _ in XCTFail("Opening must not take write ownership"); return false }, readOverview: { log in
                    log?("out op=0x90CC params=1, 0, 1")
                    throw error
                }, change: { _,_,_ in XCTFail("Read failure cannot write") })
            defer { model.close() }
            model.dismiss = { XCTFail("Debug failure remains shareable") }
            model.notice = { _ in XCTFail("Initial debug read uses the diagnostic panel") }
            model.open()
            for _ in 0..<300 { if model.initialLoadFinished { break }; try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(model.initialLoadFinished); XCTAssertFalse(model.opening)
            XCTAssertTrue(model.loadFailed); XCTAssertNil(model.overview)
            XCTAssertTrue(model.report.contains("out op=0x90CC params=1, 0, 1")); XCTAssertTrue(model.report.contains("READ FAILED"))
            XCTAssertEqual(model.loadFailureResource, error == .movieBankUnsupported ? "picture_control_movie_bank_unsupported" : "picture_control_slots_read_failed")
            model.act(.activate(201)); XCTAssertNil(model.pending)
            XCTAssertEqual(PictureControlPanelModel.message(NikonPictureControlError.presetUnsupported("new adjustment"), slot: 201), AppLocalized.resource("picture_control_camera_preset_unsupported"))
        }
    }
    func testLateClosedOverviewCannotReplaceNewPanelsReportButOperationIsIndependent() async throws {
        let reports = PictureControlReportHistory(), entered = GateTestLatch(), release = GateTestLatch()
        let old = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { _ in true },
            readOverview: { log in await entered.signal(); await release.wait(); log?("OLD UNIQUE"); throw PTPSessionError.invalidResponse },
            change: { _,_,_ in }, reports: reports)
        old.open(); await entered.wait(); old.close()
        let fresh = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { _ in true },
            readOverview: { log in log?("NEW UNIQUE"); return .init(slots: [], selected: 1, canActivate: false, canEdit: false) },
            change: { _,_,_ in }, reports: reports)
        defer { fresh.close() }
        fresh.open()
        for _ in 0..<300 { if fresh.initialLoadFinished { break }; try await Task.sleep(for: .milliseconds(5)) }
        await release.signal()
        for _ in 0..<300 { if old.initialLoadFinished { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(reports.text.contains("NEW UNIQUE")); XCTAssertFalse(reports.text.contains("OLD UNIQUE"))
    }
}
