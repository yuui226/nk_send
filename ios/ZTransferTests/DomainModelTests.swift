import XCTest
import UIKit
@testable import ZTransfer

final class DomainModelTests: XCTestCase {
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
        XCTAssertEqual(firstPolled, first.id)
        XCTAssertEqual(secondPolled, second.id)
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

    func testBurstGroupingMatchesConsecutiveNameAndOneSecondRule() {
        let files = (100...102).map { n in
            CameraFile(id: UInt32(n), storageID: 1, format: 0x3801, size: 1,
                       fileName: "DSC_\(n).JPG", captureDate: "20260913T01020\(n - 100)", isProtected: false)
        }
        XCTAssertEqual(PhotoCatalogGrouping.bursts(in: files).first?.files.map(\.id), [UInt32(100), UInt32(101), UInt32(102)])
    }

    func testManualQueueAllowsRepeatedExportsOfSameCameraHandle() async {
        let defaults = UserDefaults.standard
        let persistenceKey = "transferQueue.items.v1"
        let previous = defaults.data(forKey: persistenceKey)
        defaults.removeObject(forKey: persistenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: persistenceKey) }
            else { defaults.removeObject(forKey: persistenceKey) }
        }
        let queue = TransferQueue()
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 10, fileName: "a.JPG", captureDate: nil, isProtected: false)
        let first = await queue.enqueue(file)
        let second = await queue.enqueue(file)
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotEqual(first, second)
        let snapshot = await queue.snapshots().first(where: { _ in true })
        XCTAssertEqual(snapshot?.items.count, 2)
    }

    func testAutomaticQueueDeduplicatesCameraIdentity() async {
        let defaults = UserDefaults.standard
        let persistenceKey = "transferQueue.items.v1"
        let previous = defaults.data(forKey: persistenceKey)
        defaults.removeObject(forKey: persistenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: persistenceKey) }
            else { defaults.removeObject(forKey: persistenceKey) }
        }
        let queue = TransferQueue()
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

    func testQueueItemPersistsDestinationFolderSnapshot() throws {
        let file = CameraFile(id: 3, storageID: 1, format: 0x3801, size: 10,
                              fileName: "same.JPG", captureDate: "20260817T142530", isProtected: false)
        let item = TransferQueueItem(id: UUID(), file: file, destinationFolderName: "ZT2026-08-17")
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TransferQueueItem.self, from: data)
        XCTAssertEqual(decoded.destinationFolderName, "ZT2026-08-17")
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
