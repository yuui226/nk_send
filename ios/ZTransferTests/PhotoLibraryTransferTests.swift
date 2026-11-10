import UIKit
import Photos
import XCTest
@testable import ZTransfer

final class PhotoLibraryTransferTests: XCTestCase {
    func testNewInstallDefaultsToPhotoLibrary() {
        let defaults = UserDefaults(suiteName: "photo-library-transfer-tests")!
        defaults.removePersistentDomain(forName: "photo-library-transfer-tests")
        XCTAssertEqual(TransferSaveDestination.load(from: defaults), .photoLibrary)
    }

    func testFullPhotoAccessIsTheOnlyAcceptedGrant() {
        XCTAssertEqual(PhotoLibraryAccess.decide(.authorized), .full)
        XCTAssertEqual(PhotoLibraryAccess.decide(.limited), .blocked)
        XCTAssertEqual(PhotoLibraryAccess.decide(.denied), .blocked)
        XCTAssertEqual(PhotoLibraryAccess.decide(.restricted), .blocked)
        XCTAssertEqual(PhotoLibraryAccess.decide(.notDetermined), .blocked)
    }

    func testLedgerRemembersOneOriginalAndIgnoresADifferentSize() {
        let defaults = UserDefaults(suiteName: "photo-library-ledger-tests")!
        defaults.removePersistentDomain(forName: "photo-library-ledger-tests")
        let ledger = PhotoLibraryTransferLedger(defaults: defaults)
        let photo = CameraFile(id: 1, storageID: 1, format: 0, size: 20, fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        XCTAssertFalse(ledger.contains(photo))
        ledger.record(photo)
        ledger.record(photo)
        XCTAssertTrue(ledger.contains(photo))
        let otherSize = CameraFile(id: 1, storageID: 1, format: 0, size: 21, fileName: "DSC_0001.JPG", captureDate: nil, isProtected: false)
        XCTAssertFalse(ledger.contains(otherSize))
    }

    func testImporterAcceptsCameraStillAndVideoTypes() {
        XCTAssertEqual(PhotoLibraryTransferImporter.resourceType(for: URL(fileURLWithPath: "/a/DSC_1.JPG")), .photo)
        XCTAssertEqual(PhotoLibraryTransferImporter.resourceType(for: URL(fileURLWithPath: "/a/DSC_1.NEF")), .photo)
        XCTAssertEqual(PhotoLibraryTransferImporter.resourceType(for: URL(fileURLWithPath: "/a/DSC_1.MOV")), .video)
        XCTAssertNil(PhotoLibraryTransferImporter.resourceType(for: URL(fileURLWithPath: "/a/DSC_1.nkpart_")))
    }
    func testStartupCleanupRemovesPreviousProcessAndLegacyFilesPreservingLiveWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent("current")
        let previous = root.appendingPathComponent("previous/ZTFrames")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for url in [root.appendingPathComponent("old.nkpart_"), root.appendingPathComponent("old.JPG"),
                    previous.appendingPathComponent("effect.JPG"), active.appendingPathComponent("new.JPG")] {
            try Data([1, 2, 3]).write(to: url)
        }
        try PhotoLibraryTransferStaging.removePreviousProcessFiles(in: root, preserving: active)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["current"])
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("new.JPG")), Data([1, 2, 3]))
    }

    func testStartupCleanupHandlesMissingContainerAndActiveDirectoryCreatedLater() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent("current")
        defer { try? FileManager.default.removeItem(at: root) }
        try PhotoLibraryTransferStaging.removePreviousProcessFiles(in: root, preserving: active)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("old.JPG"))
        try PhotoLibraryTransferStaging.removePreviousProcessFiles(in: root, preserving: active)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data([2]).write(to: active.appendingPathComponent("new.JPG"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.appendingPathComponent("new.JPG").path))
    }

    func testProcessDirectoryRemainsStableAcrossRepeatedAccess() {
        let first = PhotoLibraryTransferStaging.url
        XCTAssertEqual(first, PhotoLibraryTransferStaging.url)
        XCTAssertTrue(PhotoLibraryTransferStaging.isStaging(first))
        XCTAssertFalse(PhotoLibraryTransferStaging.isStaging(first.deletingLastPathComponent()))
    }

    @MainActor
    func testAlbumWaitsForGenerationBeforeImportAndCleanup() async throws {
        try await checkGenerationLifetime(album: true, failFirst: false)
    }

    @MainActor
    func testFailedAlbumGenerationRetainsSourceForOfflineRetry() async throws {
        try await checkGenerationLifetime(album: true, failFirst: true)
    }

    @MainActor
    func testFolderGenerationRetainsOriginalWithoutImportingPhotos() async throws {
        try await checkGenerationLifetime(album: false, failFirst: false)
    }

    @MainActor
    func testAlbumImportFailureRetainsCompletedOriginalAndRetriesWithoutDuplicateImport() async throws {
        try await checkGenerationLifetime(album: true, failFirst: false, failImport: true)
    }

    @MainActor
    func testTwoAttemptsShareCompletedOriginalUntilBothReadersFinish() async throws {
        try await checkGenerationLifetime(album: true, failFirst: false, repeated: true)
    }

    @MainActor
    private func checkGenerationLifetime(album: Bool, failFirst: Bool,
                                         failImport: Bool = false, repeated: Bool = false) async throws {
        let suite = "PhotoPublication-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = album ? PhotoLibraryTransferStaging.url
            : FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(suite + ".JPG")
        let derivative = root.appendingPathComponent(suite + "-effect.JPG")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: derivative)
            defaults.removePersistentDomain(forName: suite)
        }
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in
            UIColor.red.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: 8, height: 8)).fill()
        }.jpegData(compressionQuality: 1))
        try data.write(to: source)
        let probe = PublicationProbe(failFirst: failFirst, failImport: failImport)
        let ledger = PhotoLibraryTransferLedger(defaults: defaults)
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime),
            renderFrame: { input, _, _, _ in
                try await probe.render(input: input, output: derivative)
            }, photoLibraryLedger: ledger, importPhotoFile: { url in
                _ = try PhotoAllocationBudget.loadOriginalImage(url, availableMemory: { .max })
                try await probe.imported(url, original: source)
            })
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801,
            size: UInt64(data.count), fileName: source.lastPathComponent, captureDate: nil, isProtected: false)
        var effects = PhotoEffectsSettings()
        effects.photoFrameEnabled = true
        let enqueued = await queue.enqueue(file, effects: effects)
        let id = try XCTUnwrap(enqueued)
        if repeated { await queue.enqueue(file, effects: effects) }
        await queue.start(session: nil, directory: root)
        try await waitFor(queue) { !$0.isTransferring && $0.items.first?.isGeneratingFrame == true }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let earlyImports = await probe.imports
        XCTAssertTrue(earlyImports.isEmpty)
        await probe.release()
        try await waitFor(queue) { !$0.items.contains(where: \.isGeneratingFrame) }
        if failFirst || failImport {
            try await waitFor(queue) { $0.items.first?.frameError != nil }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            _ = await queue.retry(id: id)
            try await waitFor(queue) { !$0.items.contains(where: \.isGeneratingFrame) && $0.items.first?.frameError == nil }
        }
        // Photos publication follows worker completion, so wait for its own boundary.
        for _ in 0..<300 {
            if !album || !FileManager.default.fileExists(atPath: source.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let final = await queue.snapshot()
        XCTAssertNil(final.items.first?.frameError)
        XCTAssertNil(final.items.first?.error)
        let imports = await probe.imports
        XCTAssertEqual(imports, album ? [source, derivative] : [])
        XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), !album)
        XCTAssertEqual(FileManager.default.fileExists(atPath: derivative.path), !album)
    }

    @MainActor
    private func waitFor(_ queue: TransferQueue,
                         predicate: (TransferQueueSnapshot) -> Bool) async throws {
        for _ in 0..<300 {
            if predicate(await queue.snapshot()) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Publication did not reach the expected state")
        throw CocoaError(.coderInvalidValue)
    }

}


private actor PublicationProbe {
    var imports: [URL] = []
    private var failFirst: Bool
    private var failImport: Bool
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(failFirst: Bool, failImport: Bool) {
        self.failFirst = failFirst
        self.failImport = failImport
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func imported(_ url: URL, original: URL) throws {
        if failImport, url != original {
            failImport = false
            throw CocoaError(.fileWriteUnknown)
        }
        imports.append(url)
    }

    func render(input: URL, output: URL) async throws -> URL {
        if !released { await withCheckedContinuation { waiter = $0 } }
        _ = try PhotoAllocationBudget.loadOriginalImage(input, availableMemory: { .max })
        if failFirst {
            failFirst = false
            throw CocoaError(.fileReadCorruptFile)
        }
        try Data(contentsOf: input).write(to: output)
        return output
    }
}
