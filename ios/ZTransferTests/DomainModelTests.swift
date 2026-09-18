import XCTest
import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
@testable import ZTransfer

final class DomainModelTests: XCTestCase {
    func testGeniePopupUsesTriggerShortEdgeAndSharedEndpoints() {
        for button in [CGRect(x: 119, y: 62, width: 40, height: 40),
                       CGRect(x: 12, y: 68, width: 55, height: 36),
                       CGRect(x: 20, y: 450, width: 175, height: 50)] {
            let edge = GeniePopupMotion.attachmentAnchor(for: button, cornerRadius: 20)
            XCTAssertEqual(edge.midX, button.midX)
            XCTAssertEqual(edge.maxY, button.maxY)
            let source = edge.offsetBy(dx: -31, dy: -(button.maxY + 8))
            for height: CGFloat in [193, 400, 670] {
                let size = CGSize(width: 340, height: height)
                for fraction in stride(from: CGFloat(0), through: 1, by: 0.1) {
                    let collapsed = GeniePopupMotion.row(progress: 0, fraction: fraction, source: source, size: size)
                    XCTAssertEqual(collapsed.left + 31, edge.minX, accuracy: 0.0001)
                    XCTAssertEqual(collapsed.right + 31, edge.maxX, accuracy: 0.0001)
                    XCTAssertEqual(collapsed.y + button.maxY + 8, button.maxY, accuracy: 0.0001)
                    let expanded = GeniePopupMotion.row(progress: 1, fraction: fraction, source: source, size: size)
                    XCTAssertEqual(expanded.left, 0, accuracy: 0.0001)
                    XCTAssertEqual(expanded.right, size.width, accuracy: 0.0001)
                    XCTAssertEqual(expanded.y, height * fraction, accuracy: 0.0001)
                }
            }
        }
    }

    func testGeniePopupBendsCrossSectionsAndBandCorners() {
        let size = CGSize(width: 340, height: 400)
        let source = CGRect(x: 100, y: -8, width: 20, height: 0)
        let mouth = GeniePopupMotion.row(progress: 0.5, fraction: 0, source: source, size: size)
        let tail = GeniePopupMotion.row(progress: 0.5, fraction: 1, source: source, size: size)
        // A real Genie bends and retains length; a uniform scale + mask fails
        // these independent mouth/tail width, center and height constraints.
        XCTAssertLessThan(mouth.right - mouth.left, (tail.right - tail.left) / 2)
        XCTAssertLessThan((mouth.left + mouth.right) / 2, (tail.left + tail.right) / 2)
        XCTAssertGreaterThan(tail.y - mouth.y, size.height * 0.7)
        for p: CGFloat in [0.001, 0.1, 0.5, 0.9, 1] {
            for band in 0..<48 {
                let top = GeniePopupMotion.row(progress: p, fraction: CGFloat(band) / 48, source: source, size: size)
                let bottom = GeniePopupMotion.row(progress: p, fraction: CGFloat(band + 1) / 48, source: source, size: size)
                let bandSize = CGSize(width: 340, height: 400.0 / 48)
                let t = GeniePopupMotion.bandTransform(size: bandSize, top: top, bottom: bottom)
                for (point, expected) in [
                    (CGPoint.zero, CGPoint(x: top.left, y: top.y)),
                    (CGPoint(x: bandSize.width, y: 0), CGPoint(x: top.right, y: top.y)),
                    (CGPoint(x: 0, y: bandSize.height), CGPoint(x: bottom.left, y: bottom.y)),
                    (CGPoint(x: bandSize.width, y: bandSize.height), CGPoint(x: bottom.right, y: bottom.y))
                ] {
                    let denominator = t.m14 * point.x + t.m24 * point.y + t.m44
                    XCTAssertEqual((t.m11 * point.x + t.m21 * point.y + t.m41) / denominator,
                                   expected.x, accuracy: 0.0001)
                    XCTAssertEqual((t.m12 * point.x + t.m22 * point.y + t.m42) / denominator,
                                   expected.y, accuracy: 0.0001)
                }
                XCTAssertGreaterThan(bottom.y, top.y)
            }
        }
    }

    @MainActor
    func testGeniePopupHostFirstCaptureAndReversal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let popup = GeniePopupHostView(frame: CGRect(x: 31, y: 110, width: 340, height: 400))
        popup.host.rootView = AnyView(Color.red.frame(width: 340, height: 400))
        root.view.addSubview(popup)
        popup.configure(target: 0, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        root.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        popup.configure(target: 1, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        let layers = try XCTUnwrap(popup.subviews.last?.layer.sublayers)
        XCTAssertEqual(layers.count, 48)
        let images = layers.compactMap { $0.contents }.map { $0 as! CGImage }
        XCTAssertEqual(images.count, 48)
        // A transparent first capture made the first animation invisible.
        // Inspect the actual raster used by Core Animation, not a mock image.
        let bandImage = try XCTUnwrap(images.dropFirst(24).first)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bandImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 200)
        XCTAssertGreaterThan(pixel[3], 200)
        try await Task.sleep(for: .milliseconds(80))
        popup.configure(target: 0, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        popup.configure(target: 1, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(popup.host.view.layer.opacity, 1)
        XCTAssertTrue(popup.host.view.isUserInteractionEnabled)
        XCTAssertTrue(popup.subviews.last?.isHidden == true)
        XCTAssertTrue(layers.allSatisfy { $0.contents == nil })
        popup.configure(target: 0, anchorX: 108.0 / 340, anchorWidth: 20.0 / 340, anchorGap: 8)
        popup.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(popup.host.view.layer.opacity, 0)
        XCTAssertFalse(popup.host.view.isUserInteractionEnabled)
        popup.stop()
    }

    @MainActor
    func testSTASequentialScanSurvivesTransferPreviewRemoteAndFilterChanges() async throws {
        let harness = SequentialListHarness()
        let files = (1...4).map { remoteLifecycleFile(UInt32($0), name: "\($0).NEF") }
        let model = PhotoListViewModel(
            scanCatalog: { _, _, _, onBatch in
                await harness.didStartScan()
                try await onBatch(files)
                return PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                                       handleQueriesSucceeded: true, metadataComplete: true)
            },
            prefetchBatch: { await harness.prefetch($0) },
            canFill: { true },
            setRemoteGate: { await harness.setRemote($0) },
            sequentialLoading: true
        )
        model.load()
        try await waitForRemoteLifecycle { await harness.requested == [1] }
        model.setTransferBusy(true)
        model.pauseForPreview()
        await model.pauseForRemote() // Must not await/cancel the suspended scan.
        model.setFilter(PhotoFilterState(extensions: [".jpg"]))
        model.cancelLoading() // A disappearing UI is not the session owner.
        await model.reload()
        model.load()
        await harness.releaseFirst()
        try await Task.sleep(for: .milliseconds(80))
        var requested = await harness.requested
        XCTAssertEqual(requested, [1])
        XCTAssertTrue(model.isLoadingFiles)
        model.setTransferBusy(false)
        await model.resumeAfterRemote(isConnected: true)
        try await Task.sleep(for: .milliseconds(80))
        requested = await harness.requested
        XCTAssertEqual(requested, [1], "Preview still owns the foreground")
        model.resumeAfterPreview()
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }
        let scans = await harness.scans
        let gates = await harness.remoteGates
        requested = await harness.requested
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(requested, [1, 2, 3, 4])
        XCTAssertEqual(gates, [true, false])
        XCTAssertEqual(model.availableFiles.map(\.id), [1, 2, 3, 4])
        model.clearFilter()
        try await Task.sleep(for: .milliseconds(20))
        requested = await harness.requested
        XCTAssertEqual(requested, [1, 2, 3, 4])
    }
    @MainActor
    func testInvalidTransferDirectoryBookmarkIsRemovedDuringRestore() throws {
        let suite = "directory-invalid-bookmark-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-a-bookmark".utf8), forKey: "transfer_dir")

        let store = DirectoryAccessStore(defaults: defaults)

        XCTAssertNil(store.directoryURL)
        XCTAssertNil(defaults.object(forKey: "transfer_dir"))
    }

    func testGPSLocationFailuresMatchAndroidWaitingPermissionAndUnavailableStates() {
        XCTAssertEqual(gpsLocationFailureAction(for: .locationUnknown), .keepWaiting)
        XCTAssertEqual(gpsLocationFailureAction(for: .denied), .permissionRequired)
        XCTAssertEqual(gpsLocationFailureAction(for: .network), .locationUnavailable)
    }

    func testGPSBackgroundLocationRequiresDeclaredLocationMode() {
        XCTAssertFalse(gpsBackgroundLocationModeEnabled(nil))
        XCTAssertFalse(gpsBackgroundLocationModeEnabled(["audio"]))
        XCTAssertTrue(gpsBackgroundLocationModeEnabled(["location"]))
    }

    func testGPSBlocksOnlyEntryIntoWorkspaceAndPanelOwnsConnectionPageGesture() {
        XCTAssertFalse(workspacePagerUserScrollEnabled(
            gpsEnabled: true,
            currentPage: 0,
            gpsPanelPresented: false
        ))
        XCTAssertTrue(workspacePagerUserScrollEnabled(
            gpsEnabled: true,
            currentPage: 1,
            gpsPanelPresented: false
        ))
        XCTAssertFalse(workspacePagerUserScrollEnabled(
            gpsEnabled: false,
            currentPage: 0,
            gpsPanelPresented: true
        ))
        XCTAssertTrue(workspacePagerUserScrollEnabled(
            gpsEnabled: false,
            currentPage: 0,
            gpsPanelPresented: false
        ))
    }

    func testGPSOnlyReusesLocationsFromAndroidsTwoMinuteWindow() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(isReusableGPSLocation(CLLocation(
            coordinate: .init(latitude: 31, longitude: 121),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-120)
        ), now: now))
        XCTAssertFalse(isReusableGPSLocation(CLLocation(
            coordinate: .init(latitude: 31, longitude: 121),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-121)
        ), now: now))
    }

    func testGPSLocationFixDoesNotHideAndroidErrorOrStableSessionStates() {
        XCTAssertEqual(gpsStatusAfterLocationFix(.error), .error)
        XCTAssertEqual(gpsStatusAfterLocationFix(.ready), .ready)
        XCTAssertEqual(gpsStatusAfterLocationFix(.writing), .writing)
        XCTAssertEqual(gpsStatusAfterLocationFix(.connected), .connected)
        XCTAssertEqual(gpsStatusAfterLocationFix(.waitingFix), .connected)
        XCTAssertEqual(gpsStatusAfterLocationFix(.searching), .connected)
    }

    func testLocalPhotoSelectionMatchesAndroidImageWildcardInputRange() {
        XCTAssertTrue(isSupportedLocalPhoto([.jpeg]))
        XCTAssertTrue(isSupportedLocalPhoto([.png]))
        XCTAssertTrue(isSupportedLocalPhoto([.image, .png]))
        XCTAssertTrue(isSupportedLocalPhoto([.heic]))
        XCTAssertTrue(isSupportedLocalPhoto([.rawImage]))
        XCTAssertTrue(isSupportedLocalPhoto([]))
        XCTAssertFalse(isSupportedLocalPhoto([.movie]))
    }

    func testTransferSpeedMatchesAndroidInvalidAndRetainedSampleRules() {
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 0, elapsedMs: 100), 0)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 1_048_576, elapsedMs: 1_000), 1_048_576)
        XCTAssertEqual(endToEndBytesPerSecond(transferredBytes: 1_048_576, elapsedMs: 0), 0)
        XCTAssertEqual(retainLastValidTransferSpeed(previous: 2_400, sample: 0), 2_400)
        XCTAssertEqual(retainLastValidTransferSpeed(previous: 2_400, sample: 1_200), 1_200)
    }

    func testTransferCardCompletionFillsBeforeFadingWhileFailuresKeepRealProgress() {
        XCTAssertEqual(transferCardProgressTarget(status: .completed, progress: 0.87), 1)
        XCTAssertEqual(transferCardProgressTarget(status: .failed, progress: 0.87), 0.87)
        XCTAssertEqual(transferCardProgressTarget(status: .cancelled, progress: .nan), 0)
        XCTAssertTrue(transferCardWaveEligible(status: .transferring))
        XCTAssertTrue(transferCardWaveEligible(status: .completed))
        XCTAssertFalse(transferCardWaveEligible(status: .failed))
    }

    func testSkinPreferenceRestorationMatchesAndroidMigration() {
        XCTAssertEqual(normalizedSkinPreset(nil), "FROSTED_GLASS")
        XCTAssertEqual(normalizedSkinPreset("WOOD"), "WOOD")
        if #available(iOS 26.0, *) {
            XCTAssertEqual(normalizedSkinPreset("LIQUID_GLASS"), "LIQUID_GLASS")
        } else {
            XCTAssertEqual(normalizedSkinPreset("LIQUID_GLASS"), "FROSTED_GLASS")
        }
        XCTAssertEqual(normalizedSkinPreset("retired_skin"), "TITANIUM")
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

    func testCatalogGroupingPreservesCameraOrderForEqualCaptureTimes() {
        let raw = remoteLifecycleFile(0x091961BF, name: "DSC_0001.NEF")
        let jpeg = remoteLifecycleFile(0x291961BF, name: "DSC_0001.JPG")
        XCTAssertEqual(PhotoCatalogGrouping.byCaptureDay([raw, jpeg]).first?.files.map(\.id),
                       [raw.id, jpeg.id])
    }

    func testPhotoDateRangeRejectsInvalidCalendarDates() {
        let range = PhotoDateRange(start: "20260201", end: "20260301")
        XCTAssertFalse(range.contains("20260229T120000"))
        XCTAssertFalse(range.contains("20261301T120000"))
        XCTAssertTrue(range.contains("20260228T235959"))
        XCTAssertTrue(PhotoDateRange(start: "20240229", end: "20240229").contains("20240229T120000"))
        XCTAssertEqual(validPhotoCaptureDay("20260806T010000"), "20260806")
        XCTAssertNil(validPhotoCaptureDay("20260229T120000"))
    }

    func testPreviewCaptureDateFallsBackFromInvalidTimeAndRejectsInvalidDay() {
        XCTAssertEqual(formatPreviewCaptureDate("20260724T123456"), "2026-07-24 12:34:56")
        XCTAssertEqual(formatPreviewCaptureDate("20260724T996099"), "2026-07-24")
        XCTAssertNil(formatPreviewCaptureDate("20261340T120000"))
        XCTAssertNil(formatPreviewCaptureDate("20260229T120000"))
    }

    func testStorageFilterUsesPhysicalSlotsInsteadOfOpaqueStorageIDs() {
        let firstID: UInt32 = 0x0001_0001
        let secondID: UInt32 = 0x0002_0001
        let mapping = photoStorageIDsBySlot([secondID, firstID])
        XCTAssertEqual(mapping[1], [firstID])
        XCTAssertEqual(mapping[2], [secondID])
        let files = [
            CameraFile(id: 1, storageID: firstID, format: 0x3801, size: 1,
                       fileName: "a.JPG", captureDate: nil, isProtected: false,
                       storageIDs: [firstID]),
            CameraFile(id: 2, storageID: secondID, format: 0x3801, size: 1,
                       fileName: "b.JPG", captureDate: nil, isProtected: false,
                       storageIDs: [secondID]),
        ]
        var filter = PhotoFilterState()
        filter.storageSlot = 2
        XCTAssertEqual(PhotoFilter.apply(files, state: filter, storageIDsBySlot: mapping).map(\.id), [2])
        XCTAssertNil(normalizedPhotoStorageSlot(2, available: [1], scanComplete: true))
        XCTAssertEqual(normalizedPhotoStorageSlot(2, available: [], scanComplete: false), 2)
        XCTAssertTrue(isPhotoStorageSlotSelected(nil, slot: 1))
        XCTAssertTrue(isPhotoStorageSlotSelected(nil, slot: 2))
        XCTAssertEqual(toggledPhotoStorageSlot(nil, toggled: 1, available: [1, 2]), 2)
        XCTAssertEqual(toggledPhotoStorageSlot(2, toggled: 2, available: [1, 2]), 2)
        XCTAssertNil(toggledPhotoStorageSlot(2, toggled: 1, available: [1, 2]))
    }

    func testFilterPersistenceMatchesAndroidAndDoesNotRestoreCameraSlot() throws {
        let suite = "photo-filter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PhotoFilterState(extensions: [".jpg"], protectedOnly: true,
                                     burstOnly: true, untransferredOnly: true,
                                     storageSlot: 2,
                                     dateRange: PhotoDateRange(start: "20260901", end: "20260917"))
        PhotoFilterPersistence.save(state, to: defaults)
        let restored = PhotoFilterPersistence.load(from: defaults)
        XCTAssertEqual(restored.extensions, [".jpg"])
        XCTAssertTrue(restored.protectedOnly)
        XCTAssertTrue(restored.burstOnly)
        XCTAssertTrue(restored.untransferredOnly)
        XCTAssertNil(restored.storageSlot)
        XCTAssertEqual(restored.dateRange, state.dateRange)

        defaults.set("2026-09-17", forKey: "filter_date_start")
        defaults.set("2026-09-01", forKey: "filter_date_end")
        XCTAssertEqual(
            PhotoFilterPersistence.load(from: defaults).dateRange,
            PhotoDateRange(start: "20260901", end: "20260917")
        )
        defaults.set("20260901", forKey: "filter_date_start")
        XCTAssertNil(PhotoFilterPersistence.load(from: defaults).dateRange)
        defaults.set("2026-02-29", forKey: "filter_date_start")
        defaults.set("2026-03-01", forKey: "filter_date_end")
        XCTAssertNil(PhotoFilterPersistence.load(from: defaults).dateRange)
    }

    func testSTADirectStorageLayoutRejectsCrossSlotAggregateMembership() {
        let reliable = analyzeSTADirectStorageLayout([
            (0x0001_0001, [1, 2]),
            (0x0002_0001, [3, 4]),
        ])
        XCTAssertEqual(reliable.storageIDsByHandle[1], [0x0001_0001])
        XCTAssertEqual(reliable.filterStorageIDs, [0x0001_0001, 0x0002_0001])

        let ambiguous = analyzeSTADirectStorageLayout([
            (0x0001_0001, [1, 2]),
            (0x0002_0001, [1, 2]),
        ])
        XCTAssertEqual(ambiguous.crossSlotOverlapCount, 2)
        XCTAssertTrue(ambiguous.storageIDsByHandle.isEmpty)
        XCTAssertTrue(ambiguous.filterStorageIDs.isEmpty)
    }

    func testRemovedPrimaryHandleSwitchesToSurvivingDualCardAlias() {
        let firstID: UInt32 = 0x0001_0001
        let secondID: UInt32 = 0x0002_0001
        let primary = CameraFile(id: 10, storageID: firstID, format: 0x3801, size: 100,
                                 fileName: "same.JPG", captureDate: "20260917T120000",
                                 isProtected: false, storageIDs: [firstID, secondID])
        let alias = CameraFile(id: 20, storageID: secondID, format: 0x3801, size: 100,
                               fileName: "same.JPG", captureDate: "20260917T120000",
                               isProtected: false, storageIDs: [secondID])
        let reconciled = reconcilePublishedCameraFiles([primary], currentHandles: [20], indexedByHandle: [20: alias])
        XCTAssertEqual(reconciled.map(\.id), [20])
        XCTAssertEqual(reconciled.first?.storageIDs, [secondID])
        XCTAssertEqual(PublishedPhotoIdentity(primary), PublishedPhotoIdentity(alias))
    }

    func testExpandedBurstFollowsSurvivingLogicalMembersWhenGroupIDChanges() {
        let first = remoteLifecycleFile(10, name: "DSC_0001.JPG", captureDate: "20260917T120000")
        let second = remoteLifecycleFile(11, name: "DSC_0002.JPG", captureDate: "20260917T120001")
        let third = remoteLifecycleFile(12, name: "DSC_0003.JPG", captureDate: "20260917T120002")
        let replacementFirst = remoteLifecycleFile(20, name: "DSC_0001.JPG", captureDate: "20260917T120000")
        let previous = BurstPhotoGroup(id: "old", files: [first, second, third])
        let current = BurstPhotoGroup(id: "new", files: [replacementFirst, second, third])

        XCTAssertEqual(reconciledExpandedBurstIDs(previousGroups: [previous],
                                                  currentGroups: [current],
                                                  expandedIDs: ["old"]),
                       ["new"])
        XCTAssertEqual(reconciledExpandedBurstIDs(previousGroups: [previous],
                                                  currentGroups: [current],
                                                  expandedIDs: []),
                       [])
    }

    func testCameraRemovalDaysIgnoreInitialAdditionsAndSurvivingAliases() {
        let first = remoteLifecycleFile(10, name: "A.JPG", captureDate: "20260917T120000")
        let second = remoteLifecycleFile(11, name: "B.JPG", captureDate: "20260916T120000")
        let alias = remoteLifecycleFile(20, name: "A.JPG", captureDate: "20260917T120000")

        XCTAssertEqual(publishedCameraRemovalDays(previous: [], current: [first]), [])
        XCTAssertEqual(publishedCameraRemovalDays(previous: [first], current: [first, second]), [])
        XCTAssertEqual(publishedCameraRemovalDays(previous: [first, second], current: [alias, second]), [])
        XCTAssertEqual(publishedCameraRemovalDays(previous: [first, second], current: []),
                       ["20260917", "20260916"])
    }

    func testUntransferredExitOnlyIncludesNewQueueBackedOriginals() {
        let waiting = remoteLifecycleFile(31, name: "WAIT.JPG", captureDate: "20260917T120000")
        let completed = remoteLifecycleFile(32, name: "DONE.JPG", captureDate: "20260917T120001")
        let failed = remoteLifecycleFile(33, name: "FAIL.JPG", captureDate: "20260917T120002")
        let items = [
            TransferQueueItem(id: UUID(), file: waiting, status: .waiting),
            TransferQueueItem(id: UUID(), file: completed, status: .completed),
            TransferQueueItem(id: UUID(), file: failed, status: .failed),
        ]
        XCTAssertEqual(newlyExitingTransferredFileIDs(
            previous: [31], current: [31, 32, 33, 99], queueItems: items, untransferredOnly: true
        ), [32])
        XCTAssertEqual(newlyExitingTransferredFileIDs(
            previous: [], current: [32], queueItems: items, untransferredOnly: false
        ), [])
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

    @MainActor
    func testRemotePauseSetsGateBeforeWaitingAndResumeUsesFreshHandles() async throws {
        let old = remoteLifecycleFile(1, name: "old.JPG")
        let added = remoteLifecycleFile(2, name: "added.JPG")
        let harness = RemoteListLifecycleHarness(firstBatch: [])
        let model = remoteLifecycleModel(harness)

        model.load()
        try await waitForRemoteLifecycle { await harness.scanCount == 1 }
        await model.pauseForRemote()

        let pausedGates = await harness.gateChanges
        XCTAssertEqual(pausedGates, [true])
        XCTAssertEqual(model.loadState, .idle)
        await harness.setResumeFiles([old, added])
        await model.resumeAfterRemote(isConnected: true)
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }

        let calls = await harness.scanCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], RemoteListLifecycleHarness.ScanCall(preserve: false, hasSnapshot: false, detectNew: false))
        XCTAssertEqual(calls[1], RemoteListLifecycleHarness.ScanCall(preserve: true, hasSnapshot: false, detectNew: true))
        let resumedGates = await harness.gateChanges
        XCTAssertEqual(resumedGates, [true, false])
        XCTAssertEqual(model.availableFiles.map(\.id), [1, 2])
    }

    @MainActor
    func testRemotePauseKeepsAcceptedBatchAndFreshResumeReconcilesIt() async throws {
        let retained = remoteLifecycleFile(11, name: "retained.JPG")
        let removed = remoteLifecycleFile(12, name: "removed.JPG")
        let added = remoteLifecycleFile(13, name: "added.JPG")
        let harness = RemoteListLifecycleHarness(firstBatch: [retained, removed])
        let model = remoteLifecycleModel(harness)

        model.load()
        try await waitForRemoteLifecycle { model.availableFiles.count == 2 }
        await model.pauseForRemote()
        XCTAssertEqual(model.availableFiles.map(\.id), [11, 12])
        XCTAssertFalse(model.hasCompletedFileScan)

        await harness.setResumeFiles([retained, added], removed: [removed.id], added: [added.id])
        await model.resumeAfterRemote(isConnected: true)
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }
        XCTAssertEqual(model.availableFiles.map(\.id), [11, 13])
    }

    @MainActor
    func testRemoteDisconnectReleasesGateWithoutStartingOldSessionScan() async throws {
        let harness = RemoteListLifecycleHarness(firstBatch: [])
        let model = remoteLifecycleModel(harness)
        model.load()
        try await waitForRemoteLifecycle { await harness.scanCount == 1 }

        await model.pauseForRemote()
        await model.resumeAfterRemote(isConnected: false)
        try await Task.sleep(nanoseconds: 20_000_000)

        let gates = await harness.gateChanges
        let scans = await harness.scanCount
        XCTAssertEqual(gates, [true, false])
        XCTAssertEqual(scans, 1)
        XCTAssertFalse(model.isLoadingFiles)
    }

    @MainActor
    func testRemoteResumeWaitsForActivePreviewBeforeFreshHandleScan() async throws {
        let file = remoteLifecycleFile(21, name: "after-preview.JPG")
        let harness = RemoteListLifecycleHarness(firstBatch: [])
        let model = remoteLifecycleModel(harness)
        model.load()
        try await waitForRemoteLifecycle { await harness.scanCount == 1 }
        await model.pauseForRemote()

        model.pauseForPreview()
        await harness.setResumeFiles([file])
        await model.resumeAfterRemote(isConnected: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        let scansWhilePreviewing = await harness.scanCount
        XCTAssertEqual(scansWhilePreviewing, 1)

        model.resumeAfterPreview()
        try await waitForRemoteLifecycle { model.hasCompletedFileScan }
        let scansAfterPreview = await harness.scanCount
        XCTAssertEqual(scansAfterPreview, 2)
        XCTAssertEqual(model.availableFiles.map(\.id), [21])
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

    func testPreviewRetainsOnlyTwoPagesAroundCurrentAndSkipsCollectionBitmap() {
        let files = (1...7).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(number).JPG", captureDate: nil, isProtected: false)
        }
        let collection = BurstPhotoGroup(id: "burst", files: [files[2], files[3]])
        let entries: [PhotoPreviewEntry] = [
            .photo(files[0]), .photo(files[1]), .burst(collection), .photo(files[4]),
            .photo(files[5]), .photo(files[6])
        ]

        XCTAssertEqual(retainedPhotoPreviewIDs(entries: entries, currentIndex: 3), [2, 5, 6, 7])
        XCTAssertEqual(retainedPhotoPreviewIDs(entries: entries, currentIndex: 0), [1, 2])
    }

    func testPreviewNeighborsUsePreviousThenNextPageOrder() {
        let files = (1...3).map { number in
            CameraFile(id: UInt32(number), storageID: 1, format: 0x3801, size: 1,
                       fileName: "IMG_\(number).JPG", captureDate: nil, isProtected: false)
        }
        let entries = files.map { PhotoPreviewEntry.photo($0) }
        XCTAssertEqual(neighboringPhotoPreviewIndices(entries: entries, currentIndex: 1), [0, 2])
        XCTAssertEqual(neighboringPhotoPreviewIndices(entries: entries, currentIndex: 0), [1])
        XCTAssertEqual(neighboringPhotoPreviewIndices(entries: entries, currentIndex: 2), [1])
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

    func testImageWatermarkOutputIdentityUsesItsRenderedPhotoPosition() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        settings.watermark.enabled = true
        settings.watermark.content = .image
        settings.watermark.imageHash = String(repeating: "a", count: 64)
        settings.watermark.position = .left
        let constrained = androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)

        settings.watermark.position = .photoBottomCenter
        let explicit = androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)

        XCTAssertEqual(constrained, explicit)
    }

    func testWatermarkOnlyOutputIdentityIgnoresHiddenFrameMetadata() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = false
        settings.watermark.enabled = true
        let baseline = androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)

        settings.metadataByPreset[PhotoFramePreset.mist.rawValue] = .init(
            showDate: true, showTime: true, showCoordinates: true, showAltitude: true
        )

        XCTAssertEqual(
            baseline,
            androidPhotoFrameOutputName(sourceName: "DSC_0001.JPG", settings: settings)
        )
    }

    func testGeneratedPhotoFrameNameTreatsOccupiedNamesCaseInsensitively() {
        XCTAssertEqual(
            uniquePhotoFrameName(
                "DSC_0123_frame_mist.jpg",
                occupied: ["dsc_0123_FRAME_MIST.JPG", "DSC_0123_frame_mist (1).jpg"]
            ),
            "DSC_0123_frame_mist (2).jpg"
        )
        let occupied = Set(
            ["DSC_0123_frame_mist.jpg"] +
            (1...999).map { "DSC_0123_frame_mist (\($0)).jpg" }
        )
        XCTAssertEqual(
            uniquePhotoFrameName(
                "DSC_0123_frame_mist.jpg", occupied: occupied, fallbackMillis: 12345
            ),
            "DSC_0123_frame_mist_12345.jpg"
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

    func testTransferChunkStrategyPreservesWirelessThresholdsAndBoundsImageCaptureUSB() {
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
        // ImageCaptureCore completes pass-through requests with one in-memory
        // Data value; iOS USB deliberately does not copy Android's 64 MiB raw
        // bulk-endpoint chunk.
        XCTAssertEqual(transferDownloadChunkSize(effectiveSize: 600 * 1024 * 1024, isUSBConnection: true), 4 * 1024 * 1024)
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
        let storageIDsBySlot: [UInt32: Set<UInt32>] = [1: [1], 2: [2]]
        XCTAssertEqual(PhotoFilter.apply(files, state: state, transferredIDs: [],
                                         storageIDsBySlot: storageIDsBySlot).map(\.id), [1])
        XCTAssertTrue(PhotoFilter.apply(files, state: state, transferredIDs: [1],
                                        storageIDsBySlot: storageIDsBySlot).isEmpty)
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
        watermark.text = " \n\t "
        XCTAssertEqual(watermark.displayText, PhotoFrameWatermark.defaultText)
        watermark.text = String(repeating: "x", count: 30)
        XCTAssertEqual(watermark.displayText.count, PhotoFrameWatermark.maxTextLength)
        XCTAssertEqual(
            PhotoFrameWatermark.limitText("line one\nline two\t\u{0007}"),
            "line one line two "
        )
        XCTAssertEqual(
            PhotoFrameWatermark.limitText(String(repeating: "😀", count: 25)).unicodeScalars.count,
            PhotoFrameWatermark.maxTextLength
        )
    }

    @MainActor
    func testWatermarkImportUsesOriginalBytesAndAndroidSizeLimit() throws {
        PhotoEffectsStore.resetWatermarkImageCache()
        defer { PhotoEffectsStore.resetWatermarkImageCache() }
        let suite = "effects-watermark-import-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoEffectsStore(defaults: defaults)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2_300, height: 12))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_300, height: 12))
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 0.73))
        let expectedHash = SHA256.hash(data: original)
            .map { String(format: "%02x", $0) }.joined()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watermark-import-test-\(UUID().uuidString).jpg")
        try original.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let generation = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.watermarkImageImporting)
        XCTAssertNil(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(generation: generation, hash: nil))
        XCTAssertFalse(store.watermarkImageImporting)
        XCTAssertFalse(store.finishWatermarkImageImport(generation: generation &+ 1, hash: nil))
        XCTAssertEqual(PhotoEffectsStore.importWatermarkImageFile(sourceURL), expectedHash)
        XCTAssertEqual(store.importWatermarkImage(data: original), expectedHash)
        let successfulGeneration = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(
            generation: successfulGeneration, hash: expectedHash
        ))
        XCTAssertEqual(store.settings.watermark.content, .image)
        XCTAssertEqual(store.settings.watermark.imageHash, expectedHash)
        XCTAssertEqual(store.lastImportedWatermarkHash, expectedHash)
        XCTAssertEqual(store.watermarkImportRevision, 1)
        let repeatedGeneration = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(
            generation: repeatedGeneration, hash: expectedHash
        ))
        XCTAssertEqual(store.watermarkImportRevision, 2)
        let decoded = try XCTUnwrap(PhotoEffectsStore.watermarkImage(hash: expectedHash))
        XCTAssertLessThanOrEqual(
            max(decoded.size.width, decoded.size.height),
            CGFloat(PhotoEffectsStore.maximumWatermarkImagePixelDimension)
        )
        XCTAssertTrue(decoded === PhotoEffectsStore.watermarkImage(hash: expectedHash))
        XCTAssertEqual(PhotoEffectsStore.watermarkImageCacheCount, 1)
        for color in [UIColor.red, .green, .blue] {
            let extra = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            let data = try XCTUnwrap(extra.pngData())
            let hash = try XCTUnwrap(PhotoEffectsStore.importWatermarkImageData(data))
            XCTAssertNotNil(PhotoEffectsStore.watermarkImage(hash: hash))
        }
        XCTAssertEqual(PhotoEffectsStore.watermarkImageCacheCount, 3)
        XCTAssertFalse(decoded === PhotoEffectsStore.watermarkImage(hash: expectedHash))

        let rejectedHash = SHA256.hash(data: Data(UUID().uuidString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let rejectedGeneration = try XCTUnwrap(store.beginWatermarkImageImport())
        XCTAssertTrue(store.finishWatermarkImageImport(
            generation: rejectedGeneration, hash: rejectedHash
        ))
        XCTAssertNil(store.lastImportedWatermarkHash)
        XCTAssertEqual(store.watermarkImportRevision, 2)
        XCTAssertEqual(store.settings.watermark.content, .text)
        XCTAssertNil(store.settings.watermark.imageHash)
        XCTAssertNil(store.importWatermarkImage(data: Data()))
        XCTAssertNil(store.importWatermarkImage(
            data: Data(count: PhotoEffectsStore.maximumWatermarkImageBytes + 1)
        ))
    }

    @MainActor
    func testLegacyWatermarkSizeAndOpacityMigrateWithoutVisualJump() {
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(nil, content: .text), 80)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("SMALL", content: .text), 9)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("MEDIUM", content: .text), 26)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("SMALL", content: .image), 1)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("MEDIUM", content: .image), 20)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent("LARGE", content: .image), 51)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(200, content: .text, usesLegacyScale: true), 151)
        XCTAssertEqual(restoredPhotoFrameWatermarkSizePercent(300, content: .text), 300)
        XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent("SUBTLE"), 40)
        XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent("STANDARD"), 72)
        XCTAssertEqual(restoredPhotoFrameWatermarkOpacityPercent("STRONG"), 100)

        let suite = "effects-watermark-scale-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ZTransfer", forKey: "photo_frame_watermark_text")
        defaults.set("MEDIUM", forKey: "photo_frame_watermark_size")
        defaults.set("SUBTLE", forKey: "photo_frame_watermark_opacity")
        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.watermark.sizePercent, 26)
        XCTAssertEqual(restored.watermark.opacityPercent, 40)
        XCTAssertEqual(defaults.integer(forKey: "photo_frame_watermark_size"), 26)
        XCTAssertEqual(defaults.integer(forKey: "photo_frame_watermark_opacity"), 40)
        XCTAssertEqual(defaults.integer(forKey: "photo_frame_watermark_size_scale_version"), 2)
    }

    @MainActor
    func testFavoriteFrameWatermarkRestoreNormalizesSizeAndOpacity() {
        let suite = "effects-frame-favorite-normalization-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "photo_frame_enabled")
        defaults.set("MIST,true,TEXT,CALLIGRAPHY,999,AUTO,ADAPTIVE,-2,AUTO", forKey: "favorite_frame_effects_v1")

        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.favoriteFrameEffects.count, 1)
        XCTAssertEqual(restored.favoriteFrameEffects[0].watermark.sizePercent, 300)
        XCTAssertEqual(restored.favoriteFrameEffects[0].watermark.opacityPercent, 1)
        XCTAssertEqual(
            defaults.string(forKey: "favorite_frame_effects_v1"),
            "MIST,true,TEXT,CALLIGRAPHY,300,AUTO,ADAPTIVE,1,AUTO"
        )
    }

    func testRemoteDesqueezeRestoresWithinAndroidRange() {
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(0.25), 1)
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(1.33), 1.33)
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(9), 2)
        XCTAssertEqual(RemoteDisplayOptions.normalizedDesqueeze(.infinity), 1)
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 1.2), 1.33)
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 9), 1)
    }

    func testThumbnailColumnsRestoreWithinAndroidRange() {
        XCTAssertEqual(normalizedThumbnailColumns(-1), 2)
        XCTAssertEqual(normalizedThumbnailColumns(1), 2)
        XCTAssertEqual(normalizedThumbnailColumns(3), 3)
        XCTAssertEqual(normalizedThumbnailColumns(8), 4)
    }

    func testPreviewReturnOnlyTreatsCompleteCellAsVisible() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 700)

        XCTAssertTrue(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 120, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertTrue(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 99.75, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertFalse(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 99, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertFalse(photoFrameIsFullyVisible(
            CGRect(x: 12, y: 700, width: 118, height: 118),
            in: viewport
        ))
        XCTAssertFalse(photoFrameIsFullyVisible(.zero, in: viewport))
    }

    func testPhotoPreviewHoldAndHistogramMatchPresentationContract() throws {
        XCTAssertEqual(photoPreviewLongPressDuration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewRotationDuration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewZoomPanMinimumDistance, 8, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewDoubleTapDuration, 0.24, accuracy: 0.0001)
        XCTAssertEqual(photoPreviewDoubleTapZoom, 2.5, accuracy: 0.0001)

        let viewport = CGSize(width: 400, height: 800)
        XCTAssertEqual(
            photoPreviewRotationFitScale(
                imageSize: CGSize(width: 200, height: 400),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            photoPreviewRotationFitScale(
                imageSize: CGSize(width: 200, height: 400),
                viewportSize: viewport,
                rotationDegrees: -90
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            photoPreviewQueueDragDirection(translation: CGSize(width: 2, height: -20)),
            .upward
        )
        XCTAssertEqual(
            photoPreviewQueueDragDirection(translation: CGSize(width: 20, height: -2)),
            .rejected
        )
        XCTAssertEqual(
            photoPreviewQueueDragDirection(translation: CGSize(width: 9, height: -9)),
            .undecided
        )
        XCTAssertEqual(
            photoPreviewQueueVisualOffset(upwardDistance: 200),
            -118.88,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            photoPreviewDisplaySize(
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: -90
            ),
            CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(
            photoPreviewClampedOffset(
                CGSize(width: 500, height: -1_000),
                scale: 2.5,
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            CGSize(width: 300, height: 0)
        )
        XCTAssertEqual(
            photoPreviewDoubleTapOffset(
                location: CGPoint(x: 300, y: 400),
                scale: 2.5,
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            CGSize(width: -150, height: 0)
        )
        XCTAssertEqual(
            photoPreviewMaximumZoom(
                imageSize: CGSize(width: 400, height: 200),
                viewportSize: viewport,
                rotationDegrees: 0
            ),
            4,
            accuracy: 0.0001
        )
        XCTAssertTrue(photoPreviewHistogramOverlayVisible(
            enabled: true,
            currentPhotoID: 42,
            histogramFileID: 42,
            binCount: 256
        ))
        XCTAssertFalse(photoPreviewHistogramOverlayVisible(
            enabled: true,
            currentPhotoID: nil,
            histogramFileID: 42,
            binCount: 256
        ))
        XCTAssertTrue(photoPreviewHistogramOverlayVisible(
            enabled: true,
            currentPhotoID: 42,
            histogramFileID: 42,
            binCount: 256
        ))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 1),
            format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            UIColor.white.setFill()
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        }

        let histogram = previewLuminanceHistogram(image)
        XCTAssertEqual(histogram.count, 256)
        XCTAssertEqual(histogram[0], 1, accuracy: 0.0001)
        XCTAssertEqual(histogram[255], 1, accuracy: 0.0001)
        XCTAssertEqual(histogram[128], 0, accuracy: 0.0001)
    }
}

private actor SequentialListHarness {
    private(set) var requested: [UInt32] = []
    private(set) var scans = 0
    private(set) var remoteGates: [Bool] = []
    private var firstReleased = false
    func didStartScan() { scans += 1 }
    func setRemote(_ active: Bool) { remoteGates.append(active) }
    func releaseFirst() { firstReleased = true }
    func prefetch(_ files: [CameraFile]) async -> Set<UInt32> {
        for file in files {
            requested.append(file.id)
            while file.id == 1 && !firstReleased {
                do { try await Task.sleep(for: .milliseconds(1)) }
                catch { return [] }
            }
        }
        return Set(files.map(\.id))
    }
}

private actor RemoteListLifecycleHarness {
    struct ScanCall: Equatable, Sendable {
        let preserve: Bool
        let hasSnapshot: Bool
        let detectNew: Bool
    }

    private let firstBatch: [CameraFile]
    private var remoteGate = false
    private var resumedFiles: [CameraFile] = []
    private var resumedRemoved: Set<UInt32> = []
    private var resumedAdded: Set<UInt32> = []
    private(set) var scanCalls: [ScanCall] = []
    private(set) var gateChanges: [Bool] = []
    var scanCount: Int { scanCalls.count }

    init(firstBatch: [CameraFile]) {
        self.firstBatch = firstBatch
    }

    func setGate(_ active: Bool) {
        remoteGate = active
        gateChanges.append(active)
    }

    func setResumeFiles(_ files: [CameraFile], removed: Set<UInt32> = [], added: Set<UInt32> = []) {
        resumedFiles = files
        resumedRemoved = removed
        resumedAdded = added
    }

    func scan(
        preserve: Bool,
        snapshot: PhotoScanSnapshot?,
        detectNew: Bool,
        onBatch: @escaping @Sendable ([CameraFile]) async throws -> Void
    ) async throws -> PhotoScanResult {
        scanCalls.append(ScanCall(preserve: preserve, hasSnapshot: snapshot != nil, detectNew: detectNew))
        if scanCalls.count == 1 {
            if !firstBatch.isEmpty { try await onBatch(firstBatch) }
            while !remoteGate {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw CameraRepositoryError.foregroundPreempted
        }
        if !resumedFiles.isEmpty { try await onBatch(resumedFiles) }
        return PhotoScanResult(files: resumedFiles,
                               removedHandles: resumedRemoved,
                               addedHandles: resumedAdded,
                               handleQueriesSucceeded: true,
                               metadataComplete: true)
    }
}

@MainActor
private func remoteLifecycleModel(_ harness: RemoteListLifecycleHarness) -> PhotoListViewModel {
    PhotoListViewModel(
        scanCatalog: { preserve, snapshot, detectNew, onBatch in
            try await harness.scan(preserve: preserve, snapshot: snapshot,
                                   detectNew: detectNew, onBatch: onBatch)
        },
        setRemoteGate: { active in await harness.setGate(active) }
    )
}

private func remoteLifecycleFile(_ id: UInt32, name: String,
                                 captureDate: String = "20260917T120000") -> CameraFile {
    CameraFile(id: id, storageID: 1, format: 0x3801, size: 100,
               fileName: name, captureDate: captureDate, isProtected: false)
}

@MainActor
private func waitForRemoteLifecycle(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    _ predicate: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for remote/list lifecycle state")
    throw CocoaError(.coderReadCorrupt)
}

extension DomainModelTests {
    func testRenderedJPEGPreservesExifAndRewritesOrientationDimensionsAndCameraGPS() throws {
        func image(width: Int, height: Int, color: UIColor) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height), format: format
            ).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let sourceImage = image(width: 6, height: 4, color: .red)
        let sourceData = NSMutableData()
        let sourceDestination = try XCTUnwrap(CGImageDestinationCreateWithData(
            sourceData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        let sourceProperties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIKON CORPORATION",
                kCGImagePropertyTIFFModel: "Z 30",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:17 12:34:56",
                kCGImagePropertyExifFNumber: 1.7,
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 1.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.0,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(sourceDestination, try XCTUnwrap(sourceImage.cgImage),
                                   sourceProperties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(sourceDestination))

        let rendered = image(width: 20, height: 30, color: .blue)
        let camera = PhotoFrameMetadata(
            make: nil, model: nil, lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil,
            dateTime: nil, latitude: -31.5, longitude: 121.25, altitude: -12
        )
        let output = try XCTUnwrap(PhotoEffectsJPEGEncoder.encode(
            rendered, copyingMetadataFrom: sourceData as Data, cameraMetadata: camera
        ))
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as NSDictionary?
        )
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 20)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 30)
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? NSDictionary)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "NIKON CORPORATION")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "Z 30")
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? NSDictionary)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                       "2026:09:17 12:34:56")
        XCTAssertEqual((exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue, 20)
        XCTAssertEqual((exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue, 30)
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? NSDictionary)
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue, 31.5)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "S")
        XCTAssertEqual((gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue, 121.25)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "E")
        XCTAssertEqual((gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue, 12)
        XCTAssertEqual((gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue, 1)
    }

    func testPhotoEffectsLayoutUsesExifOrientedSourceDimensions() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 4), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        }
        let oriented = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: .right)
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = true
        settings.photoFramePreset = .plaque
        settings.watermark.enabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterCatalog.presets[0], intensityPercent: 80
        )

        let output = try PhotoEffectsRenderer.render(oriented, settings: settings)

        XCTAssertEqual(output.imageOrientation, .up)
        XCTAssertEqual(output.cgImage?.width, 4)
        XCTAssertEqual(output.cgImage?.height, 7)
    }

    func testBorderedFilterPreservesMirroredAndRotatedPixelOrientation() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let raw = UIGraphicsImageRenderer(
            size: CGSize(width: 64, height: 48), format: format
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            UIColor.green.setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 24))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 24, width: 32, height: 24))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 32, y: 24, width: 32, height: 24))
        }
        let filter = PhotoFilterSelection(
            preset: PhotoFilterCatalog.presets[0], intensityPercent: 80
        )

        func bytes(_ image: CGImage) throws -> [UInt8] {
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &result, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return result
        }

        for orientation in [UIImage.Orientation.right, .rightMirrored, .leftMirrored, .downMirrored] {
            let source = UIImage(
                cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: orientation
            )
            var filterOnly = PhotoEffectsSettings()
            filterOnly.photoFilterEnabled = true
            filterOnly.selectedFilter = filter
            let reference = try PhotoEffectsRenderer.render(source, settings: filterOnly)
            let referenceImage = try XCTUnwrap(reference.cgImage)

            var bordered = filterOnly
            bordered.photoFrameEnabled = true
            bordered.photoFrameBorderEnabled = true
            bordered.photoFramePreset = .plaque
            bordered.watermark.enabled = false
            let output = try PhotoEffectsRenderer.render(source, settings: bordered)
            let outputImage = try XCTUnwrap(output.cgImage)
            let photoLayer = try XCTUnwrap(outputImage.cropping(to: CGRect(
                x: 0, y: 0, width: referenceImage.width, height: referenceImage.height
            )))

            XCTAssertEqual(try bytes(photoLayer), try bytes(referenceImage), "\(orientation)")
        }
    }

    func testPhotoFilterDoesNotRecolorFrameBackdrop() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 64, height: 48), format: format
        ).image { context in
            UIColor(red: 0.92, green: 0.16, blue: 0.08, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            UIColor(red: 0.04, green: 0.25, blue: 0.88, alpha: 1).setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        }
        var unfiltered = PhotoEffectsSettings()
        unfiltered.photoFrameEnabled = true
        unfiltered.photoFrameBorderEnabled = true
        unfiltered.photoFramePreset = .cinema
        unfiltered.watermark.enabled = false
        var filtered = unfiltered
        filtered.photoFilterEnabled = true
        let preset = Np3FilterCatalog.presets[0]
        filtered.selectedFilter = PhotoFilterSelection(
            preset: .init(id: preset.id, name: preset.name), intensityPercent: 100
        )

        let plainOutput = try PhotoEffectsRenderer.render(source, settings: unfiltered)
        var filterOnly = PhotoEffectsSettings()
        filterOnly.photoFilterEnabled = true
        filterOnly.selectedFilter = filtered.selectedFilter
        let preparedFilter = try PhotoEffectsRenderer.render(source, settings: filterOnly)
        var decorationOnly = filtered
        decorationOnly.photoFilterEnabled = false
        let filteredOutput = try PhotoEffectsRenderer.render(
            preparedFilter, settings: decorationOnly, backdropSource: source
        )
        let exportFilteredOutput = try PhotoEffectsRenderer.render(source, settings: filtered)

        func bytes(_ image: UIImage) throws -> [UInt8] {
            let cgImage = try XCTUnwrap(image.cgImage)
            var result = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &result, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                             width: cgImage.width, height: cgImage.height))
            return result
        }
        let plainBytes = try bytes(plainOutput)
        let filteredBytes = try bytes(filteredOutput)
        let exportFilteredBytes = try bytes(exportFilteredOutput)
        let width = try XCTUnwrap(plainOutput.cgImage).width
        let height = try XCTUnwrap(plainOutput.cgImage).height
        func pixel(_ data: [UInt8], x: Int, y: Int) -> ArraySlice<UInt8> {
            let offset = (y * width + x) * 4
            return data[offset..<(offset + 4)]
        }

        XCTAssertEqual(pixel(plainBytes, x: 0, y: 0),
                       pixel(filteredBytes, x: 0, y: 0))
        XCTAssertEqual(pixel(plainBytes, x: 0, y: 0),
                       pixel(exportFilteredBytes, x: 0, y: 0))
        XCTAssertNotEqual(pixel(plainBytes, x: width / 2, y: height / 2),
                          pixel(filteredBytes, x: width / 2, y: height / 2))
        XCTAssertEqual(pixel(filteredBytes, x: width / 2, y: height / 2),
                       pixel(exportFilteredBytes, x: width / 2, y: height / 2))
    }

    func testPhotoEffectsFilterTilesUseAndroidPixelBudget() {
        XCTAssertEqual(photoEffectsFilterTileRows(sourceWidth: 4_096), 1_024)
        XCTAssertEqual(photoEffectsFilterTileRows(sourceWidth: 6_000), 699)
        XCTAssertEqual(photoEffectsFilterTileRows(sourceWidth: 5_000_000), 1)
    }

    func testCancelledPreviewFilterReleasesPixelWorkersPromptly() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 4_096, height: 3_072), format: format
        ).image { context in
            UIColor(red: 0.24, green: 0.52, blue: 0.76, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4_096, height: 3_072))
        }
        let cgImage = try XCTUnwrap(source.cgImage)
        let preset = Np3FilterCatalog.presets[0]
        let task = Task.detached(priority: .userInitiated) {
            try Np3BitmapFilter.apply(
                cgImage, parameters: preset.parameters, intensityPercent: 80
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preview pixel work unexpectedly completed")
        } catch is CancellationError {}
        XCTAssertLessThan(
            cancelledAt.duration(to: .now), .seconds(1),
            "A stale filter preview must not keep the shared render gate occupied"
        )
    }

    func testPhotoEffectsBorderPreviewUsesAndroid1920PixelLayout() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 300), format: format
        ).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        func renderedSize(_ preset: PhotoFramePreset) throws -> CGSize {
            try autoreleasepool {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true
                settings.photoFrameBorderEnabled = true
                settings.photoFramePreset = preset
                settings.watermark.enabled = false
                let output = try XCTUnwrap(PhotoEffectsRenderer.render(
                    source, settings: settings, previewLongEdge: 1_920
                ).cgImage)
                return CGSize(width: output.width, height: output.height)
            }
        }

        XCTAssertEqual(try renderedSize(.mist), CGSize(width: 1_920, height: 1_440))
        XCTAssertEqual(try renderedSize(.plaque), CGSize(width: 1_920, height: 1_670))
        XCTAssertEqual(try renderedSize(.classicSignature), CGSize(width: 1_920, height: 1_802))
        // Android caps immersive previews but never upscales them.
        XCTAssertEqual(try renderedSize(.immersive), CGSize(width: 400, height: 300))
    }

    func testPhotoEffectsPreviewIdentityIgnoresNonPixelEditorPreferences() {
        var current = PhotoEffectsSettings()
        current.photoFrameEnabled = true
        current.photoFrameBorderEnabled = true
        current.photoFramePreset = .mist
        current.photoFilterEnabled = true
        current.selectedFilter = PhotoFilterSelection(
            preset: PhotoFilterCatalog.presets[0], intensityPercent: 80
        )
        var preferences = current
        preferences.favoriteFilterIDs = [
            PhotoEffectsSettings.filterKey(PhotoFilterCatalog.presets[1].id)
        ]
        preferences.filterIntensities[
            PhotoEffectsSettings.filterKey(PhotoFilterCatalog.presets[2].id)
        ] = 42
        preferences.favoriteFramePresets = [.cinema]
        preferences.metadataByPreset[PhotoFramePreset.cinema.rawValue] = .defaults(for: .cinema)

        XCTAssertEqual(photoEffectsPreviewPixelSettings(current),
                       photoEffectsPreviewPixelSettings(preferences))

        preferences.metadata.showModel.toggle()
        XCTAssertNotEqual(photoEffectsPreviewPixelSettings(current),
                          photoEffectsPreviewPixelSettings(preferences))
    }

    func testPhotoEffectsPreviewUsesAndroidMetadataPlaceholdersFieldByField() throws {
        var settings = PhotoFrameMetadataSettings()
        settings.showDate = true
        settings.showTime = true
        settings.showLensModel = true
        settings.showCoordinates = true
        settings.showAltitude = true
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 17, hour: 12
        )))
        let empty = PhotoFrameMetadata(
            make: nil, model: nil, lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil,
            dateTime: nil
        )

        let preview = presentedPhotoFrameMetadata(
            empty, settings: settings, preview: true, now: now
        )
        XCTAssertEqual(preview.make, "NIKON")
        XCTAssertEqual(preview.model, "Z 233")
        XCTAssertEqual(preview.lensModel, "1-800mm f/0.1")
        XCTAssertEqual(preview.focalLength, "5100mm")
        XCTAssertEqual(preview.aperture, "f/0.1")
        XCTAssertEqual(preview.shutter, "1/99999")
        XCTAssertEqual(preview.iso, "ISO999999")
        XCTAssertEqual(preview.dateTime, "2026-08-18 25:61:61")
        XCTAssertEqual(preview.latitude, 66.6666)
        XCTAssertEqual(preview.longitude, 66.6666)
        XCTAssertEqual(preview.altitude, 23_333)

        let exported = presentedPhotoFrameMetadata(empty, settings: settings)
        XCTAssertNil(exported.make)
        XCTAssertNil(exported.model)
        XCTAssertNil(exported.lensModel)
        XCTAssertNil(exported.focalLength)
        XCTAssertNil(exported.aperture)
        XCTAssertNil(exported.shutter)
        XCTAssertNil(exported.iso)
        XCTAssertNil(exported.dateTime)
        XCTAssertNil(exported.latitude)
        XCTAssertNil(exported.longitude)
        XCTAssertNil(exported.altitude)
    }

    func testPhotoEffectsMetadataInfersBrandFromModelLikeAndroid() {
        let metadata = PhotoFrameMetadata(
            make: nil, model: "NIKON Z 8", lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil,
            dateTime: nil
        )
        var settings = PhotoFrameMetadataSettings()
        settings.showBrand = true
        settings.showModel = false

        let presented = presentedPhotoFrameMetadata(metadata, settings: settings)

        XCTAssertEqual(presented.make, "NIKON")
        XCTAssertNil(presented.model)
    }

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
        XCTAssertEqual(Array(restored.orderedFramePresets.prefix(3)), [.cinema, .mist, .minimal])
        XCTAssertEqual(restored.selectedFilter, settings.selectedFilter)
        restored.toggleFilterFavorite(c.id)
        restored.toggleFilterFavorite(c.id)
        XCTAssertEqual(Array(restored.orderedFilters.prefix(2)).map(\.id), [a.id, c.id])
    }

    @MainActor
    func testEffectsRestoreNormalizesWatermarkAndLocalMetadata() {
        let cameraSuite = "effects-normalize-camera-\(UUID())"
        let localSuite = "effects-normalize-local-\(UUID())"
        let cameraDefaults = UserDefaults(suiteName: cameraSuite)!
        let localDefaults = UserDefaults(suiteName: localSuite)!
        defer {
            cameraDefaults.removePersistentDomain(forName: cameraSuite)
            localDefaults.removePersistentDomain(forName: localSuite)
        }

        var camera = PhotoEffectsSettings()
        camera.watermark.content = .image
        camera.watermark.imageHash = String(repeating: "z", count: 64)
        camera.watermark.text = "  abc\n\tdef  "
        camera.watermark.sizePercent = 999
        camera.watermark.opacityPercent = -2
        camera.metadataByPreset[PhotoFramePreset.mist.rawValue] = .init(
            showCoordinates: true, showAltitude: true,
            datePattern: " invalid ", timePattern: " invalid "
        )
        let cameraStore = PhotoEffectsStore(defaults: cameraDefaults)
        cameraStore.update(camera)
        let restoredCamera = PhotoEffectsStore(defaults: cameraDefaults).settings
        XCTAssertEqual(restoredCamera.watermark.content, .text)
        XCTAssertNil(restoredCamera.watermark.imageHash)
        XCTAssertEqual(restoredCamera.watermark.text, "abc def")
        XCTAssertEqual(restoredCamera.watermark.sizePercent, 300)
        XCTAssertEqual(restoredCamera.watermark.opacityPercent, 1)
        XCTAssertEqual(restoredCamera.metadataByPreset[PhotoFramePreset.mist.rawValue]?.datePattern, "yyyy-MM-dd")
        XCTAssertEqual(restoredCamera.metadataByPreset[PhotoFramePreset.mist.rawValue]?.timePattern, "HH:mm:ss")
        XCTAssertEqual(restoredCamera.metadataByPreset[PhotoFramePreset.mist.rawValue]?.showCoordinates, true)

        var local = camera
        local.watermark.text = "  abc\n\tdef  "
        let localStore = PhotoEffectsStore(defaults: localDefaults, scope: .localPhotos)
        localStore.update(local)
        let restoredLocal = PhotoEffectsStore(defaults: localDefaults, scope: .localPhotos).settings
        XCTAssertEqual(restoredLocal.watermark.text, "  abc def  ")
        XCTAssertEqual(restoredLocal.metadataByPreset[PhotoFramePreset.mist.rawValue]?.showCoordinates, false)
        XCTAssertEqual(restoredLocal.metadataByPreset[PhotoFramePreset.mist.rawValue]?.showAltitude, false)
    }

    @MainActor
    func testEffectsRestoreEveryAndroidMetadataPreferenceGeneration() {
        let suite = "effects-metadata-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            // Original six flags + two patterns.
            "MIST|true|false|true|true|true|true|yyyy/MM/dd|HH:mm",
            // Lens-model generation.
            "CINEMA|false|false|true|true|true|true|true|yyyy.MM.dd|HH.mm",
            // Former location generation with the now-removed address slot.
            "PLAQUE|true|true|true|true|true|true|false|true|true|true|MM-dd-yyyy|HH.mm.ss",
        ].joined(separator: ";"), forKey: "photo_frame_metadata_settings_v1")

        let restored = PhotoEffectsStore(defaults: defaults).settings.metadataByPreset

        XCTAssertEqual(restored[PhotoFramePreset.mist.rawValue]?.showLensModel, false)
        XCTAssertEqual(restored[PhotoFramePreset.mist.rawValue]?.datePattern, "yyyy/MM/dd")
        XCTAssertEqual(restored[PhotoFramePreset.cinema.rawValue]?.showLensModel, true)
        XCTAssertEqual(restored[PhotoFramePreset.cinema.rawValue]?.timePattern, "HH.mm")
        XCTAssertEqual(restored[PhotoFramePreset.plaque.rawValue]?.showCoordinates, true)
        XCTAssertEqual(restored[PhotoFramePreset.plaque.rawValue]?.showAltitude, true)
        XCTAssertEqual(restored[PhotoFramePreset.plaque.rawValue]?.datePattern, "MM-dd-yyyy")
    }

    @MainActor
    func testLocalEffectsFirstRunMigratesOnlyLegacyFavoritesOnce() {
        let legacySuite = "effects-legacy-\(UUID())"
        let localSuite = "effects-local-migration-\(UUID())"
        let legacy = UserDefaults(suiteName: legacySuite)!
        let local = UserDefaults(suiteName: localSuite)!
        defer {
            legacy.removePersistentDomain(forName: legacySuite)
            local.removePersistentDomain(forName: localSuite)
        }
        let a = PhotoFilterCatalog.presets[0]
        var old = PhotoEffectsSettings()
        old.selectFilter(a.id)
        old.toggleFilterFavorite(a.id)
        old.favoriteFrameEffects = [.init(preset: .cinema, watermark: .init())]
        old.favoriteFramePresets = [.cinema]
        old.photoFrameEnabled = true
        old.photoFramePreset = .filmEdge
        PhotoEffectsStore(defaults: legacy).update(old)

        let migrated = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                         legacyDefaults: legacy).settings
        XCTAssertEqual(migrated.favoriteFilterIDs, [PhotoEffectsSettings.filterKey(a.id)])
        XCTAssertEqual(migrated.favoriteFrameEffects.map(\.preset), [.cinema])
        XCTAssertFalse(migrated.photoFrameEnabled)
        XCTAssertEqual(migrated.photoFramePreset, .mist)

        legacy.set("", forKey: "favorite_photo_filters_v1")
        legacy.set("", forKey: "favorite_frame_effects_v1")
        let reopened = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                         legacyDefaults: legacy).settings
        XCTAssertEqual(reopened.favoriteFilterIDs, migrated.favoriteFilterIDs)
        XCTAssertEqual(reopened.favoriteFrameEffects.map(\.preset), [.cinema])
    }

    @MainActor
    func testLocalEffectsFirstRunPersistsIndependentScopeWithoutEdits() {
        let legacySuite = "effects-empty-legacy-\(UUID())"
        let localSuite = "effects-empty-local-\(UUID())"
        let legacy = UserDefaults(suiteName: legacySuite)!
        let local = UserDefaults(suiteName: localSuite)!
        defer {
            legacy.removePersistentDomain(forName: legacySuite)
            local.removePersistentDomain(forName: localSuite)
        }

        let first = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                      legacyDefaults: legacy).settings
        XCTAssertEqual(local.integer(forKey: "settings_version"), 3)
        XCTAssertTrue(first.favoriteFilterIDs.isEmpty)

        let preset = PhotoFilterCatalog.presets[0]
        var camera = PhotoEffectsSettings()
        camera.toggleFilterFavorite(preset.id)
        PhotoEffectsStore(defaults: legacy).update(camera)

        let reopened = PhotoEffectsStore(defaults: local, scope: .localPhotos,
                                         legacyDefaults: legacy).settings
        XCTAssertTrue(reopened.favoriteFilterIDs.isEmpty)
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

    @MainActor
    func testTransferEffectsRestoreImmediateEditorPreferencesWithoutCommittedDraft() {
        let suite = "effects-partial-editor-persistence-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Np3FilterCatalog.presets[0]
        defaults.set("\(first.catalogKey),63", forKey: "photo_filter_intensities_v1")
        defaults.set(
            "CINEMA,true,TEXT,CALLIGRAPHY,80,AUTO,ADAPTIVE,72,AUTO",
            forKey: "favorite_frame_effects_v1"
        )

        let restored = PhotoEffectsStore(defaults: defaults).settings

        XCTAssertEqual(restored.selectedFilter?.preset.id, first.id)
        XCTAssertEqual(restored.selectedFilter?.intensityPercent, 64)
        XCTAssertEqual(restored.filterIntensities[first.catalogKey], 64)
        XCTAssertFalse(restored.photoFilterEnabled)
        XCTAssertEqual(restored.favoriteFrameEffects.map(\.preset), [.cinema])
    }

    @MainActor
    func testLocalEffectsKeepValidIntensityMapWhenSelectedFilterWasRemoved() {
        let suite = "local-effects-removed-filter-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Np3FilterCatalog.presets[0]

        defaults.set(3, forKey: "settings_version")
        defaults.set("removed-filter", forKey: "filter_id")
        defaults.set(true, forKey: "filter_enabled")
        defaults.set("\(first.catalogKey),63;removed-key,42", forKey: "filter_intensities_v1")

        let restored = PhotoEffectsStore(defaults: defaults, scope: .localPhotos).settings
        XCTAssertNil(restored.selectedFilter)
        XCTAssertFalse(restored.photoFilterEnabled)
        XCTAssertEqual(restored.filterIntensities, [first.catalogKey: 64])
        XCTAssertEqual(defaults.string(forKey: "filter_intensities_v1"), "\(first.catalogKey),64")
    }

    @MainActor
    func testLegacyEffectsJSONDropsRemovedFilterIntensityKeys() throws {
        let suite = "effects-json-intensity-normalization-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PhotoFilterCatalog.presets[0]
        let validKey = PhotoEffectsSettings.filterKey(first.id)
        var legacy = PhotoEffectsSettings()
        legacy.filterIntensities = [validKey: 63, "removed-key": 42]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "photoEffectsSettings.v1")

        let restored = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertEqual(restored.filterIntensities, [validKey: 64])
    }

    @MainActor
    func testLegacyCurrentFilterIntensityMigratesIntoPerFilterMap() {
        let transferSuite = "effects-transfer-intensity-migration-\(UUID())"
        let localSuite = "effects-local-intensity-migration-\(UUID())"
        let transferDefaults = UserDefaults(suiteName: transferSuite)!
        let localDefaults = UserDefaults(suiteName: localSuite)!
        defer {
            transferDefaults.removePersistentDomain(forName: transferSuite)
            localDefaults.removePersistentDomain(forName: localSuite)
        }
        let preset = Np3FilterCatalog.presets[0]

        transferDefaults.set(preset.id, forKey: "photo_filter_selected_id")
        transferDefaults.set(37, forKey: "photo_filter_intensity")
        let transfer = PhotoEffectsStore(defaults: transferDefaults).settings
        let transferIntensity = Np3FilterEngine.normalizeIntensity(37)
        XCTAssertEqual(transfer.selectedFilter?.intensityPercent, transferIntensity)
        XCTAssertEqual(transfer.filterIntensities[preset.catalogKey], transferIntensity)
        XCTAssertNil(transferDefaults.object(forKey: "photo_filter_intensity"))
        XCTAssertEqual(transferDefaults.string(forKey: "photo_filter_intensities_v1"), "\(preset.catalogKey),\(transferIntensity)")

        localDefaults.set(3, forKey: "settings_version")
        localDefaults.set(preset.id, forKey: "filter_id")
        localDefaults.set(42, forKey: "filter_intensity")
        let local = PhotoEffectsStore(defaults: localDefaults, scope: .localPhotos).settings
        let localIntensity = Np3FilterEngine.normalizeIntensity(42)
        XCTAssertEqual(local.selectedFilter?.intensityPercent, localIntensity)
        XCTAssertEqual(local.filterIntensities[preset.catalogKey], localIntensity)
        XCTAssertNil(localDefaults.object(forKey: "filter_intensity"))
        XCTAssertEqual(localDefaults.string(forKey: "filter_intensities_v1"), "\(preset.catalogKey),\(localIntensity)")
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
    func testThumbnailCacheIdentityMatchesAndroidSerialAndResponderFallbacks() {
        let validSerial = deviceInfo(manufacturer: " Nikon ", model: " Z 8 ", serial: " 12345 ")
        XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: validSerial,
                                                     transportIdentifier: "guid-fallback"),
                       "Nikon\u{0}Z 8\u{0}12345")

        for placeholder in ["", " ", "unknown", "NONE", "null", "n/a", "00-00"] {
            let info = deviceInfo(manufacturer: " Nikon ", model: " Z 8 ", serial: placeholder)
            XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: info,
                                                         transportIdentifier: " responder-guid "),
                           "Nikon\u{0}Z 8\u{0}responder-guid")
        }
    }

    func testThumbnailCacheIdentityStillScopesCameraWithoutAnyPhysicalIdentifier() {
        let info = deviceInfo(manufacturer: " Nikon ", model: " Z 8 ", serial: "0000")
        XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: info, transportIdentifier: "---"),
                       "Nikon\u{0}Z 8\u{0}unknown-device")
        XCTAssertEqual(cameraThumbnailCacheIdentity(deviceInfo: nil, transportIdentifier: "abc123"),
                       "\u{0}\u{0}abc123")
    }

    private func deviceInfo(manufacturer: String, model: String, serial: String) -> PTPDeviceInfo {
        PTPDeviceInfo(standardVersion: 100, vendorExtensionID: 10, vendorExtensionVersion: 100,
                      vendorExtensionDescription: "", functionalMode: 0,
                      manufacturer: manufacturer, model: model, version: "", serialNumber: serial,
                      operations: [], events: [], properties: [], captureFormats: [], imageFormats: [])
    }

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
