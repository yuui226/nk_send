import XCTest
@testable import ZTransfer

@MainActor
final class PictureControlPanelModelTests: XCTestCase {
    func testLateInitialReadFailureCannotDismissReplacementPanel() async throws {
        let entered = GateTestLatch(), release = GateTestLatch()
        var shown = "old", notices: [String] = []
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true },
            busy: { _ in true }, readOverview: {
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
            busy: { _ in true }, readOverview: {
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
            busy: { busy = $0; return true }, readOverview: { overview }, change: { slot, _, _ in changes.append(slot) })
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
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { _ in true }, readOverview: {
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
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { busy = $0; return true }, readOverview: {
            if fail { throw PTPSessionError.invalidResponse }; return overview
        }, change: { _, _, _ in fail = true; throw PictureControlExposureModeError(program: 0, userMode: nil) })
        model.notice = { messages.append($0) }
        await model.refresh(); model.act(.activate(201)); await drain(model)
        XCTAssertFalse(busy); XCTAssertEqual(messages, [AppLocalized.resource("picture_control_exposure_mode_required")])
    }
    func testClosingPanelKeepsWriteBusyUntilAcceptedOperationReturns() async throws {
        let entered = GateTestLatch(), release = GateTestLatch()
        var busy = false, reads = 0
        let model = PictureControlPanelModel(folders: PictureControlFolderState(), current: { true }, allowed: { true }, busy: { busy = $0; return true }, readOverview: {
            reads += 1
            return .init(slots: [.init(slot: 201, availability: .occupied)], selected: 1, canActivate: true, canEdit: true)
        }, change: { _, _, _ in await entered.signal(); await release.wait() })
        model.notice = { _ in XCTFail("Closed panel published notice") }
        await model.refresh(); model.act(.activate(201)); await entered.wait()
        model.close(); XCTAssertTrue(busy)
        await release.signal(); await drain(model)
        XCTAssertFalse(busy); XCTAssertEqual(reads, 1)
    }

    private func drain(_ model: PictureControlPanelModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.pending != nil && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(model.pending)
    }
}
