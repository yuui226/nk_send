import XCTest
@testable import ZTransfer

final class PhotoRatingPairsTests: XCTestCase {
    private func file(_ id: UInt32, _ name: String, date: String? = "20260929T120000", card: UInt32 = 1) -> CameraFile {
        CameraFile(id: id, storageID: card, format: 0x3801, size: 100,
                   fileName: name, captureDate: date, isProtected: false,
                   storageIDs: [card])
    }

    func testUniquePairUsesJPEGEvenWhenRawComesFirst() {
        let raw = file(1, "Z30_9049.NEF")
        let jpeg = file(2, "z30_9049.jpg")
        let sources = photoRatingSources([raw, jpeg])
        XCTAssertEqual(sources[1], jpeg)
        XCTAssertEqual(sources[2], jpeg)
    }

    func testUniquePairAlsoProjectsJPEGRatingToNRW() {
        let raw = file(1, "Z30_9049.NRW")
        let jpeg = file(2, "Z30_9049.JPG")
        XCTAssertEqual(photoRatingSources([raw, jpeg])[1], jpeg)
    }

    func testUnmatchedDifferentCardDateOrAmbiguousRawStaysIndependent() {
        let raw = file(1, "Z30_9049.NEF")
        let cases: [[CameraFile]] = [
            [],
            [file(2, "Z30_9049.JPG", card: 2)],
            [file(2, "Z30_9049.JPG", date: "20260928T120000")],
            [file(2, "Z30_9049.JPG"), file(3, "Z30_9049.JPEG")],
        ]
        for others in cases { XCTAssertEqual(photoRatingSources([raw] + others)[1], raw) }
    }

    func testLateJPEGChangesSourceAndRemovalRestoresRaw() {
        let raw = file(1, "Z30_9049.NEF", date: nil)
        let jpeg = file(2, "Z30_9049.JPG")
        XCTAssertEqual(photoRatingSources([raw])[1], raw)
        XCTAssertEqual(photoRatingSources([raw, jpeg])[1], jpeg)
        XCTAssertEqual(photoRatingSources([raw])[1], raw)
    }
}
