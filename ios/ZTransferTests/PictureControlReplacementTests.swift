import XCTest
@testable import ZTransfer

final class PictureControlReplacementTests: XCTestCase {
    private func store() throws -> PictureControlBackupStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return PictureControlBackupStore(directory: folder)
    }
    func testReplacementVerifiesBeforeActivationAndKeepsFirstOriginal() async throws {
        let camera = ReplacementCamera()
        let backup = try store()
        let replacement = PictureControlReplacement(backup: backup)
        try await replacement.apply(camera, dataset: Data([20]))
        let calls = await camera.log
        XCTAssertEqual(calls, ["read", "selection", "write", "read", "select:209", "selection"])
        try await replacement.apply(camera, dataset: Data([30]))
        XCTAssertEqual(try backup.load(identity: camera.cameraIdentity, slot: 209)?.data, Data([10]))
        let current = try await camera.readSlot()
        XCTAssertEqual(current, Data([30]))
    }
    func testMismatchRestoresMostRecentContentsAndSelectionWithoutOverwritingOriginal() async throws {
        let camera = ReplacementCamera()
        let backup = try store()
        let replacement = PictureControlReplacement(backup: backup)
        try await replacement.apply(camera, dataset: Data([20]))
        try await camera.select(4)
        await camera.failNextWrite()
        do { try await replacement.apply(camera, dataset: Data([30])); XCTFail("Expected verification failure") }
        catch let error as PictureControlReplacementError {
            XCTAssertEqual(error.stage, .verify)
            XCTAssertTrue(error.originalRestored)
        }
        let bytes = try await camera.readSlot(), selection = try await camera.readSelection()
        XCTAssertEqual(bytes, Data([20]))
        XCTAssertEqual(selection, 4)
        XCTAssertEqual(try backup.load(identity: camera.cameraIdentity, slot: 209)?.data, Data([10]))
    }
    func testClearLeavesStandardSelectedAndRecoveryDoesNotReviveOldOtherSlot() async throws {
        let camera = ReplacementCamera()
        let backup = try store()
        let replacement = PictureControlReplacement(backup: backup)
        try await camera.select(209)
        try await replacement.clear(camera)
        let cleared = try await camera.readSlot(), standard = try await camera.readSelection()
        XCTAssertNil(cleared); XCTAssertEqual(standard, 1)
        try await camera.select(205)
        try await replacement.restoreOriginal(camera)
        let restored = try await camera.readSlot(), selected = try await camera.readSelection()
        XCTAssertEqual(restored, Data([10])); XCTAssertEqual(selected, 205)
    }
    func testCancellationAfterAcceptedWriteFinishesVerificationAndActivation() async throws {
        let camera = ReplacementCamera()
        let entered = GateTestLatch(), release = GateTestLatch()
        await camera.suspendNextWrite(entered: entered, release: release)
        let replacement = PictureControlReplacement(backup: try store())
        let task = Task { try await replacement.apply(camera, dataset: Data([20])) }
        await entered.wait()
        task.cancel()
        await release.signal()
        try await task.value
        let bytes = try await camera.readSlot(), selected = try await camera.readSelection()
        XCTAssertEqual(bytes, Data([20])); XCTAssertEqual(selected, 209)
    }
    func testUnknownReadbackCanRestoreKnownDataButDisconnectCannotClaimRecovery() async throws {
        let camera = ReplacementCamera()
        let backup = try store()
        let replacement = PictureControlReplacement(backup: backup)
        try await replacement.apply(camera, dataset: Data([20]))
        await camera.damageReadback()
        try await replacement.restoreOriginal(camera)
        let repaired = try await camera.readSlot()
        XCTAssertEqual(repaired, Data([10]))
        await camera.disconnectAfterNextWrite()
        do { try await replacement.apply(camera, dataset: Data([30])); XCTFail("Expected disconnect") }
        catch let error as PictureControlReplacementError { XCTAssertFalse(error.originalRestored) }
        XCTAssertEqual(try backup.load(identity: camera.cameraIdentity, slot: 209)?.data, Data([10]))
    }
    func testSecondSlotWaitsForAcceptedWriteToFinishEvenWhenFirstCallerCancels() async throws {
        let first = ReplacementCamera(slot: 201), second = ReplacementCamera(slot: 209)
        let entered = GateTestLatch(), release = GateTestLatch()
        await first.suspendNextWrite(entered: entered, release: release)
        let replacement = PictureControlReplacement(backup: try store())
        let a = Task { try await replacement.apply(first, dataset: Data([20])) }
        await entered.wait(); a.cancel()
        let b = Task { try await replacement.apply(second, dataset: Data([30])) }
        try await Task.sleep(for: .milliseconds(20))
        let waiting = await second.log; XCTAssertTrue(waiting.isEmpty)
        await release.signal(); try await a.value; try await b.value
        let firstData = try await first.readSlot(), secondData = try await second.readSlot()
        XCTAssertEqual(firstData, Data([20])); XCTAssertEqual(secondData, Data([30]))
    }

    func testInvalidSlotCannotReadOrMutateCamera() async throws {
        let camera = ReplacementCamera(slot: 1)
        do { try await PictureControlReplacement(backup: store()).apply(camera, dataset: Data([20])); XCTFail("System slot") }
        catch { }
        let log = await camera.log
        XCTAssertTrue(log.isEmpty)
    }
}

private actor ReplacementCamera: PictureControlSlotAccess {
    nonisolated let cameraIdentity = "Nikon\0Z30\0serial\0picture-control-photo"
    nonisolated let slot: Int
    private var bytes: Data? = Data([10])
    private var selected = 1
    private var corrupt = false
    private var connected = true
    private var disconnectOnWrite = false
    private var pause: (GateTestLatch, GateTestLatch)?
    private(set) var log: [String] = []
    init(slot: Int = 209) { self.slot = slot }
    func checkSession() throws { if !connected { throw CameraTransportError.disconnected } }
    func failNextWrite() { corrupt = true }
    func damageReadback() { bytes = Data([99]) }
    func disconnectAfterNextWrite() { disconnectOnWrite = true }
    func suspendNextWrite(entered: GateTestLatch, release: GateTestLatch) { pause = (entered, release) }
    func readSlot() throws -> Data? {
        try checkSession(); log.append("read")
        if bytes == Data([99]) { throw NikonPictureControlError.invalid("Malformed slot") }
        return bytes
    }
    func writeSlot(_ data: Data) async throws {
        try checkSession(); log.append("write")
        bytes = corrupt ? Data([99]) : data
        corrupt = false
        if let pause { self.pause = nil; await pause.0.signal(); await pause.1.wait() }
        if disconnectOnWrite { connected = false; throw CameraTransportError.disconnected }
    }
    func clearSlot() throws {
        try checkSession()
        if selected == slot { throw NikonPictureControlError.invalid("Selected slot cannot be cleared") }
        log.append("clear"); bytes = nil
    }
    func readSelection() throws -> Int { try checkSession(); log.append("selection"); return selected }
    func select(_ value: Int) throws { try checkSession(); log.append("select:\(value)"); selected = value }
}
