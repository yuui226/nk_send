import XCTest
@testable import ZTransfer

final class DownloadIntegrityTests: XCTestCase {
    func testDeclaredSizeWinsOverKnownSize() {
        XCTAssertEqual(mismatchedFullObjectSize(received: 90, declared: 100, known: 110), 100)
    }
    func testUnknownSentinelAndMatchingSizesAreAccepted() {
        XCTAssertNil(mismatchedFullObjectSize(received: 100, declared: UInt64(UInt32.max), known: 100))
        XCTAssertNil(mismatchedFullObjectSize(received: 0, declared: 0, known: 0))
    }
    func testOnlyVideosKeepPartialOnCancellation() {
        XCTAssertTrue(keepsPartialOnCancellation(fileName: "clip.MP4"))
        XCTAssertTrue(keepsPartialOnCancellation(fileName: "clip.mov"))
        XCTAssertTrue(keepsPartialOnCancellation(fileName: "clip.NEV"))
        XCTAssertFalse(keepsPartialOnCancellation(fileName: "photo.JPG"))
        XCTAssertFalse(shouldUsePartialObjectDownload(partialObjectSupported: true, effectiveSize: 200 * 1024 * 1024, videoTransfer: false))
        XCTAssertTrue(shouldUsePartialObjectDownload(partialObjectSupported: true, effectiveSize: 200 * 1024 * 1024, videoTransfer: true))
    }
}
