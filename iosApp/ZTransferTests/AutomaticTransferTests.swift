import Foundation
import ZTransferShared
import XCTest
@testable import ZTransfer

/// Captures orchestration only. Duplicate/media/identity decisions still run the real shared queue.
private actor AutomaticAdmissionProbe: CameraAutomaticTransferAdmitting {
    struct Call: Sendable {
        let handle: Int32
        let byDate: Bool
        let dayKey: Int32
        let deferred: Bool
    }
    private let core = NativeOriginalTransferQueue()
    private var calls: [Call] = []
    private var completedCalls = 0
    private var target = true
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() { holdNext = true }
    func release() { held?.resume(); held = nil }
    func isHeld() -> Bool { held != nil }
    func completedCount() -> Int { completedCalls }
    func setTarget(_ value: Bool) { target = value }
    func pause() { core.pauseAfterCurrent() }
    func observations() -> (calls: [Call], count: Int, running: Bool, paused: Bool) {
        (calls, Int(core.count), core.running, core.paused)
    }
    func enqueueNewMedia(_ infos: [PtpObjectInfo], files: [CameraFileInfo], enabled: Bool,
                         byDate: Bool, dayKey: Int32, deferred: Bool) async -> Int {
        defer { completedCalls += 1 }
        calls.append(Call(handle: infos.first?.handle ?? 0, byDate: byDate, dayKey: dayKey, deferred: deferred))
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
        guard !Task.isCancelled, enabled, target else { return 0 }
        let accepted = Int(core.enqueueNewMedia(infos: infos, files: files, byDate: byDate, dayKey: dayKey))
        if accepted > 0 && core.shouldAutoStart(deferred: deferred) { _ = core.start() }
        return accepted
    }
}

private actor AutomaticSelectedDirectory: OriginalFilesDestination {
    func validateSelection() {}
    func publish(_ saved: SavedCameraFile, originalName: String?, folder: String?) -> SavedCameraFile { saved }
    func originals(since revision: Int64, rescan: Bool) -> OriginalIndexUpdate {
        OriginalIndexUpdate(revision: 0, baseRevision: revision, fullSnapshot: true, entries: [])
    }
    func copyOriginal(_ reference: ExistingOriginalReference, to output: SandboxTransferFile) throws -> Int64 {
        throw OriginalIndexError.unsafeRoot
    }
    func originalData(locator: String) throws -> Data { throw OriginalIndexError.unsafeRoot }
    func originalRawPreviewData(locator: String) throws -> Data? { throw OriginalIndexError.unsafeRoot }
    func originalExif(locator: String) throws -> PhotoExif? { throw OriginalIndexError.unsafeRoot }
}

final class AutomaticTransferTests: XCTestCase {
    @MainActor func testAutomaticDefaultAndOldVersionOneDocumentRemainOff() throws {
        let suite = "automatic-default-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TransferPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.readAutomatic(), false)
        XCTAssertNil(defaults.object(forKey: TransferPreferencesStore.key))
        let legacy = Data(#"{"version":1,"organizeByDate":true,"deferStart":true}"#.utf8)
        defaults.set(legacy, forKey: TransferPreferencesStore.key)
        XCTAssertEqual(store.readAutomatic(), false)
        XCTAssertEqual(store.read()?.organizeByDate, true)
        XCTAssertEqual(store.read()?.deferStart, true)
        XCTAssertEqual(defaults.data(forKey: TransferPreferencesStore.key), legacy)
    }

    @MainActor func testAutomaticAndManualOptionsShareOneDocumentWithoutClobbering() throws {
        let suite = "automatic-options-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TransferPreferencesStore(defaults: defaults)
        defaults.set(Data([4, 5]), forKey: BrowsePreferencesStore.key)
        XCTAssertTrue(store.saveAutomatic(true))
        XCTAssertTrue(store.save(NativeTransferPreferences(organizeByDate: true, deferStart: true)))
        XCTAssertEqual(store.readAutomatic(), true)
        XCTAssertTrue(store.saveAutomatic(false))
        let reopened = TransferPreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.read()?.organizeByDate, true)
        XCTAssertEqual(reopened.read()?.deferStart, true)
        XCTAssertEqual(reopened.readAutomatic(), false)
        XCTAssertEqual(defaults.data(forKey: BrowsePreferencesStore.key), Data([4, 5]))
    }

    @MainActor func testCorruptFutureWrongTypeAndOversizedAutomaticDocumentsAreNotOverwritten() throws {
        let suite = "automatic-invalid-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TransferPreferencesStore(defaults: defaults)
        for bytes in [Data("broken".utf8), Data(repeating: 0, count: 4097),
                      Data(#"{"version":2,"organizeByDate":true,"deferStart":true,"autoTransferNewMedia":true}"#.utf8),
                      Data(#"{"version":1,"organizeByDate":false,"deferStart":false,"autoTransferNewMedia":"true"}"#.utf8)] {
            defaults.set(bytes, forKey: TransferPreferencesStore.key)
            XCTAssertNil(store.readAutomatic()); XCTAssertNil(store.read())
            XCTAssertFalse(store.saveAutomatic(true)); XCTAssertFalse(store.save(NativeTransferPreferences.companion.defaults()))
            XCTAssertEqual(defaults.data(forKey: TransferPreferencesStore.key), bytes)
        }
        defaults.set("wrong type", forKey: TransferPreferencesStore.key)
        XCTAssertNil(store.readAutomatic()); XCTAssertFalse(store.saveAutomatic(false))
        XCTAssertEqual(defaults.string(forKey: TransferPreferencesStore.key), "wrong type")
    }

    @MainActor func testExplicitRecoveryResetsOnlyTransferOptionsAndKeepsAutomaticOff() throws {
        let suite = "automatic-reset-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([9]), forKey: TransferPreferencesStore.key)
        defaults.set(Data([8]), forKey: BrowsePreferencesStore.key)
        let store = TransferPreferencesStore(defaults: defaults)
        let owner = CameraAutomaticTransferCoordinator(connectionID: UUID(), queue: AutomaticAdmissionProbe(), preferences: store)
        XCTAssertNil(owner.enabled); XCTAssertFalse(owner.setEnabled(true))
        XCTAssertTrue(owner.resetAfterUserConfirmation())
        XCTAssertEqual(owner.enabled, false)
        XCTAssertEqual(store.read()?.organizeByDate, false); XCTAssertEqual(store.read()?.deferStart, false)
        XCTAssertEqual(defaults.data(forKey: BrowsePreferencesStore.key), Data([8]))
        owner.close(); XCTAssertFalse(owner.resetAfterUserConfirmation())
    }

    @MainActor func testOnlyNewSupportedMediaFromSameGenerationEntersSharedQueue() async throws {
        let suite = "automatic-media-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        owner.receive(try addition(UUID(), handle: 1, revision: 100)) // Foreign revision cannot poison the real cursor.
        owner.receive(try addition(id, handle: 1, revision: 1, newMedia: false)) // Backup/refresh publication.
        owner.receive(try addition(id, handle: 2, revision: 2, name: "NOTES.TXT")) // Shared media whitelist.
        owner.receive(try addition(id, handle: 3, revision: 3, complete: false))
        owner.receive(try addition(id, handle: 4, revision: 4, changed: true))
        owner.receive(try addition(id, handle: 5, revision: 5, name: "NEW.NEF"))
        try await eventually { await queue.observations().count == 1 }
        let state = await queue.observations()
        XCTAssertEqual(state.calls.map(\.handle), [2, 5]); XCTAssertTrue(state.running)
    }

    @MainActor func testDuplicatePublicationAndDuplicateLogicalMediaAreBothSuppressed() async throws {
        let suite = "automatic-duplicates-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        let first = try addition(id, handle: 1, revision: 1, name: "DUP.JPG")
        owner.receive(first); owner.receive(first)
        owner.receive(try addition(id, handle: 2, revision: 2, name: "DUP.JPG"))
        owner.receive(try addition(id, handle: 3, revision: 3, name: "NEXT.MOV"))
        try await eventually { await queue.observations().count == 2 }
        let state = await queue.observations()
        XCTAssertEqual(state.calls.map(\.handle), [1, 2, 3]); XCTAssertEqual(state.count, 2)
    }

    @MainActor func testOneCatchUpPublicationAdmitsEveryUniqueNewHandleInOrder() async throws {
        let suite = "automatic-catchup-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        let first = try addition(id, handle: 1, revision: 8)
        owner.receive(first)
        owner.receive(try addition(id, handle: 2, revision: 8))
        owner.receive(first)
        owner.receive(try addition(id, handle: 3, revision: 7)) // Out-of-order stale publication.
        owner.receive(try addition(id, handle: 4, revision: 8))
        try await eventually { await queue.observations().count == 3 }
        let state = await queue.observations()
        XCTAssertEqual(state.calls.map(\.handle), [1, 2, 4])
    }

    @MainActor func testLargeCatchUpKeepsAllCandidatesInPublicationOrder() async throws {
        let suite = "automatic-large-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        for handle in Int32(1)...Int32(600) { owner.receive(try addition(id, handle: handle, revision: 5)) }
        try await eventually { await queue.observations().count == 600 }
        let state = await queue.observations()
        XCTAssertEqual(state.calls.map(\.handle), Array(Int32(1)...Int32(600)))
    }

    @MainActor func testToggleOnDoesNotBackfillDisabledEventsAndToggleOffDropsPendingOnly() async throws {
        let suite = "automatic-toggle-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        let disabled = try addition(id, handle: 1, revision: 1)
        owner.receive(disabled); XCTAssertTrue(owner.setEnabled(true)); owner.receive(disabled)
        owner.receive(try addition(id, handle: 2, revision: 2))
        XCTAssertTrue(owner.setEnabled(false)) // Same MainActor turn: task has not reached admission.
        XCTAssertTrue(owner.setEnabled(true))
        owner.receive(try addition(id, handle: 3, revision: 3))
        try await eventually { await queue.observations().count == 1 }
        let state = await queue.observations(); XCTAssertEqual(state.calls.map(\.handle), [3])
        XCTAssertTrue(owner.setEnabled(false))
        let retained = await queue.observations(); XCTAssertEqual(retained.count, 1)
    }

    @MainActor func testDisableWhileAdmissionIsSuspendedCancelsOldTaskWithoutPoisoningNewWorker() async throws {
        let suite = "automatic-cancel-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        await queue.hold()
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        owner.receive(try addition(id, handle: 1, revision: 1))
        try await eventually { await queue.isHeld() }
        owner.receive(try addition(id, handle: 2, revision: 2))
        XCTAssertTrue(owner.setEnabled(false)); XCTAssertTrue(owner.setEnabled(true))
        owner.receive(try addition(id, handle: 3, revision: 3))
        await queue.release()
        try await eventually { await queue.observations().count == 1 }
        let state = await queue.observations(); XCTAssertEqual(state.calls.map(\.handle), [1, 3])
    }

    @MainActor func testFailedDisableCancelsHeldAdmissionAndCannotSilentlyReenableThisSession() async throws {
        let suite = "automatic-failed-disable-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        let validEnabledDocument = try XCTUnwrap(defaults.data(forKey: TransferPreferencesStore.key))
        await queue.hold()
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        owner.receive(try addition(id, handle: 1, revision: 1))
        try await eventually { await queue.isHeld() }
        owner.receive(try addition(id, handle: 2, revision: 2))

        let corrupt = Data("broken".utf8)
        defaults.set(corrupt, forKey: TransferPreferencesStore.key)
        XCTAssertFalse(owner.setEnabled(false))
        XCTAssertNil(owner.enabled) // Preserve the recovery warning, not a false successful save.
        XCTAssertEqual(defaults.data(forKey: TransferPreferencesStore.key), corrupt)
        XCTAssertFalse(owner.setEnabled(true)) // Failed enable cannot release the session latch.
        await queue.release()
        try await eventually { await queue.completedCount() == 1 }
        let stopped = await queue.observations()
        XCTAssertEqual(stopped.count, 0)
        XCTAssertEqual(stopped.calls.map(\.handle), [1])

        // Even if the old enabled document becomes readable, only explicit enabling resumes.
        defaults.set(validEnabledDocument, forKey: TransferPreferencesStore.key)
        owner.preferencesDidChange()
        XCTAssertEqual(owner.enabled, false)
        let disabled = try addition(id, handle: 3, revision: 3)
        owner.receive(disabled)
        XCTAssertTrue(owner.setEnabled(true))
        XCTAssertEqual(owner.enabled, true)
        owner.receive(disabled) // No backfill of media observed while the session was stopped.
        owner.receive(try addition(id, handle: 4, revision: 4))
        try await eventually { await queue.completedCount() == 2 }
        let resumed = await queue.observations()
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(resumed.calls.map(\.handle), [1, 4])
    }

    @MainActor func testConfirmedRecoveryCancelsHeldAdmissionAndRequiresExplicitEnable() async throws {
        let suite = "automatic-reset-held-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        await queue.hold()
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        owner.receive(try addition(id, handle: 1, revision: 1))
        try await eventually { await queue.isHeld() }
        owner.receive(try addition(id, handle: 2, revision: 2))
        defaults.set(Data("broken".utf8), forKey: TransferPreferencesStore.key)
        XCTAssertTrue(owner.resetAfterUserConfirmation())
        XCTAssertEqual(owner.enabled, false)
        XCTAssertEqual(store.readAutomatic(), false)
        await queue.release()
        try await eventually { await queue.completedCount() == 1 }
        let stopped = await queue.observations()
        XCTAssertEqual(stopped.count, 0)
        XCTAssertEqual(stopped.calls.map(\.handle), [1])
        let disabled = try addition(id, handle: 3, revision: 3)
        owner.receive(disabled)
        XCTAssertTrue(owner.setEnabled(true))
        owner.receive(disabled)
        owner.receive(try addition(id, handle: 4, revision: 4))
        try await eventually { await queue.completedCount() == 2 }
        let resumed = await queue.observations()
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(resumed.calls.map(\.handle), [1, 4])
    }

    @MainActor func testDateDeferredAndFallbackDayAreFrozenTogetherAtReceipt() async throws {
        let suite = "automatic-snapshot-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        XCTAssertTrue(store.save(NativeTransferPreferences(organizeByDate: true, deferStart: true)))
        var day: Int32 = 20260908
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store, dayKey: { day })
        defer { owner.close() }
        owner.receive(try addition(id, handle: 1, revision: 1))
        day = 20260909
        XCTAssertTrue(store.save(NativeTransferPreferences(organizeByDate: false, deferStart: false)))
        owner.receive(try addition(id, handle: 2, revision: 2))
        // Effective page state can differ from disk after an acknowledged UI choice fails to save.
        owner.receive(try addition(id, handle: 3, revision: 3),
                      transfer: NativeTransferPreferences(organizeByDate: true, deferStart: false))
        try await eventually { await queue.observations().calls.count == 3 }
        let calls = await queue.observations().calls
        XCTAssertEqual(calls.map(\.byDate), [true, false, true])
        XCTAssertEqual(calls.map(\.deferred), [true, false, false])
        XCTAssertEqual(calls.map(\.dayKey), [20260908, 20260909, 20260909])
    }

    @MainActor func testMissingDirectoryDoesNotCreateRetryOrBackfillAndManualPauseSurvives() async throws {
        let suite = "automatic-directory-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        await queue.setTarget(false)
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        defer { owner.close() }
        let missing = try addition(id, handle: 1, revision: 1)
        owner.receive(missing)
        try await eventually { await queue.observations().calls.count == 1 }
        await queue.setTarget(true); await queue.pause()
        owner.receive(missing); owner.receive(try addition(id, handle: 2, revision: 2))
        try await eventually { await queue.observations().count == 1 }
        let state = await queue.observations()
        XCTAssertEqual(state.calls.map(\.handle), [1, 2]); XCTAssertTrue(state.paused); XCTAssertFalse(state.running)
    }

    @MainActor func testCloseCancelsHeldAndPendingEventsAndRejectsOldGenerationReuse() async throws {
        let suite = "automatic-close-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), queue = AutomaticAdmissionProbe(), store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        await queue.hold()
        let owner = CameraAutomaticTransferCoordinator(connectionID: id, queue: queue, preferences: store)
        owner.receive(try addition(id, handle: 1, revision: 1))
        try await eventually { await queue.isHeld() }
        owner.receive(try addition(id, handle: 2, revision: 2)); owner.close()
        owner.receive(try addition(id, handle: 3, revision: 3)); XCTAssertFalse(owner.setEnabled(true))
        await queue.release()
        let newID = UUID(), reopened = CameraAutomaticTransferCoordinator(connectionID: UUID(), queue: queue, preferences: store)
        reopened.receive(try addition(id, handle: 4, revision: 4)); reopened.close()
        let next = CameraAutomaticTransferCoordinator(connectionID: newID, queue: queue, preferences: store)
        defer { next.close() }
        next.receive(try addition(newID, handle: 5, revision: 1))
        try await eventually { await queue.observations().count == 1 }
        let state = await queue.observations(); XCTAssertEqual(state.calls.map(\.handle), [1, 5])
    }

    @MainActor func testRealOriginalQueueReceivesFrozenFolderAndRetainsManualPause() async throws {
        let suite = "automatic-real-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let camera = CameraWiFiConnection(command: try CameraTCPStream(host: "127.0.0.1", port: 15740),
                                          event: try CameraTCPStream(host: "127.0.0.1", port: 15740))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root),
                                        destination: AutomaticSelectedDirectory())
        let store = TransferPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.saveAutomatic(true))
        XCTAssertTrue(store.save(NativeTransferPreferences(organizeByDate: true, deferStart: false)))
        await queue.pauseAfterCurrent()
        let owner = CameraAutomaticTransferCoordinator(connectionID: camera.connectionID, queue: queue, preferences: store)
        defer { owner.close() }
        owner.receive(try addition(camera.connectionID, handle: 1, revision: 1))
        owner.receive(try addition(camera.connectionID, handle: 2, revision: 2, name: "IMG_1.JPG"))
        try await eventually { await queue.snapshot().rows.count == 1 }
        let state = await queue.snapshot()
        XCTAssertTrue(state.paused); XCTAssertFalse(state.running)
        XCTAssertEqual(state.rows.first?.destinationFolderName, "ZT2026-09-08")
        XCTAssertEqual(state.rows.first?.status, "WAITING")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)) // No socket or disk IO before explicit resume.
        await camera.abort()
    }

    private func eventually(_ predicate: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Automatic transfer did not reach the expected state")
        throw CameraStreamError.timedOut
    }

    private func addition(_ id: UUID, handle: Int32, revision: UInt64, name: String? = nil,
                          newMedia: Bool = true, complete: Bool = true, changed: Bool = false) throws -> CameraCatalogAddition {
        var payload = Data(repeating: 0, count: 52)
        payload[0] = 1; payload[2] = 1; payload[4] = 1; payload[5] = 0x38; payload[8] = 10
        for value in [name ?? "IMG_\(handle).JPG", "20260908T120000", ""] {
            payload.append(UInt8(value.utf16.count + 1))
            for unit in value.utf16 { payload.append(UInt8(truncatingIfNeeded: unit)); payload.append(UInt8(unit >> 8)) }
            payload.append(contentsOf: [0, 0])
        }
        let info = try XCTUnwrap(PtpIPChannel.objectInfo(handle: handle, payload: payload))
        let file = try XCTUnwrap(NewCameraObjectPolicy.shared.publicationFile(info: info))
        let snapshot = CameraCatalogSnapshot(connectionID: id, revision: revision, storageIDs: [0x10001],
            files: [file], objectInfos: [handle: info], totalHandles: 1, metadataComplete: complete,
            changedWhileScanning: changed, publicationRevision: revision)
        return CameraCatalogAddition(snapshot: snapshot, info: info, newMedia: newMedia ? file : nil)
    }
}
