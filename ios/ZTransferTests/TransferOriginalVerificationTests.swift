import Foundation
import XCTest
@testable import ZTransfer

private func originalFile(_ id: UInt32 = 1, size: UInt64 = 100, name: String? = nil) -> CameraFile {
    CameraFile(id: id, storageID: 1, format: 0x3801, size: size,
        fileName: name ?? String(format: "DSC_%04d.JPG", id), captureDate: nil, isProtected: false)
}

private func originalDirectory(_ test: XCTestCase) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("original-check-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
}

final class TransferOriginalVerificationTests: XCTestCase {
    func testFreshReaderValueDoesNotTreatIndexRevisionAsFileMetadata() throws {
        let root = try originalDirectory(self), url = root.appendingPathComponent("DSC_0001.JPG")
        var index = TransferDirectoryIndex(directory: root); index.addOriginal(url, size: 100)
        var calls = 0
        let found = try index.findVerified(for: originalFile(), verify: { observed in
            calls += 1
            guard calls == 1 else { throw CocoaError(.coderInvalidValue) }
            return IndexedTransferOriginal(url: observed.url, size: observed.size, name: observed.name)
        }, onInvalidated: { _ in XCTFail("Unchanged metadata is still valid") })
        XCTAssertEqual(found?.url, url); XCTAssertEqual(calls, 1)
    }

    func testUncachedFilesDoNotPerformIOAndDeletedCopiesFallThroughWithoutMatchingEffects() throws {
        let root = try originalDirectory(self), file = originalFile()
        let exact = root.appendingPathComponent(file.fileName)
        let copy = root.appendingPathComponent("DSC_0001 (1).JPG")
        let effect = root.appendingPathComponent("DSC_0001_f_e.JPG")
        for url in [exact, copy, effect] { try Data(count: 100).write(to: url) }
        var index = try TransferDirectoryIndex.read(directory: root)
        XCTAssertNil(try index.findVerified(for: originalFile(9), verify: { _ in XCTFail("New files must stay in-memory"); return nil }))
        try FileManager.default.removeItem(at: exact)
        var invalidated: [URL] = []
        XCTAssertEqual(try index.findVerified(for: file, onInvalidated: { invalidated.append($0.url) })?.url, copy)
        XCTAssertEqual(invalidated, [exact])
        try FileManager.default.removeItem(at: copy)
        XCTAssertNil(try index.findVerified(for: file, onInvalidated: { invalidated.append($0.url) }))
        XCTAssertEqual(invalidated, [exact, copy])
        XCTAssertEqual(index.existingOriginal(for: originalFile(name: effect.lastPathComponent)), effect)
    }

    func testFreshMetadataDetectsEditedSizeAndUnknownSizeUsesTheActualBytes() throws {
        let root = try originalDirectory(self), url = root.appendingPathComponent("DSC_0001.JPG")
        try Data(count: 100).write(to: url)
        var index = try TransferDirectoryIndex.read(directory: root)
        try Data(count: 200).write(to: url)
        var invalidated: [UInt64] = []
        XCTAssertNil(try index.findVerified(for: originalFile(), onInvalidated: { invalidated.append($0.size) }))
        XCTAssertEqual(invalidated, [100])
        XCTAssertEqual(try index.findVerified(for: originalFile(size: 200))?.size, 200)
        XCTAssertEqual(try index.findVerified(for: originalFile(size: UInt64(UInt32.max)))?.size, 200)
        XCTAssertEqual(index.existingOriginal(for: originalFile(size: 200)), url)
    }

    func testRenameAndObservedVersionRemovalPreserveNewPublication() throws {
        let root = try originalDirectory(self), url = root.appendingPathComponent("DSC_0001.JPG")
        var index = TransferDirectoryIndex(directory: root); index.addOriginal(url, size: 100)
        let old = try XCTUnwrap(index.candidate(for: originalFile()))
        index.addOriginal(url, size: 100)
        XCTAssertFalse(index.remove(old), "A delayed result cannot erase a newer publication even at the same path")
        XCTAssertNil(try index.findVerified(for: originalFile(), verify: { var renamed = $0; renamed.name = "holiday.JPG"; return renamed }))
        XCTAssertEqual(index.existingOriginal(for: originalFile(name: "HOLIDAY.jpg")), url)
        XCTAssertNil(index.existingOriginal(for: originalFile()))
    }

    func testProviderErrorRetainsCandidateButPriorProvenDeletionsStayRemoved() throws {
        let root = try originalDirectory(self), exact = root.appendingPathComponent("DSC_0001.JPG")
        let copy = root.appendingPathComponent("DSC_0001 (1).JPG")
        var index = TransferDirectoryIndex(directory: root)
        index.addOriginal(exact, size: 100); index.addOriginal(copy, size: 100)
        var invalidated: [URL] = []
        XCTAssertThrowsError(try index.findVerified(for: originalFile(), verify: {
            if $0.url == exact { return nil }
            throw CocoaError(.fileReadNoPermission)
        }, onInvalidated: { invalidated.append($0.url) }))
        XCTAssertEqual(invalidated, [exact])
        XCTAssertEqual(index.existingOriginal(for: originalFile()), copy)
    }

    func testReaderOpensTheFileAndDirectoryReplacementDoesNotBecomeMissing() throws {
        let root = try originalDirectory(self), url = root.appendingPathComponent("DSC_0001.JPG")
        try Data(count: 100).write(to: url)
        var index = try TransferDirectoryIndex.read(directory: root)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        XCTAssertThrowsError(try index.findVerified(for: originalFile()))
        XCTAssertNotNil(index.existingOriginal(for: originalFile()))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try index.findVerified(for: originalFile())) { XCTAssertEqual($0.localizedDescription, "Indexed original is a directory") }
        XCTAssertNotNil(index.existingOriginal(for: originalFile()))
    }

    func testExportRemovalRequiresExactURLSizeAndFolderAndClearsUnknownSizeBucket() {
        let root = URL(fileURLWithPath: "/originals"), old = URL(fileURLWithPath: "/old/DSC_0001.JPG")
        let new = root.appendingPathComponent("DSC_0001.JPG")
        var index = ExportedOriginalIndex()
        index.add(new, size: 100, folderName: nil); index.add(new, size: 200, folderName: nil)
        index.add(new, size: 100, folderName: "ZT2026-11-02")
        XCTAssertFalse(index.remove(IndexedTransferOriginal(url: old, size: 100), folderName: nil))
        XCTAssertTrue(index.remove(IndexedTransferOriginal(url: new, size: 100), folderName: nil))
        XCTAssertNil(index.original(for: originalFile(), folderName: nil))
        XCTAssertNotNil(index.original(for: originalFile(size: 200), folderName: nil))
        XCTAssertNotNil(index.original(for: originalFile(), folderName: "ZT2026-11-02"))
        XCTAssertTrue(index.remove(IndexedTransferOriginal(url: new, size: 200), folderName: nil))
        XCTAssertNil(index.original(for: originalFile(size: UInt64(UInt32.max)), folderName: nil))
    }
}

private actor OriginalScanGate {
    private(set) var calls = 0
    private var waits: [Int: CheckedContinuation<Void, Never>] = [:]
    func pause() async { calls += 1; let call = calls; await withCheckedContinuation { waits[call] = $0 } }
    func release(_ call: Int) { waits.removeValue(forKey: call)?.resume() }
}

private final class OriginalReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { waiting } }
    func pause() throws {
        lock.withLock { waiting = true }
        guard semaphore.wait(timeout: .now() + 4) == .success else { throw CocoaError(.coderInvalidValue) }
    }
    func release() { semaphore.signal() }
}

private final class OriginalScopeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func change(_ delta: Int) { lock.withLock { value += delta } }
}

@MainActor final class TransferOriginalStoreTests: XCTestCase {
    private func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < end else { XCTFail("Original store did not settle"); throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testLateScanCannotResurrectMissingCandidateOrOverwriteNewPublication() async throws {
        let root = try originalDirectory(self), old = root.appendingPathComponent("DSC_0001.JPG")
        try Data(count: 100).write(to: old)
        let gate = OriginalScanGate()
        let store = TransferOriginalStore(scan: { root, _ in
            let snapshot = try TransferDirectoryIndex.read(directory: root)
            await gate.pause(); return [.init(folder: nil, index: snapshot)]
        })
        store.refresh(directory: root, mode: .unified); try await wait { await gate.calls == 1 }
        XCTAssertFalse(store.forget(.init(url: old, size: 100), root: root, folder: nil))
        await gate.release(1); try await wait { !store.isScanning }
        XCTAssertNil(store.original(for: originalFile(), folder: nil, root: root))
        // Switching mode starts another scan. Its old URI must not overwrite
        // a completed transfer published while that scan is in flight.
        store.refresh(directory: root, mode: .byDay); try await wait { await gate.calls == 2 }
        let new = root.appendingPathComponent("DSC_0001 (1).JPG")
        XCTAssertTrue(store.record(.init(url: new, size: 100), root: root, folder: nil, fileID: 1))
        await gate.release(2); try await wait { !store.isScanning }
        XCTAssertEqual(store.original(for: originalFile(), folder: nil, root: root), new)
        store.refresh(directory: root, mode: .byDay)
        XCTAssertFalse(store.isScanning)
        let calls = await gate.calls; XCTAssertEqual(calls, 2, "Catalog batches must reuse the completed scan")
    }

    func testOldRootAndCancelledScanCannotPolluteNewDirectory() async throws {
        let old = try originalDirectory(self), new = try originalDirectory(self), gate = OriginalScanGate()
        try Data(count: 100).write(to: old.appendingPathComponent("DSC_0001.JPG"))
        let store = TransferOriginalStore(scan: { root, _ in
            let snapshot = try TransferDirectoryIndex.read(directory: root)
            await gate.pause(); return [.init(folder: nil, index: snapshot)]
        })
        store.refresh(directory: old, mode: .unified); try await wait { await gate.calls == 1 }
        store.refresh(directory: new, mode: .unified); try await wait { await gate.calls == 2 }
        XCTAssertFalse(store.record(.init(url: old.appendingPathComponent("DSC_0001.JPG"), size: 100), root: old, folder: nil))
        await gate.release(1); await gate.release(2); try await wait { !store.isScanning }
        XCTAssertNil(store.original(for: originalFile(), folder: nil, root: new))
        store.select(nil)
        XCTAssertFalse(store.record(.init(url: new.appendingPathComponent("DSC_0001.JPG"), size: 100), root: new, folder: nil))
    }

    func testFailedScanPreservesConcurrentOutputAndCanRetry() async throws {
        let root = try originalDirectory(self), gate = OriginalScanGate()
        let store = TransferOriginalStore(scan: { _, _ in await gate.pause(); throw CocoaError(.fileReadNoPermission) })
        store.refresh(directory: root, mode: .unified); try await wait { await gate.calls == 1 }
        let output = root.appendingPathComponent("DSC_0001.JPG")
        store.record(.init(url: output, size: 100), root: root, folder: nil, fileID: 1)
        await gate.release(1); try await wait { !store.isScanning }
        XCTAssertEqual(store.original(for: originalFile(), folder: nil, root: root), output)
        store.refresh(directory: root, mode: .unified); try await wait { await gate.calls == 2 }
        await gate.release(2); try await wait { !store.isScanning }
    }

    @MainActor
    func testPhotoListObservesInvalidationWithoutQueueHistoryReplayOrCatalog() async throws {
        let root = try originalDirectory(self), output = root.appendingPathComponent("DSC_0001.JPG")
        try Data(count: 100).write(to: output)
        let store = TransferOriginalStore(), model = PhotoListViewModel(scanCatalog: nil, setRemoteGate: { _ in })
        model.useOriginalStore(store); model.refreshTransferredIDs(directory: root, storageMode: .unified)
        try await wait { !store.isScanning }
        let before = model.transferOriginalIndexRevision
        XCTAssertTrue(model.hasTransferredOriginal(originalFile(), folderName: nil, directory: root))
        XCTAssertTrue(store.forget(.init(url: output, size: 100), root: root, folder: nil))
        try await wait { await MainActor.run { model.transferOriginalIndexRevision > before } }
        XCTAssertFalse(model.hasTransferredOriginal(originalFile(), folderName: nil, directory: root))
        model.refreshTransferredIDs(directory: root, storageMode: .unified)
        XCTAssertFalse(model.hasTransferredOriginal(originalFile(), folderName: nil, directory: root))
        XCTAssertTrue(store.record(.init(url: output, size: 100), root: root, folder: nil, fileID: 1))
        XCTAssertTrue(model.hasTransferredOriginal(originalFile(), folderName: nil, directory: root))
    }

    func testReselectingSameDirectoryEmitsSelectionWithoutRedundantViewInvalidation() async throws {
        let root = try originalDirectory(self), suite = "original-selection-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = DirectoryAccessStore(defaults: defaults,
            accessOperations: .init(start: { _ in true }, stop: { _ in }),
            makeBookmark: { Data($0.path.utf8) })
        var selections: [URL?] = [], invalidations = 0
        let selection = directory.selectionChanges.sink { selections.append($0) }
        let views = directory.objectWillChange.sink { invalidations += 1 }
        defer { withExtendedLifetime((selection, views)) {} }
        await directory.setDirectory(root).value
        XCTAssertEqual(directory.directoryURL, root)
        await directory.setDirectory(root).value
        XCTAssertEqual(directory.directoryURL, root)
        XCTAssertEqual(selections, [root, root]); XCTAssertEqual(invalidations, 1)
        directory.clear()
        XCTAssertNil(directory.directoryURL)
        XCTAssertEqual(selections, [root, root, nil]); XCTAssertEqual(invalidations, 2)
        directory.clear()
        XCTAssertEqual(selections.count, 3); XCTAssertEqual(invalidations, 2)
    }

    func testCancelledScanKeepsSecurityScopeUntilIOEndsThenBalancesIt() async throws {
        let root = try originalDirectory(self), gate = OriginalScanGate(), scope = OriginalScopeCount()
        let store = TransferOriginalStore(accessOperations: .init(start: { _ in scope.change(1); return true },
            stop: { _ in scope.change(-1) }), scan: { _, _ in await gate.pause(); return [] })
        store.refresh(directory: root, mode: .unified); try await wait { await gate.calls == 1 }
        XCTAssertEqual(scope.count, 1)
        store.select(nil)
        XCTAssertEqual(scope.count, 1, "An in-flight provider read still owns its grant")
        await gate.release(1); try await wait { scope.count == 0 }
        XCTAssertNil(store.original(for: originalFile(), folder: nil, root: root))
    }

    func testConflatedSignalsExposeLatestMembershipAndPrecisePublicationIDs() async throws {
        let root = try originalDirectory(self), store = TransferOriginalStore()
        store.select(root)
        var updates = store.updates().makeAsyncIterator()
        _ = await updates.next()
        let first = IndexedTransferOriginal(url: root.appendingPathComponent("DSC_0001.JPG"), size: 100)
        store.record(first, root: root, folder: nil, fileID: 1)
        store.record(.init(url: root.appendingPathComponent("DSC_0002.JPG"), size: 100), root: root, folder: nil, fileID: 2)
        store.forget(first, root: root, folder: nil)
        _ = await updates.next()
        let current = store.membership([originalFile(1), originalFile(2)], root: root, mode: .unified, since: 0)
        XCTAssertEqual(current.ids, [2]); XCTAssertEqual(current.publishedIDs, [2])
        XCTAssertTrue(store.membership([originalFile(2)], root: root, mode: .unified, since: current.revision).publishedIDs.isEmpty)
    }
}

private actor OriginalCheckCamera: TransferDownloading {
    private(set) var requests: [UInt32] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private let holdFirst: Bool
    init(holdFirst: Bool = true) { self.holdFirst = holdFirst }
    func release() { continuation?.resume(); continuation = nil }
    func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        requests.append(file.id)
        if holdFirst && requests.count == 1 { await withCheckedContinuation { continuation = $0 } }
        let temporary = directory.appendingPathComponent(".nkpart_test_\(UUID())")
        try Data(count: Int(file.size)).write(to: temporary)
        return try finalizeTransferTemporary(temporary: temporary, directory: directory, fileName: file.fileName, allowCopy: false)
    }
}

@MainActor final class TransferOriginalQueueTests: XCTestCase {
    private func queue(_ root: URL, verify: @escaping @Sendable (IndexedTransferOriginal) throws -> IndexedTransferOriginal? = readExistingTransferOriginal) -> TransferQueue {
        let suite = "original-queue-\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime), verifyOriginal: verify)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(4)
        while !(await condition()) {
            guard ContinuousClock.now < end else { XCTFail("Original queue did not settle"); throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testDeletionAfterBatchScanDownloadsAgainAndNeverUsesDerivedFile() async throws {
        let root = try originalDirectory(self), queue = queue(root), camera = OriginalCheckCamera()
        let second = root.appendingPathComponent("DSC_0002.JPG")
        try Data(count: 100).write(to: second)
        try Data(count: 100).write(to: root.appendingPathComponent("DSC_0002_f_e.JPG"))
        _ = await queue.enqueue([originalFile(1), originalFile(2)])
        await queue.start(session: camera, directory: root)
        try await wait { await camera.requests == [1] }
        try FileManager.default.removeItem(at: second); await camera.release()
        try await wait { !(await queue.snapshot()).isTransferring }
        let snapshot = await queue.snapshot(), requests = await camera.requests
        XCTAssertEqual(requests, [1, 2]); XCTAssertTrue(snapshot.items.allSatisfy { $0.status == .completed && !$0.skipped })
        XCTAssertEqual(queue.originalStore.original(for: originalFile(2), folder: nil, root: root), second)
    }

    func testEditedOriginalIsPreservedAndNewDownloadUsesNumberedName() async throws {
        let root = try originalDirectory(self), queue = queue(root), camera = OriginalCheckCamera()
        let second = root.appendingPathComponent("DSC_0002.JPG")
        try Data(count: 100).write(to: second)
        _ = await queue.enqueue([originalFile(1), originalFile(2)])
        await queue.start(session: camera, directory: root)
        try await wait { await camera.requests == [1] }
        try Data(count: 200).write(to: second); await camera.release()
        try await wait { !(await queue.snapshot()).isTransferring }
        let snapshot = await queue.snapshot(), requests = await camera.requests
        XCTAssertEqual(requests, [1, 2]); XCTAssertEqual(try Data(contentsOf: second).count, 200)
        XCTAssertEqual(snapshot.items.last?.outputURL?.lastPathComponent, "DSC_0002 (1).JPG")
    }

    func testDeletedExactOriginalFallsBackToSurvivingCopyWithoutCameraRead() async throws {
        let root = try originalDirectory(self), queue = queue(root), camera = OriginalCheckCamera()
        let second = root.appendingPathComponent("DSC_0002.JPG"), copy = root.appendingPathComponent("DSC_0002 (1).JPG")
        for url in [second, copy] { try Data(count: 100).write(to: url) }
        _ = await queue.enqueue([originalFile(1), originalFile(2)])
        await queue.start(session: camera, directory: root)
        try await wait { await camera.requests == [1] }
        try FileManager.default.removeItem(at: second); await camera.release()
        try await wait { !(await queue.snapshot()).isTransferring }
        let snapshot = await queue.snapshot(), requests = await camera.requests
        XCTAssertEqual(requests, [1]); XCTAssertEqual(snapshot.items.last?.outputURL, copy)
        XCTAssertEqual(snapshot.items.last?.skipped, true)
    }

    func testProviderFailureFailsInsteadOfFalseSkipOrDuplicateDownload() async throws {
        let root = try originalDirectory(self), camera = OriginalCheckCamera(holdFirst: false)
        let output = root.appendingPathComponent("DSC_0001.JPG"); try Data(count: 100).write(to: output)
        let queue = queue(root, verify: { _ in throw CocoaError(.fileReadNoPermission) })
        await queue.attach(session: camera, directory: root)
        queue.originalStore.record(.init(url: output, size: 100), root: root, folder: nil)
        _ = await queue.enqueue(originalFile()); await queue.start(session: camera, directory: root)
        try await wait { !(await queue.snapshot()).isTransferring }
        let snapshot = await queue.snapshot(), requests = await camera.requests
        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(item.status, .failed); XCTAssertFalse(item.skipped); XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(queue.originalStore.original(for: originalFile(), folder: nil, root: root), output)
    }

    func testWithdrawalDuringProviderReadKeepsActorResponsiveAndCannotPublishLateSuccess() async throws {
        let root = try originalDirectory(self), gate = OriginalReadGate(), camera = OriginalCheckCamera(holdFirst: false)
        defer { gate.release() }
        let output = root.appendingPathComponent("DSC_0001.JPG"); try Data(count: 100).write(to: output)
        let queue = queue(root, verify: { entry in try gate.pause(); return try readExistingTransferOriginal(entry) })
        let id = await queue.enqueue(originalFile())
        await queue.start(session: camera, directory: root)
        try await wait { gate.entered }
        await queue.withdraw(id: try XCTUnwrap(id))
        let pending = await queue.snapshot()
        XCTAssertEqual(pending.items.first?.status, .cancelled)
        gate.release(); try await wait { !(await queue.snapshot()).isTransferring }
        let finished = await queue.snapshot(), requests = await camera.requests
        XCTAssertEqual(finished.items.first?.status, .cancelled)
        XCTAssertNil(finished.items.first?.outputURL); XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationAfterReadCannotInvalidateObservedOriginal() async throws {
        let root = try originalDirectory(self), gate = OriginalReadGate()
        defer { gate.release() }
        let output = root.appendingPathComponent("DSC_0001.JPG")
        let worker = Task.detached {
            var index = TransferDirectoryIndex(directory: root); index.addOriginal(output, size: 100)
            let result = Result { try index.findVerified(for: originalFile(), verify: { _ in try gate.pause(); return nil },
                onInvalidated: { _ in XCTFail("Cancellation must win over the missing result") }) }
            return (index, result)
        }
        try await wait { gate.entered }; worker.cancel(); gate.release()
        let (index, result) = await worker.value
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(index.existingOriginal(for: originalFile()), output)
    }
}
