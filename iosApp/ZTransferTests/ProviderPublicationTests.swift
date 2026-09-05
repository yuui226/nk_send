import Foundation
import XCTest
import ZTransferShared
@testable import ZTransfer

/// Apple filesystem/coordinator tests. Registered for Mac, never counted as Windows execution.
final class ProviderPublicationTests: XCTestCase {
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
    func cancel() {} // Streaming cancellation is separately exercised via the per-chunk check seam.
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
}
