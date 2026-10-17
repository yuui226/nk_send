import XCTest
@testable import ZTransfer

@MainActor
final class PictureControlFolderStateTests: XCTestCase {
    func testUnresolvedSavedFolderCanRetryAndPublishRecoveredBookmark() async throws {
        let suite = "picture-folder-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Recovered.np3"))
        let saved = Data([0, 1, 2])
        defaults.set(saved, forKey: "picture_control_folder_bookmark")
        let attempts = FolderRecoveryAttempts()
        let state = PictureControlFolderState(defaults: defaults, queue: PresetIOQueue(), scan: { replacement, bookmark, ticket in
            XCTAssertNil(replacement)
            XCTAssertEqual(bookmark, saved)
            if attempts.next() == 1 { throw RemoteLUTFolderAccessError.missing }
            return try RemoteLUTFolderAccess.prepareFolder(root, fileExtension: "np3",
                operations: .init(start: { _ in true }, stop: { _ in }), checkCancelled: ticket.checkCancellation)
        })
        XCTAssertNil(state.folder)
        state.refresh(); try await finish(state)
        XCTAssertEqual(state.failure, .missing)
        XCTAssertEqual(defaults.data(forKey: "picture_control_folder_bookmark"), saved)
        state.refresh(); try await finish(state)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.files.map(\.name), ["Recovered.np3"])
        XCTAssertEqual(state.folder?.standardizedFileURL, root.standardizedFileURL)
        let restarted = PictureControlFolderState(defaults: defaults)
        XCTAssertEqual(restarted.folder?.standardizedFileURL, root.standardizedFileURL)
        state.close(); restarted.close()
    }
    func testSharedFolderScannerFiltersNP3AndUsesExtensionIndependentLabels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Film/Deeper"), withIntermediateDirectories: true)
        for name in ["Test.NP3", "Other.cube", "Film/Test.np3", "Film/Deeper/Hidden.np3"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let files = try RemoteLUTFolderAccess.scanContents(root, fileExtension: "np3")
        XCTAssertEqual(files.map(\.relativePath), ["Test.NP3", "Film/Test.np3"])
        XCTAssertEqual(files.map(\.label), ["Test", "Test"])
        XCTAssertEqual(Set(RemoteLUTCatalog.labels(files, uncategorized: "Root").values), ["Test · Root", "Test · Film"])
        XCTAssertThrowsError(try RemoteLUTFolderAccess.scanContents(root, fileExtension: "np3", entryLimit: 3))
        XCTAssertEqual(try RemoteLUTFolderAccess.scanContents(root).map(\.name), ["Other.cube"])
    }

    func testFolderReplacementFailurePreservesSnapshotAndIndependentBookmarksAcrossRestart() async throws {
        let suite = "picture-folder-\(UUID().uuidString)", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("A.np3"))
        let monitor = RemoteLUTFolderAccess(defaults: defaults, scope: .monitor)
        let photo = RemoteLUTFolderAccess(defaults: defaults, scope: .photo)
        try monitor.save(root); try photo.save(root)
        let oldMonitor = monitor.bookmarkData, oldPhoto = photo.bookmarkData
        let state = PictureControlFolderState(defaults: defaults, queue: PresetIOQueue(), scan: { replacement, bookmark, ticket in
            guard let replacement else { throw RemoteLUTFolderAccessError.denied }
            return try RemoteLUTFolderAccess.prepareFolder(replacement, fileExtension: "np3",
                operations: .init(start: { _ in true }, stop: { _ in }), checkCancelled: ticket.checkCancellation)
        })
        var notices: [String] = []
        state.onNotice = { notices.append($0) }
        state.changeFolder(root)
        try await finish(state)
        XCTAssertEqual(state.files.map(\.name), ["A.np3"]); XCTAssertTrue(state.hasSnapshot)
        state.changeFolder(root.appendingPathComponent("Missing"))
        try await finish(state)
        XCTAssertEqual(notices, ["lut_folder_missing"])
        XCTAssertEqual(state.folder, root); XCTAssertEqual(state.files.map(\.name), ["A.np3"])
        XCTAssertNil(state.failure)
        state.refresh(); try await finish(state)
        XCTAssertEqual(state.failure, .denied); XCTAssertEqual(state.files.count, 1)
        XCTAssertEqual(monitor.bookmarkData, oldMonitor); XCTAssertEqual(photo.bookmarkData, oldPhoto)
        let reopened = PictureControlFolderState(defaults: defaults)
        XCTAssertEqual(reopened.folder?.standardizedFileURL, root.standardizedFileURL)
        state.close(); state.changeFolder(root); XCTAssertFalse(state.scanning)
    }
    func testTimedOutProviderReleasesCallerButStillDrainsBeforeAnotherOwner() async throws {
        let queue = PresetIOQueue(), release = DispatchSemaphore(value: 0)
        let started = expectation(description: "provider started")
        let reader = PresetAsyncRead<Int>(queue: queue, timeout: .milliseconds(40))
        let task = Task {
            try await reader.perform { _ in started.fulfill(); release.wait(); return 1 }
        }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected timeout") }
        catch PictureControlImportFailure.timeout {} catch { XCTFail("Unexpected \(error)") }
        var nextDelivered = false
        queue.submit(action: { _ in 2 }, deliver: { _ in nextDelivered = true })
        try await Task.sleep(for: .milliseconds(30)); XCTAssertFalse(nextDelivered)
        release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !nextDelivered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(nextDelivered)
    }

    func testReadCancellationResumesWithoutWaitingForUncooperativeProvider() async throws {
        let release = DispatchSemaphore(value: 0), started = expectation(description: "provider started")
        let reader = PresetAsyncRead<Int>(queue: PresetIOQueue(), timeout: .seconds(10))
        let task = Task { try await reader.perform { _ in started.fulfill(); release.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        release.signal()
    }

    private func finish(_ state: PictureControlFolderState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.scanning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(state.scanning)
    }
}

private final class FolderRecoveryAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
