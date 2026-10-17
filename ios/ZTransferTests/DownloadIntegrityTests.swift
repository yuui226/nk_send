import XCTest
@testable import ZTransfer

final class DownloadIntegrityTests: XCTestCase {
    // Android DownloadIntegrityTest: a self-consistent data phase is not
    // sufficient when ObjectInfo/GetObjectSize provides another reliable size.
    func testSelfConsistentShortAndOversizedDataPhasesAreRejected() {
        XCTAssertEqual(mismatchedFullObjectSize(received: 80, declared: 80, known: 100), 100)
        XCTAssertEqual(mismatchedFullObjectSize(received: 120, declared: 120, known: 100), 100)
    }

    func testUnknownSizesAndLargeVideoSentinelsMatchAndroid() {
        let unknown = UInt64(UInt32.max)
        XCTAssertEqual(mismatchedFullObjectSize(received: 80, declared: 100, known: unknown), 100)
        XCTAssertEqual(mismatchedFullObjectSize(received: 80, declared: 0, known: 100), 100)
        XCTAssertNil(mismatchedFullObjectSize(received: 100, declared: 0, known: unknown))
        let large: UInt64 = 6 * 1024 * 1024 * 1024
        XCTAssertNil(mismatchedFullObjectSize(received: large, declared: unknown, known: large))
        XCTAssertEqual(mismatchedFullObjectSize(received: large - 1, declared: 0, known: large), large)
    }

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

    func testPhotoRequestBudgetIsWholeImageExceptForImageCaptureUSB() {
        let size: UInt64 = 120 * 1024 * 1024
        for throughput in [false, true] {
            XCTAssertEqual(transferDownloadChunkSize(effectiveSize: size, preferHighThroughput: throughput,
                                                     videoTransfer: false), size)
            XCTAssertEqual(transferDownloadChunkSize(effectiveSize: size, isUSBConnection: true,
                                                     preferHighThroughput: throughput, videoTransfer: false),
                           transferChunkSize)
            XCTAssertEqual(transferDownloadChunkSize(effectiveSize: size, preferHighThroughput: throughput),
                           throughput ? transferHighThroughputChunkSize : transferChunkSize)
        }
    }
}
