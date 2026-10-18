import XCTest
#if !THUMBNAIL_CACHE_STANDALONE
@testable import ZTransfer
#endif

final class PhotoThumbnailStoreTests: XCTestCase {
    func testSharedPrefetchWaitersReceiveTheSameWriteFailure() async throws {
        for invalidBytes in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data([1]).write(to: root)
            let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
            let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                fileName: "photo.JPG", captureDate: "20261001T120000", isProtected: false)
            let gate = ThumbnailWriteFailureGate()
            let first = Task {
                try await store.prefetchOutcome(file: file, identity: "camera",
                    validate: { _ in !invalidBytes }) { await gate.wait() }
            }
            for _ in 0..<200 {
                if await store.activeWaiterCount == 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let second = Task {
                try await store.prefetchOutcome(file: file, identity: "camera",
                    validate: { _ in !invalidBytes }) {
                    XCTFail("The second caller must share the first flight")
                    return Data([2])
                }
            }
            for _ in 0..<200 {
                if await store.activeWaiterCount == 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let count = await store.activeWaiterCount
            XCTAssertEqual(count, 2)
            await gate.release()
            let firstResult = try await first.value
            let secondResult = try await second.value
            XCTAssertEqual(firstResult, .unsettled)
            XCTAssertEqual(secondResult, .unsettled)
            let blocked = await store.diskWritesBlocked
            XCTAssertEqual(blocked, !invalidBytes)
            let remaining = await store.activeWaiterCount
            XCTAssertEqual(remaining, 0)
        }
    }

    func testDiskWriteFailureBlocksFurtherFetchesUntilNewStoreSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file where the cache directory should be forces real IO failure.
        try Data([1]).write(to: root)
        let disk = PhotoThumbnailDiskCache(root: root)
        let store = PhotoThumbnailStore(disk: disk)
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
            fileName: "photo.JPG", captureDate: "20261001T120000", isProtected: false)
        let invalid = try await store.prefetchOutcome(file: file, identity: "camera", validate: { _ in false }) { Data([2]) }
        XCTAssertEqual(invalid, .unsettled)
        let validationBlocked = await store.diskWritesBlocked
        XCTAssertFalse(validationBlocked)
        let failed = try await store.prefetchOutcome(file: file, identity: "camera") { Data([2]) }
        XCTAssertEqual(failed, .unsettled)
        let blocked = await store.diskWritesBlocked
        XCTAssertTrue(blocked)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await store.resetForScan(identity: "camera")
        let stillBlocked = try await store.prefetchOutcome(file: file, identity: "camera") {
            XCTFail("Scan resets and repaired storage must not reset this connection's latch")
            return Data([3])
        }
        XCTAssertEqual(stillBlocked, .unsettled)
        let reconnected = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let recovered = try await reconnected.prefetchOutcome(file: file, identity: "camera") { Data([3]) }
        XCTAssertEqual(recovered, .settled)
    }

    func testRemovalClearsPendingAndFailedOwnersBeforeHandleReuse() async throws {
        let file = CameraFile(id: 9, storageID: 1, format: 0x3801, size: 100,
            fileName: "same.JPG", captureDate: "20261001T120000", isProtected: false)
        for failed in [false, true] {
            let queue = PhotoThumbnailFillQueue(sequential: true)
            await queue.beginScan()
            await queue.seed([file])
            if failed {
                let item = await queue.poll()
                let work = try XCTUnwrap(item)
                await queue.finish(work.id, expectedRevision: work.revision, owner: work.owner, settled: false)
            }
            await queue.remove([9])
            let empty = await queue.state()
            XCTAssertTrue(empty.pending.isEmpty)
            XCTAssertTrue(empty.failed.isEmpty)
            XCTAssertTrue(empty.settled.isEmpty)
            await queue.enqueueNew([file])
            let replacement = await queue.poll()
            XCTAssertEqual(replacement?.id, 9)
        }
        // Even identical photo metadata cannot make a deleted request own
        // the next incarnation of the same handle.
        let queue = PhotoThumbnailFillQueue(sequential: true)
        await queue.seed([file])
        let first = await queue.poll()
        let old = try XCTUnwrap(first)
        await queue.remove([9])
        await queue.enqueueNew([file])
        await queue.finish(9, expectedRevision: old.revision, owner: old.owner, settled: true)
        let current = await queue.poll()
        let new = try XCTUnwrap(current)
        XCTAssertNotEqual(old.owner, new.owner)
        await queue.returnToFront(9, expectedRevision: old.revision, owner: old.owner)
        let duplicate = await queue.poll()
        XCTAssertNil(duplicate)
        await queue.finish(9, expectedRevision: new.revision, owner: new.owner, settled: true)
        let completed = await queue.state()
        XCTAssertEqual(completed.settled, [9])
    }

    func testEnhancedSTAJpegRejectsEveryOldCacheRouteAndReusesNewEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PhotoThumbnailDiskCache(root: root)
        let file = CameraFile(id: 42, storageID: 1, format: 0x3801, size: 123,
                              fileName: "DSC_0042.JPG", captureDate: "20261001T120000", isProtected: false)
        let camera = disk.openCamera(identity: "jpeg-quality")
        for key in [
            PhotoThumbnailDiskCache.staCacheFileName(handle: file.id, size: file.size),
            PhotoThumbnailDiskCache.cacheFileName(fileName: file.fileName, size: file.size, captureDate: file.captureDate),
            PhotoThumbnailDiskCache.legacyCacheFileName(fileName: file.fileName, size: file.size, captureDate: file.captureDate)
        ] { XCTAssertTrue(camera.write(Data([1]), as: key)) }
        let store = PhotoThumbnailStore(disk: disk)
        let oldHit = try await store.load(file: file, identity: "jpeg-quality", directSTA: true, allowRemote: false) {
            XCTFail("Cache-only lookup cannot read the camera")
            return Data()
        }
        XCTAssertNil(oldHit)
        let calls = LockedCounter()
        let filled = try await store.prefetch(file: file, identity: "jpeg-quality", directSTA: true) {
            calls.increment()
            return Data([2, 3])
        }
        XCTAssertTrue(filled)
        XCTAssertEqual(calls.value, 1)
        let relaunched = PhotoThumbnailStore(disk: disk)
        let reused = try await relaunched.load(file: file, identity: "jpeg-quality", directSTA: true, allowRemote: true) {
            XCTFail("New quality key must survive relaunch")
            return Data()
        }
        XCTAssertEqual(reused, Data([2, 3]))
    }

    func testSequentialSTAIncludesNEFAndRejectsBadDiskAndRemoteBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PhotoThumbnailDiskCache(root: root)
        let file = CameraFile(id: 77, storageID: 1, format: 0xB101, size: 128,
                              fileName: "77.NEF", captureDate: nil, isProtected: false)
        let key = PhotoThumbnailDiskCache.staCacheFileName(handle: 77, size: 128)
        XCTAssertTrue(disk.openCamera(identity: "sequential").write(Data([0]), as: key))
        let store = PhotoThumbnailStore(disk: disk)
        let calls = LockedCounter()
        let invalid = try await store.prefetch(file: file, identity: "sequential", directSTA: true,
                                               validate: { $0 == Data([1, 2, 3]) }) {
            calls.increment()
            return Data([0])
        }
        XCTAssertFalse(invalid)
        let empty = try await store.prefetch(file: file, identity: "sequential", directSTA: true,
                                             validate: { $0 == Data([1, 2, 3]) }) {
            calls.increment()
            return Data()
        }
        XCTAssertFalse(empty)
        let valid = try await store.prefetch(file: file, identity: "sequential", directSTA: true,
                                             validate: { $0 == Data([1, 2, 3]) }) {
            calls.increment()
            return Data([1, 2, 3])
        }
        XCTAssertTrue(valid)
        let hit = try await store.prefetch(file: file, identity: "sequential", directSTA: true,
                                           validate: { $0 == Data([1, 2, 3]) }) {
            calls.increment()
            return Data()
        }
        XCTAssertTrue(hit)
        XCTAssertEqual(calls.value, 3)
    }

    func testLeavingCellOnlyCancelsObservationWhileSequentialFetchCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let file = file()
        let observer = Task {
            for await _ in await store.updates(handle: file.id) {
                _ = try await store.load(file: file, identity: "observe", allowRemote: false) {
                    XCTFail("cell must never fetch")
                    return Data()
                }
            }
        }
        let pipeline = Task {
            let result = try await store.prefetch(file: file, identity: "observe", validate: { !$0.isEmpty }) {
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()
                return Data([1, 2, 3])
            }
            await store.publish(handle: file.id)
            return result
        }
        try await Task.sleep(for: .milliseconds(10))
        observer.cancel()
        _ = try await observer.value
        let finished = try await pipeline.value
        XCTAssertTrue(finished)
        let returning = await store.updates(handle: file.id)
        var iterator = returning.makeAsyncIterator()
        let initialEvent: Void? = await iterator.next()
        XCTAssertNotNil(initialEvent)
        let cached = try await store.load(file: file, identity: "observe", allowRemote: false) {
            XCTFail("returning cell uses cached result")
            return Data()
        }
        XCTAssertEqual(cached, Data([1, 2, 3]))
    }

    func testSequentialQueueIgnoresFiltersAndAppendsNewFilesWithoutRestart() async {
        let queue = PhotoThumbnailFillQueue(sequential: true)
        func item(_ id: UInt32, _ day: String) -> CameraFile {
            CameraFile(id: id, storageID: 1, format: 0x3801, size: 1,
                       fileName: "\(id).NEF", captureDate: day, isProtected: false)
        }
        let files = [item(1, "20260901"), item(2, "20260902"), item(3, "20260903")]
        await queue.beginScan()
        await queue.seed(files, priorityRange: PhotoDateRange(start: "20260903", end: "20260903"))
        let first = await queue.poll()
        XCTAssertEqual(first?.id, 1)
        await queue.markSettled(1)
        await queue.updatePriorityRange(files, range: PhotoDateRange(start: "20260903", end: "20260903"))
        await queue.enqueueNew([item(4, "20260904")])
        await queue.seed(files) // Repeat publication cannot re-enqueue settled work.
        let second = await queue.poll()
        XCTAssertEqual(second?.id, 2)
        if let second { await queue.returnToFront(second.id, expectedRevision: second.revision) }
        let resumed = await queue.poll()
        let third = await queue.poll()
        let fourth = await queue.poll()
        let end = await queue.poll()
        XCTAssertEqual([resumed?.id, third?.id, fourth?.id], [2, 3, 4])
        XCTAssertNil(end)
        XCTAssertEqual(first?.revision, resumed?.revision)
    }

    private func file() -> CameraFile {
        CameraFile(id: 7, storageID: 1, format: 0x3801, size: 128,
                   fileName: "DSC_0007.JPG", captureDate: "20260914T010203",
                   isProtected: false)
    }

    func testConcurrentLoadsShareOneRemoteReadAndThenUseMemoryCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let counter = LockedCounter()
        let cameraFile = CameraFile(id: 7, storageID: 1, format: 0x3801, size: 128,
                                    fileName: "DSC_0007.JPG", captureDate: "20260914T010203",
                                    isProtected: false)
        let first = Task {
            try await store.load(file: cameraFile, identity: "camera-1", allowRemote: true) {
            counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return Data([1, 2, 3])
            }
        }
        let second = Task {
            try await store.load(file: cameraFile, identity: "camera-1", allowRemote: true) {
            counter.increment()
            return Data([1, 2, 3])
            }
        }
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, Data([1, 2, 3]))
        XCTAssertEqual(secondValue, Data([1, 2, 3]))
        XCTAssertEqual(counter.value, 1)

        let cached = try await store.load(file: file(), identity: "camera-1", allowRemote: true) {
            XCTFail("memory cache should avoid a second remote read")
            return Data()
        }
        XCTAssertEqual(cached, Data([1, 2, 3]))
        XCTAssertEqual(counter.value, 1)
    }

    func testEmptyPrefetchSettlesNegativeCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-negative-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let counter = LockedCounter()
        let firstResult = try await store.prefetch(file: file(), identity: "camera-2") {
            counter.increment()
            return Data()
        }
        XCTAssertTrue(firstResult)
        let secondResult = try await store.prefetch(file: file(), identity: "camera-2") {
            counter.increment()
            return Data([9])
        }
        XCTAssertTrue(secondResult)
        XCTAssertEqual(counter.value, 1)
    }

    func testPrefetchStoresRawBytesAndVisibleLoadProcessesExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-raw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let counter = LockedCounter()
        let prefetched = try await store.prefetch(file: file(), identity: "camera-raw") {
            counter.increment()
            return Data([1, 2, 3])
        }
        XCTAssertTrue(prefetched)
        let visible = try await store.load(file: file(), identity: "camera-raw", allowRemote: true,
                                           transform: { $0 + Data([9]) }) {
            counter.increment()
            return Data([8])
        }
        XCTAssertEqual(visible, Data([1, 2, 3, 9]))
        XCTAssertEqual(counter.value, 1)
    }

    func testCacheOnlyPreviewGateDoesNotFetchAndRemoteLoadResumesLater() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-cache-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let counter = LockedCounter()

        let cacheOnly = try await store.load(file: file(), identity: "camera-gated", allowRemote: false) {
            counter.increment()
            return Data([1])
        }
        XCTAssertNil(cacheOnly)
        XCTAssertEqual(counter.value, 0)

        let resumed = try await store.load(file: file(), identity: "camera-gated", allowRemote: true) {
            counter.increment()
            return Data([1])
        }
        XCTAssertEqual(resumed, Data([1]))
        XCTAssertEqual(counter.value, 1)
    }

    func testAuthoritativeRemovalClearsNegativeStateForReusedObject() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-reuse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let counter = LockedCounter()
        let cameraFile = file()

        let missing = try await store.load(file: cameraFile, identity: "camera-reuse", allowRemote: true) {
            counter.increment()
            return Data()
        }
        XCTAssertNil(missing)
        await store.invalidate(files: [cameraFile], identity: "camera-reuse", directSTA: false)
        let reused = try await store.load(file: cameraFile, identity: "camera-reuse", allowRemote: true) {
            counter.increment()
            return Data([7])
        }

        XCTAssertEqual(reused, Data([7]))
        XCTAssertEqual(counter.value, 2)
    }

    func testDirectSTARawEmptyProbeRemainsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-sta-raw-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let counter = LockedCounter()
        let raw = CameraFile(id: 9, storageID: 1, format: 0xB103, size: 50_000_000,
                             fileName: "DSC_0009.NEF", captureDate: "20260914T010203",
                             isProtected: false)

        let missing = try await store.load(file: raw, identity: "camera-sta", directSTA: true,
                                           allowRemote: true) {
            counter.increment()
            return Data()
        }
        XCTAssertNil(missing)

        let retried = try await store.load(file: raw, identity: "camera-sta", directSTA: true,
                                           allowRemote: true) {
            counter.increment()
            return Data([0xFF, 0xD8, 0xFF, 0xD9])
        }
        XCTAssertEqual(retried, Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertEqual(counter.value, 2)
    }

    func testDirectSTARawPrefetchDoesNotWaitForVisibility() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-sta-raw-lazy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let counter = LockedCounter()
        let raw = CameraFile(id: 10, storageID: 1, format: 0xB103, size: 50_000_000,
                             fileName: "DSC_0010.NEF", captureDate: "20260914T010204",
                             isProtected: false)

        let settled = try await store.prefetch(file: raw, identity: "camera-sta",
                                               directSTA: true) {
            counter.increment()
            return Data([1])
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(counter.value, 1)
    }

    func testRejectedNEFBytesAreNotPersistedAndImmediateRetryDoesNotReuseFailedFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nef-cache-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PhotoThumbnailDiskCache(root: root)
        let store = PhotoThumbnailStore(disk: disk)
        let raw = CameraFile(id: 9, storageID: 1, format: 0xB103, size: 50_000_000,
                             fileName: "DSC_0009.NEF", captureDate: nil, isProtected: false)
        let key = PhotoThumbnailDiskCache.staCacheFileName(handle: raw.id, size: raw.size)
        let camera = disk.openCamera(identity: "nef-body")
        // Simulate a retained old on-disk entry during an in-place app update.
        XCTAssertTrue(camera.write(Data([0]), as: key))
        let missing = try await store.load(file: raw, identity: "nef-body", directSTA: true,
                                           allowRemote: true, validate: { $0 == Data([9]) }) { Data([0]) }
        XCTAssertNil(missing)
        XCTAssertNil(camera.find(key))
        let retried = try await store.load(file: raw, identity: "nef-body", directSTA: true,
                                           allowRemote: true, validate: { $0 == Data([9]) }) { Data([9]) }
        XCTAssertEqual(retried, Data([9]))
        let relaunched = PhotoThumbnailStore(disk: disk)
        let persisted = try await relaunched.load(file: raw, identity: "nef-body", directSTA: true,
                                                  allowRemote: false, validate: { $0 == Data([9]) }) {
            XCTFail("Validated bytes must survive an ordinary relaunch, no reinstall needed")
            return Data()
        }
        XCTAssertEqual(persisted, Data([9]))
    }

    func testMalformedDiskEntryIsDeletedAndRefetchedInsteadOfNegativelyCached() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-thumb-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let prefetched = try await store.prefetch(file: file(), identity: "camera-corrupt") {
            Data([0])
        }
        XCTAssertTrue(prefetched)
        let counter = LockedCounter()
        let value = try await store.load(file: file(), identity: "camera-corrupt", allowRemote: true,
                                         validate: { $0 == Data([9]) }) {
            counter.increment()
            return Data([9])
        }
        XCTAssertEqual(value, Data([9]))
        XCTAssertEqual(counter.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor ThumbnailWriteFailureGate {
    private var released = false
    private var continuation: CheckedContinuation<Data, Never>?
    func wait() async -> Data {
        if released { return Data([2]) }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: Data([2]))
        continuation = nil
    }
}

final class PhotoThumbnailPerformanceTests: XCTestCase {
    func testByteBoundedAccessOrderOverwriteRemovalAndOversizedEntry() {
        var cache = PhotoThumbnailMemoryCache(budget: 6)
        cache.insert(Data([1, 1]), for: "a")
        cache.insert(Data([2, 2]), for: "b")
        cache.insert(Data([3, 3]), for: "c")
        XCTAssertEqual(cache.value(for: "a"), Data([1, 1]))
        cache.insert(Data([4, 4]), for: "d")
        XCTAssertNil(cache.value(for: "b"))
        cache.insert(Data([5, 5, 5]), for: "a")
        XCTAssertNil(cache.value(for: "c"))
        XCTAssertEqual(cache.byteCount, 5)
        cache.remove("missing")
        cache.remove("d")
        cache.insert(Data([6]), for: "e")
        cache.insert(Data([7]), for: "f")
        cache.retainOnly(["a", "f"])
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.byteCount, 4)
        cache.insert(Data(repeating: 8, count: 7), for: "oversized")
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.byteCount, 0)
        cache.insert(Data([9]), for: "new")
        XCTAssertEqual(cache.value(for: "new"), Data([9]))
        cache.removeAll(keepingCapacity: true)
        cache.insert(Data([10]), for: "after-clear")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.byteCount, 1)
    }

    func testRandomAccessMatchesExistingArrayPolicyAcrossReplacementAndPruning() {
        // Independent reference is the former dictionary + removeAll policy.
        // Compare externally observable hits/costs, not internal list links.
        var cache = PhotoThumbnailMemoryCache(budget: 111)
        var values: [String: Data] = [:]
        var order: [String] = []
        var seed: UInt64 = 0x32_2026_1018
        func random() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        for iteration in 0..<20_000 {
            let key = String(random() % 64)
            switch random() % 16 {
            case 0...7:
                let value = Data(repeating: UInt8(iteration % 256), count: random() % 130)
                cache.insert(value, for: key)
                values[key] = value
                order.removeAll { $0 == key }; order.append(key)
                while values.values.reduce(0, { $0 + $1.count }) > 111 {
                    values.removeValue(forKey: order.removeFirst())
                }
            case 8...12:
                XCTAssertEqual(cache.value(for: key), values[key], "operation \(iteration)")
                if values[key] != nil { order.removeAll { $0 == key }; order.append(key) }
            case 13:
                cache.remove(key)
                values.removeValue(forKey: key); order.removeAll { $0 == key }
            case 14:
                let retained = Set((0..<64).filter { $0 % 3 != iteration % 3 }.map(String.init))
                cache.retainOnly(retained)
                values = values.filter { retained.contains($0.key) }
                order.removeAll { !retained.contains($0) }
            default:
                cache.removeAll(keepingCapacity: iteration.isMultiple(of: 2))
                values.removeAll(); order.removeAll()
            }
            XCTAssertEqual(cache.count, values.count, "operation \(iteration)")
            XCTAssertEqual(cache.byteCount, values.values.reduce(0) { $0 + $1.count })
        }
    }

    func testLargeCatalogAccessKeepsExactValuesAndBoundedCost() {
        var cache = PhotoThumbnailMemoryCache(budget: 50_000)
        for index in 0..<50_000 { cache.insert(Data([UInt8(index % 251)]), for: String(index)) }
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<20_000 {
            let item = (index * 3571) % 50_000
            XCTAssertEqual(cache.value(for: String(item)), Data([UInt8(item % 251)]))
        }
        print("P32: 20000 hits in 50000-entry thumbnail LRU: \(start.duration(to: clock.now))")
        XCTAssertEqual(cache.count, 50_000)
        XCTAssertEqual(cache.byteCount, 50_000)
        cache.retainOnly(Set((0..<50_000).filter { $0.isMultiple(of: 100) }.map(String.init)))
        XCTAssertEqual(cache.count, 500)
        XCTAssertEqual(cache.byteCount, 500)
    }

    func testConcurrentVisibleLoadsDecodeOnceEvenIfTooLargeForMemory() async throws {
        for valid in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root), memoryBudget: 0)
            let gate = ThumbnailWriteFailureGate()
            let transforms = LockedCounter()
            let validations = LockedCounter()
            let fetches = LockedCounter()
            let photo = file(1)
            let requests = (0..<24).map { _ in Task {
                try await store.load(file: photo, identity: "shared", allowRemote: true,
                    transform: { data in transforms.increment(); return data + Data([3]) },
                    validate: { _ in validations.increment(); return valid }) {
                        fetches.increment()
                        return await gate.wait()
                    }
            } }
            try await waitForWaiters(24, store: store)
            await gate.release()
            for request in requests {
                let result = try await request.value
                XCTAssertEqual(result, valid ? Data([2, 3]) : nil)
            }
            XCTAssertEqual(fetches.value, 1)
            XCTAssertEqual(transforms.value, 1)
            XCTAssertEqual(validations.value, 1)
            // No oversized memory entry: valid raw disk bytes decode again;
            // invalid remote bytes remain negatively cached for this session.
            let again = try await store.load(file: photo, identity: "shared", allowRemote: true,
                transform: { data in transforms.increment(); return data + Data([3]) }) {
                    XCTFail("Shared result must have been persisted or negatively cached")
                    return Data()
                }
            XCTAssertEqual(again, valid ? Data([2, 3]) : nil)
            XCTAssertEqual(transforms.value, valid ? 2 : 1)
        }
    }

    func testProductionEvictionUsesDiskThenInvalidationAndResetReloadCorrectly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PhotoThumbnailDiskCache(root: root)
        let store = PhotoThumbnailStore(disk: disk, memoryBudget: 4)
        let transforms = LockedCounter()
        let fetches = LockedCounter()
        func load(_ id: UInt32, identity: String = "camera") async throws -> Data? {
            try await store.load(file: file(id), identity: identity, allowRemote: true,
                transform: { data in transforms.increment(); return data + Data([9]) }) {
                    fetches.increment(); return Data([UInt8(id)])
                }
        }
        _ = try await load(1); _ = try await load(2); _ = try await load(1)
        _ = try await load(3)
        XCTAssertEqual(transforms.value, 3)
        _ = try await load(1)
        XCTAssertEqual(transforms.value, 3)
        let reloaded = try await load(2)
        XCTAssertEqual(reloaded, Data([2, 9]))
        XCTAssertEqual(transforms.value, 4)
        XCTAssertEqual(fetches.value, 3)
        await store.invalidate(files: [file(2)], identity: "camera", directSTA: false)
        _ = try await load(2)
        XCTAssertEqual(transforms.value, 5)
        XCTAssertEqual(fetches.value, 3) // Handle invalidation retains stable disk entries.
        await store.resetForScan(identity: "camera")
        _ = try await load(2)
        XCTAssertEqual(transforms.value, 6)
        await store.reconcile(files: [file(1)], identity: "camera", directSTA: false)
        _ = try await load(2)
        XCTAssertEqual(fetches.value, 4) // Authoritative reconciliation removes stale disk too.
        _ = try await load(2, identity: "different-camera")
        XCTAssertEqual(fetches.value, 5)
        await store.clear()
        _ = try await load(2, identity: "different-camera")
        XCTAssertEqual(fetches.value, 5)
    }

    func testCancellingOneVisibleWaiterPreservesSharedDecodeForRemainingOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root))
        let gate = ThumbnailWriteFailureGate()
        let transforms = LockedCounter()
        let photo = file(1)
        let first = Task {
            try await store.load(file: photo, identity: "camera", allowRemote: true,
                transform: { data in transforms.increment(); return data }) { await gate.wait() }
        }
        try await waitForWaiters(1, store: store)
        let second = Task {
            try await store.load(file: photo, identity: "camera", allowRemote: true,
                transform: { data in transforms.increment(); return data }) {
                    XCTFail("Must share the original request"); return Data()
                }
        }
        try await waitForWaiters(2, store: store)
        first.cancel()
        try await waitForWaiters(1, store: store)
        await gate.release()
        let value = try await second.value
        _ = try? await first.value
        XCTAssertEqual(value, Data([2]))
        XCTAssertEqual(transforms.value, 1)
        let remaining = await store.activeWaiterCount
        XCTAssertEqual(remaining, 0)
    }

    private func file(_ id: UInt32) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 100,
                   fileName: "photo-\(id).JPG", captureDate: "20261018T120000", isProtected: false)
    }

    private func waitForWaiters(_ count: Int, store: PhotoThumbnailStore) async throws {
        for _ in 0..<400 {
            if await store.activeWaiterCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let actual = await store.activeWaiterCount
        XCTFail("Expected \(count) shared waiters, got \(actual)")
        throw CancellationError()
    }
}
