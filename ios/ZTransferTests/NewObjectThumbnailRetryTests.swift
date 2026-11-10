import XCTest
@testable import ZTransfer

final class NewObjectThumbnailRetryTests: XCTestCase, @unchecked Sendable {
    func testFillQueuePreservesBlockedFailuresUntilTheirOwnDeadline() async throws {
        for sequential in [false, true] {
            let queue = PhotoThumbnailFillQueue(sequential: sequential)
            await queue.seed([photo(1), photo(2)], loadingRange: nil)
            while let work = await queue.poll() {
                await queue.finish(work.id, expectedRevision: work.revision, owner: work.owner, settled: false)
            }
            await queue.retryFailed(excluding: [1])
            let ready = await queue.poll()
            XCTAssertEqual(ready?.id, 2)
            let waiting = await queue.poll()
            XCTAssertNil(waiting)
            await queue.retryFailed(excluding: [])
            let later = await queue.poll()
            XCTAssertEqual(later?.id, 1, "A blocked failed item must not be dropped or settled")
        }
    }

    func testAndroidFiniteBudgetAndJoinedFailureBoundaries() {
        var retries = NewObjectThumbnailRetries()
        XCTAssertNil(retries.failed(9, now: 0))
        retries.register(1)
        XCTAssertEqual(retries.failed(1, now: 0), 300)
        retries.register(1)
        XCTAssertEqual(retries.failed(1, now: 200), 300)
        XCTAssertFalse(retries.canAttempt(1, now: 299))
        XCTAssertEqual(retries.takeDue(now: 299), [])
        XCTAssertTrue(retries.canAttempt(1, now: 300))
        // A request can beat the timer at the exact boundary.
        XCTAssertEqual(retries.failed(1, now: 300), 1_200)
        XCTAssertEqual(retries.takeDue(now: 301), [])
        XCTAssertEqual(retries.takeDue(now: 1_200), [1])
        XCTAssertEqual(retries.failed(1, now: 1_200), 3_000)
        XCTAssertEqual(retries.takeDue(now: 3_000), [1])
        XCTAssertNil(retries.failed(1, now: 3_000))
        XCTAssertNil(retries.nextRetryAt)
        XCTAssertFalse(retries.isRetry(1))
    }

    func testIndependentDeadlinesAndRemovalReset() {
        var retries = NewObjectThumbnailRetries()
        retries.register(1); retries.register(2)
        XCTAssertEqual(retries.failed(1, now: 0), 300)
        XCTAssertEqual(retries.failed(2, now: 100), 400)
        XCTAssertEqual(retries.nextRetryAt, 300)
        XCTAssertEqual(retries.takeDue(now: 300), [1])
        XCTAssertEqual(retries.blockedHandles(now: 300), [2])
        XCTAssertEqual(retries.nextRetryAt, 400)
        XCTAssertFalse(retries.remove(1))
        XCTAssertFalse(retries.isRetry(1))
        retries.retainOnly([1])
        XCTAssertNil(retries.nextRetryAt)
        retries.register(1)
        XCTAssertEqual(retries.failed(1, now: 500), 800)
        retries.clear()
        XCTAssertNil(retries.failed(1, now: 500))
    }

    func testBothStoreLanesWaitAndStopAfterThreeRetries() async throws {
        for (prefetch, direct) in [(false, false), (true, false), (false, true), (true, true)] {
            let clock = ThumbnailRetryClock()
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root), nowMilliseconds: { clock.now })
            let file = photo(1)
            let validate: (@Sendable (Data) -> Bool)? = direct ? { @Sendable data in !data.isEmpty } : nil
            await store.registerNewObjects([file], identity: "camera", directSTA: direct)
            for (index, time) in [0, 300, 1_200, 3_000].enumerated() {
                clock.now = Int64(time)
                if prefetch {
                    let result = try await store.prefetchOutcome(file: file, identity: "camera", directSTA: direct, validate: validate) { Data() }
                    XCTAssertEqual(result.isSettled, index == 3)
                } else {
                    let result = try await store.load(file: file, identity: "camera", directSTA: direct, allowRemote: true) { Data() }
                    XCTAssertNil(result)
                }
                let blocked = await store.blockedRetryHandles()
                XCTAssertEqual(blocked, index == 3 ? [] : [1])
                let visible = try await store.load(file: file, identity: "camera", directSTA: direct, allowRemote: true) {
                    XCTFail("Waiting and exhausted objects cannot start another camera read")
                    return Data([1])
                }
                XCTAssertNil(visible)
                let filled = try await store.prefetchOutcome(file: file, identity: "camera", directSTA: direct, validate: validate) {
                    XCTFail("Background fill obeys the same deadline/negative cache")
                    return Data([1])
                }
                XCTAssertEqual(filled.isSettled, index == 3)
            }
            await store.stopRetries()
        }
    }

    func testSharedVisibleAndPrefetchFailureConsumesOnlyOneAttempt() async throws {
        let clock = ThumbnailRetryClock()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root), nowMilliseconds: { clock.now })
        let file = photo(1)
        await store.registerNewObjects([file], identity: "camera", directSTA: false)
        let gate = NewThumbnailReadGate()
        let visible = Task { try await store.load(file: file, identity: "camera", allowRemote: true) { await gate.wait() } }
        try await waitForWaiters(1, in: store)
        let fill = Task { try await store.prefetchOutcome(file: file, identity: "camera") {
            XCTFail("The background lane must join the visible request")
            return Data()
        } }
        try await waitForWaiters(2, in: store)
        await gate.finish(Data())
        let visibleResult = try await visible.value
        let fillResult = try await fill.value
        XCTAssertNil(visibleResult)
        XCTAssertFalse(fillResult.isSettled)
        clock.now = 300
        _ = try await store.load(file: file, identity: "camera", allowRemote: true) { Data() }
        clock.now = 1_199
        let early = await store.blockedRetryHandles()
        XCTAssertEqual(early, [1])
        clock.now = 1_200
        let due = await store.blockedRetryHandles()
        XCTAssertEqual(due, [])
        await store.stopRetries()
    }

    func testSuccessHistoricalMissAndHandleReuseKeepIndependentPolicies() async throws {
        let clock = ThumbnailRetryClock()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root), nowMilliseconds: { clock.now })
        let fresh = photo(1), historical = photo(2)
        await store.registerNewObjects([fresh], identity: "camera", directSTA: false)
        _ = try await store.load(file: historical, identity: "camera", allowRemote: true) { Data() }
        _ = try await store.load(file: fresh, identity: "camera", allowRemote: true) { Data() }
        let pending = await store.blockedRetryHandles()
        XCTAssertEqual(pending, [1])
        clock.now = 300
        let loaded = try await store.load(file: fresh, identity: "camera", allowRemote: true) { Data([1]) }
        XCTAssertEqual(loaded, Data([1]))
        let retry = await store.isNewObjectRetry(1)
        XCTAssertFalse(retry)
        _ = try await store.load(file: historical, identity: "camera", allowRemote: true) {
            XCTFail("A new object's retry must not clear an old object's negative cache")
            return Data([1])
        }
        await store.invalidate(files: [fresh], identity: "camera", directSTA: false)
        let replacement = photo(1, name: "replacement.JPG")
        await store.registerNewObjects([replacement], identity: "camera", directSTA: false)
        _ = try await store.load(file: replacement, identity: "camera", allowRemote: true) { Data() }
        clock.now = 599
        let before = await store.blockedRetryHandles()
        XCTAssertEqual(before, [1])
        clock.now = 600
        let after = await store.blockedRetryHandles()
        XCTAssertEqual(after, [])
        await store.stopRetries()
    }

    func testTransportFailureRetriesButCancellationDoesNotSpendBudget() async throws {
        enum Failure: Error { case transport }
        let clock = ThumbnailRetryClock()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root), nowMilliseconds: { clock.now })
        let file = photo(1)
        await store.registerNewObjects([file], identity: "camera", directSTA: false)
        do {
            _ = try await store.load(file: file, identity: "camera", allowRemote: true) { throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
        let afterCancellation = await store.isNewObjectRetry(1)
        XCTAssertFalse(afterCancellation)
        do {
            _ = try await store.prefetchOutcome(file: file, identity: "camera") { throw Failure.transport }
            XCTFail("Transport errors must propagate")
        } catch Failure.transport { }
        let pending = await store.blockedRetryHandles()
        XCTAssertEqual(pending, [1])
        await store.stopRetries()
        await store.registerNewObjects([file], identity: "camera", directSTA: false)
        let stopped = await store.blockedRetryHandles()
        XCTAssertEqual(stopped, [])
        let stream = await store.retryWakes()
        var iterator = stream.makeAsyncIterator()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testRealTimerWakesOnceWithoutOwningCameraIO() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let file = photo(1)
        let stream = await store.retryWakes()
        let woke = expectation(description: "The 300 ms retry clock wakes the fill queue")
        let listener = Task {
            for await _ in stream { woke.fulfill(); break }
        }
        defer { listener.cancel() }
        await store.registerNewObjects([file], identity: "camera", directSTA: false)
        _ = try await store.load(file: file, identity: "camera", allowRemote: true) { Data() }
        let unrelated = try await store.load(file: photo(2), identity: "camera", allowRemote: true) { Data([2]) }
        XCTAssertEqual(unrelated, Data([2]), "A retry delay cannot hold the remote read gate")
        await fulfillment(of: [woke], timeout: 2)
        let due = await store.blockedRetryHandles()
        XCTAssertEqual(due, [])
        let retried = try await store.load(file: file, identity: "camera", allowRemote: true) { Data([1]) }
        XCTAssertEqual(retried, Data([1]))
        await store.stopRetries()
    }

    func testLateInFlightResultAfterDeletionCannotRecreateRetryOrCache() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let file = photo(1)
        let gate = NewThumbnailReadGate()
        await store.registerNewObjects([file], identity: "camera", directSTA: false)
        let task = Task { try await store.load(file: file, identity: "camera", allowRemote: true) { await gate.wait() } }
        try await waitForWaiters(1, in: store)
        await store.invalidate(files: [file], identity: "camera", directSTA: false)
        await gate.finish(Data([1]))
        do { _ = try await task.value; XCTFail("A removed flight cannot publish") }
        catch is CancellationError { }
        let pending = await store.blockedRetryHandles()
        XCTAssertEqual(pending, [])
        let cached = try await store.load(file: file, identity: "camera", allowRemote: false) { XCTFail(); return Data() }
        XCTAssertNil(cached)
        await store.stopRetries()
    }

    #if os(iOS)
    @MainActor
    func testCatalogEventRegistersBeforePublishingOrAutomaticTransfer() async throws {
        let file = photo(1)
        let order = NewThumbnailRegistrationLog()
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: [], removedHandles: [], addedHandles: [],
                            handleQueriesSucceeded: true, metadataComplete: true)
        }, registerNewThumbnailObjects: { files in
            for file in files { order.append("register:\(file.id)") }
        }, setRemoteGate: { _ in })
        defer { model.transportDidDisconnect() }
        await model.reload()
        XCTAssertEqual(model.loadState, .loaded)
        let observer = model.$sections.sink { sections in
            if sections.flatMap(\.files).contains(file) { order.append("publish") }
        }
        defer { observer.cancel() }
        model.setNewMediaHandler { files in
            if files.contains(file) { order.append("transfer") }
        }
        await model.applyCatalogUpdate([file])
        XCTAssertEqual(order.values, ["register:1", "publish", "transfer"])
        await model.applyCatalogUpdate([file])
        XCTAssertEqual(order.values.filter { $0 == "register:1" }.count, 1,
                       "Duplicate catalog snapshots cannot replenish the retry budget")
    }

    @MainActor
    func testScanRegistersOnlyRealAdditionsBeforeFirstBatchRead() async throws {
        let old = photo(1), new = photo(2)
        let order = NewThumbnailRegistrationLog()
        let snapshot = PhotoScanSnapshot(sessionID: UUID(), storageIDs: [1], handleOrders: [(1, [1, 2])],
            processedHandles: [1], handleQueriesSucceeded: true, addedHandles: [2])
        let model = PhotoListViewModel(scanCatalog: { preserve, _, _, _, onBatch in
            try await onBatch(preserve ? [new] : [old])
            return PhotoScanResult(files: preserve ? [old, new] : [old], removedHandles: [],
                addedHandles: preserve ? [2] : [], handleQueriesSucceeded: true, metadataComplete: true)
        }, resumeSnapshotProvider: { snapshot }, prefetchBatch: { files in
            for file in files { order.append("read:\(file.id)") }
            return ThumbnailBatchResult(settled: Set(files.map(\.id)))
        }, canFill: { true }, registerNewThumbnailObjects: { files in
            for file in files { order.append("register:\(file.id)") }
        }, setRemoteGate: { _ in })
        defer { model.transportDidDisconnect() }
        await model.reload()
        await model.reload()
        let events = order.values
        XCTAssertFalse(events.contains("register:1"), "A historical metadata batch is not new media")
        let registered = try XCTUnwrap(events.firstIndex(of: "register:2"))
        let fetched = try XCTUnwrap(events.firstIndex(of: "read:2"))
        XCTAssertLessThan(registered, fetched)
    }
    #endif

    private func photo(_ id: UInt32, name: String? = nil) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 100,
                   fileName: name ?? "\(id).JPG", captureDate: "20261030T120000", isProtected: false)
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func waitForWaiters(_ count: Int, in store: PhotoThumbnailStore) async throws {
        for _ in 0..<200 {
            if await store.activeWaiterCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected \(count) shared request owners")
    }
}

private final class ThumbnailRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
private final class NewThumbnailRegistrationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
}
private actor NewThumbnailReadGate {
    private var continuation: CheckedContinuation<Data, Never>?
    private var completed: Data?
    func wait() async -> Data {
        if let completed { return completed }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ data: Data) {
        completed = data; continuation?.resume(returning: data); continuation = nil
    }
}
