import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class PTPCodecTests: XCTestCase {
    func testCommandRoundTripPreservesLittleEndianFields() throws {
        let encoded = PTPCodec.encodeCommand(code: 0x1001, transactionID: 7, parameters: [0x11223344, 9])
        XCTAssertEqual(encoded.count, 20)
        let packet = try PTPCodec.decode(encoded)
        XCTAssertEqual(packet.type, .command)
        XCTAssertEqual(packet.code, 0x1001)
        XCTAssertEqual(packet.transactionID, 7)
        XCTAssertEqual(packet.payload, Data([0x44, 0x33, 0x22, 0x11, 9, 0, 0, 0]))
        XCTAssertEqual(try PTPCodec.decode((Data([0xAA]) + encoded).dropFirst()), packet)
    }

    func testRejectsTruncatedContainersAndLengthsSmallerThanHeader() throws {
        XCTAssertThrowsError(try PTPCodec.decode(Data(repeating: 0, count: 11))) {
            XCTAssertEqual($0 as? PTPCodecError, .truncatedHeader)
        }
        for length: [UInt8] in [[8, 0, 0, 0], [0xFF, 0xFF, 0xFF, 0xFF]] {
            XCTAssertThrowsError(try PTPCodec.decode(Data(length) + Data(repeating: 0, count: 8)))
        }
        let command = PTPCodec.encodeCommand(code: 0x1001, transactionID: 1, parameters: [7])
        XCTAssertThrowsError(try PTPCodec.decode(command.dropLast())) {
            XCTAssertEqual($0 as? PTPCodecError, .truncatedPayload(expected: 16, actual: 15))
        }
    }

    func testCommandKeepsAtMostFiveParametersLikeAndroidUSB() throws {
        let packet = try PTPCodec.decode(PTPCodec.encodeCommand(code: 0x1007, transactionID: 1, parameters: [1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(packet.payload.count, 20)
        XCTAssertEqual(packet.payload.suffix(4), Data([5, 0, 0, 0]))
    }

    func test32BitWireLengthIsNotConfusedWithInMemoryPayloadLimit() {
        var header = PTPCodec.encode(type: .data, code: 0x1009, transactionID: 1)
        header.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try PTPCodec.decode(header)) {
            XCTAssertEqual($0 as? PTPCodecError, .truncatedPayload(expected: Int(UInt32.max), actual: 12))
        }
    }

    func testRejectsUnknownContainerType() {
        var command = PTPCodec.encodeCommand(code: 0x1001, transactionID: 1)
        command[4] = 5
        XCTAssertThrowsError(try PTPCodec.decode(command)) {
            XCTAssertEqual($0 as? PTPCodecError, .invalidType(5))
        }
    }
}
