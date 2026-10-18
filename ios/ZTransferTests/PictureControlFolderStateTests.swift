import XCTest
import Combine
@testable import ZTransfer

@MainActor
final class PictureControlFolderStateTests: XCTestCase {
    func testBlockedBookmarkRestoreDoesNotBlockMainAndCloseDiscardsLateRenewal() async throws {
        let suite = "picture-restore-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = Data([1, 2, 3]), refreshed = Data([4, 5, 6])
        preferences.set(saved, forKey: "picture_control_folder_bookmark")
        let entered = expectation(description: "Bookmark provider entered")
        let drained = expectation(description: "Bookmark provider drained")
        let gate = DispatchSemaphore(value: 0), queue = PresetIOQueue()
        defer { gate.signal() }
        var state: PictureControlFolderState? = PictureControlFolderState(defaults: preferences, queue: queue, resolve: { bookmark in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(bookmark, saved)
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return .init(url: URL(fileURLWithPath: "/restored"), bookmark: refreshed)
        })
        weak var owner = state
        XCTAssertTrue(try XCTUnwrap(state).isRestoring)
        await fulfillment(of: [entered], timeout: 2)
        let heartbeat = expectation(description: "Main actor still responds")
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        XCTAssertNil(state?.folder)
        state?.close()
        state = nil
        XCTAssertNil(owner)
        queue.submit(action: { _ in true }, deliver: { _ in drained.fulfill() })
        gate.signal()
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(preferences.data(forKey: "picture_control_folder_bookmark"), saved)
    }

    func testPreparedScanReusesResolvedFolderAndRestorationStaysOffMain() async throws {
        let suite = "picture-resolve-once-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Test.np3"))
        preferences.set(try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            forKey: "picture_control_folder_bookmark")
        let calls = FolderRecoveryAttempts()
        let state = PictureControlFolderState(defaults: preferences, queue: PresetIOQueue(), resolve: { data in
            XCTAssertFalse(Thread.isMainThread)
            _ = calls.next()
            return RemoteLUTFolderAccess.prepareResolution(data)
        }, scan: { _, _, ticket in
            XCTAssertFalse(Thread.isMainThread)
            return try RemoteLUTFolderAccess.prepareFolder(root, fileExtension: "np3",
                operations: .init(start: { _ in true }, stop: { _ in }), checkCancelled: ticket.checkCancellation)
        })
        try await restore(state)
        XCTAssertEqual(state.folder?.standardizedFileURL, root.standardizedFileURL)
        state.refresh(); try await finish(state)
        XCTAssertEqual(state.files.map(\.name), ["Test.np3"])
        XCTAssertEqual(state.folder, root)
        XCTAssertEqual(calls.next(), 2, "Only initialization resolves; scan carries its already resolved root")
        state.close()
    }
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
        try await restore(restarted)
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
        try await restore(reopened)
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

    func testSameScanRetainsIndexAndOnlyChangedMetadataPublishesNewFiles() async throws {
        let suite = "np3-catalog-performance-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = (0..<10_000).map { index in
            PresetFile(identifier: "id-\(index)", name: "Film-\(index % 100).NP3",
                relativePath: "Category-\(index % 10)/Film-\(index).NP3", size: 100)
        }
        let source = PictureControlCatalogTestSource(files)
        let state = PictureControlFolderState(defaults: defaults, queue: PresetIOQueue(), scan: { _, _, _ in
            .init(bookmark: Data([1, 2, 3]), files: source.read())
        })
        defer { state.close() }
        state.changeFolder(URL(fileURLWithPath: "/np3-test-folder"))
        try await finish(state)
        let catalog = state.catalog
        let labels = catalog.labels(uncategorized: "Root")
        let category = try XCTUnwrap(catalog.filesByCategory["Category-0"])
        var fileUpdates = 0, folderUpdates = 0, snapshotUpdates = 0
        let subscriptions = [state.$files.dropFirst().sink { _ in fileUpdates += 1 },
            state.$folder.dropFirst().sink { _ in folderUpdates += 1 },
            state.$hasSnapshot.dropFirst().sink { _ in snapshotUpdates += 1 }]
        defer { subscriptions.forEach { $0.cancel() } }
        for _ in 0..<10 { state.refresh(); try await finish(state); XCTAssertTrue(state.catalog === catalog) }
        XCTAssertEqual(fileUpdates + folderUpdates + snapshotUpdates, 0)
        for _ in 0..<120 {
            XCTAssertTrue(state.catalog === catalog)
            XCTAssertEqual(state.catalog.labels(uncategorized: "Root")["id-100"], labels["id-100"])
            let repeated = try XCTUnwrap(state.catalog.filesByCategory["Category-0"])
            category.withUnsafeBufferPointer { first in
                repeated.withUnsafeBufferPointer { second in XCTAssertEqual(first.baseAddress, second.baseAddress) }
            }
        }
        XCTAssertEqual(catalog.categories.count, 10)
        XCTAssertEqual(category.count, 1_000)
        var changed = files
        changed[0].modified = Date(timeIntervalSince1970: 1_700_000_000)
        source.replace(changed)
        state.refresh(); try await finish(state)
        XCTAssertEqual(fileUpdates, 1)
        XCTAssertFalse(state.catalog === catalog)
        XCTAssertEqual(state.catalog.filesByIdentifier["id-0"]?.modified, changed[0].modified)
        XCTAssertNotNil(defaults.data(forKey: "picture_control_folder_bookmark"),
                        "Same snapshots must still retain the accepted bookmark")
    }

    private func restore(_ state: PictureControlFolderState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.isRestoring && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(state.isRestoring)
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


private final class PictureControlCatalogTestSource: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [PresetFile]
    init(_ files: [PresetFile]) { self.files = files }
    func read() -> [PresetFile] { lock.lock(); defer { lock.unlock() }; return files }
    func replace(_ files: [PresetFile]) { lock.lock(); defer { lock.unlock() }; self.files = files }
}
