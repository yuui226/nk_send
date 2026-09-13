import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class PTPIPCodecTests: XCTestCase {
    func testCommandRequestWrapsStandardPTPContainer() throws {
        let command = PTPCodec.encodeCommand(code: 0x1002, transactionID: 7, parameters: [1])
        let packet = try PTPIPCodec.decode(try PTPIPCodec.commandRequest(from: command))
        XCTAssertEqual(packet.type, .commandRequest)
        XCTAssertEqual(packet.payload.readUInt32LE(at: 0), 1)
        XCTAssertEqual(packet.payload.readUInt16LE(at: 4), 0x1002)
        XCTAssertEqual(packet.payload.readUInt32LE(at: 6), 7)
        XCTAssertEqual(packet.payload.readUInt32LE(at: 10), 1)
    }

    func testSTAIdentityAndVersionMatchAndroidWhileAPStaysSeparate() throws {
        let id = Data("0123456789abcdef".utf8)
        let sta = try PTPIPCodec.decode(PTPIPCodec.staInitCommandRequest(initiatorID: id))
        XCTAssertEqual(sta.payload.prefix(16), id)
        XCTAssertEqual(sta.payload.subdata(in: 16..<36), "ZTransfer\0".data(using: .utf16LittleEndian))
        XCTAssertEqual(sta.payload.suffix(4), Data([0, 0, 1, 0]))
        XCTAssertEqual(sta.payload.count, 40)
        let ap = try PTPIPCodec.decode(PTPIPCodec.initCommandRequest(guid: id))
        XCTAssertEqual(ap.payload.suffix(2), Data([1, 0]))
        XCTAssertEqual(ap.payload.count, 36)
    }

    func testResponseContainerLengthIncludesLengthAndTypeFields() throws {
        let payload = Data([1, 0x20, 7, 0, 0, 0])
        let container = try PTPIPCodec.commandResponseContainer(payload)
        XCTAssertEqual(container.count, 12)
        let response = try PTPCodec.decode(container)
        XCTAssertEqual(response.code, 0x2001)
        XCTAssertEqual(response.transactionID, 7)
        XCTAssertEqual(response.type, .response)
    }

    func testRejectsLengthMismatchAndUnknownType() throws {
        XCTAssertThrowsError(try PTPIPCodec.decode(Data(repeating: 0, count: 8)))
        var unknown = Data(); unknown.append(contentsOf: UInt32(8).littleEndianBytes); unknown.append(contentsOf: UInt32(99).littleEndianBytes)
        XCTAssertThrowsError(try PTPIPCodec.decode(unknown)) { error in
            XCTAssertEqual(error as? PTPIPCodecError, .unsupportedPacketType(99))
        }
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func readUInt32LE(at offset: Int) -> UInt32 { UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24 }
}
private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}
