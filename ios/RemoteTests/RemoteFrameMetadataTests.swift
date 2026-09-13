import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferRemote
#else
@testable import ZTransfer
#endif

final class RemoteFrameMetadataTests: XCTestCase {
    func testAndroidDisplayInformationHeaderParsesFocusFrameAndSoundLevels() throws {
        var payload = [UInt8](repeating: 0, count: 512 + 6)
        put16(&payload, 0, 1)
        put16(&payload, 2, 0)
        put32(&payload, 8, 512)
        put32(&payload, 12, 6)
        put16(&payload, 16, 1000)
        put16(&payload, 18, 800)
        put16(&payload, 28, 500)
        put16(&payload, 30, 400)
        payload[42] = 2
        payload[44] = 1
        payload[45] = 0
        put16(&payload, 48, 200)
        put16(&payload, 50, 160)
        put16(&payload, 52, 500)
        put16(&payload, 54, 400)
        payload[388..<392] = [14, 12, 9, 7]
        payload[512..<518] = [0xFF, 0xD8, 0x00, 0x01, 0xFF, 0xD9]

        let metadata = try XCTUnwrap(RemoteFrameParser.metadata(
            from: Data(payload), jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx
        ))
        XCTAssertEqual(metadata.focusJudgement, .focused)
        let frame = try XCTUnwrap(metadata.selectedFocusFrame)
        XCTAssertEqual(frame.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(frame.centerY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(frame.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(metadata.soundLevels, RemoteLiveViewSoundLevels(
            peakLeft: 14, peakRight: 12, currentLeft: 9, currentRight: 7
        ))
    }

    func testUnknownHeaderAndOutOfRangeSoundLevelsAreRejected() {
        var payload = [UInt8](repeating: 0, count: 512 + 6)
        put16(&payload, 0, 1)
        put32(&payload, 8, 512)
        put32(&payload, 12, 6)
        put16(&payload, 16, 1000)
        put16(&payload, 18, 800)
        payload[42] = 2
        payload[44] = 1
        payload[45] = 0
        put16(&payload, 48, 200)
        put16(&payload, 50, 160)
        put16(&payload, 52, 500)
        put16(&payload, 54, 400)
        payload[388] = 15
        payload[512..<518] = [0xFF, 0xD8, 0x00, 0x01, 0xFF, 0xD9]
        XCTAssertNil(RemoteFrameParser.metadata(
            from: Data(payload), jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx
        ))
        XCTAssertNil(RemoteFrameParser.metadata(
            from: Data(payload), jpegOffset: 512, operation: PTPConstants.getLiveViewImage
        ))
    }

    private func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}
