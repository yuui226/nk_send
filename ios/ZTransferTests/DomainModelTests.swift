import XCTest
import UIKit
@testable import ZTransfer

final class DomainModelTests: XCTestCase {
    func testTransferSpeedMatchesAndroidInvalidAndRetainedSampleRules() {
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 0, elapsedMs: 100), 0)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 1_048_576, elapsedMs: 1_000), 1_048_576)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 1_048_576, elapsedMs: 0), 0)
        XCTAssertEqual(retainLastValidTransferSpeed(previous: 2_400, sample: 0), 2_400)
        XCTAssertEqual(retainLastValidTransferSpeed(previous: 2_400, sample: 1_200), 1_200)
    }

    @MainActor
    func testEffectPreviewCandidateSkipsVideoAndUsesNewestCaptureDateThenHandle() {
        let files = [
            CameraFile(id: 9, storageID: 1, format: 0x300E, size: 1,
                       fileName: "new.MP4", captureDate: "20990101T000000", isProtected: false),
            CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                       fileName: "older.JPG", captureDate: "20260101T000000", isProtected: false),
            CameraFile(id: 7, storageID: 1, format: 0x3801, size: 1,
                       fileName: "newer.JPG", captureDate: "20260914T000000", isProtected: false),
        ]
        XCTAssertEqual(PhotoListViewModel.latestEffectPreviewFile(in: files)?.id, 7)
    }
    func testCatalogGroupingKeepsFirstSeenDayOrderAndUnknownBucket() {
        let files = [
            CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: false),
            CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1, fileName: "b.JPG", captureDate: nil, isProtected: false),
            CameraFile(id: 3, storageID: 1, format: 0x3801, size: 1, fileName: "c.JPG", captureDate: "20260913T020304", isProtected: true),
        ]
        let sections = PhotoCatalogGrouping.byCaptureDay(files)
        XCTAssertEqual(sections.map(\.day), ["zzz_unknown", "20260913"])
        XCTAssertEqual(sections[1].files.map(\.id), [3, 1])
    }

    func testDualCardHeadSelectionMatchesAndroidMissingDateAndStableTieRules() {
        let dated = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                               fileName: "dated.JPG", captureDate: "20260914T010000", isProtected: false)
        let missing = CameraFile(id: 2, storageID: 2, format: 0x3801, size: 1,
                                 fileName: "missing.JPG", captureDate: nil, isProtected: false)
        XCTAssertEqual(selectNewestPhotoHeadIndex([dated, missing]), 1)

        let sameDateA = CameraFile(id: 3, storageID: 1, format: 0x3801, size: 1,
                                   fileName: "a.JPG", captureDate: "20260914T020000", isProtected: false)
        let sameDateB = CameraFile(id: 4, storageID: 2, format: 0x3801, size: 1,
                                   fileName: "b.JPG", captureDate: "20260914T020000", isProtected: false)
        XCTAssertEqual(selectNewestPhotoHeadIndex([sameDateA, sameDateB]), 0)
    }

    func testPhotoScanSnapshotResumeKeepsOnlyUnprocessedHandlesPerCard() {
        let snapshot = PhotoScanSnapshot(
            storageIDs: [1, 2],
            handleOrders: [(storageID: 1, handles: [11, 10]),
                           (storageID: 2, handles: [21, 20])],
            processedHandles: [11, 21],
            handleQueriesSucceeded: true,
        )

        XCTAssertEqual(snapshot.remainingHandles.map(\.storageID), [1, 2])
        XCTAssertEqual(snapshot.remainingHandles.map(\.handles), [[10], [20]])
    }

    func testThumbnailFillQueuePreservesSameDateEnumerationOrder() async {
        let queue = PhotoThumbnailFillQueue()
        let first = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1,
                               fileName: "a.JPG", captureDate: "20260914T020000", isProtected: false)
        let second = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 1,
                                fileName: "b.JPG", captureDate: "20260914T020000", isProtected: false)
        await queue.beginScan()
        await queue.seed([first, second])
        let firstPolled = await queue.poll()
        let secondPolled = await queue.poll()
        XCTAssertEqual(firstPolled?.id, first.id)
        XCTAssertEqual(secondPolled?.id, second.id)
        XCTAssertEqual(firstPolled?.revision, secondPolled?.revision)
    }

    func testThumbnailFillQueueWakeReleasesAnEmptyWorker() async {
        let queue = PhotoThumbnailFillQueue()
        let waiter = Task {
            await queue.waitForWake()
            return true
        }
        await Task.yield()
        await queue.wake()
        let released = await waiter.value
        XCTAssertTrue(released)
    }

    func testThumbnailFillQueueRetriesFailedItemsOnlyAfterWakeBoundary() async {
        let queue = PhotoThumbnailFillQueue()
        let file = CameraFile(id: 31, storageID: 1, format: 0x3801, size: 1,
                              fileName: "retry.JPG", captureDate: "20260914T020000", isProtected: false)
        await queue.beginScan()
        await queue.seed([file])
        _ = await queue.poll()
        await queue.markFailed(file.id)
        let beforeWake = await queue.poll()
        XCTAssertNil(beforeWake)
        await queue.wake()
        await queue.waitForWake()
        await queue.retryFailed()
        let retried = await queue.poll()
        XCTAssertEqual(retried?.id, file.id)
    }

    func testThumbnailFillQueueDoesNotRequeueAcrossScanRevision() async {
        let queue = PhotoThumbnailFillQueue()
        let first = CameraFile(id: 11, storageID: 1, format: 0x3801, size: 1,
                               fileName: "first.JPG", captureDate: "20260914T020000", isProtected: false)
        let second = CameraFile(id: 12, storageID: 1, format: 0x3801, size: 1,
                                fileName: "second.JPG", captureDate: "20260914T010000", isProtected: false)
        await queue.beginScan()
        await queue.seed([first])
        let stale = await queue.poll()
        await queue.beginScan()
        await queue.seed([second])
        if let stale { await queue.returnToFront(stale.id, expectedRevision: stale.revision) }
        let next = await queue.poll()
        XCTAssertEqual(next?.id, second.id)
    }

    func testThumbnailFillQueuePreservesDatePriorityAcrossBeginScan() async {
        let queue = PhotoThumbnailFillQueue()
        let inRange = CameraFile(id: 21, storageID: 1, format: 0x3801, size: 1,
                                 fileName: "in-range.JPG", captureDate: "20260914T020000", isProtected: false)
        let outOfRange = CameraFile(id: 22, storageID: 1, format: 0x3801, size: 1,
                                    fileName: "out-of-range.JPG", captureDate: "20260913T020000", isProtected: false)
        await queue.beginScan()
        await queue.seed([], priorityRange: PhotoDateRange(start: "20260914", end: "20260914"))
        await queue.beginScan()
        await queue.enqueueNew([outOfRange, inRange])

        let first = await queue.poll()
        let second = await queue.poll()
        XCTAssertEqual(first?.id, inRange.id)
        XCTAssertEqual(second?.id, outOfRange.id)
    }

    func testBurstGroupingMatchesConsecutiveNameAndOneSecondRule() {
        let files = (100...102).map { n in
            CameraFile(id: UInt32(n), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(n).JPG", captureDate: "20260913T01020\(n - 100)", isProtected: false)
        }
        XCTAssertEqual(PhotoCatalogGrouping.bursts(in: files).first?.files.map(\.id), [UInt32(100), UInt32(101), UInt32(102)])
    }

    func testPreviewUsesIndependentCollapsedBurstPageAndRestoresMembersOnExpand() {
        let files = (100...103).map { n in
            CameraFile(id: UInt32(n), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(n).JPG", captureDate: n == 103 ? "20260913T010204" : "20260913T01020\(n - 100)", isProtected: false)
        }
        let collapsed = collapsedPhotoPreviewEntries(files: files)
        XCTAssertEqual(collapsed.count, 2)
        guard case .burst(let group) = collapsed[0] else {
            return XCTFail("the first three consecutive shots must be one collection page")
        }
        XCTAssertEqual(group.files.map(\.id), [100, 101, 102])
        let expanded = expandPhotoPreviewBurst(collapsed, at: 0)
        XCTAssertEqual(expanded.compactMap(\.file).map(\.id), [100, 101, 102, 103])
        XCTAssertEqual(photoPreviewCollectionIndex(expanded, memberIndex: 2), 0)
        let collapsedAgain = collapsePhotoPreviewBurst(expanded, burstID: group.id)
        XCTAssertEqual(collapsedAgain, collapsed)
    }

    func testPreviewDoesNotTreatNonFirstBurstMemberAsCollectionPage() {
        let files = (200...202).map { n in
            CameraFile(id: UInt32(n), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(n).JPG", captureDate: "20260913T02030\(n - 200)", isProtected: false)
        }
        let entries = collapsedPhotoPreviewEntries(files: files)
        XCTAssertEqual(entries.count, 1)
        let expanded = expandPhotoPreviewBurst(entries, at: 0)
        XCTAssertEqual(expanded.compactMap(\.burstID).count, 3)
        XCTAssertNil(photoPreviewCollectionIndex(expanded, memberIndex: 0))
    }

    func testBurstIdentitySurvivesDisablingCollectionsAndFilteringToOneMember() {
        let originals = (300...302).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(number).JPG", captureDate: "20260913T02030\(number - 300)", isProtected: false)
        }
        let group = PhotoCatalogGrouping.bursts(in: originals)[0]
        let membership = Dictionary(uniqueKeysWithValues: group.files.map { ($0.id, group.id) })
        let single = collapsedPhotoPreviewEntries(files: [originals[1]], burstIDByFile: membership)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].burstID, group.id)
        let dispersed = originals.map { PhotoPreviewEntry.photo($0, burstID: membership[$0.id]) }
        XCTAssertEqual(dispersed.compactMap(\.burstID).count, 3)
        XCTAssertTrue(dispersed.allSatisfy { $0.file != nil })
        XCTAssertNil(photoPreviewCollectionIndex(dispersed, memberIndex: 0))
    }

    func testManualQueueAllowsRepeatedExportsOfSameCameraHandle() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferQueueTests.\(UUID())")!)
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 10, fileName: "a.JPG", captureDate: nil, isProtected: false)
        let first = await queue.enqueue(file)
        let second = await queue.enqueue(file)
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second)
        let snapshot = await queue.snapshots().first(where: { _ in true })
        XCTAssertEqual(snapshot?.items.count, 2)
    }

    func testTransferQueueIgnoresPauseRequestWhileIdle() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferQueueIdlePauseTests")!)
        await queue.pauseAfterCurrentFile()
        let paused = await queue.pauseAfterCurrent
        XCTAssertFalse(paused)
    }

    func testTransferQueueItemKeepsIndependentEffectSnapshotForQueuedExport() {
        let file = CameraFile(id: 44, storageID: 1, format: 0x3801, size: 10,
                              fileName: "snapshot.JPG", captureDate: "20260914T010203", isProtected: false)
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFramePreset = .minimal
        effects.watermark.text = "Locked"
        effects.photoFilterEnabled = true
        effects.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterPreset(id: "NP3_FILM", name: "Film"), intensityPercent: 63
        )
        let item = TransferQueueItem(id: UUID(), file: file, effects: effects)
        let snapshot = effects
        effects.photoFramePreset = .mist
        effects.watermark.text = "Changed"
        XCTAssertEqual(item.effects, snapshot)
        XCTAssertTrue(item.effects?.hasEffect == true)
    }

    func testQueueDoesNotRestoreLegacyIOSOnlyTaskHistory() async {
        let suite = "TransferQueueLegacyTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)!.set(Data("[{\"status\":\"transferring\"}]".utf8), forKey: "transferQueue.items.v1")
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let state = await queue.snapshot()
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(state.isTransferring)
        XCTAssertFalse(state.pauseAfterCurrent)
        XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "transferQueue.items.v1"))
        _ = await queue.enqueue(CameraFile(id: 45, storageID: 1, format: 0x3801, size: 10,
                                          fileName: "queued.JPG", captureDate: nil, isProtected: false))
        let reopened = TransferQueue(defaults: UserDefaults(suiteName: suite)!)
        let fresh = await reopened.snapshot()
        XCTAssertTrue(fresh.items.isEmpty)
        XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: "transferQueue.items.v1"))
    }

    func testAutomaticQueueDeduplicatesCameraIdentity() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferQueueTests.\(UUID())")!)
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 10, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: false)
        let first = await queue.enqueueAutomatic(file)
        let second = await queue.enqueueAutomatic(file)
        XCTAssertNotNil(first); XCTAssertNil(second)
        let changedHandle = CameraFile(id: 10, storageID: 1, format: 0x3801, size: 10, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: false)
        let duplicateIdentity = await queue.enqueueAutomatic(changedHandle)
        XCTAssertNil(duplicateIdentity)
    }

    func testTransferQueueUsesExistingDestinationAsSkipped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = CameraFile(id: 3, storageID: 1, format: 0x3801, size: 10, fileName: "same.JPG", captureDate: nil, isProtected: false)
        XCTAssertNil(existingTransferDestination(for: file, in: directory))
        FileManager.default.createFile(atPath: directory.appendingPathComponent(file.fileName).path, contents: Data(repeating: 0, count: 10))
        XCTAssertEqual(existingTransferDestination(for: file, in: directory)?.lastPathComponent, "same.JPG")
        let unknownSize = CameraFile(id: file.id, storageID: file.storageID, format: file.format, size: UInt64(UInt32.max), fileName: file.fileName, captureDate: file.captureDate, isProtected: file.isProtected)
        XCTAssertEqual(existingTransferDestination(for: unknownSize, in: directory)?.lastPathComponent, "same.JPG")
    }

    func testAndroidPhotoFrameOutputNameUsesVersionedRenderingIdentity() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFramePreset = .mist
        XCTAssertEqual(
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings),
            "DSC_0001_frame_mist_w5188c3de1416.jpg"
        )

        settings.photoFrameBorderEnabled = false
        settings.watermark.enabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterPreset(id: "NP3_FILM", name: "Film"),
            intensityPercent: 63
        )
        XCTAssertEqual(
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings),
            "DSC_0001_filter_f42f030dci64.jpg"
        )

        settings.watermark.enabled = true
        settings.photoFrameEnabled = false
        XCTAssertEqual(
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings),
            "DSC_0001_filter_f42f030dci64.jpg"
        )
    }

    func testTransferDateFolderMatchesAndroidAndFallsBackForInvalidDate() {
        let fallback = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 21))!
        XCTAssertEqual(transferDateFolderName("20260817T142530", fallback: fallback), "ZT2026-08-17")
        XCTAssertEqual(transferDateFolderName("20260231T120000", fallback: fallback), "ZT2026-03-21")
        XCTAssertEqual(transferDateFolderName(nil, fallback: fallback), "ZT2026-03-21")
    }

    func testTransferDestinationDirectoryKeepsRootAndDatedFoldersSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dated = transferDestinationDirectory(root: root, folderName: "ZT2026-08-17")
        XCTAssertEqual(dated.lastPathComponent, "ZT2026-08-17")
        XCTAssertEqual(transferDestinationDirectory(root: root, folderName: nil), root)
    }

    func testQueueLocksDestinationFolderWhenEnqueued() async {
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "TransferDestinationTests.\(UUID())")!)
        let file = CameraFile(id: 3, storageID: 1, format: 0x3801, size: 10,
                              fileName: "same.JPG", captureDate: "20260817T142530", isProtected: false)
        await queue.enqueue(file, organizeByDate: true)
        await queue.enqueue(file, organizeByDate: false)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.items[0].destinationFolderName, "ZT2026-08-17")
        XCTAssertNil(snapshot.items[1].destinationFolderName)
    }

    func testLocalOriginalPreviewRoutesMatchAndroidFileTypes() {
        XCTAssertEqual(localOriginalPreviewRoute(for: ".JPG"), .directBitmap)
        XCTAssertEqual(localOriginalPreviewRoute(for: ".nef"), .rawEmbeddedJPEG)
        XCTAssertEqual(localOriginalPreviewRoute(for: ".nrw"), .rawEmbeddedJPEG)
        XCTAssertEqual(localOriginalPreviewRoute(for: ".tiff"), .cameraFHD)
        XCTAssertEqual(localOriginalPreviewRoute(for: ".mp4"), .cameraFHD)
    }

    func testTransferPartialIdentityAndResumeBoundaryMatchAndroid() {
        XCTAssertEqual(
            transferPartialFileName(size: 42, captureDate: "20260817T142530", fileName: "A_B.JPG"),
            ".nkpart_42.20260817T142530_A_B.JPG"
        )
        XCTAssertNil(transferResumeOffset(existingSize: 1024, totalSize: 20_000_000, reportedSize: 20_000_000))
        XCTAssertEqual(
            transferResumeOffset(existingSize: 4 * 1024 * 1024 + 7, totalSize: 20_000_000, reportedSize: 20_000_000),
            4 * 1024 * 1024
        )
        XCTAssertEqual(
            transferResumeOffset(existingSize: 8 * 1024 * 1024, totalSize: 8 * 1024 * 1024, reportedSize: 8 * 1024 * 1024),
            8 * 1024 * 1024
        )
    }

    func testTransferChunkStrategyMatchesAndroidThresholds() {
        XCTAssertTrue(shouldUsePartialObjectDownload(partialObjectSupported: nil, effectiveSize: 1))
        XCTAssertFalse(shouldUsePartialObjectDownload(
            partialObjectSupported: nil,
            effectiveSize: UInt64(UInt32.max)
        ))
        XCTAssertFalse(shouldUsePartialObjectDownload(
            partialObjectSupported: nil, effectiveSize: 64 * 1024 * 1024,
            isUSBConnection: true
        ))
        XCTAssertTrue(shouldUsePartialObjectDownload(
            partialObjectSupported: nil, effectiveSize: 64 * 1024 * 1024,
            resumeOffset: 4 * 1024 * 1024, isUSBConnection: true
        ))
        XCTAssertTrue(shouldUsePartialObjectDownload(
            partialObjectSupported: nil, effectiveSize: 64 * 1024 * 1024,
            isUSBConnection: true, forcePartial: true
        ))
        XCTAssertFalse(shouldUsePartialObjectDownload(
            partialObjectSupported: false, effectiveSize: 1024
        ))
        XCTAssertEqual(transferDownloadChunkSize(effectiveSize: 1), 4 * 1024 * 1024)
        XCTAssertEqual(transferDownloadChunkSize(effectiveSize: 600 * 1024 * 1024), 32 * 1024 * 1024)
        XCTAssertEqual(transferDownloadChunkSize(effectiveSize: 600 * 1024 * 1024, isUSBConnection: true), 64 * 1024 * 1024)
    }

    func testTransferOutputNeverOverwritesAnExistingSameNameFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("DSC_0001.JPG")
        FileManager.default.createFile(atPath: original.path, contents: Data([1]))
        XCTAssertEqual(transferUniqueOutputURL(directory: directory, fileName: "DSC_0001.JPG").lastPathComponent, "DSC_0001 (1).JPG")
        FileManager.default.createFile(atPath: directory.appendingPathComponent("DSC_0001 (1).JPG").path, contents: Data([1]))
        XCTAssertEqual(transferUniqueOutputURL(directory: directory, fileName: "DSC_0001.JPG").lastPathComponent, "DSC_0001 (2).JPG")
    }

    func testTransferDirectoryIndexMatchesNameAndSizeAndKeepsPartialSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("DSC_0001 (2).JPG")
        FileManager.default.createFile(atPath: original.path, contents: Data(repeating: 1, count: 10))
        let partial = directory.appendingPathComponent(".nkpart_10.20260817T142530_DSC_0001.JPG")
        FileManager.default.createFile(atPath: partial.path, contents: Data(repeating: 1, count: 4))
        let index = TransferDirectoryIndex.scan(directory: directory)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
                              fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        XCTAssertEqual(index.existingOriginal(for: file)?.lastPathComponent, "DSC_0001 (2).JPG")
        XCTAssertEqual(index.partials.count, 1)
        let differentSize = CameraFile(id: file.id, storageID: file.storageID, format: file.format,
                                       size: 11, fileName: file.fileName, captureDate: file.captureDate,
                                       isProtected: file.isProtected)
        XCTAssertNil(index.existingOriginal(for: differentSize))
    }

    func testStartupCleanupRemovesOnlyAndroidTemporaryFilesInRootAndDatedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dated = root.appendingPathComponent("ZT2026-08-17", isDirectory: true)
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleRootPart = root.appendingPathComponent(".nkpart_10.20260817T142530_a.JPG")
        let staleRootFrame = root.appendingPathComponent(".nkframe_old_a.jpg")
        let staleDatedPart = dated.appendingPathComponent(".nkpart_20.20260817T142531_b.JPG")
        let ordinary = root.appendingPathComponent("keep.JPG")
        for file in [staleRootPart, staleRootFrame, staleDatedPart, ordinary] {
            FileManager.default.createFile(atPath: file.path, contents: Data([1]))
        }

        XCTAssertEqual(TransferDirectoryIndex.removeStaleTemporaryFiles(in: root), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRootPart.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRootFrame.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDatedPart.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordinary.path))
    }

    func testPhotoFilterAppliesTypeProtectionStorageAndDate() {
        let files = [
            CameraFile(id: 1, storageID: 1, format: 0x3801, size: 1, fileName: "a.JPG", captureDate: "20260913T010203", isProtected: true),
            CameraFile(id: 2, storageID: 2, format: 0xB101, size: 1, fileName: "b.NEF", captureDate: "20260912T010203", isProtected: false),
        ]
        let state = PhotoFilterState(extensions: [".jpg"], protectedOnly: true, untransferredOnly: true, storageSlot: 1, dateRange: PhotoDateRange(start: "20260913", end: "20260913"))
        XCTAssertEqual(PhotoFilter.apply(files, state: state, transferredIDs: []).map(\.id), [1])
        XCTAssertTrue(PhotoFilter.apply(files, state: state, transferredIDs: [1]).isEmpty)
    }

    func testPhotoEffectsUseAndroidDefaultsAndNormalizeWatermarkText() {
        let settings = PhotoEffectsSettings()
        XCTAssertFalse(settings.photoFrameEnabled)
        XCTAssertEqual(settings.photoFramePreset, .mist)
        XCTAssertEqual(settings.watermark.displayText, "ZTransfer")
        XCTAssertFalse(PhotoFrameMetadataSettings.defaults(for: .galleryMat).showExposure)
        XCTAssertTrue(PhotoFrameMetadataSettings.defaults(for: .plaque).showDate)
        var watermark = PhotoFrameWatermark(text: "  a\nb\t")
        XCTAssertEqual(watermark.displayText, "a b")
        watermark.text = String(repeating: "x", count: 30)
        XCTAssertEqual(watermark.displayText.count, PhotoFrameWatermark.maxTextLength)
    }
}

extension DomainModelTests {
    func testFilterSelectionUsesOwnRememberedIntensityAndOffKeepsSelection() {
        let first = PhotoFilterCatalog.presets[0]
        let next = PhotoFilterCatalog.presets[1]
        var settings = PhotoEffectsSettings()
        settings.selectFilter(first.id)
        settings.filterIntensities[PhotoEffectsSettings.filterKey(first.id)] = 22
        settings.selectedFilter = .init(preset: first, intensityPercent: 22)
        settings.selectFilter(next.id)
        XCTAssertEqual(settings.selectedFilter?.intensityPercent, 80)
        settings.selectFilter(first.id)
        XCTAssertEqual(settings.selectedFilter?.intensityPercent, 22)
        settings.selectFilter(nil)
        XCTAssertFalse(settings.photoFilterEnabled)
        XCTAssertEqual(settings.selectedFilter?.preset.id, first.id)
    }

    @MainActor
    func testEffectFavoritesKeepAdditionOrderAcrossPersistenceAndRetoggling() {
        let suite = "effects-order-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = PhotoFilterCatalog.presets[0], c = PhotoFilterCatalog.presets[2]
        var settings = PhotoEffectsSettings()
        settings.selectFilter(a.id)
        settings.toggleFilterFavorite(c.id)
        settings.toggleFilterFavorite(a.id)
        settings.favoriteFrameEffects = [.init(preset: .cinema, watermark: .init()), .init(preset: .mist, watermark: .init())]
        let store = PhotoEffectsStore(defaults: defaults)
        store.update(settings)
        var restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(Array(restored.orderedFilters.prefix(2)).map(\.id), [c.id, a.id])
        XCTAssertEqual(restored.favoriteFrameEffects.map(\.preset), [.cinema, .mist])
        XCTAssertEqual(restored.selectedFilter, settings.selectedFilter)
        restored.toggleFilterFavorite(c.id)
        restored.toggleFilterFavorite(c.id)
        XCTAssertEqual(Array(restored.orderedFilters.prefix(2)).map(\.id), [a.id, c.id])
    }

    @MainActor
    func testAndroidIntensityCodecKeepsFirstDuplicateAndNormalizesValues() {
        let suite = "effects-codec-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = Np3FilterCatalog.presets[0], b = Np3FilterCatalog.presets[1]
        defaults.set(a.id, forKey: "photo_filter_selected_id")
        defaults.set("\(a.catalogKey),79;missing,60;\(a.catalogKey),22;\(b.catalogKey),101;broken", forKey: "photo_filter_intensities_v1")
        defaults.set("\(b.catalogKey),71;missing;\(a.catalogKey);\(b.catalogKey),92", forKey: "favorite_photo_filters_v1")
        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.filterIntensities, [a.catalogKey: 80, b.catalogKey: 100])
        XCTAssertEqual(restored.favoriteFilterIDs, [b.catalogKey, a.catalogKey])
    }

    func testFrameFavoriteUsesCurrentContentAndRejectsMissingLogo() throws {
        let historical = PhotoFrameWatermark(content: .image, text: "historical", imageHash: String(repeating: "a", count: 64), sizePercent: 242, opacityPercent: 1)
        let favorite = PhotoFrameFavorite(preset: .minimal, watermark: historical)
        let current = PhotoFrameWatermark(text: "current", imageHash: String(repeating: "b", count: 64))
        let applied = try XCTUnwrap(favorite.applying(to: current))
        XCTAssertEqual(applied.text, "current")
        XCTAssertEqual(applied.imageHash, current.imageHash)
        XCTAssertEqual(applied.sizePercent, 242)
        XCTAssertEqual(applied.opacityPercent, 1)
        XCTAssertNil(favorite.applying(to: .init()))
    }

    @MainActor
    func testWatermarkFullAndroidRangeSurvivesSaveAndReopen() {
        let suite = "effects-watermark-range-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoEffectsStore(defaults: defaults)
        var settings = store.settings
        settings.watermark.sizePercent = 300
        settings.watermark.opacityPercent = 1
        store.update(settings)
        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.watermark.sizePercent, 300)
        XCTAssertEqual(restored.watermark.opacityPercent, 1)
    }

    func testTransferDraftPreferencesPersistWithoutApplyingActiveEffects() {
        let first = PhotoFilterCatalog.presets[0], next = PhotoFilterCatalog.presets[1]
        var saved = PhotoEffectsSettings()
        saved.selectFilter(first.id)
        var draft = saved
        draft.selectFilter(next.id)
        draft.photoFramePreset = .minimal
        draft.metadataByPreset[PhotoFramePreset.minimal.rawValue] = .init(showCoordinates: true)
        draft.toggleFilterFavorite(next.id)
        let result = saved.persistingEditorPreferences(from: draft)
        XCTAssertEqual(result.selectedFilter, saved.selectedFilter)
        XCTAssertEqual(result.photoFramePreset, .mist)
        XCTAssertEqual(result.favoriteFilterIDs, draft.favoriteFilterIDs)
        XCTAssertEqual(result.metadataByPreset, draft.metadataByPreset)
        XCTAssertEqual(result.filterIntensities, draft.filterIntensities)
    }
}


extension DomainModelTests {
    @MainActor
    func testBundledWatermarkFontsResolveWithoutSystemFallback() throws {
        let paths = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertEqual(paths.count, 3)
        for path in paths {
            let url = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing registered font: \(path)")
        }
        for name in ["GreatVibes-Regular", "BebasNeue-Regular", "CormorantGaramond-MediumItalic"] {
            let font = try XCTUnwrap(UIFont(name: name, size: 24), "Watermark would fall back to a system font: \(name)")
            XCTAssertEqual(font.fontName, name)
        }
    }
}

/// Android TransferStateTest + processQueue/withdraw/retry scenarios. These use
/// controlled camera/render operations so task-boundary races are repeatable.
@MainActor
final class TransferQueueScenarioTests: XCTestCase {
    private func file(_ id: UInt32) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 10,
                   fileName: "DSC_\(id).JPG", captureDate: "20260914T120000", isProtected: false)
    }

    private func fixture(renderer: TransferQueue.FrameRenderer? = nil) throws -> (TransferQueue, URL) {
        let suite = "TransferQueueScenarioTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        if let renderer {
            return (TransferQueue(defaults: UserDefaults(suiteName: suite)!, renderFrame: renderer), directory)
        }
        return (TransferQueue(defaults: UserDefaults(suiteName: suite)!), directory)
    }

    private func snapshot(_ queue: TransferQueue) async -> TransferQueueSnapshot {
        await queue.snapshot()
    }

    private func wait(_ queue: TransferQueue, until predicate: (TransferQueueSnapshot) -> Bool) async throws -> TransferQueueSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let value = await snapshot(queue)
            if predicate(value) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Queue did not reach the expected state")
        throw CocoaError(.coderInvalidValue)
    }

    func testBatchDeduplicatesHandlesButSeparateClicksCreateNewAttempts() async throws {
        let (queue, _) = try fixture()
        let first = await queue.enqueue([file(1), file(1), file(2)])
        let second = await queue.enqueue([file(1), file(2)])
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(Set(first).isDisjoint(with: second))
        let state = await snapshot(queue)
        XCTAssertEqual(state.items.map(\.file.id), [1, 2, 1, 2])
    }

    func testOfflineLocalHitAndMissingOriginalNeverPublishFalseDownloadState() async throws {
        let (queue, directory) = try fixture()
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.enqueue([file(1), file(2)])
        let stream = await queue.snapshots()
        await queue.start(session: nil, directory: directory)
        var finished: TransferQueueSnapshot?
        for await value in stream {
            XCTAssertFalse(value.items.contains { $0.status == .transferring })
            if value.items.allSatisfy({ $0.status == .completed || $0.status == .failed }) && !value.isTransferring {
                finished = value
                break
            }
        }
        XCTAssertEqual(finished?.items[0].status, .completed)
        XCTAssertEqual(finished?.items[0].skipped, true)
        XCTAssertNil(finished?.items[0].elapsedMs)
        XCTAssertEqual(finished?.items[1].error, AppLocalized.resource("camera_not_connected"))
    }

    func testCompletePartialIsRenamedBeforeCameraStateAndRecheckedAsLocalOriginal() async throws {
        let (queue, directory) = try fixture()
        let source = file(7)
        let partialName = transferPartialFileName(
            size: source.size, captureDate: source.captureDate, fileName: source.fileName
        )
        let partial = directory.appendingPathComponent(partialName)
        try Data(repeating: 7, count: Int(source.size)).write(to: partial)
        await queue.enqueue(source)

        let stream = await queue.snapshots()
        await queue.start(session: nil, directory: directory)
        var finished: TransferQueueSnapshot?
        for await value in stream {
            if !value.isTransferring && value.items.first?.status == .completed {
                finished = value
                break
            }
        }
        let item = try XCTUnwrap(finished?.items.first)
        XCTAssertEqual(item.status, .completed)
        XCTAssertTrue(item.skipped)
        XCTAssertEqual(item.outputURL?.lastPathComponent, source.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.fileName).path))
    }

    func testResumeUnavailableDeletesPartAndUsesAndroidFailureText() async throws {
        let (queue, directory) = try fixture()
        let source = CameraFile(id: 8, storageID: 1, format: 0x3801,
                                size: 8 * 1024 * 1024,
                                fileName: "DSC_8.JPG", captureDate: "20260914T120000", isProtected: false)
        let partial = directory.appendingPathComponent(
            transferPartialFileName(size: source.size, captureDate: source.captureDate, fileName: source.fileName)
        )
        try Data(repeating: 8, count: 4 * 1024 * 1024).write(to: partial)
        await queue.enqueue(source)
        await queue.start(session: ResumeUnavailableCamera(), directory: directory)
        let failed = try await wait(queue) { !$0.isTransferring && $0.items.first?.status == .failed }
        XCTAssertEqual(failed.items.first?.error, AppLocalized.resource("transfer_failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRetryKeepsCardPositionButExecutesAfterAlreadyPendingTasks() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let old = await queue.enqueue(file(9))!
        await queue.withdraw(id: old)
        await queue.enqueue([file(1), file(2)])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[1].status == .transferring }
        let attempt = await queue.retry(id: old)
        XCTAssertNotNil(attempt)
        XCTAssertNotEqual(attempt, old)
        await camera.finish(1)
        _ = try await wait(queue) { $0.items[2].status == .transferring }
        await camera.finish(2)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await camera.finish(9)
        let final = try await wait(queue) { !$0.isTransferring }
        let requests = await camera.requests
        XCTAssertEqual(requests, [1, 2, 9])
        XCTAssertEqual(final.items.map(\.file.id), [9, 1, 2])
        XCTAssertTrue(final.items.allSatisfy { $0.status == .completed })
    }

    func testPauseWaitsForCurrentFileAndRetryCannotReleaseIt() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue([file(1), file(2), file(3)])
        await queue.withdraw(id: ids[2])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await queue.pauseAfterCurrentFile()
        // An overlapping explicit start is ignored while the worker is active.
        await queue.startPendingTransfers(session: camera, directory: directory)
        await camera.finish(1)
        let paused = try await wait(queue) { !$0.isTransferring }
        XCTAssertTrue(paused.pauseAfterCurrent)
        XCTAssertEqual(paused.items[0].status, .completed)
        let replacement = await queue.retry(id: ids[2])
        XCTAssertNotNil(replacement)
        let afterRetry = await snapshot(queue)
        XCTAssertFalse(afterRetry.isTransferring)
        XCTAssertTrue(afterRetry.pauseAfterCurrent)
        let replacementCamera = ControlledTransferCamera()
        await queue.attach(session: replacementCamera, directory: directory)
        await queue.resume()
        _ = try await wait(queue) { $0.items[1].status == .transferring }
        await replacementCamera.finish(2)
        _ = try await wait(queue) { $0.items[2].status == .transferring }
        await replacementCamera.finish(3)
        let final = try await wait(queue) { !$0.isTransferring }
        XCTAssertFalse(final.pauseAfterCurrent)
        let oldRequests = await camera.requests
        let newRequests = await replacementCamera.requests
        XCTAssertEqual(oldRequests, [1])
        XCTAssertEqual(newRequests, [2, 3])
    }

    func testWithdrawAndRetryAllExcludeCardsAlreadyLeaving() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue([file(1), file(2), file(3)])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await queue.withdrawPending()
        await queue.retryFailed(excluding: [ids[1]])
        await queue.removeCleared()
        let during = await snapshot(queue)
        XCTAssertEqual(during.items.map(\.file.id), [1, 3])
        await camera.finish(1)
        _ = try await wait(queue) { $0.items.last?.status == .transferring }
        await camera.finish(3)
        _ = try await wait(queue) { !$0.isTransferring }
        let requests = await camera.requests
        XCTAssertEqual(requests, [1, 3])
    }

    func testDetachDoesNotReuseOldCameraAndReconnectRetryUsesNewOne() async throws {
        let (queue, directory) = try fixture()
        let camera = ControlledTransferCamera()
        let ids = await queue.enqueue([file(1), file(2)])
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await queue.detach()
        await camera.finish(1)
        let disconnected = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(disconnected.items[0].status, .completed)
        XCTAssertEqual(disconnected.items[1].status, .failed)
        XCTAssertEqual(disconnected.items[1].error, AppLocalized.resource("camera_not_connected"))
        let replacement = ControlledTransferCamera()
        await queue.attach(session: replacement, directory: directory)
        await queue.retry(id: ids[1])
        _ = try await wait(queue) { $0.items[1].status == .transferring }
        await replacement.finish(2)
        _ = try await wait(queue) { !$0.isTransferring }
        let oldRequests = await camera.requests
        let newRequests = await replacement.requests
        XCTAssertEqual(oldRequests, [1])
        XCTAssertEqual(newRequests, [2])
    }

    func testFramesUseTwoWorkersAndClearProtectsActiveAndWaitingRenders() async throws {
        let renderer = ControlledFrameRenderer()
        let (queue, directory) = try fixture { source, _, target, _ in
            try await renderer.render(source: source, directory: target)
        }
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false // Android permits offline watermark-only export.
        let files = [file(1), file(2), file(3)]
        for file in files { try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file.fileName)) }
        let ids = await queue.enqueue(files, effects: effects)
        await queue.start(session: nil, directory: directory)
        let generating = try await wait(queue) { !$0.isTransferring && $0.items.allSatisfy(\.isGeneratingFrame) }
        XCTAssertTrue(generating.items.allSatisfy { !$0.skipped })
        let removed = await queue.remove(id: ids[0])
        XCTAssertFalse(removed)
        await queue.clearFinished()
        await queue.removeCleared()
        let protected = await snapshot(queue)
        XCTAssertEqual(protected.items.count, 3)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await renderer.peak < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await renderer.releaseAll()
        let final = try await wait(queue) { $0.items.allSatisfy { !$0.isGeneratingFrame } }
        let peak = await renderer.peak
        XCTAssertEqual(peak, 2)
        XCTAssertTrue(final.items.allSatisfy { $0.status == .completed && $0.frameURL != nil })
        await queue.removeCleared()
        let cleared = await snapshot(queue)
        XCTAssertTrue(cleared.items.isEmpty)
    }

    func testExistingOriginalFrameFailureCanRetryOfflineWithLockedEffects() async throws {
        let renderer = FailOnceFrameRenderer()
        let (queue, directory) = try fixture { source, settings, target, _ in
            try await renderer.render(source: source, settings: settings, directory: target)
        }
        let source = directory.appendingPathComponent(file(1).fileName)
        try Data(repeating: 1, count: 10).write(to: source)
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false // Android permits offline watermark-only export.
        effects.photoFramePreset = .minimal
        let id = await queue.enqueue(file(1), effects: effects)!
        await queue.start(session: nil, directory: directory)
        let failed = try await wait(queue) { !$0.isTransferring && $0.items[0].status == .failed && !$0.items[0].isGeneratingFrame }
        XCTAssertEqual(failed.items[0].outputURL, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let replacement = await queue.retry(id: id)
        XCTAssertNotEqual(replacement, id)
        let final = try await wait(queue) { !$0.isTransferring && $0.items[0].status == .completed && !$0.items[0].isGeneratingFrame }
        XCTAssertEqual(final.items[0].effects, effects)
        XCTAssertNotNil(final.items[0].frameURL)
        XCTAssertNil(final.items[0].error)
        let selections = await renderer.selections
        XCTAssertEqual(selections, [effects, effects])
    }

    func testNewDownloadRemainsCompletedWhenOnlyItsFrameFails() async throws {
        let (queue, directory) = try fixture { _, _, _, _ in throw CocoaError(.fileWriteUnknown) }
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        effects.photoFrameBorderEnabled = false // Android permits offline watermark-only export.
        await queue.enqueue(file(1), effects: effects)
        let camera = ControlledTransferCamera()
        await queue.start(session: camera, directory: directory)
        _ = try await wait(queue) { $0.items[0].status == .transferring }
        await camera.finish(1)
        let final = try await wait(queue) { !$0.isTransferring && !$0.items[0].isGeneratingFrame }
        XCTAssertEqual(final.items[0].status, .completed)
        XCTAssertNil(final.items[0].error)
        XCTAssertNotNil(final.items[0].frameError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file(1).fileName).path))
    }

    func testInvalidDestinationClearsQueueDirectoryAndDoesNotRestartOnRetry() async throws {
        let (queue, directory) = try fixture()
        let id = await queue.enqueue(file(1))!
        try FileManager.default.removeItem(at: directory)
        await queue.start(session: nil, directory: directory)
        let invalid = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(invalid.items[0].error, AppLocalized.resource("error_dir_invalid"))
        let retry = await queue.retry(id: id)
        XCTAssertNil(retry)
    }

    func testReselectedDirectoryCanRetryWithoutHistoricalErrorInvalidatingIt() async throws {
        let (queue, directory) = try fixture()
        let id = await queue.enqueue(file(1))!
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        await queue.start(session: nil, directory: missing)
        let invalid = try await wait(queue) { !$0.isTransferring }
        XCTAssertEqual(invalid.invalidatedDirectory, missing)
        try Data(repeating: 1, count: 10).write(to: directory.appendingPathComponent(file(1).fileName))
        await queue.attach(session: nil, directory: directory)
        let selected = await snapshot(queue)
        XCTAssertNil(selected.invalidatedDirectory)
        XCTAssertNotNil(selected.items[0].error)
        let attempt = await queue.retry(id: id)
        XCTAssertNotNil(attempt)
        let completed = try await wait(queue) { !$0.isTransferring && $0.items[0].status == .completed }
        XCTAssertNil(completed.invalidatedDirectory)
        XCTAssertEqual(completed.items[0].outputURL?.deletingLastPathComponent(), directory)
    }
}

private actor ControlledTransferCamera: TransferDownloading {
    private(set) var requests: [UInt32] = []
    private var waiting: [UInt32: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<UInt32> = []

    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        requests.append(file.id)
        if finished.remove(file.id) == nil {
            await withCheckedContinuation { waiting[file.id] = $0 }
        }
        progress?(1)
        let result = directory.appendingPathComponent(file.fileName)
        try Data(repeating: 1, count: Int(file.size)).write(to: result)
        return result
    }

    func finish(_ id: UInt32) {
        if let continuation = waiting.removeValue(forKey: id) { continuation.resume() }
        else { finished.insert(id) }
    }
}

private actor ResumeUnavailableCamera: TransferDownloading {
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw CameraRepositoryError.resumeUnavailable
    }
}

private actor ControlledFrameRenderer {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var active = 0
    private(set) var peak = 0

    func render(source: URL, directory: URL) async throws -> URL {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if !released { await withCheckedContinuation { waiting.append($0) } }
        let result = directory.appendingPathComponent(source.lastPathComponent + ".frame.jpg")
        try Data([1]).write(to: result)
        return result
    }

    func releaseAll() {
        released = true
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FailOnceFrameRenderer {
    private(set) var selections: [PhotoEffectsSettings] = []
    func render(source: URL, settings: PhotoEffectsSettings, directory: URL) throws -> URL {
        selections.append(settings)
        if selections.count == 1 { throw CocoaError(.fileWriteUnknown) }
        let result = directory.appendingPathComponent(source.lastPathComponent + ".frame.jpg")
        try Data([1]).write(to: result)
        return result
    }
}

extension DomainModelTests {
    func testExportedOriginalIndexMatchesCopyNameSizeAndDestination() {
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                              fileName: "DSC_0001.JPG", captureDate: "20260817T120000", isProtected: false)
        let copy = URL(fileURLWithPath: "/exports/ZT2026-08-17/dsc_0001 (2).jpg")
        var index = ExportedOriginalIndex()
        XCTAssertTrue(index.add(copy, size: 100, folderName: "ZT2026-08-17"))
        XCTAssertFalse(index.add(copy, size: 100, folderName: "ZT2026-08-17"))
        XCTAssertEqual(index.original(for: file, folderName: "ZT2026-08-17"), copy)
        XCTAssertNil(index.original(for: file, folderName: nil))
        XCTAssertNil(index.original(for: file, folderName: "ZT2026-08-18"))
        let wrongSize = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 99,
                                   fileName: file.fileName, captureDate: file.captureDate, isProtected: false)
        XCTAssertNil(index.original(for: wrongSize, folderName: "ZT2026-08-17"))
        let unknown = CameraFile(id: 1, storageID: 1, format: 0x3801, size: UInt64(UInt32.max),
                                fileName: file.fileName, captureDate: file.captureDate, isProtected: false)
        XCTAssertEqual(index.original(for: unknown, folderName: "ZT2026-08-17"), copy)
    }

    func testExportedOriginalSurvivesFrameFailureAndQueueClearing() {
        let root = URL(fileURLWithPath: "/exports", isDirectory: true)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                              fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        let output = root.appendingPathComponent(file.fileName)
        let failedFrame = TransferQueueItem(id: UUID(), file: file, status: .failed, outputURL: output)
        var index = ExportedOriginalIndex()
        XCTAssertTrue(index.record([failedFrame], root: root))
        XCTAssertFalse(index.record([], root: root))
        XCTAssertEqual(index.original(for: file, folderName: nil), output)
        XCTAssertFalse(index.record([failedFrame], root: root))
    }

    func testLateOldDirectoryOutputDoesNotPolluteNewExportIndex() {
        let oldRoot = URL(fileURLWithPath: "/old", isDirectory: true)
        let newRoot = URL(fileURLWithPath: "/new", isDirectory: true)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                              fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        let oldTask = TransferQueueItem(id: UUID(), file: file, status: .completed,
                                        outputURL: oldRoot.appendingPathComponent(file.fileName))
        var index = ExportedOriginalIndex()
        XCTAssertFalse(index.record([oldTask], root: newRoot))
        XCTAssertNil(index.original(for: file, folderName: nil))
        let changedHandle = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 100,
                                       fileName: file.fileName, captureDate: nil, isProtected: false)
        let output = newRoot.appendingPathComponent(file.fileName)
        index.add(output, size: 100, folderName: nil)
        XCTAssertEqual(index.original(for: changedHandle, folderName: nil), output)
    }
}
