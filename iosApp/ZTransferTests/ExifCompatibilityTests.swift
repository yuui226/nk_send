import XCTest
import Foundation
import ImageIO
import ZTransferShared
@testable import ZTransfer

/// Metadata-only TIFF fixtures deliberately have no pixel raster/RAW camera MakerNote.
/// These source tests must run on Mac; they do not claim sensor/codec support on Windows.
final class ExifCompatibilityTests: XCTestCase {
    private struct Tag {
        let id: UInt32
        let type: UInt32
        let data: Data
    }
    private func integer(_ value: UInt32, _ width: Int, _ little: Bool = true) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : width - $0 - 1) * 8)) })
    }
    private func text(_ id: UInt32, _ value: String) -> Tag {
        Tag(id: id, type: 2, data: Data(value.utf8) + Data([0]))
    }
    private func rational(_ id: UInt32, _ pairs: [(UInt32, UInt32)], little: Bool = true) -> Tag {
        Tag(id: id, type: 5, data: pairs.reduce(Data()) { $0 + integer($1.0, 4, little) + integer($1.1, 4, little) })
    }
    private func fixture(little: Bool = true, original: String = "2026:09:08 11:12:13",
                         latitudeReference: String = "S") -> Data {
        var bytes = Data(repeating: 0, count: 2048)
        func put(_ at: Int, _ value: UInt32, _ width: Int) {
            bytes.replaceSubrange(at..<(at + width), with: integer(value, width, little))
        }
        bytes[0] = little ? 73 : 77; bytes[1] = bytes[0]
        put(2, 42, 2); put(4, 8, 4)
        var body = 1024
        func directory(_ at: Int, _ tags: [Tag]) {
            put(at, UInt32(tags.count), 2)
            for (index, tag) in tags.enumerated() {
                let entry = at + 2 + index * 12
                put(entry, tag.id, 2); put(entry + 2, tag.type, 2)
                let width = tag.type == 3 ? 2 : tag.type == 4 ? 4 : tag.type == 5 ? 8 : 1
                put(entry + 4, UInt32(tag.data.count / width), 4)
                if tag.data.count <= 4 {
                    bytes.replaceSubrange((entry + 8)..<(entry + 8 + tag.data.count), with: tag.data)
                } else {
                    put(entry + 8, UInt32(body), 4)
                    bytes.replaceSubrange(body..<(body + tag.data.count), with: tag.data)
                    body += tag.data.count
                }
            }
        }
        directory(8, [Tag(id: 0x8769, type: 4, data: integer(256, 4, little)),
            Tag(id: 0x8825, type: 4, data: integer(512, 4, little)), text(0x0132, "2001:01:01 00:00:00")])
        directory(256, [Tag(id: 0x8827, type: 3, data: integer(64, 2, little) + integer(100, 2, little)),
            text(0xA434, " NIKKOR Z "), text(0x9003, original), text(0x9004, "2020:02:03 04:05:06"),
            rational(0x829D, [(28, 10)], little: little), rational(0x829A, [(3, 2)], little: little)])
        directory(512, [text(1, latitudeReference), rational(2, [(31, 1), (12, 1), (123456789, 10000000)], little: little),
            text(3, "E"), rational(4, [(121, 1), (30, 1), (0, 1)], little: little),
            Tag(id: 5, type: 1, data: Data([1])), rational(6, [(31, 2)], little: little)])
        return Data(bytes.prefix(body))
    }

    func testTiffHeaderHasIsoLensDateAndGpsWithoutAnImageRaster() throws {
        for little in [true, false] {
            let result = try XCTUnwrap(PreviewExifReader.metadata(header: fixture(little: little), locale: Locale(identifier: "en_US_POSIX")))
            XCTAssertEqual(result.iso, "ISO64,100"); XCTAssertEqual(result.lensModel, "NIKKOR Z")
            XCTAssertEqual(result.dateTime, "2026:09:08 11:12:13"); XCTAssertEqual(result.aperture, "f/2.8")
            XCTAssertEqual(result.shutterSpeed, "1.5s")
            XCTAssertEqual(try XCTUnwrap(result.latitude).doubleValue, -(31 + 12.0 / 60 + 12.3456789 / 3600), accuracy: 1e-12)
            XCTAssertEqual(result.longitude?.doubleValue, 121.5); XCTAssertEqual(result.altitudeMeters?.doubleValue, -15.5)
        }
    }

    func testValidatedLocalRawDescriptorDoesNotDependOnImageIoRasterAvailability() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".NEF")
        let bytes = fixture(); try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        try input.seek(toOffset: 17)
        let result = try PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: Int64(bytes.count),
            cancellation: PreviewExifReadCancellation(), locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(result?.iso, "ISO64,100"); XCTAssertEqual(result?.dateTime, "2026:09:08 11:12:13")
        XCTAssertEqual(try input.offset(), 17); XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testNonLatinAndExtensionlessNamesDoNotChangeDescriptorExifOrBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = fixture()
        for name in ["相片_日本語.NEF", "촬영_صورة.tiff", "照片没有扩展名"] {
            let url = directory.appendingPathComponent(name); try bytes.write(to: url)
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            let result = try PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: Int64(bytes.count),
                cancellation: PreviewExifReadCancellation())
            XCTAssertEqual(result?.iso, "ISO64,100"); XCTAssertEqual(result?.lensModel, "NIKKOR Z")
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testRawDateFallbackIsUnchangedAcrossRegionsAndCalendars() throws {
        for identifier in ["en_US_POSIX", "fr_FR", "zh_CN", "ar_SA"] {
            let value = try PreviewExifReader.metadata(header: fixture(original: " "), locale: Locale(identifier: identifier))
            XCTAssertEqual(value?.dateTime, "2020:02:03 04:05:06")
        }
        let french = try PreviewExifReader.metadata(header: fixture(), locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(french?.aperture, "f/2,8"); XCTAssertEqual(french?.shutterSpeed, "1,5s")
    }

    func testLowercaseRawGpsReferenceUsesOriginalFloatFallbackNotImageIoDecimal() throws {
        let result = try XCTUnwrap(PreviewExifReader.metadata(header: fixture(latitudeReference: "s")))
        let expected = -(31 + 12.0 / 60 + Double(Float(123456789) / Float(10000000)) / 3600)
        XCTAssertEqual(try XCTUnwrap(result.latitude).doubleValue, expected, accuracy: 1e-12)
    }

    func testHeaderTextTruncationKeepsOnlyAlreadyReadAttributes() throws {
        // Root's DateTime ends at 1044; EXIF ISO is inline and the following lens extends past this prefix.
        let result = try XCTUnwrap(PreviewExifReader.metadata(header: Data(fixture().prefix(1047))))
        // EXIF is visited before root DateTime; ISO is complete even if the next text body is truncated.
        XCTAssertEqual(result.iso, "ISO64,100")
        // Unvisited fields may still be supplied by ImageIO; do not infer absence from truncation.
    }

    func testInvalidFileMetadataIsNotSilentlyAcceptedAsPartialHeader() throws {
        let bytes = Data(fixture().prefix(1047))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        XCTAssertThrowsError(try PreviewExifReader.metadata(fileDescriptor: input.fileDescriptor, size: Int64(bytes.count),
            cancellation: PreviewExifReadCancellation()))
    }

    func testBooleanImageIoFieldsCannotFillAbsentRawTags() throws {
        let data = fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let reader = try PreviewExifFileReader(fileDescriptor: input.fileDescriptor, size: Int64(data.count), cancellation: PreviewExifReadCancellation())
        let raw = NativePreviewExifRationalBridge.shared.read(source: reader, size: Int64(data.count))
        let result = PreviewExifReader.metadata([kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifISOSpeedRatings as String: [999], kCGImagePropertyExifLensModel as String: "wrong embedded image",
            kCGImagePropertyExifExposureBiasValue as String: true]], rawRationals: raw)
        XCTAssertEqual(result?.iso, "ISO64,100"); XCTAssertEqual(result?.lensModel, "NIKKOR Z")
        XCTAssertNil(result?.exposureCompensation)
    }

    func testUnobservedRawExtrasKeepImageIoOnlyEmbeddedMetadata() throws {
        // Empty root IFD: the bounded walker does not know which other RAW container routes
        // ImageIO used. Missing raw fields must not erase that existing adapter fallback.
        let data = Data([73, 73, 42, 0, 8, 0, 0, 0, 0, 0])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let reader = try PreviewExifFileReader(fileDescriptor: input.fileDescriptor, size: Int64(data.count), cancellation: PreviewExifReadCancellation())
        let raw = NativePreviewExifRationalBridge.shared.read(source: reader, size: Int64(data.count))
        let result = PreviewExifReader.metadata([
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String: [800],
                kCGImagePropertyExifLensModel as String: "ImageIO lens", kCGImagePropertyExifDateTimeOriginal as String: "2026:09:08 12:00:00"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 12.5,
                kCGImagePropertyGPSLatitudeRef as String: "N", kCGImagePropertyGPSLongitude as String: 30.25,
                kCGImagePropertyGPSLongitudeRef as String: "W", kCGImagePropertyGPSAltitude as String: 50.0,
                kCGImagePropertyGPSAltitudeRef as String: 0]], rawRationals: raw)
        XCTAssertEqual(result?.iso, "ISO800"); XCTAssertEqual(result?.lensModel, "ImageIO lens")
        XCTAssertEqual(result?.dateTime, "2026:09:08 12:00:00")
        XCTAssertEqual(result?.latitude?.doubleValue, 12.5); XCTAssertEqual(result?.longitude?.doubleValue, -30.25)
        XCTAssertEqual(result?.altitudeMeters?.doubleValue, 50.0)
    }
}
