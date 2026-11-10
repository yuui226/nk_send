import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class JpegThumbnailFallbackTests: XCTestCase {
    private func file(_ name: String = "Z30_0395.JPG", size: UInt64 = 11_262_279, handle: UInt32 = 7) -> CameraFile {
        .init(id: handle, storageID: 1, format: 0x3801, size: size, fileName: name, captureDate: nil, isProtected: false)
    }
    private func response(_ code: UInt16 = PTPConstants.noThumbnailPresent, data: Data = Data()) -> PTPResponse {
        .init(code: code, transactionID: 1, data: data)
    }

    func testOnlySuccessfulEmptyOrMissingJPEGSchedulesABoundedRead() {
        for name in ["Z30_0395.JPG", "Z30_0395.jpeg"] {
            for code in [PTPConstants.noThumbnailPresent, PTPConstants.responseOK] {
                XCTAssertEqual(JpegThumbnailFallback.headerBytes(responseCode: code, hasThumbnail: false, file: file(name)), 128 * 1024)
                XCTAssertEqual(JpegThumbnailFallback.headerBytes(responseCode: code, hasThumbnail: true, file: file(name)), 0)
            }
        }
        for name in ["a.NEF", "a.NRW", "a.MOV", "a.MP4"] {
            XCTAssertEqual(JpegThumbnailFallback.headerBytes(responseCode: PTPConstants.noThumbnailPresent, hasThumbnail: false, file: file(name)), 0)
        }
        for code: UInt16 in [0x2009, 0x2019, 0x2005] {
            XCTAssertEqual(JpegThumbnailFallback.headerBytes(responseCode: code, hasThumbnail: false, file: file()), 0)
        }
        XCTAssertEqual(JpegThumbnailFallback.headerBytes(responseCode: 0x2010, hasThumbnail: false, file: nil), 0)
    }

    func testSmallZeroAndMaximumFileSizesCannotOverflowOrOverread() {
        for (size, expected): (UInt64, Int) in [(127, 127), (0, 0), (.max, 128 * 1024)] {
            XCTAssertEqual(JpegThumbnailFallback.headerBytes(responseCode: 0x2010, hasThumbnail: false, file: file(size: size)), expected)
        }
    }

    func testJPEGIFD1IsReadWithoutRawDimensionValidationOrMarkerGuessing() {
        for little in [false, true] {
            // Android returns the EXIF byte range even before bitmap decoding.
            let bytes = Data([1, 2, 3, 4])
            XCTAssertEqual(NEFExifThumbnail.readJPEG(jpeg(bytes, little: little)), bytes)
            let noExif = Data([255, 216, 255, 224, 0, 2]) + bytes + Data([255, 217])
            XCTAssertNil(NEFExifThumbnail.readJPEG(noExif))
        }
    }

    func testTruncatedExifOrOutOfRangeThumbnailDoesNotTriggerMoreReads() async throws {
        let full = jpeg(Data([1, 2, 3, 4]))
        for bytes in [Data(full.prefix(20)), jpeg(Data([1, 2, 3, 4]), claimedOffset: 60000)] {
            let wire = STAScriptTransport([.init(0x9431, [7, 0, 0, 128 * 1024, 0], payload: bytes)])
            let value = try await JpegThumbnailFallback.read(session: .init(transport: wire), handle: 7, file: file(), response: response())
            XCTAssertTrue(value.isEmpty)
            let commands = await wire.commands
            XCTAssertEqual(commands.count, 1)
        }
    }

    func testMissingAndSuccessfulEmptyResponseReadExactlyOnePrefix() async throws {
        let thumbnail = Data([255, 216, 1, 2, 255, 217])
        for code in [PTPConstants.noThumbnailPresent, PTPConstants.responseOK] {
            let wire = STAScriptTransport([.init(0x9431, [7, 0, 0, 128 * 1024, 0], payload: jpeg(thumbnail))])
            let value = try await JpegThumbnailFallback.read(session: .init(transport: wire), handle: 7, file: file(), response: response(code))
            XCTAssertEqual(value, thumbnail)
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testExistingThumbnailAndWrongHandleNeverReadHeader() async throws {
        let wire = STAScriptTransport([]), thumbnail = Data([1, 2, 3])
        let session = PTPSession(transport: wire)
        let existing = try await JpegThumbnailFallback.read(session: session, handle: 7, file: file(), response: response(0x2001, data: thumbnail))
        XCTAssertEqual(existing, thumbnail)
        let missing = try await JpegThumbnailFallback.read(session: session, handle: 7, file: file(handle: 8), response: response())
        XCTAssertTrue(missing.isEmpty)
        let commands = await wire.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testPartialReadRejectionAndEmptyPayloadStayMisses() async throws {
        for code: UInt16 in [0x2001, 0x2005, 0x2019] {
            let wire = STAScriptTransport([.init(0x9431, [7, 0, 0, 127, 0], response: code)])
            let value = try await JpegThumbnailFallback.read(session: .init(transport: wire), handle: 7, file: file(size: 127), response: response())
            XCTAssertTrue(value.isEmpty)
        }
    }

    func testCancelledRequestDoesNotReadHeaderOrBecomeAMiss() async throws {
        let wire = STAScriptTransport([])
        let session = PTPSession(transport: wire), file = file(), response = response()
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await JpegThumbnailFallback.read(session: session, handle: 7, file: file, response: response)
        }
        do { _ = try await work.value; XCTFail("Cancellation returned a completed miss") }
        catch { XCTAssertTrue(error is CancellationError) }
        let commands = await wire.commands
        XCTAssertTrue(commands.isEmpty)
    }

    private func jpeg(_ thumbnail: Data, little: Bool = true, claimedOffset: Int = 96) -> Data {
        var tiff = Data(repeating: 0, count: 96 + thumbnail.count)
        func put(_ at: Int, _ value: Int, _ size: Int) {
            for i in 0..<size { tiff[at + i] = UInt8(truncatingIfNeeded: value >> ((little ? i : size - 1 - i) * 8)) }
        }
        func entry(_ at: Int, _ tag: Int, _ type: Int, _ value: Int) {
            put(at, tag, 2); put(at + 2, type, 2); put(at + 4, 1, 4); put(at + 8, value, type == 3 ? 2 : 4)
        }
        tiff[0] = little ? 73 : 77; tiff[1] = tiff[0]
        put(2, 42, 2); put(4, 8, 4)
        put(8, 1, 2); entry(10, 274, 3, 1); put(22, 26, 4)
        put(26, 3, 2)
        entry(28, 259, 3, 6); entry(40, 513, 4, claimedOffset); entry(52, 514, 4, thumbnail.count)
        tiff.replaceSubrange(96..<tiff.count, with: thumbnail)
        let payload = Data([69, 120, 105, 102, 0, 0]) + tiff
        let length = payload.count + 2
        return Data([255, 216, 255, 224, 0, 4, 9, 9, 255, 225, UInt8(length >> 8), UInt8(length & 255)]) + payload + Data([255, 217])
    }
}
