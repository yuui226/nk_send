import Foundation
import XCTest
import ZTransferShared
@testable import ZTransfer

/// Apple filesystem/coordinator tests. Registered for Mac, never counted as Windows execution.
final class ProviderPublicationTests: XCTestCase {
    func testRealCoordinatorCopiesLargeOriginalAndBalancesGrantWithoutDeletingSource() async throws {
        let area = try PublicationArea()
        let saved = try await ProviderOriginalPublisher(directory: area.store).publish(area.saved)
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
        XCTAssertEqual(saved.url.deletingLastPathComponent(), movedTarget)
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
        XCTAssertThrowsError(try ProviderOriginalPublisher.copyVerified(area.saved, coordinatedSource: area.saved.url,
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
        XCTAssertThrowsError(try ProviderOriginalPublisher.copyVerified(area.saved, coordinatedSource: area.saved.url,
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
        let publisher = ProviderOriginalPublisher(directory: area.store, coordinatorFactory: { coordinator })
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
        XCTAssertThrowsError(try ProviderOriginalPublisher.copyVerified(area.saved, coordinatedSource: area.saved.url,
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
    func publisher(_ coordinator: PublicationCoordinator = PublicationCoordinator()) -> ProviderOriginalPublisher {
        ProviderOriginalPublisher(directory: store, coordinatorFactory: { coordinator })
    }
}

/// Configuration is fixed before awaited calls; counters read only after the operation completes.
private final class PublicationGrant: ExportDirectoryAccess {
    let url: URL
    var allowed = true, starts = 0, stops = 0
    init(_ url: URL) { self.url = url }
    func start(_ url: URL) -> Bool { starts += 1; return allowed }
    func stop(_ url: URL) { stops += 1 }
    func isDirectory(_ url: URL) -> Bool { true }
    func bookmark(_ url: URL) -> Data { Data([1]) }
    func resolve(_ bookmark: Data) -> ResolvedExportDirectory { ResolvedExportDirectory(url: url, stale: false) }
}

private final class PublicationCoordinator: ProviderFileCoordinating, @unchecked Sendable {
    var source: URL?, directory: URL?
    var onBegin: (() throws -> Void)?
    private(set) var calls = 0
    func copy(source: URL, directory: URL, accessor: (URL, URL) throws -> SavedCameraFile) throws -> SavedCameraFile {
        calls += 1; try onBegin?()
        return try accessor(self.source ?? source, self.directory ?? directory)
    }
    func cancel() {} // Streaming cancellation is separately exercised via the per-chunk check seam.
}

private final class WaitingPublicationCoordinator: ProviderFileCoordinating, @unchecked Sendable {
    private let condition = NSCondition()
    private let began: XCTestExpectation
    private var cancelled = false
    init(_ began: XCTestExpectation) { self.began = began }
    func copy(source: URL, directory: URL, accessor: (URL, URL) throws -> SavedCameraFile) throws -> SavedCameraFile {
        condition.lock(); defer { condition.unlock() }
        began.fulfill()
        while !cancelled { condition.wait() }
        throw CancellationError()
    }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
}
