import Foundation
import XCTest
@testable import ZTransfer

final class RatingProtocolReplayTests: XCTestCase {
    private func file(_ handle: UInt32, _ name: String, size: UInt64 = 1) -> CameraFile {
        CameraFile(id: handle, storageID: 1, format: 0x3801, size: size,
                   fileName: name, captureDate: "20261007T120000", isProtected: false)
    }

    private func tiff(_ rating: UInt16) -> Data {
        var data = Data([73, 73])
        data.appendUInt16(42, littleEndian: true)
        data.appendUInt32(8, littleEndian: true)
        data.appendUInt16(1, littleEndian: true)
        data.appendUInt16(0x4746, littleEndian: true)
        data.appendUInt16(3, littleEndian: true)
        data.appendUInt32(1, littleEndian: true)
        data.appendUInt16(rating, littleEndian: true)
        data.appendUInt16(0, littleEndian: true)
        data.appendUInt32(0, littleEndian: true)
        return data
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        var result = Data()
        result.appendUInt32(UInt32(payload.count + 8), littleEndian: false)
        result.append(contentsOf: Data(type.utf8))
        result.append(payload)
        return result
    }

    private func video(_ stars: Int) -> Data {
        var tag = Data()
        tag.appendUInt32(0x1001, littleEndian: false)
        tag.appendUInt16(8, littleEndian: false)
        tag.appendUInt16(1, littleEndian: false)
        tag.appendUInt16(UInt16(bitPattern: Int16(stars)), littleEndian: false)
        return atom("ftyp", Data(repeating: 0, count: 20)) +
            atom("moov", atom("udta", atom("NCDT", atom("NCTG", tag))))
    }

    func testObjectPropertyUsesAndroidOperationAndWireProperty() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue,
                  [7, PTPConstants.objectPropRating], payload: Data([99, 0]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let result = try await repository.readObjectRating(file: file(7, "DSC_0007.JPG"))
        XCTAssertEqual(result, 5)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testObjectPropertyUnsupportedIsLatchedForTheConnection() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue,
                  [8, PTPConstants.objectPropRating], response: PTPConstants.operationNotSupported)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let first = try await repository.readObjectRating(file: file(8, "DSC_0008.JPG"))
        let second = try await repository.readObjectRating(file: file(9, "DSC_0009.JPG"))
        XCTAssertNil(first)
        XCTAssertNil(second)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testBusyObjectPropertyRemainsRetryable() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue,
                  [10, PTPConstants.objectPropRating], response: PTPConstants.deviceBusy),
            .init(PTPConstants.getObjectPropValue,
                  [10, PTPConstants.objectPropRating], payload: Data([50, 0]))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        do {
            _ = try await repository.readObjectRating(file: file(10, "DSC_0010.JPG"))
            XCTFail("DeviceBusy must be surfaced to the scan")
        } catch let error as CameraRepositoryError {
            XCTAssertEqual(error, .ratingReadDeferred)
        }
        let result = try await repository.readObjectRating(file: file(10, "DSC_0010.JPG"))
        XCTAssertEqual(result, 3)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHeaderFallsBackToStandardPartialObjectAfterNikonUnsupported() async throws {
        let bytes = tiff(4)
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [11, 0, 0, 102_400, 0],
                  response: PTPConstants.operationNotSupported),
            .init(PTPConstants.getPartialObject, [11, 0, 102_400], payload: bytes)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let result = try await repository.readPhotoRatingHeader(file: file(11, "DSC_0011.NEF"))
        XCTAssertEqual(result, 4)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testRawObjectPropertyMissLatchesExtensionAndUsesHeaderForFollowingRaws() async throws {
        let bytes = tiff(1)
        let wire = STAScriptTransport([
            .init(PTPConstants.getObjectPropValue, [15, PTPConstants.objectPropRating],
                  response: 0xA80A),
            .init(PTPConstants.getPartialObjectEx, [15, 0, 0, 102_400, 0], payload: bytes),
            .init(PTPConstants.getPartialObjectEx, [16, 0, 0, 102_400, 0], payload: bytes)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let first = try await repository.readObjectOrRawHeaderRating(file: file(15, "DSC_0015.NEF"))
        let second = try await repository.readObjectOrRawHeaderRating(file: file(16, "DSC_0016.NEF"))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHeaderExtendsContiguousPrefixWithoutRepeatingFirstRead() async throws {
        let bytes = tiff(2)
        let split = bytes.prefix(8)
        let tail = bytes.dropFirst(8)
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [12, 0, 0, 102_400, 0], payload: Data(split)),
            .init(PTPConstants.getPartialObjectEx, [12, 8, 0, 8_192, 0], payload: Data(tail))
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let result = try await repository.readPhotoRatingHeader(file: file(12, "DSC_0012.NEF"))
        XCTAssertEqual(result, 2)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testVideoReaderUsesNikonPartialWindowsAndNCTGPath() async throws {
        let bytes = video(5)
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx,
                  [13, 0, 0, UInt32(bytes.count), 0], payload: bytes)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let result = try await repository.readVideoRating(file: file(13, "CLIP_0013.MOV", size: UInt64(bytes.count)))
        XCTAssertEqual(result, 5)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testHeaderUnsupportedLatchesBothPartialOperations() async throws {
        let wire = STAScriptTransport([
            .init(PTPConstants.getPartialObjectEx, [14, 0, 0, 102_400, 0],
                  response: PTPConstants.operationNotSupported),
            .init(PTPConstants.getPartialObject, [14, 0, 102_400],
                  response: PTPConstants.operationNotSupported)
        ])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let first = try await repository.readPhotoRatingHeader(file: file(14, "DSC_0014.NEF"))
        let second = try await repository.readPhotoRatingHeader(file: file(14, "DSC_0014.NEF"))
        XCTAssertNil(first)
        XCTAssertNil(second)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16, littleEndian: Bool) {
        var value = littleEndian ? value.littleEndian : value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32, littleEndian: Bool) {
        var value = littleEndian ? value.littleEndian : value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
