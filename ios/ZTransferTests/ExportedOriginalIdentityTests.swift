import XCTest
@testable import ZTransfer

/// Android ExistingFileNameIndexTest: AP real names and STA inferred names
/// share number/type identity without changing filename reservation behavior.
final class ExportedOriginalIdentityTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/exports", isDirectory: true)
    private func file(_ name: String, size: UInt64 = 123) -> CameraFile {
        CameraFile(id: 99, storageID: 1, format: 0x3801, size: size,
                   fileName: name, captureDate: "20260929T120000", isProtected: false)
    }

    func testDifferentPrefixesMatchOnlySameNumberTypeSizeAndDirectory() {
        var index = TransferDirectoryIndex(directory: root)
        let copy = root.appendingPathComponent("DSC_9049 (2).JPG")
        index.addOriginal(copy, size: 123)
        XCTAssertEqual(index.existingOriginal(for: file("Z30_9049.jpg")), copy)
        XCTAssertNil(index.existingOriginal(for: file("Z30_9049.NEF")))
        XCTAssertNil(index.existingOriginal(for: file("Z30_9049.JPG", size: 124)))
        XCTAssertNil(index.existingOriginal(for: file("Z30_9050.JPG")))
        XCTAssertEqual(index.existingOriginal(for: file("Z30_9049.JPG", size: UInt64(UInt32.max))), copy)

        var exported = ExportedOriginalIndex()
        exported.add(copy, size: 123, folderName: "ZT2026-09-29")
        XCTAssertEqual(exported.original(for: file("Z30_9049.JPG"), folderName: "ZT2026-09-29"), copy)
        XCTAssertNil(exported.original(for: file("Z30_9049.JPG"), folderName: nil))
        XCTAssertNil(exported.original(for: file("Z30_9049.JPG"), folderName: "ZT2026-09-28"))
        XCTAssertNil(exported.original(for: file("Z30_9049.NEF"), folderName: "ZT2026-09-29"))
        XCTAssertNil(exported.original(for: file("Z30_9049.JPG", size: 124), folderName: "ZT2026-09-29"))
    }

    func testExactNameWinsAndReplacementRemovesOldSize() {
        var index = TransferDirectoryIndex(directory: root)
        let copy = root.appendingPathComponent("DSC_0001 (2).JPG")
        let exact = root.appendingPathComponent("DSC_0001.JPG")
        index.addOriginal(copy, size: 123)
        index.addOriginal(exact, size: 123)
        XCTAssertEqual(index.existingOriginal(for: file("DSC_0001.JPG")), exact)
        XCTAssertEqual(index.existingOriginal(for: file("dsc_0001.jpg")), copy)
        index.addOriginal(copy, size: 120)
        index.addOriginal(exact, size: 120)
        XCTAssertNil(index.existingOriginal(for: file("Z30_0001.JPG")))
        XCTAssertEqual(index.existingOriginal(for: file("Z30_0001.JPG", size: 120)), copy)
    }

    func testVideosCropsNonNumericNamesAndLeadingZeros() {
        var index = TransferDirectoryIndex(directory: root)
        for name in ["DSC_9053.MP4", "DSC_9049_crop.JPG", "holiday.JPG", "DSC_0001.JPG"] {
            index.addOriginal(root.appendingPathComponent(name), size: 123)
        }
        XCTAssertNotNil(index.existingOriginal(for: file("Z30_9053.mp4")))
        for name in ["Z30_9053.MOV", "Z30_9049.JPG", "trip.JPG", "Z30_1.JPG"] {
            XCTAssertNil(index.existingOriginal(for: file(name)))
        }
        XCTAssertNotNil(index.existingOriginal(for: file("HOLIDAY.jpg")))
    }

    func testDiskScanAndExportMergeUseTheSameCrossModeIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("DSC_9049 (2).JPG")
        try Data(count: 123).write(to: output)
        let index = TransferDirectoryIndex.scan(directory: directory)
        XCTAssertEqual(index.existingOriginal(for: file("Z30_9049.JPG")), output)
        XCTAssertEqual(existingTransferDestination(for: file("Z30_9049.JPG"), in: directory), output)
        var exported = ExportedOriginalIndex()
        exported.merge(index, folderName: nil)
        XCTAssertEqual(exported.original(for: file("Z30_9049.JPG"), folderName: nil), output)
    }
}


extension ExportedOriginalIdentityTests {
    @MainActor
    func testRetryReadsDiskIndexUsingCapturedFolderAndPublishesWithoutCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retry-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("ZT-JPG", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 123).write(to: folder.appendingPathComponent("DSC_9049.JPG"))
        let model = PhotoListViewModel(scanCatalog: nil, setRemoteGate: { _ in })
        model.refreshTransferredIDs(directory: directory, storageMode: .byType)
        let startedRevision = model.transferOriginalIndexRevision
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.transferOriginalIndexRevision == startedRevision, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(model.transferOriginalIndexRevision, startedRevision)
        XCTAssertTrue(model.availableFiles.isEmpty, "No catalog is needed to admit a queue retry")
        let source = file("Z30_9049.JPG")
        XCTAssertTrue(model.hasTransferredOriginal(source, folderName: "ZT-JPG", directory: directory))
        XCTAssertFalse(model.hasTransferredOriginal(source, folderName: nil, directory: directory))
        XCTAssertFalse(model.hasTransferredOriginal(source, folderName: "ZT-NEF", directory: directory))
        XCTAssertFalse(model.hasTransferredOriginal(file("Z30_9049.JPG", size: 124), folderName: "ZT-JPG", directory: directory))
        var failed = TransferQueueItem(id: UUID(), file: source, status: .failed, destinationFolderName: "ZT-JPG")
        XCTAssertTrue(failed.canRetry)
        XCTAssertFalse(failed.retryNeedsCamera(hasIndexedOriginal: model.hasTransferredOriginal(source, folderName: failed.destinationFolderName, directory: directory)))
        XCTAssertTrue(failed.retryNeedsCamera(hasIndexedOriginal: false))
        failed.outputURL = folder.appendingPathComponent("DSC_9049.JPG")
        XCTAssertFalse(failed.retryNeedsCamera(hasIndexedOriginal: false))
        model.refreshTransferredIDs(directory: nil, storageMode: .unified)
        XCTAssertFalse(model.hasTransferredOriginal(source, folderName: "ZT-JPG", directory: directory))
    }

    func testRetryEligibilityIgnoresStaleErrorWhileGenerating() {
        for status: TransferStatus in [.waiting, .transferring, .completed, .failed, .cancelled] {
            for error in [nil, "generation failed"] as [String?] {
                var item = TransferQueueItem(id: UUID(), file: file("A.JPG"), status: status)
                item.frameError = error
                XCTAssertEqual(item.canRetry, status == .failed || status == .cancelled || error != nil)
                item.isGeneratingFrame = true
                XCTAssertFalse(item.canRetry)
            }
        }
    }

    @MainActor
    func testManualOfflineAdmissionRequiresWholeBatchInCurrentDestination() {
        let model = PhotoListViewModel(scanCatalog: nil, setRemoteGate: { _ in })
        model.refreshTransferredIDs(directory: root, storageMode: .unified)
        let first = file("Z30_9049.JPG")
        let missing = file("Z30_9050.JPG") // Deliberately the same handle, different source.
        let saved = root.appendingPathComponent("DSC_9049 (2).JPG")
        model.recordTransferredOriginals([TransferQueueItem(id: UUID(), file: first,
            status: .completed, outputURL: saved)])
        XCTAssertTrue(model.canEnqueueManually([first], connected: false, directory: root, storageMode: .unified))
        XCTAssertFalse(model.canEnqueueManually([first, missing], connected: false, directory: root, storageMode: .unified))
        XCTAssertFalse(model.canEnqueueManually([file("Z30_9049.JPG", size: 124)], connected: false, directory: root, storageMode: .unified))
        XCTAssertFalse(model.canEnqueueManually([first], connected: false, directory: root, storageMode: .byType))
        XCTAssertFalse(model.canEnqueueManually([first], connected: false, directory: root.appendingPathComponent("other"), storageMode: .unified))
        XCTAssertFalse(model.canEnqueueManually([first], connected: true, directory: nil, storageMode: .unified))
        XCTAssertFalse(model.canEnqueueManually([], connected: true, directory: root, storageMode: .unified))
        XCTAssertTrue(model.canEnqueueManually([first, missing], connected: true, directory: root, storageMode: .unified))
        model.recordTransferredOriginals([TransferQueueItem(id: UUID(), file: missing,
            status: .completed, outputURL: root.appendingPathComponent(missing.fileName))])
        XCTAssertTrue(model.canEnqueueManually([first, missing], connected: false, directory: root, storageMode: .unified))
        let typed = root.appendingPathComponent("ZT-JPG").appendingPathComponent(first.fileName)
        model.recordTransferredOriginals([TransferQueueItem(id: UUID(), file: first,
            status: .completed, outputURL: typed, destinationFolderName: "ZT-JPG")])
        XCTAssertTrue(model.canEnqueueManually([first], connected: false, directory: root, storageMode: .byType))
        model.refreshTransferredIDs(directory: nil, storageMode: .unified)
        XCTAssertFalse(model.canEnqueueManually([first], connected: false, directory: root, storageMode: .unified))
    }

    @MainActor
    func testManualAdmissionUsesRefreshedDiskIndexForEveryStorageMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = file("Z30_9049.JPG")
        let second = file("Z30_9050.JPG")
        for mode in TransferStorageMode.allCases {
            let destinationRoot = directory.appendingPathComponent(mode.rawValue)
            let folderName = transferStorageFolderName(file: first, mode: mode)
            let destination = folderName.map { destinationRoot.appendingPathComponent($0) } ?? destinationRoot
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let firstURL = destination.appendingPathComponent("DSC_9049 (2).JPG")
            let secondURL = destination.appendingPathComponent(second.fileName)
            try Data(count: 123).write(to: firstURL)
            let model = PhotoListViewModel(scanCatalog: nil, setRemoteGate: { _ in })

            func refresh() async throws {
                model.refreshTransferredIDs(directory: destinationRoot, storageMode: mode)
                let revision = model.transferOriginalIndexRevision
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while model.transferOriginalIndexRevision == revision, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThan(model.transferOriginalIndexRevision, revision)
            }
            func admits(_ files: [CameraFile], connected: Bool = false) -> Bool {
                model.canEnqueueManually(files, connected: connected, directory: destinationRoot, storageMode: mode)
            }

            try await refresh()
            XCTAssertTrue(admits([first]))
            XCTAssertFalse(admits([second]))
            XCTAssertFalse(admits([first, second]), "Reject the entire mixed batch")
            XCTAssertTrue(admits([first, second], connected: true), "Reconnect permits camera sources")
            try Data(count: 123).write(to: secondURL)
            try await refresh()
            XCTAssertTrue(admits([first, second]))
            try FileManager.default.removeItem(at: firstURL)
            try await refresh()
            XCTAssertFalse(admits([first]))
            XCTAssertFalse(admits([first, second]))
            XCTAssertTrue(admits([second]))
        }
    }

    func testDisconnectedSignalAttentionTimingAndInterruption() {
        var motion = PhotoListSignalAttentionMotion()
        motion.trigger()
        motion.advance(0)
        motion.advance(60_000_000)
        XCTAssertEqual(motion.scale.value, 1 + 0.15 * 0.7755613, accuracy: 0.00001)
        let shown = motion.scale.value
        motion.trigger()
        XCTAssertEqual(motion.scale.value, shown)
        motion.advance(180_000_000)
        XCTAssertEqual(motion.scale.value, 1.15, accuracy: 0.00001)
        motion.advance(196_000_000)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.scale.value, 1)
        XCTAssertFalse(motion.scale.isRunning)
        motion.trigger()
        motion.advance(3_000_000_000)
        motion.advance(3_120_000_000)
        XCTAssertEqual(motion.scale.value, 1.15, accuracy: 0.00001)
    }
}


extension ExportedOriginalIdentityTests {
    func testBottomHintSpringRetainsOutgoingContentAndReversesWithoutJump() {
        var hint = PhotoListHintMotion()
        hint.setVisible(true, height: 121)
        XCTAssertEqual(hint.offset.value, 60)
        hint.setVisible(true, height: 161)
        XCTAssertEqual(hint.offset.value, 80)
        hint.setVisible(true, height: 121)
        hint.advance(0)
        hint.advance(100_000_000)
        let expected = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 400)
            .animationSample(at: 100_000_000, from: 0, to: 1, velocity: 0)
        XCTAssertEqual(hint.alpha.value, expected.value, accuracy: 0.00001)
        let alpha = hint.alpha.value
        hint.setVisible(false, height: 121)
        XCTAssertTrue(hint.retained)
        XCTAssertEqual(hint.alpha.value, alpha)
        hint.advance(150_000_000)
        let exiting = hint.alpha.value
        hint.setVisible(true, height: 121)
        XCTAssertEqual(hint.alpha.value, exiting)
        hint.advance(2_000_000_000)
        XCTAssertEqual(hint.alpha.value, 1)
        XCTAssertEqual(hint.offset.value, 0)
        hint.setVisible(false, height: 121)
        hint.advance(3_000_000_000)
        hint.advance(5_000_000_000)
        XCTAssertFalse(hint.retained)
        XCTAssertEqual(hint.offset.value, 60)
    }

    @MainActor
    func testBottomHintReplacementRestartsDeadlineAndRetainsTextOnExit() async throws {
        let state = PhotoListHintState()
        state.show("first", duration: .milliseconds(30))
        state.show("replacement", duration: .milliseconds(180))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.text, "replacement")
        state.show("replacement", duration: .milliseconds(180))
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertTrue(state.visible)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(state.visible)
        XCTAssertEqual(state.text, "replacement")
        state.show("last", duration: .milliseconds(30))
        state.stop()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(state.visible)
        XCTAssertEqual(state.text, "last")
    }
}
