import Foundation
import XCTest
@testable import ZTransfer

final class PhotoRatingTests: XCTestCase {
    private func tiff(_ rating: Int, littleEndian: Bool) -> Data {
        var data = Data()
        data.append(contentsOf: littleEndian ? [73, 73] : [77, 77])
        data.appendUInt16(42, littleEndian: littleEndian)
        data.appendUInt32(8, littleEndian: littleEndian)
        data.appendUInt16(1, littleEndian: littleEndian)
        data.appendUInt16(0x4746, littleEndian: littleEndian)
        data.appendUInt16(3, littleEndian: littleEndian)
        data.appendUInt32(1, littleEndian: littleEndian)
        data.appendUInt16(UInt16(truncatingIfNeeded: rating), littleEndian: littleEndian)
        data.appendUInt16(0, littleEndian: littleEndian)
        data.appendUInt32(0, littleEndian: littleEndian)
        return data
    }

    private func jpeg(_ payload: Data) -> Data {
        var result = Data([0xFF, 0xD8, 0xFF, 0xE1])
        result.appendUInt16(UInt16(payload.count + 2), littleEndian: false)
        result.append(payload)
        result.append(contentsOf: [0xFF, 0xD9])
        return result
    }

    func testObjectRatingUsesExactVerifiedMapping() {
        for (stars, raw) in [0, 1, 25, 50, 75, 99].enumerated() {
            XCTAssertEqual(parseNikonObjectRating(Data([UInt8(raw), 0])), stars)
        }
        for raw in [2, 20, 40, 60, 80, 100, 255, 65_535] {
            XCTAssertNil(parseNikonObjectRating(Data([UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF)])))
        }
        XCTAssertNil(parseNikonObjectRating(Data([25])))
        XCTAssertNil(parseNikonObjectRating(Data([25, 0, 0, 0])))
    }

    func testStandardTiffAndJpegPreserveExactStarsAndUnknown() {
        for littleEndian in [true, false] {
            for rating in 0...5 {
                let bytes = tiff(rating, littleEndian: littleEndian)
                XCTAssertEqual(parsePhotoRating(bytes), rating)
                XCTAssertEqual(parsePhotoRating(jpeg(Data([69, 120, 105, 102, 0, 0]) + bytes)), rating)
                for length in 0..<22 { XCTAssertNil(parsePhotoRating(bytes.prefix(length))) }
            }
            XCTAssertNil(parsePhotoRating(tiff(65_535, littleEndian: littleEndian)))
            XCTAssertNil(parsePhotoRating(tiff(99, littleEndian: littleEndian)))
        }
    }

    func testXMPSupportsAttributeElementAliasAndRejectsUnknown() {
        let prefix = "http://ns.adobe.com/xap/1.0/\u{0}"
        for rating in -1...5 {
            let packet = "<rdf:Description xmlns:q='http://ns.adobe.com/xap/1.0/' q:Rating='\(rating)'/>"
            XCTAssertEqual(parsePhotoRating(jpeg(Data((prefix + packet).utf8))), rating)
            let element = "<rdf:Description xmlns:q='http://ns.adobe.com/xap/1.0/'><q:Rating>\(rating)</q:Rating></rdf:Description>"
            XCTAssertEqual(parsePhotoRating(jpeg(Data((prefix + element).utf8))), rating)
        }
        XCTAssertNil(parsePhotoRating(jpeg(Data((prefix + "<xmp:Rating>3</xmp:Rating>").utf8))))
        XCTAssertNil(parsePhotoRating(Data([1, 2, 3])))
    }

    func testMalformedOffsetsCannotEscapeBoundedHeader() {
        var bytes = tiff(3, littleEndian: true)
        bytes.replaceSubrange(4..<8, with: Data([0xFF, 0xFF, 0xFF, 0x7F]))
        XCTAssertNil(parsePhotoRating(bytes))
    }

    func testNEFXMPIsReadOnlyWhenPacketIsWithinCapturedBytes() {
        let packet = Data("<r xmlns:xmp='http://ns.adobe.com/xap/1.0/' xmp:Rating='4'/>".utf8)
        var bytes = Data()
        bytes.append(contentsOf: [73, 73]); bytes.appendUInt16(42, littleEndian: true)
        bytes.appendUInt32(8, littleEndian: true); bytes.appendUInt16(1, littleEndian: true)
        bytes.appendUInt16(700, littleEndian: true); bytes.appendUInt16(1, littleEndian: true)
        bytes.appendUInt32(UInt32(packet.count), littleEndian: true); bytes.appendUInt32(26, littleEndian: true)
        bytes.appendUInt32(0, littleEndian: true); bytes.append(packet)
        XCTAssertEqual(parsePhotoRating(bytes), 4)
        XCTAssertNil(parsePhotoRating(bytes.dropLast()))
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
}
