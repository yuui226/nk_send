import XCTest
@testable import ZTransfer

/// T01, Android 617082c3 AutoTransferModeTest and NewMediaTransferPolicyTest.
/// Also covers admission against the real iOS queue and catalog publication.
final class AutoTransferModeTests: XCTestCase {
    func testSupportedFormatsArePartitionedWithoutRawVideoConfusion() {
        let names = ["a.JPG", "a.jpeg", "a.NEF", "a.MOV", "a.mp4",
                     "a.NEV", "a.HIF", "a.NRW", "a.wav", "no-extension"]
        XCTAssertEqual(names.filter(AutoTransferMode.all.accepts), Array(names.prefix(5)))
        XCTAssertEqual(names.filter(AutoTransferMode.jpg.accepts), Array(names.prefix(2)))
        XCTAssertEqual(names.filter(AutoTransferMode.raw.accepts), ["a.NEF"])
        XCTAssertEqual(names.filter(AutoTransferMode.video.accepts), ["a.MOV", "a.mp4"])
        XCTAssertTrue(names.filter(AutoTransferMode.off.accepts).isEmpty)
        for name in ["jpg", "file.", "", "a.jpg.tmp", "a.AVI", "a.TIF"] {
            XCTAssertFalse(AutoTransferMode.all.accepts(name), name)
        }
        XCTAssertTrue(AutoTransferMode.jpg.accepts("照片.副本.JpEg"))
    }

    func testRestoresNewModesAndMigratesOldSwitch() {
        XCTAssertEqual(AutoTransferMode.allCases.map(\.rawValue), ["OFF", "ALL", "JPG", "RAW", "VIDEO"])
        for legacy in [true, false] {
            for invalid in [nil, "", "jpg", "UNKNOWN"] as [String?] {
                XCTAssertEqual(AutoTransferMode.restored(invalid, legacyEnabled: legacy), legacy ? .all : .off)
            }
            for mode in AutoTransferMode.allCases {
                XCTAssertEqual(AutoTransferMode.restored(mode.rawValue, legacyEnabled: legacy), mode)
            }
        }
    }

    func testPreferencesSurviveReopeningAndPreserveLegacyCompatibility() {
        let suite = isolatedSuite()
        let defaults = UserDefaults(suiteName: suite)!
        XCTAssertEqual(AutoTransferMode.load(from: defaults), .off)
        defaults.set(true, forKey: "auto_transfer_new_media")
        XCTAssertEqual(AutoTransferMode.load(from: defaults), .all)
        for mode in AutoTransferMode.allCases {
            mode.save(to: defaults)
            let reopened = UserDefaults(suiteName: suite)!
            XCTAssertEqual(AutoTransferMode.load(from: reopened), mode)
            XCTAssertEqual(reopened.string(forKey: "auto_transfer_mode"), mode.rawValue)
            XCTAssertEqual(reopened.bool(forKey: "auto_transfer_new_media"), mode != .off)
        }
    }

    func testRealQueueAdmitsOnlyChosenFormatsInSourceOrder() async {
        let names = ["a.JPG", "b.JPEG", "c.NEF", "d.MOV", "e.mp4", "f.AVI", "g.NEV", "h.BIN"]
        let expected: [AutoTransferMode: [String]] = [
            .off: [], .all: Array(names.prefix(5)), .jpg: Array(names.prefix(2)),
            .raw: ["c.NEF"], .video: ["d.MOV", "e.mp4"]
        ]
        for mode in AutoTransferMode.allCases {
            let queue = makeQueue()
            let files = names.enumerated().map { file(UInt32($0.offset + 1), $0.element) }
            let accepted = await queue.enqueueAutomatic(files, mode: mode)
            let snapshot = await queue.snapshot()
            XCTAssertEqual(snapshot.items.map(\.file.fileName), expected[mode])
            XCTAssertEqual(snapshot.items.map(\.id), accepted)
            XCTAssertTrue(snapshot.items.allSatisfy { $0.status == .waiting })
            XCTAssertFalse(snapshot.isTransferring)
        }
    }

    func testModeChangesDoNotRewriteExistingTasksOrFilterManualTransfers() async {
        let queue = makeQueue()
        let jpeg = file(1, "a.JPG"), raw = file(2, "b.NEF"), video = file(3, "c.MOV")
        let jpgIDs = await queue.enqueueAutomatic([jpeg, raw], mode: .jpg)
        let before = await queue.snapshot()
        let ignored = await queue.enqueueAutomatic([raw, video], mode: .off)
        XCTAssertTrue(ignored.isEmpty)
        // No retained rejected batch exists to replay when the preference changes.
        let noEvent = await queue.enqueueAutomatic([], mode: .all)
        XCTAssertTrue(noEvent.isEmpty)
        let after = await queue.snapshot()
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.items.map(\.id), jpgIDs)
        let rawIDs = await queue.enqueueAutomatic([raw, video], mode: .raw)
        XCTAssertEqual(rawIDs.count, 1)
        _ = await queue.enqueue(video) // Manual transfers bypass the selected mode.
        _ = await queue.enqueue(jpeg) // Manual repeats remain independent tasks.
        let final = await queue.snapshot()
        XCTAssertEqual(final.items.map(\.file.fileName), ["a.JPG", "b.NEF", "c.MOV", "a.JPG"])
    }

    func testAutomaticIdentityDeduplicatesBatchAndExistingManualTasks() async {
        let queue = makeQueue()
        let existing = file(1, "a.JPG")
        _ = await queue.enqueue(existing)
        let sameOnOtherCard = file(9, "a.JPG", storage: 2)
        let next = file(2, "b.JPG")
        let nextAlias = file(10, "b.JPG", storage: 2)
        let accepted = await queue.enqueueAutomatic([sameOnOtherCard, next, nextAlias, next], mode: .jpg)
        XCTAssertEqual(accepted.count, 1)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.file.id), [1, 2])
        let differentDate = CameraFile(id: 20, storageID: 1, format: 0x3801, size: 10,
                                      fileName: "a.JPG", captureDate: "20261002T120000", isProtected: false)
        let fresh = await queue.enqueueAutomatic(differentDate, mode: .all)
        XCTAssertNotNil(fresh)
    }

    @MainActor
    func testAutomaticEntryRequiresCameraAndDirectory() async {
        let queue = makeQueue()
        let model = TransferQueueViewModel(queue: queue)
        model.enqueueAutomatic([file(1, "a.JPG")], mode: .all, session: nil,
                               directory: FileManager.default.temporaryDirectory, autoStart: true)
        let session = CameraSession(repository: CameraRepository(debugData: .shared))
        model.enqueueAutomatic([file(1, "a.JPG")], mode: .all, session: session,
                               directory: nil, autoStart: true)
        model.enqueueAutomatic([file(1, "a.JPG")], mode: .off, session: session,
                               directory: FileManager.default.temporaryDirectory, autoStart: true)
        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    @MainActor
    func testAutomaticEntryPassesChosenModeWithoutStartingDeferredWork() async throws {
        let queue = makeQueue()
        let model = TransferQueueViewModel(queue: queue)
        let session = CameraSession(repository: CameraRepository(debugData: .shared))
        model.enqueueAutomatic([file(1, "a.JPG"), file(2, "b.NEF")], mode: .raw, session: session,
                               directory: FileManager.default.temporaryDirectory, autoStart: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await queue.snapshot().items.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items.map(\.file.fileName), ["b.NEF"])
        XCTAssertFalse(snapshot.isTransferring)
        XCTAssertEqual(snapshot.items.first?.status, .waiting)
    }

    @MainActor
    func testCatalogReportsJPEGAndKnownMediaButNeverReplaysOldFiles() async {
        let old = file(1, "old.JPG")
        let additions = [file(2, "new.JPEG"), file(3, "new.NEF"), file(4, "new.MOV"),
                         file(5, "new.AVI"), file(6, "OBJECT.BIN")]
        let harness = AutomaticCatalogHarness(initial: [old], additions: additions)
        let model = PhotoListViewModel(
            scanCatalog: { _, _, _, _, onBatch in
                let result = await harness.next()
                try await onBatch(result.files)
                return result
            }, setRemoteGate: { _ in }
        )
        var batches: [[CameraFile]] = []
        model.setNewMediaHandler { batches.append($0) }
        await model.reload()
        XCTAssertTrue(batches.isEmpty, "Initial catalog is not newly captured media")
        await model.reload()
        XCTAssertEqual(batches.map { $0.map(\.fileName) }, [["new.JPEG", "new.NEF", "new.MOV", "new.AVI"]])
        // The queue's ALL gate further excludes AVI; catalog visibility is independent.
        XCTAssertEqual(model.availableFiles.count, 6)
        await model.reload()
        XCTAssertEqual(batches.count, 1, "Repeated refresh must not replay previously rejected files")
    }

    func testModeCopyMatchesAndroidInAllThreeLanguages() {
        XCTAssertEqual(AndroidLocalization.byResource["auto_transfer_video"],
                       ["zh": "视频", "en": "Video", "hant": "影片"])
        XCTAssertEqual(AndroidLocalization.byResource["auto_transfer_new_media_summary"]?["zh"],
                       "按档位自动加入新增文件：全部、JPG、RAW（NEF 照片）或视频（MOV/MP4）。不影响已有任务和手动传输。")
        XCTAssertEqual(AndroidLocalization.byResource["auto_transfer_new_media_summary"]?["en"],
                       "New files are queued automatically by mode: All, JPG, RAW (NEF photos), or Video (MOV/MP4). Existing tasks and manual transfers are unaffected.")
        XCTAssertEqual(AndroidLocalization.byResource["auto_transfer_new_media_summary"]?["hant"],
                       "依檔位自動加入新增檔案：全部、JPG、RAW（NEF 照片）或影片（MOV/MP4）。不影響既有任務與手動傳輸。")
    }

    private func isolatedSuite() -> String {
        let suite = "AutoTransferModeTests.\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return suite
    }

    private func makeQueue() -> TransferQueue {
        TransferQueue(defaults: UserDefaults(suiteName: isolatedSuite())!)
    }

    private func file(_ id: UInt32, _ name: String, storage: UInt32 = 1) -> CameraFile {
        CameraFile(id: id, storageID: storage, format: 0x3801, size: 10,
                   fileName: name, captureDate: "20261001T120000", isProtected: false)
    }
}

private actor AutomaticCatalogHarness {
    let initial: [CameraFile]
    let additions: [CameraFile]
    var scans = 0
    init(initial: [CameraFile], additions: [CameraFile]) {
        self.initial = initial; self.additions = additions
    }
    func next() -> PhotoScanResult {
        scans += 1
        return PhotoScanResult(files: scans == 1 ? initial : initial + additions,
                               removedHandles: [], addedHandles: scans == 2 ? Set(additions.map(\.id)) : [],
                               handleQueriesSucceeded: true, metadataComplete: true)
    }
}
