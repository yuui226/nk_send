import XCTest
#if !THUMBNAIL_CACHE_STANDALONE
@testable import ZTransfer
#endif

final class PhotoThumbnailDiskCacheTests: XCTestCase {
    func testCameraIsolationRetentionBoundaryAndReconnect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PhotoThumbnailDiskCache(root: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let old = cache.openCamera(identity: "old", now: start)
        let other = cache.openCamera(identity: "other", now: start)
        XCTAssertTrue(old.write(Data([1]), as: "same.jpg"))
        XCTAssertNil(other.find("same.jpg"))
        XCTAssertNotEqual(old.target("same.jpg"), other.target("same.jpg"))
        let boundary = start.addingTimeInterval(PhotoThumbnailDiskCache.maxIdleInterval)
        XCTAssertEqual(cache.cleanupExpired(now: boundary), 0)
        let refreshed = cache.openCamera(identity: "other", now: boundary)
        XCTAssertTrue(refreshed === other)
        XCTAssertEqual(cache.cleanupExpired(now: boundary.addingTimeInterval(0.001)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.target("same.jpg").deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.target("same.jpg").deletingLastPathComponent().path))
    }

    func testLegacyAndDisplayNameMigrationAndWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PhotoThumbnailDiskCache(root: root)
        let store = cache.openCamera(identity: "body")
        let legacy = root.appendingPathComponent("legacy.jpg")
        try Data([1]).write(to: legacy)
        XCTAssertEqual(store.find("hashed.jpg", legacyName: "legacy.jpg"), store.target("hashed.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(store.write(Data([2]), as: "display.jpg"))
        XCTAssertEqual(store.find("stable.jpg", alternateName: "display.jpg"), store.target("stable.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.target("display.jpg").path))
        let directory = store.target("unused").deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data([3]).write(to: directory)
        XCTAssertFalse(store.write(Data([4]), as: "failed.jpg"))
        XCTAssertNil(store.find("failed.jpg"))
        try FileManager.default.removeItem(at: directory)
        let reopened = cache.openCamera(identity: "body")
        XCTAssertTrue(reopened === store)
        XCTAssertNil(reopened.find("hashed.jpg"))
        XCTAssertTrue(reopened.write(Data([5]), as: "fresh.jpg"))
    }

    func testUnicodeKeysRemainDistinctWhileLegacyUsesAndroidASCII() {
        let first = PhotoThumbnailDiskCache.cacheFileName(fileName: "照片 1.JPG", size: 123, captureDate: nil)
        XCTAssertEqual(first, PhotoThumbnailDiskCache.cacheFileName(fileName: "照片 1.JPG", size: 123, captureDate: nil))
        XCTAssertNotEqual(first, PhotoThumbnailDiskCache.cacheFileName(fileName: "照片-1.JPG", size: 123, captureDate: nil))
        XCTAssertNotNil(first.range(of: #"^[0-9a-f]{64}\.jpg$"#, options: .regularExpression))
        XCTAssertEqual(PhotoThumbnailDiskCache.legacyCacheFileName(fileName: "照片 1.JPG", size: 123, captureDate: nil), "___1.JPG_123_0.jpg")
    }

    func testKeysAreStableAndSeparateByMetadata() {
        let first = PhotoThumbnailDiskCache.cacheFileName(
            fileName: "DSC_0001.JPG", size: 42, captureDate: "20260913T010203"
        )
        XCTAssertEqual(first, PhotoThumbnailDiskCache.cacheFileName(
            fileName: "DSC_0001.JPG", size: 42, captureDate: "20260913T010203"
        ))
        XCTAssertNotEqual(first, PhotoThumbnailDiskCache.cacheFileName(
            fileName: "DSC_0001.JPG", size: 43, captureDate: "20260913T010203"
        ))
        XCTAssertNotEqual(
            PhotoThumbnailDiskCache.staCacheFileName(handle: 1, size: 42),
            PhotoThumbnailDiskCache.staCacheFileName(handle: 2, size: 42)
        )
    }

    func testWriteFindAndReconcileOnlyUseNonEmptyFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PhotoThumbnailDiskCache(root: root)
        let store = cache.openCamera(identity: "camera-1")
        let key = PhotoThumbnailDiskCache.cacheFileName(fileName: "a.JPG", size: 3, captureDate: nil)
        XCTAssertTrue(store.write(Data([1, 2, 3]), as: key))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.find(key))), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.target(key + ".tmp").path))
        let stale = PhotoThumbnailDiskCache.cacheFileName(fileName: "stale.JPG", size: 1, captureDate: nil)
        XCTAssertTrue(store.write(Data([9]), as: stale))
        XCTAssertEqual(store.reconcile(validNames: [key]), 1)
        XCTAssertNil(store.find(stale))
    }

    func testExpirationCleanupIsClaimedOnlyOncePerSharedCache() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PhotoThumbnailDiskCache(root: root)
        XCTAssertTrue(cache.claimCleanup())
        XCTAssertFalse(cache.claimCleanup())
    }

    func testLegacyFileNameMatchesAndroidSafeCharacters() {
        XCTAssertEqual(
            PhotoThumbnailDiskCache.legacyCacheFileName(fileName: "A/B.JPG", size: 3, captureDate: nil),
            "A_B.JPG_3_0.jpg"
        )
    }

    func testCleanupRemovesTemporaryAndZeroByteEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PhotoThumbnailDiskCache(root: root)
        let store = cache.openCamera(identity: "manual")
        let cameraDirectory = store.target("placeholder.jpg").deletingLastPathComponent()
        let temporary = cameraDirectory.appendingPathComponent("pending.jpg.tmp")
        let zero = cameraDirectory.appendingPathComponent("empty.jpg")
        try Data([1]).write(to: temporary)
        try Data().write(to: zero)

        _ = cache.cleanupExpired()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zero.path))
    }

    func testFindRecreatesDirectoryAfterSystemCacheEviction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PhotoThumbnailDiskCache(root: root)
        let store = cache.openCamera(identity: "camera-evicted")
        let key = PhotoThumbnailDiskCache.cacheFileName(fileName: "a.JPG", size: 3, captureDate: nil)
        try FileManager.default.removeItem(at: store.target(key).deletingLastPathComponent())
        XCTAssertNil(store.find(key))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.target(key).deletingLastPathComponent().path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
