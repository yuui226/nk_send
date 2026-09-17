import XCTest
@testable import ZTransfer

final class PhotoThumbnailStoreTests: XCTestCase {
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
