import XCTest
@testable import ZTransfer

final class PhotoThumbnailDiskCacheTests: XCTestCase {
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
        let stale = PhotoThumbnailDiskCache.cacheFileName(fileName: "stale.JPG", size: 1, captureDate: nil)
        XCTAssertTrue(store.write(Data([9]), as: stale))
        XCTAssertEqual(store.reconcile(validNames: [key]), 1)
        XCTAssertNil(store.find(stale))
    }

    func testLegacyFileNameMatchesAndroidSafeCharacters() {
        XCTAssertEqual(
            PhotoThumbnailDiskCache.legacyCacheFileName(fileName: "A/B.JPG", size: 3, captureDate: nil),
            "A_B.JPG_3_0.jpg"
        )
    }
}
