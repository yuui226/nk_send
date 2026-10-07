import Foundation
import XCTest
@testable import ZTransfer

final class VideoRatingTests: XCTestCase {
    private func box(_ type: String, _ data: Data, extended: Bool = false) -> Data {
        var result = Data()
        if extended {
            result.appendUInt32(1, littleEndian: false)
            result.append(contentsOf: Data(type.utf8))
            result.appendUInt64(UInt64(data.count + 16), littleEndian: false)
        } else {
            result.appendUInt32(UInt32(data.count + 8), littleEndian: false)
            result.append(contentsOf: Data(type.utf8))
        }
        result.append(data)
        return result
    }

    private func tag(_ stars: Int, type: UInt16 = 8, count: UInt16 = 1) -> Data {
        var result = Data(); result.appendUInt32(0x1001, littleEndian: false)
        result.appendUInt16(type, littleEndian: false); result.appendUInt16(count, littleEndian: false)
        result.appendUInt16(UInt16(bitPattern: Int16(stars)), littleEndian: false)
        return result
    }

    private func movie(_ stars: Int, padding: Int = 0, extended: Bool = false) -> Data {
        var preceding = Data(); preceding.appendUInt32(1, littleEndian: false)
        preceding.appendUInt16(2, littleEndian: false); preceding.appendUInt16(UInt16(padding), littleEndian: false)
        preceding.append(Data(repeating: 0, count: padding))
        return box("ftyp", Data(repeating: 0, count: 20)) +
            box("moov", box("udta", box("NCDT", box("NCTG", preceding + tag(stars)))), extended: extended)
    }

    func testParsesExactPathAndSignedShortNotFixedOffset() {
        for stars in -1...5 {
            for padding in [0, 18, 400, 6_000] {
                let bytes = movie(stars, padding: padding)
                XCTAssertEqual(parseNikonVideoRating(bytes, fileSize: UInt64(bytes.count)), stars)
            }
        }
        let extended = movie(5, padding: 10, extended: true)
        XCTAssertEqual(parseNikonVideoRating(extended, fileSize: UInt64(extended.count)), 5)
        XCTAssertNil(parseNikonVideoRating(movie(6)))
        XCTAssertNil(parseNikonVideoRating(box("mdat", tag(3))))
        XCTAssertNil(parseNikonVideoRating(box("moov", box("NCTG", tag(3)))))
        for bad in [tag(3, type: 3), tag(3, type: 8, count: 2)] {
            XCTAssertNil(parseNikonVideoRating(box("moov", box("udta", box("NCDT", box("NCTG", bad))))))
        }
    }

    func testBoundedPrefixAndOneSmallRemoteRead() async {
        let bytes = movie(5, padding: 5_800) + box("mdat", Data(repeating: 0, count: 30_000))
        let reader = VideoRatingReader(bytes: bytes)
        let rating = await readNikonVideoRating(fileSize: UInt64(bytes.count)) { offset, count in
            await reader.read(offset: offset, count: count)
        }
        let requestCount = await reader.requestCount
        XCTAssertEqual(rating, 5); XCTAssertEqual(requestCount, 1)
        let cached = await readNikonVideoRating(fileSize: UInt64(bytes.count), prefix: bytes.prefix(8_192)) { _, _ in
            XCTFail("cached prefix must suffice"); return nil
        }
        XCTAssertEqual(cached, 5)
        for length in [0, 7, 28, 60, 100] {
            XCTAssertNil(parseNikonVideoRating(bytes.prefix(length), fileSize: UInt64(bytes.count)))
        }
    }

    func testSkipsLargeVideoPayloadToTailMetadata() async {
        let bytes = box("ftyp", Data(repeating: 0, count: 20)) + box("mdat", Data(repeating: 0, count: 200_000)) + movie(2)
        let reader = VideoRatingReader(bytes: bytes)
        let rating = await readNikonVideoRating(fileSize: UInt64(bytes.count)) { offset, count in
            await reader.read(offset: offset, count: count)
        }
        let offsets = await reader.offsets
        XCTAssertEqual(rating, 2); XCTAssertEqual(offsets.count, 2); XCTAssertGreaterThan(offsets[1], 200_000)
    }

    func testMalformedOrTruncatedInputRemainsUnknown() async {
        XCTAssertNil(parseNikonVideoRating(Data([0, 0, 0, 4, 109, 111, 111, 118])))
        var overflow = Data(); overflow.appendUInt32(1, littleEndian: false); overflow.append(contentsOf: Data("moov".utf8)); overflow.appendUInt64(UInt64.max, littleEndian: false)
        XCTAssertNil(parseNikonVideoRating(overflow))
        let short = await readNikonVideoRating(fileSize: 100) { _, _ in Data([0]) }
        XCTAssertNil(short)
        let oversized = await readNikonVideoRating(fileSize: 100) { _, count in Data(repeating: 0, count: count + 1) }
        XCTAssertNil(oversized)
        let unknownSize = await readNikonVideoRating(fileSize: 0xFFFF_FFFF) { _, _ in nil }
        XCTAssertNil(unknownSize)
    }

    func testRemoteBudgetStopsWithoutDownloadingWholeFile() async {
        var bytes = Data()
        for _ in 0..<40 { bytes.append(box("free", Data(repeating: 0, count: 8_184))) }
        bytes.append(movie(4))
        let reader = VideoRatingReader(bytes: bytes)
        let result = await readNikonVideoRating(fileSize: UInt64(bytes.count)) { offset, count in
            await reader.read(offset: offset, count: count)
        }
        let calls = await reader.requestCount
        let total = await reader.totalBytes
        XCTAssertNil(result)
        XCTAssertEqual(calls, 32); XCTAssertEqual(total, 262_144)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16, littleEndian: Bool) {
        let value = littleEndian ? value.littleEndian : value.bigEndian
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }
    mutating func appendUInt32(_ value: UInt32, littleEndian: Bool) {
        let value = littleEndian ? value.littleEndian : value.bigEndian
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }
    mutating func appendUInt64(_ value: UInt64, littleEndian: Bool) {
        let value = littleEndian ? value.littleEndian : value.bigEndian
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }
}

private actor VideoRatingReader {
    let bytes: Data
    var offsets: [UInt64] = []
    var totalBytes = 0
    init(bytes: Data) { self.bytes = bytes }
    var requestCount: Int { offsets.count }
    func read(offset: UInt64, count: Int) -> Data? {
        offsets.append(offset); totalBytes += count
        guard offset <= UInt64(bytes.count), count <= bytes.count - Int(offset) else { return nil }
        return bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
}
