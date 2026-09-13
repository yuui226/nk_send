import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class PTPDatasetTests: XCTestCase {
    func testDeviceInfoReadsFunctionalModeAndEveryCapabilityArray() throws {
        let info = try XCTUnwrap(PTPDatasetParser.parseDeviceInfo(deviceInfoFixture()))
        XCTAssertEqual(info.standardVersion, 100)
        XCTAssertEqual(info.vendorExtensionID, 10)
        XCTAssertEqual(info.vendorExtensionVersion, 100)
        XCTAssertEqual(info.vendorExtensionDescription, "Nikon")
        XCTAssertEqual(info.functionalMode, 1)
        XCTAssertEqual(info.operations, [0x1001, 0x1002, 0x9431])
        XCTAssertEqual(info.events, [0x4002, 0x4003])
        XCTAssertEqual(info.properties, [0x5001])
        XCTAssertEqual(info.captureFormats, [0x3801])
        XCTAssertEqual(info.imageFormats, [0x3801, 0xB101])
        XCTAssertEqual(info.manufacturer, "Nikon")
        XCTAssertEqual(info.model, "Z 30")
        XCTAssertEqual(info.version, "1.20")
        XCTAssertEqual(info.serialNumber, "1234567")
    }

    func testDeviceInfoRejectsEveryTruncatedPrefix() {
        let data = deviceInfoFixture()
        for length in 0..<data.count {
            XCTAssertNil(PTPDatasetParser.parseDeviceInfo(data.prefix(length)), "prefix \(length)")
        }
    }

    func testReaderAcceptsUnalignedIntegersAndNonzeroDataStartIndex() throws {
        let payload = deviceInfoFixture()
        let slice = (Data([0xAA]) + payload).dropFirst()
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(PTPDatasetParser.parseDeviceInfo(slice), PTPDatasetParser.parseDeviceInfo(payload))
        var reader = PTPDataReader(Data([0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12]))
        XCTAssertTrue(reader.skipBytes(count: 1))
        XCTAssertEqual(reader.readUInt64(), 0x129078563412EFCD)
        XCTAssertNil(reader.readUInt16())
    }

    func testCountsAreCheckedBeforeAllocatingOrReading() {
        var handles = Data()
        handles.appendLE(UInt32(2))
        handles.appendLE(UInt32(0x12345678))
        handles.appendLE(UInt32.max)
        XCTAssertEqual(PTPDatasetParser.readObjectHandles(handles), [0x12345678, UInt32.max])
        XCTAssertEqual(PTPDatasetParser.readStorageIDs(Data([0, 0, 0, 0])), [])
        for data in [Data(), Data([1, 0, 0, 0]), Data(repeating: 0xFF, count: 4), handles.dropLast()] {
            XCTAssertNil(PTPDatasetParser.readObjectHandles(data))
        }
    }

    func testObjectInfoUsesFilenameAtOffset52AndUnsignedSize() throws {
        let result = PTPDatasetParser.parseObjectInfoResult(handle: 7, objectInfoFixture(size: UInt32.max))
        let file = try XCTUnwrap(result.file)
        XCTAssertTrue(result.successful)
        XCTAssertEqual(file.storageID, 0x00020001)
        XCTAssertEqual(file.format, 0x3801)
        XCTAssertEqual(file.size, 0xFFFFFFFF)
        XCTAssertTrue(file.isProtected)
        XCTAssertEqual(file.fileName, "DSC_0007.JPG")
        XCTAssertEqual(file.captureDate, "20260812T120000")
        XCTAssertEqual(file.fileExtension, ".jpg")
    }

    func testDirectoryIsSuccessfulButNeverBecomesAPhoto() {
        let result = PTPDatasetParser.parseObjectInfoResult(handle: 7, objectInfoFixture(format: 0x3001))
        XCTAssertTrue(result.successful)
        XCTAssertNil(result.file)
    }

    // These cases mirror Android ObjectInfoCacheIdentityTest, including preserving
    // display fallback while refusing to mark an incomplete identity cache-safe.
    func testExplicitlyEmptyDateIsComplete() {
        let result = PTPDatasetParser.parseObjectInfoResult(handle: 7, objectInfoFixture(date: nil))
        XCTAssertTrue(result.successful)
        XCTAssertNil(result.file?.captureDate)
    }

    func testTruncatedFilenameUsesLow16BitHandleAndFormatFallback() {
        var data = objectInfoFixture(format: 0x300D).prefix(55)
        data[52] = 8
        let result = PTPDatasetParser.parseObjectInfoResult(handle: 0x10007, data)
        XCTAssertFalse(result.successful)
        XCTAssertEqual(result.file?.fileName, "DSC_0007.mov")
        XCTAssertNil(result.file?.captureDate)
    }

    func testTruncatedOrUnterminatedDateKeepsNameButIsIncomplete() {
        var unterminated = objectInfoFixture()
        unterminated[unterminated.count - 1] = 0x58
        for data in [objectInfoFixture().dropLast(4), unterminated, objectInfoFixture(date: "2026")] {
            let result = PTPDatasetParser.parseObjectInfoResult(handle: 7, data)
            XCTAssertFalse(result.successful)
            XCTAssertEqual(result.file?.fileName, "DSC_0007.JPG")
            XCTAssertNil(result.file?.captureDate)
        }
    }

    func testEmptyNameFallsBackAndTooShortPrefixIsRejected() {
        let result = PTPDatasetParser.parseObjectInfoResult(handle: 42, objectInfoFixture(name: "", format: 0xB803))
        XCTAssertFalse(result.successful)
        XCTAssertEqual(result.file?.fileName, "DSC_0042.cr3")
        for length in 0..<53 {
            let result = PTPDatasetParser.parseObjectInfoResult(handle: 7, objectInfoFixture().prefix(length))
            XCTAssertFalse(result.successful)
            XCTAssertNil(result.file)
        }
    }

    func testActualFilenameDeterminesExtensionEvenForUnknownFormat() {
        let result = PTPDatasetParser.parseObjectInfo(handle: 7, objectInfoFixture(name: "DSC_0007.NEF", format: 0xFFFF))
        XCTAssertEqual(result?.fileExtension, ".nef")
        XCTAssertEqual(PTPDatasetParser.parseObjectInfo(handle: 7, objectInfoFixture(name: "FILE"))?.fileExtension, "")
        XCTAssertEqual(PTPDatasetParser.parseObjectInfo(handle: 7, objectInfoFixture(name: "FILE."))?.fileExtension, ".")
    }
}

private func deviceInfoFixture() -> Data {
    // RemoteLab.parseDeviceInfo: versions, vendor description, functional mode,
    // operations/events/properties/capture formats/image formats, then four strings.
    var data = Data()
    data.appendLE(UInt16(100)); data.appendLE(UInt32(10)); data.appendLE(UInt16(100))
    data.appendPTPString("Nikon"); data.appendLE(UInt16(1))
    for codes: [UInt16] in [[0x1001, 0x1002, 0x9431], [0x4002, 0x4003], [0x5001], [0x3801], [0x3801, 0xB101]] {
        data.appendLE(UInt32(codes.count))
        codes.forEach { data.appendLE($0) }
    }
    ["Nikon", "Z 30", "1.20", "1234567"].forEach { data.appendPTPString($0) }
    return data
}

private func objectInfoFixture(
    name: String = "DSC_0007.JPG", date: String? = "20260812T120000",
    format: UInt16 = 0x3801, size: UInt32 = 123456
) -> Data {
    var data = Data()
    data.appendLE(UInt32(0x00020001)); data.appendLE(format)
    data.appendLE(UInt16(1)); data.appendLE(size)
    // Nonzero unused fields catch accidentally parsing one as a string count.
    data.append(Data(repeating: 0xAA, count: 40))
    data.appendPTPString(name)
    if let date { data.appendPTPString(date) } else { data.append(0) }
    return data
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendPTPString(_ value: String) {
        append(UInt8(value.utf16.count + 1))
        value.utf16.forEach { appendLE($0) }
        appendLE(UInt16(0))
    }
}
