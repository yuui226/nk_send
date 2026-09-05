import Foundation
import CoreGraphics
import ImageIO
import XCTest
import ZTransferShared
@testable import ZTransfer

/// Apple filesystem/coordinator tests. Registered for Mac, never counted as Windows execution.
final class ProviderPublicationTests: XCTestCase {
    func testExistingOriginalStreamsIntoAppShareWithoutChangingProviderOrItsIndex() async throws {
        for bytes in [Data(), Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })] {
            let area = try PublicationArea(bytes: bytes), coordinator = PublicationCoordinator()
            let publisher = area.publisher(coordinator)
            let original = try await publisher.publish(area.saved)
            let index = try await publisher.originals(since: -1, rescan: true)
            let app = CameraOriginalStore(root: area.root.appendingPathComponent("app"))
            let output = try await app.makeShareFile(name: original.url.lastPathComponent, size: original.bytes)
            coordinator.onBegin = { XCTAssertGreaterThan(area.access.starts, area.access.stops) }
            let reference = ExistingOriginalReference(name: original.url.lastPathComponent, size: original.bytes, locator: original.url.absoluteString)
            let count = try await publisher.copyOriginal(reference, to: output)
            XCTAssertEqual(area.access.starts, area.access.stops) // Provider grant ended before app publication.
            let shared = try output.commit(expectedBytes: count)
            XCTAssertEqual(shared.bytes, original.bytes); XCTAssertEqual(shared.sha256, original.sha256)
            XCTAssertEqual(try Data(contentsOf: shared.url), bytes)
            XCTAssertEqual(try Data(contentsOf: original.url), bytes)
            let unchanged = try await publisher.originals(since: index.revision, rescan: false)
            XCTAssertEqual(unchanged.revision, index.revision); XCTAssertTrue(unchanged.entries.isEmpty)
            let appIndex = try await app.originals(since: -1, rescan: true)
            XCTAssertTrue(appIndex.entries.isEmpty) // Shares cannot become accidental transfer matches.
        }
    }

    func testExistingShareRejectsChangedMetadataEvenAfterIndexRescan() async throws {
        let area = try PublicationArea(bytes: Data("ABC".utf8)), publisher = area.publisher()
        let original = try await publisher.publish(area.saved)
        _ = try await publisher.originals(since: -1, rescan: true)
        let reference = ExistingOriginalReference(name: original.url.lastPathComponent, size: original.bytes, locator: original.url.absoluteString)
        try Data("changed size".utf8).write(to: original.url)
        _ = try await publisher.originals(since: -1, rescan: true)
        let app = CameraOriginalStore(root: area.root.appendingPathComponent("app"))
        let output = try await app.makeShareFile(name: reference.name, size: reference.size)
        do { _ = try await publisher.copyOriginal(reference, to: output); XCTFail("Frozen size changed") }
        catch { guard case OriginalIndexError.incompleteMetadata = error else { return XCTFail("\(error)") } }
        output.discard()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: area.root.appendingPathComponent("app/Shared Originals").path), [])
        XCTAssertEqual(try Data(contentsOf: original.url), Data("changed size".utf8))
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testRevokedGrantCannotMaterializeAnExistingOriginalForSharing() async throws {
        let area = try PublicationArea(bytes: Data("ABC".utf8)), publisher = area.publisher()
        let original = try await publisher.publish(area.saved)
        _ = try await publisher.originals(since: -1, rescan: true)
        let app = CameraOriginalStore(root: area.root.appendingPathComponent("app"))
        let output = try await app.makeShareFile(name: original.url.lastPathComponent, size: original.bytes)
        area.access.allowed = false
        let reference = ExistingOriginalReference(name: original.url.lastPathComponent, size: original.bytes, locator: original.url.absoluteString)
        do { _ = try await publisher.copyOriginal(reference, to: output); XCTFail("Missing grant") }
        catch { guard case ExportDirectoryError.permissionLost = error else { return XCTFail("\(error)") } }
        output.discard()
        XCTAssertEqual(try Data(contentsOf: original.url), area.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: area.root.appendingPathComponent("app/Shared Originals").path), [])
    }

    func testCancelledExistingShareCoordinationDoesNotPublishOrDeleteAnOriginal() async throws {
        let area = try PublicationArea(bytes: Data("ABC".utf8)), coordinator = PublicationCoordinator()
        let publisher = area.publisher(coordinator), original = try await publisher.publish(area.saved)
        _ = try await publisher.originals(since: -1, rescan: true)
        let app = CameraOriginalStore(root: area.root.appendingPathComponent("app"))
        let output = try await app.makeShareFile(name: original.url.lastPathComponent, size: original.bytes)
        let began = expectation(description: "share content coordination blocked")
        coordinator.blockedContents = WaitingPublicationCoordinator(began)
        let reference = ExistingOriginalReference(name: original.url.lastPathComponent, size: original.bytes, locator: original.url.absoluteString)
        let copy = Task {
            do {
                let count = try await publisher.copyOriginal(reference, to: output)
                try Task.checkCancellation()
                return try output.commit(expectedBytes: count)
            } catch { output.discard(); throw error }
        }
        await fulfillment(of: [began], timeout: 3)
        copy.cancel()
        do { _ = try await copy.value; XCTFail("Cancelled share") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(area.access.starts, area.access.stops)
        XCTAssertEqual(try Data(contentsOf: original.url), area.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: area.root.appendingPathComponent("app/Shared Originals").path), [])
    }

    func testExistingShareUsesTheSameNoFollowDescriptorBoundaryAndCancellationFlag() throws {
        let area = try PublicationArea(bytes: Data("ABC".utf8))
        let root = area.saved.url.deletingLastPathComponent()
        let entry = OriginalIndexEntry(name: area.saved.url.lastPathComponent, size: area.saved.bytes, folder: nil, url: area.saved.url)
        let reference = ExistingOriginalReference(name: entry.name, size: entry.size, locator: entry.url.absoluteString)
        let output = try SandboxTransferFile(directory: area.root.appendingPathComponent("shares"), name: entry.name, declaredSize: entry.size, captureDate: nil)
        defer { output.discard() }
        let cancellation = PreviewExifReadCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try IndexedOriginalReader(root: root, entry: entry, cancellation: cancellation).copyOriginal(reference, to: output)) {
            XCTAssertTrue($0 is CancellationError)
        }
        let outside = area.root.appendingPathComponent("outside.JPG"); try area.bytes.write(to: outside)
        try FileManager.default.removeItem(at: entry.url)
        try FileManager.default.createSymbolicLink(at: entry.url, withDestinationURL: outside)
        XCTAssertThrowsError(try IndexedOriginalReader(root: root, entry: entry).copyOriginal(reference, to: output))
        XCTAssertEqual(try Data(contentsOf: outside), area.bytes)
    }

    func testExplicitCameraNameUsesTargetCollisionRulesWithoutRenamingSandboxOriginal() async throws {
        let area = try PublicationArea()
        let originalName = "camera.NEF", existing = area.target.appendingPathComponent("camera.NEF")
        try Data([8]).write(to: existing)
        let result = try await area.publisher().publish(area.saved, originalName: originalName)
        XCTAssertEqual(result.url.lastPathComponent, PtpTransferBridge.shared.copyName(name: originalName, number: 1))
        XCTAssertEqual(try Data(contentsOf: existing), Data([8]))
        XCTAssertEqual(try Data(contentsOf: result.url), area.bytes)
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
    }

    func testExplicitCameraNameCannotBypassSafeComponentOrPrivatePartChecks() async throws {
        let area = try PublicationArea()
        let part = PtpTransferBridge.shared.partName(name: "source.JPG", size: 4, captureDate: nil)
        for name in ["", "..", "bad/name.JPG", "bad\\name.JPG", part] {
            do { _ = try await area.publisher().publish(area.saved, originalName: name); XCTFail("Unsafe name") }
            catch { guard case ProviderPublicationError.unsafePath = error else { return XCTFail("\(error)") } }
        }
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
    }

    func testSelectionPreparationBindsGrantWithoutScanningOrCoordinatingContent() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator(), store = area.publisher(coordinator)
        try await store.validateSelection()
        XCTAssertEqual(coordinator.calls, 0)
        XCTAssertEqual(area.access.starts, 1); XCTAssertEqual(area.access.stops, 1)
        XCTAssertEqual(try area.children(), [])
        try await area.store.select(area.target) // A newly persisted grant, even at the same path.
        do { try await store.validateSelection(); XCTFail("Already bound to earlier selection") }
        catch { guard case ExportDirectoryError.selectionChanged = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(coordinator.calls, 0)
    }

    func testSelectionPreparationMissingGrantDoesNotCreateDirectoryOrBookmark() async throws {
        let area = try PublicationArea()
        try await area.store.forget()
        let coordinator = PublicationCoordinator(), store = area.publisher(coordinator)
        do { try await store.validateSelection(); XCTFail("Missing grant") }
        catch { guard case ExportDirectoryError.missing = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(coordinator.calls, 0); XCTAssertEqual(area.access.starts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: area.bookmark.path))
        XCTAssertEqual(try area.children(), [])
    }

    func testRealCoordinatedContentReadUsesIndexedDateEntryWithoutChangingIndexOrSource() async throws {
        let area = try PublicationArea()
        let store = ProviderOriginalStore(directory: area.store)
        let folder = PtpTransferBridge.shared.destinationFolder(captureDate: "20260102T123456", byDate: true, dayKey: 20260905)
        let saved = try await store.publish(area.saved, folder: folder)
        let snapshot = try await store.originals(since: -1, rescan: true)
        let bytes = try await store.originalData(locator: saved.url.absoluteString)
        XCTAssertEqual(bytes, area.bytes)
        let unchanged = try await store.originals(since: snapshot.revision, rescan: false)
        XCTAssertEqual(unchanged.revision, snapshot.revision); XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testProviderExifAndSandboxUseSameActualMetadataReader() async throws {
        let area = try PublicationArea(bytes: providerJpeg())
        let store = ProviderOriginalStore(directory: area.store)
        let saved = try await store.publish(area.saved)
        _ = try await store.originals(since: -1, rescan: true)
        let sandbox = CameraOriginalStore(root: area.saved.url.deletingLastPathComponent())
        _ = try await sandbox.originals(since: -1, rescan: true)
        let providerExif = try await store.originalExif(locator: saved.url.absoluteString)
        let sandboxExif = try await sandbox.originalExif(locator: area.saved.url.absoluteString)
        let actual = try XCTUnwrap(providerExif), expected = try XCTUnwrap(sandboxExif)
        XCTAssertEqual(actual.iso, "ISO64"); XCTAssertEqual(actual.dateTime, "2026:09:05 01:02:03")
        XCTAssertEqual(actual.aperture, expected.aperture); XCTAssertEqual(actual.shutterSpeed, expected.shutterSpeed)
        XCTAssertEqual(actual.iso, expected.iso); XCTAssertEqual(actual.dateTime, expected.dateTime)
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testProviderRawUsesSharedRangesBeyondTwoGiBAndOrdinaryReadRetainsOriginalLimit() async throws {
        let area = try PublicationArea(bytes: Data([1]))
        let jpeg = try providerJpeg()
        let url = area.target.appendingPathComponent("LARGE.NEF")
        let offset: UInt32 = 2_147_483_648 + 4096
        var header = Data(repeating: 0, count: 128)
        func u16(_ at: Int, _ value: UInt16) { for i in 0..<2 { header[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        func u32(_ at: Int, _ value: UInt32) { for i in 0..<4 { header[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) } }
        header[0] = 73; header[1] = 73; u16(2, 42); u32(4, 8); u16(8, 2)
        u16(10, 0x0201); u16(12, 4); u32(14, 1); u32(18, offset)
        u16(22, 0x0202); u16(24, 4); u32(26, 1); u32(30, UInt32(jpeg.count))
        try header.write(to: url)
        let output = try FileHandle(forWritingTo: url)
        do { try output.seek(toOffset: UInt64(offset)); try output.write(contentsOf: jpeg); try output.close() }
        catch { try? output.close(); throw error }
        let store = ProviderOriginalStore(directory: area.store)
        let snapshot = try await store.originals(since: -1, rescan: true)
        let locator = try XCTUnwrap(snapshot.entries.first).url.absoluteString
        let actual = try await store.originalRawPreviewData(locator: locator)
        XCTAssertEqual(actual, jpeg)
        do { _ = try await store.originalData(locator: locator); XCTFail("Ordinary data still bounded") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testContentRejectsUnindexedOrModifiedLocatorBeforeCoordination() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator(), store = area.publisher()
        let saved = try await store.publish(area.saved)
        let reader = area.publisher(coordinator)
        do { _ = try await reader.originalData(locator: saved.url.absoluteString); XCTFail("No scan") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        XCTAssertEqual(coordinator.calls, 0)
        _ = try await reader.originals(since: -1, rescan: true)
        let calls = coordinator.calls
        for locator in [area.saved.url.absoluteString, saved.url.absoluteString + "?x=1", saved.url.absoluteString + "#part"] {
            do { _ = try await reader.originalData(locator: locator); XCTFail("Not exact indexed locator") }
            catch { XCTAssertTrue(error is OriginalIndexError) }
        }
        XCTAssertEqual(coordinator.calls, calls)
    }

    func testChangedSelectionRejectsAllThreeContentRoutesWithoutRedirecting() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator(), store = area.publisher()
        let saved = try await store.publish(area.saved)
        let reader = area.publisher(coordinator)
        _ = try await reader.originals(since: -1, rescan: true)
        let calls = coordinator.calls
        let other = area.root.appendingPathComponent("another", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try await area.store.select(other)
        for mode in 0..<3 {
            do {
                if mode == 0 { _ = try await reader.originalData(locator: saved.url.absoluteString) }
                else if mode == 1 { _ = try await reader.originalRawPreviewData(locator: saved.url.absoluteString) }
                else { _ = try await reader.originalExif(locator: saved.url.absoluteString) }
                XCTFail("Old selection must fail")
            } catch { guard case ExportDirectoryError.selectionChanged = error else { return XCTFail("\(error)") } }
        }
        XCTAssertEqual(coordinator.calls, calls)
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }

    func testContentRevokedGrantDoesNotTouchCoordinatorOrDiscardBookmark() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator(), store = area.publisher(coordinator)
        let saved = try await store.publish(area.saved)
        _ = try await store.originals(since: -1, rescan: true)
        let calls = coordinator.calls, stops = area.access.stops
        area.access.allowed = false
        do { _ = try await store.originalData(locator: saved.url.absoluteString); XCTFail("Revoked") }
        catch { guard case ExportDirectoryError.permissionLost = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(coordinator.calls, calls); XCTAssertEqual(area.access.stops, stops)
        XCTAssertTrue(FileManager.default.fileExists(atPath: area.bookmark.path))
    }

    func testFrozenContentLocatorRejectsCoordinatorRelocationAndCanRetryOriginal() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator(), store = area.publisher(coordinator)
        let saved = try await store.publish(area.saved)
        _ = try await store.originals(since: -1, rescan: true)
        coordinator.source = area.saved.url // Even identical bytes elsewhere cannot replace the frozen file.
        do { _ = try await store.originalData(locator: saved.url.absoluteString); XCTFail("Redirect") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        coordinator.source = nil
        let actual = try await store.originalData(locator: saved.url.absoluteString)
        XCTAssertEqual(actual, area.bytes)
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testContentChangedSizeOrLeafLinkFailsAndClosesScope() async throws {
        let area = try PublicationArea()
        let store = area.publisher()
        let saved = try await store.publish(area.saved)
        _ = try await store.originals(since: -1, rescan: true)
        try Data([1]).write(to: saved.url)
        do { _ = try await store.originalData(locator: saved.url.absoluteString); XCTFail("Changed size") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        try FileManager.default.removeItem(at: saved.url) // Only this fixture's exported file.
        try FileManager.default.createSymbolicLink(at: saved.url, withDestinationURL: area.saved.url)
        do { _ = try await store.originalRawPreviewData(locator: saved.url.absoluteString); XCTFail("Link") }
        catch { XCTAssertTrue(error is OriginalIndexError) }
        XCTAssertEqual(area.access.starts, area.access.stops)
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
    }

    func testContentCoordinationWaitCancellationReleasesGrantAndAllowsRetry() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator(), store = area.publisher(coordinator)
        let saved = try await store.publish(area.saved)
        _ = try await store.originals(since: -1, rescan: true)
        let began = expectation(description: "content wait")
        coordinator.blockedContents = WaitingPublicationCoordinator(began)
        let task = Task { try await store.originalData(locator: saved.url.absoluteString) }
        await fulfillment(of: [began], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        coordinator.blockedContents = nil
        let actual = try await store.originalData(locator: saved.url.absoluteString)
        XCTAssertEqual(actual, area.bytes)
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testReaderSharedCancellationFlagRejectsAllRoutesEvenWithoutCancelledTask() throws {
        let area = try PublicationArea()
        let cancellation = PreviewExifReadCancellation()
        cancellation.cancel()
        let reader = IndexedOriginalReader(root: area.saved.url.deletingLastPathComponent(),
            entry: OriginalIndexEntry(name: area.saved.url.lastPathComponent, size: area.saved.bytes, folder: nil, url: area.saved.url),
            cancellation: cancellation)
        XCTAssertFalse(Task.isCancelled)
        XCTAssertThrowsError(try reader.originalData(locator: area.saved.url.absoluteString)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try reader.originalRawPreviewData(locator: area.saved.url.absoluteString)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try reader.originalExif(locator: area.saved.url.absoluteString)) { XCTAssertTrue($0 is CancellationError) }
    }

    private func providerJpeg() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifFNumber: 4, kCGImagePropertyExifExposureTime: 0.004,
            kCGImagePropertyExifISOSpeedRatings: [64], kCGImagePropertyExifDateTimeOriginal: "2026:09:05 01:02:03"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testRealCoordinatorCopiesLargeOriginalAndBalancesGrantWithoutDeletingSource() async throws {
        let area = try PublicationArea()
        let saved = try await ProviderOriginalStore(directory: area.store).publish(area.saved)
        XCTAssertEqual(saved.bytes, area.saved.bytes); XCTAssertEqual(saved.sha256, area.saved.sha256)
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
        XCTAssertEqual(area.access.starts, area.access.stops)
        XCTAssertEqual(try area.children(), [area.saved.url.lastPathComponent])
    }

    func testExistingNameUsesSharedCopyRuleAndNeverOverwritesOriginalOrUnrelatedPart() async throws {
        let area = try PublicationArea()
        let existing = area.target.appendingPathComponent(area.saved.url.lastPathComponent)
        try Data([255]).write(to: existing)
        let unrelated = area.target.appendingPathComponent(".another-writers-part")
        try Data([123]).write(to: unrelated)
        let saved = try await area.publisher().publish(area.saved)
        XCTAssertEqual(saved.url.lastPathComponent, PtpTransferBridge.shared.copyName(name: area.saved.url.lastPathComponent, number: 1))
        XCTAssertEqual(try Data(contentsOf: existing), Data([255]))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([123]))
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
    }

    func testDateBucketIsProvidedBySharedPolicyAndRootDoesNotReceiveAnotherCopy() async throws {
        let area = try PublicationArea()
        let folder = try XCTUnwrap(PtpTransferBridge.shared.destinationFolder(captureDate: "20260102T123456", byDate: true, dayKey: 20260905))
        let saved = try await area.publisher().publish(area.saved, folder: folder)
        XCTAssertEqual(saved.url.deletingLastPathComponent().lastPathComponent, folder)
        XCTAssertEqual(try area.children(), [folder])
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
    }

    func testCoordinatorSuppliedUrlsAreUsedAfterRelocation() async throws {
        let area = try PublicationArea()
        let movedSource = area.root.appendingPathComponent("relocated.JPG")
        let movedTarget = area.root.appendingPathComponent("relocated-provider", isDirectory: true)
        try FileManager.default.moveItem(at: area.saved.url, to: movedSource)
        try FileManager.default.moveItem(at: area.target, to: movedTarget)
        let coordinator = PublicationCoordinator()
        coordinator.source = movedSource; coordinator.directory = movedTarget
        coordinator.onBegin = { XCTAssertGreaterThan(area.access.starts, area.access.stops) }
        let saved = try await area.publisher(coordinator).publish(area.saved)
        XCTAssertEqual(saved.url.deletingLastPathComponent(), movedTarget.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(saved.url.lastPathComponent, area.saved.url.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: area.target.path))
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testWrongLengthRejectsSourceWithoutLeavingTemporaryOrFinalFiles() async throws {
        let area = try PublicationArea()
        let changed = SavedCameraFile(url: area.saved.url, bytes: area.saved.bytes + 1, sha256: area.saved.sha256)
        do { _ = try await area.publisher().publish(changed); XCTFail("Changed length") }
        catch { XCTAssertTrue(error is ProviderPublicationError) }
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testSameLengthChangedContentFailsDigestAndCleansOnlyOwnedPart() async throws {
        let area = try PublicationArea()
        var changed = area.bytes; changed[0] ^= 1
        try changed.write(to: area.saved.url)
        do { _ = try await area.publisher().publish(area.saved); XCTFail("Changed digest") }
        catch { guard case ProviderPublicationError.sourceChanged = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(try Data(contentsOf: area.saved.url), changed)
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testCancellationBetweenChunksClosesAndRemovesPartButPreservesOriginal() throws {
        let area = try PublicationArea()
        var checks = 0
        XCTAssertThrowsError(try ProviderOriginalStore.copyVerified(area.saved, coordinatedSource: area.saved.url,
            coordinatedDirectory: area.target, folder: nil, checkCancellation: {
                checks += 1
                if checks == 4 { throw CancellationError() } // After a chunk, not just before opening.
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
    }

    func testCancellationAtFinalBoundaryDoesNotPublishVerifiedPart() throws {
        let area = try PublicationArea(bytes: Data([1, 2, 3]))
        var checks = 0
        XCTAssertThrowsError(try ProviderOriginalStore.copyVerified(area.saved, coordinatedSource: area.saved.url,
            coordinatedDirectory: area.target, folder: nil, checkCancellation: {
                checks += 1
                if checks == 7 { throw CancellationError() } // Source and closed-part readback have finished.
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 7); XCTAssertEqual(try area.children(), [])
    }

    func testCancelledCoordinationWaitReleasesSecurityScopeWithoutEnteringAccessor() async throws {
        let area = try PublicationArea()
        let began = expectation(description: "coordinator waiting")
        let coordinator = WaitingPublicationCoordinator(began)
        let publisher = ProviderOriginalStore(directory: area.store, coordinatorFactory: { coordinator })
        let task = Task { try await publisher.publish(area.saved) }
        await fulfillment(of: [began], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testCoordinationFailureNeverCopiesAndStillBalancesScope() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator()
        coordinator.onBegin = { throw ProviderPublicationError.coordinationFailed }
        do { _ = try await area.publisher(coordinator).publish(area.saved); XCTFail("No accessor grant") }
        catch { guard case ProviderPublicationError.coordinationFailed = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testRevokedPermissionPreservesBookmarkAndNeverCallsCoordinator() async throws {
        let area = try PublicationArea()
        area.access.allowed = false
        let coordinator = PublicationCoordinator()
        do { _ = try await area.publisher(coordinator).publish(area.saved); XCTFail("Revoked") }
        catch { guard case ExportDirectoryError.permissionLost = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(coordinator.calls, 0)
        XCTAssertEqual(area.access.stops, 0)
        XCTAssertEqual(try Data(contentsOf: area.bookmark), Data([1]))
        XCTAssertEqual(try area.children(), [])
    }

    func testInvalidFoldersNeverTraverseOrCreateArbitraryDirectories() async throws {
        let area = try PublicationArea()
        for folder in ["..", "../outside", "A/B", "arbitrary", ""] {
            do { _ = try await area.publisher().publish(area.saved, folder: folder); XCTFail("Invalid folder") }
            catch { guard case ProviderPublicationError.unsafePath = error else { return XCTFail("\(error)") } }
        }
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testSourceAndDestinationDirectoryLinksAreRejectedWithoutTouchingTargets() async throws {
        let area = try PublicationArea()
        let link = area.root.appendingPathComponent("linked.JPG")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: area.saved.url)
        let linked = SavedCameraFile(url: link, bytes: area.saved.bytes, sha256: area.saved.sha256)
        do { _ = try await area.publisher().publish(linked); XCTFail("Source link") }
        catch { XCTAssertTrue(error is ProviderPublicationError) }
        let folder = "ZT2026-01-02"
        try FileManager.default.createSymbolicLink(at: area.target.appendingPathComponent(folder), withDestinationURL: area.root)
        do { _ = try await area.publisher().publish(area.saved, folder: folder); XCTFail("Date link") }
        catch { XCTAssertTrue(error is ProviderPublicationError) }
        XCTAssertEqual(try area.children(), [folder])
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
    }

    func testReadbackDetectsProviderPartMutationAndRemovesOnlyOwnedPart() throws {
        let area = try PublicationArea(bytes: Data([1, 2, 3]))
        var checks = 0
        XCTAssertThrowsError(try ProviderOriginalStore.copyVerified(area.saved, coordinatedSource: area.saved.url,
            coordinatedDirectory: area.target, folder: nil, checkCancellation: {
                checks += 1
                if checks == 5 { // The writer is closed; verification has just opened the same part.
                    let part = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: area.target, includingPropertiesForKeys: nil).first)
                    let writer = try FileHandle(forWritingTo: part)
                    try writer.write(contentsOf: Data([9, 9, 9])); try writer.close()
                }
            })) { error in
                guard case ProviderPublicationError.verificationFailed = error else { return XCTFail("\(error)") }
            }
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
    }
    func testProviderScanReusesRootDateBucketHiddenAndPrivatePartRules() async throws {
        let area = try PublicationArea()
        for folder in ["ZT2026-01-02", "effects", "ZT2026-01-02/nested"] {
            try FileManager.default.createDirectory(at: area.target.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["root.JPG", ".hidden.JPG", "ZT2026-01-02/date.NEF", "effects/ignored.JPG", "ZT2026-01-02/nested/ignored.JPG"] {
            try Data([1]).write(to: area.target.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: area.target.appendingPathComponent("link.JPG"), withDestinationURL: area.saved.url)
        let pending = try SandboxTransferFile(directory: area.target, name: "partial.JPG", declaredSize: 3, captureDate: nil)
        defer { pending.discard() }
        try pending.write(Data([1]))
        let store = ProviderOriginalStore(directory: area.store) // Actual Apple directory-read coordinator.
        let snapshot = try await store.originals(since: -1, rescan: true)
        XCTAssertTrue(snapshot.fullSnapshot)
        XCTAssertEqual(Set(snapshot.entries.map(\.name)), Set(["root.JPG", ".hidden.JPG", "date.NEF"]))
        XCTAssertEqual(snapshot.entries.first { $0.name == "date.NEF" }?.folder, "ZT2026-01-02")
        XCTAssertTrue(snapshot.entries.allSatisfy { $0.size == 1 })
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testProviderPublicationUpdatesSameIndexWithoutAnotherFilesystemScan() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator()
        let store = area.publisher(coordinator)
        let first = try await store.originals(since: -1, rescan: true)
        XCTAssertTrue(first.entries.isEmpty)
        let saved = try await store.publish(area.saved)
        let delta = try await store.originals(since: first.revision, rescan: false)
        XCTAssertFalse(delta.fullSnapshot); XCTAssertEqual(delta.entries.count, 1)
        XCTAssertEqual(delta.entries.first?.url, saved.url)
        XCTAssertEqual(delta.entries.first?.size, saved.bytes)
        XCTAssertEqual(coordinator.calls, 3) // Scan + copy + coordinated cached-root check, not another full scan.
        let reopened = try await area.publisher().originals(since: -1, rescan: false)
        XCTAssertTrue(reopened.fullSnapshot); XCTAssertEqual(reopened.entries, delta.entries)
    }

    func testMovedCoordinatedRootRebuildsLocatorsEvenWhenRescanWasNotRequested() async throws {
        let area = try PublicationArea()
        try Data([1]).write(to: area.target.appendingPathComponent("kept.JPG"))
        let coordinator = PublicationCoordinator()
        let store = area.publisher(coordinator)
        let first = try await store.originals(since: -1, rescan: true)
        let moved = area.root.appendingPathComponent("relocated-provider")
        try FileManager.default.moveItem(at: area.target, to: moved)
        coordinator.directory = moved
        let refreshed = try await store.originals(since: first.revision, rescan: false)
        XCTAssertTrue(refreshed.fullSnapshot)
        XCTAssertGreaterThan(refreshed.revision, first.revision)
        XCTAssertEqual(refreshed.entries.map(\.name), ["kept.JPG"])
        XCTAssertEqual(refreshed.entries.first?.url.deletingLastPathComponent(), moved.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testMissingProviderDirectoryDoesNotReplacePreviousIndexWithEmptySnapshot() async throws {
        let area = try PublicationArea()
        try Data([1]).write(to: area.target.appendingPathComponent("kept.JPG"))
        let store = area.publisher()
        let first = try await store.originals(since: -1, rescan: true)
        let moved = area.root.appendingPathComponent("moved-provider")
        try FileManager.default.moveItem(at: area.target, to: moved)
        do { _ = try await store.originals(since: -1, rescan: true); XCTFail("Missing provider must fail") }
        catch { XCTAssertFalse(error is CancellationError) }
        try FileManager.default.moveItem(at: moved, to: area.target)
        let retained = try await store.originals(since: -1, rescan: false)
        XCTAssertEqual(retained.revision, first.revision); XCTAssertEqual(retained.entries, first.entries)
    }

    func testChangedGrantRejectsOldIndexAndWritesRatherThanRedirectingToNewDirectory() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator()
        let oldStore = area.publisher(coordinator)
        _ = try await oldStore.originals(since: -1, rescan: true)
        let other = area.root.appendingPathComponent("other-provider")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try Data([9]).write(to: other.appendingPathComponent("OTHER.JPG"))
        try await area.store.select(other)
        do { _ = try await oldStore.originals(since: -1, rescan: false); XCTFail("Old cached metadata must not be accepted") }
        catch { guard case ExportDirectoryError.selectionChanged = error else { return XCTFail("\(error)") } }
        do { _ = try await oldStore.publish(area.saved); XCTFail("Old store must not redirect") }
        catch { guard case ExportDirectoryError.selectionChanged = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(coordinator.calls, 1)
        let fresh = try await area.publisher().originals(since: -1, rescan: true)
        XCTAssertEqual(fresh.entries.map(\.name), ["OTHER.JPG"])
        XCTAssertEqual(try area.children(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), ["OTHER.JPG"])
    }

    func testForgottenGrantRejectsCachedReadsWithoutDeletingAnyOriginal() async throws {
        let area = try PublicationArea()
        let store = area.publisher()
        _ = try await store.originals(since: -1, rescan: true)
        let saved = try await store.publish(area.saved)
        try await area.store.forget()
        do { _ = try await store.originals(since: -1, rescan: false); XCTFail("Forgotten grant") }
        catch { guard case ExportDirectoryError.missing = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
        XCTAssertEqual(try Data(contentsOf: area.saved.url), area.bytes)
    }

    func testPinnedStaleGrantDoesNotOverwriteBookmarkedSelection() async throws {
        let area = try PublicationArea()
        let store = area.publisher()
        _ = try await store.originals(since: -1, rescan: true)
        area.access.stale = true
        _ = try await store.originals(since: -1, rescan: true)
        XCTAssertEqual(try Data(contentsOf: area.bookmark), Data([1]))
        _ = try await area.store.displayName() // Ordinary owner refresh, not the pinned old operation.
        let refreshed = try Data(contentsOf: area.bookmark)
        XCTAssertNotEqual(refreshed, Data([1]))
        do { _ = try await store.originals(since: -1, rescan: false); XCTFail("Rebind after bookmark refresh") }
        catch { guard case ExportDirectoryError.selectionChanged = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try Data(contentsOf: area.bookmark), refreshed)
        XCTAssertEqual(area.access.starts, area.access.stops)
    }

    func testCancelledRescanPreservesPreviousRevisionAndEntries() async throws {
        let area = try PublicationArea()
        let coordinator = PublicationCoordinator()
        let store = area.publisher(coordinator)
        let saved = try await store.publish(area.saved)
        let first = try await store.originals(since: -1, rescan: true)
        coordinator.onBegin = { throw CancellationError() }
        do { _ = try await store.originals(since: -1, rescan: true); XCTFail("Cancelled scan") }
        catch { XCTAssertTrue(error is CancellationError) }
        coordinator.onBegin = nil
        let retained = try await store.originals(since: -1, rescan: false)
        XCTAssertEqual(retained.revision, first.revision); XCTAssertEqual(retained.entries, first.entries)
        XCTAssertEqual(try Data(contentsOf: saved.url), area.bytes)
    }

    func testCancelledReadCoordinationWaitReleasesScope() async throws {
        let area = try PublicationArea()
        let began = expectation(description: "read coordination waiting")
        let coordinator = WaitingPublicationCoordinator(began)
        let store = ProviderOriginalStore(directory: area.store, coordinatorFactory: { coordinator })
        let task = Task { try await store.originals(since: -1, rescan: true) }
        await fulfillment(of: [began], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Read cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(area.access.starts, area.access.stops)
        XCTAssertEqual(try area.children(), [])
    }

    func testScannerDefaultMissingRootBehaviorRemainsUnchangedForSandbox() throws {
        let area = try PublicationArea()
        try Data([1]).write(to: area.target.appendingPathComponent("original.JPG"))
        let sandbox = OriginalFileIndexCache(), provider = OriginalFileIndexCache()
        try sandbox.scan(root: area.target); try provider.scan(root: area.target, missingRootIsEmpty: false)
        let before = provider.update(since: -1)
        try FileManager.default.moveItem(at: area.target, to: area.root.appendingPathComponent("moved"))
        try sandbox.scan(root: area.target)
        XCTAssertTrue(sandbox.update(since: -1).entries.isEmpty)
        XCTAssertThrowsError(try provider.scan(root: area.target, missingRootIsEmpty: false))
        XCTAssertEqual(provider.update(since: -1).revision, before.revision)
        XCTAssertEqual(provider.update(since: -1).entries, before.entries)
    }

    func testCancellationInsideSharedDirectoryScannerNeverPublishesPartialCandidate() throws {
        let area = try PublicationArea()
        try Data([1]).write(to: area.target.appendingPathComponent("first.JPG"))
        let cache = OriginalFileIndexCache()
        try cache.scan(root: area.target)
        let before = cache.update(since: -1)
        try Data([2]).write(to: area.target.appendingPathComponent("second.JPG"))
        var checks = 0
        XCTAssertThrowsError(try cache.scan(root: area.target, missingRootIsEmpty: false, checkCancellation: {
            checks += 1; if checks == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(cache.update(since: -1).revision, before.revision)
        XCTAssertEqual(cache.update(since: -1).entries, before.entries)
    }
}

private final class PublicationArea {
    let root: URL, target: URL, bookmark: URL
    let bytes: Data, saved: SavedCameraFile
    let access: PublicationGrant
    let store: ScopedDirectoryStore
    init(bytes: Data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-test-\(UUID().uuidString)", isDirectory: true)
        target = root.appendingPathComponent("provider", isDirectory: true)
        bookmark = root.appendingPathComponent("grant")
        self.bytes = bytes
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let part = try SandboxTransferFile(directory: root.appendingPathComponent("originals"), name: "DSC_0001.JPG",
            declaredSize: Int64(bytes.count), captureDate: nil)
        try part.write(bytes); saved = try part.commit(expectedBytes: Int64(bytes.count))
        try Data([1]).write(to: bookmark)
        access = PublicationGrant(target)
        store = ScopedDirectoryStore(bookmarkFile: bookmark, access: access)
    }
    deinit { try? FileManager.default.removeItem(at: root) } // This fixture's UUID temp root only.
    func children() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() }
    func publisher(_ coordinator: PublicationCoordinator = PublicationCoordinator()) -> ProviderOriginalStore {
        ProviderOriginalStore(directory: store, coordinatorFactory: { coordinator })
    }
}

/// Configuration is fixed before awaited calls; counters read only after the operation completes.
private final class PublicationGrant: ExportDirectoryAccess {
    let url: URL
    var allowed = true, stale = false, starts = 0, stops = 0
    private var version: UInt8 = 1
    private var urls: [Data: URL]
    init(_ url: URL) { self.url = url; urls = [Data([1]): url] }
    func start(_ url: URL) -> Bool { starts += 1; return allowed }
    func stop(_ url: URL) { stops += 1 }
    func isDirectory(_ url: URL) -> Bool { true }
    func bookmark(_ url: URL) -> Data { version += 1; let data = Data([version]); urls[data] = url; return data }
    func resolve(_ bookmark: Data) throws -> ResolvedExportDirectory {
        guard let url = urls[bookmark] else { throw ExportDirectoryError.invalidBookmark }
        return ResolvedExportDirectory(url: url, stale: stale)
    }
}

private final class PublicationCoordinator: ProviderFileCoordinating, @unchecked Sendable {
    var source: URL?, directory: URL?
    var blockedContents: WaitingPublicationCoordinator?
    var onBegin: (() throws -> Void)?
    private(set) var calls = 0
    func copy(source: URL, directory: URL, accessor: (URL, URL) throws -> SavedCameraFile) throws -> SavedCameraFile {
        calls += 1; try onBegin?()
        return try accessor(self.source ?? source, self.directory ?? directory)
    }
    func read(directory: URL, accessor: (URL) throws -> ProviderIndexScan) throws -> ProviderIndexScan {
        calls += 1; try onBegin?()
        return try accessor(self.directory ?? directory)
    }
    func cancel() { blockedContents?.cancel() }
    func contents<T>(file: URL, accessor: (URL) throws -> T) throws -> T {
        calls += 1; try onBegin?()
        if let blockedContents { return try blockedContents.contents(file: file, accessor: accessor) }
        return try accessor(self.source ?? file)
    }
}

private final class WaitingPublicationCoordinator: ProviderFileCoordinating, @unchecked Sendable {
    private let condition = NSCondition()
    private let began: XCTestExpectation
    private var cancelled = false
    init(_ began: XCTestExpectation) { self.began = began }
    func read(directory: URL, accessor: (URL) throws -> ProviderIndexScan) throws -> ProviderIndexScan {
        condition.lock(); defer { condition.unlock() }
        began.fulfill()
        while !cancelled { condition.wait() }
        throw CancellationError()
    }
    func copy(source: URL, directory: URL, accessor: (URL, URL) throws -> SavedCameraFile) throws -> SavedCameraFile {
        condition.lock(); defer { condition.unlock() }
        began.fulfill()
        while !cancelled { condition.wait() }
        throw CancellationError()
    }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    func contents<T>(file: URL, accessor: (URL) throws -> T) throws -> T {
        condition.lock(); defer { condition.unlock() }
        began.fulfill()
        while !cancelled { condition.wait() }
        throw CancellationError()
    }
}
