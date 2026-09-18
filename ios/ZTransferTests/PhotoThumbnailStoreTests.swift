import XCTest
#if !THUMBNAIL_CACHE_STANDALONE
@testable import ZTransfer
#endif

final class PhotoThumbnailStoreTests: XCTestCase {
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
