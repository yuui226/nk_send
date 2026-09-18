import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class PTPIPCodecTests: XCTestCase {
    func testSignedUnknownDownloadDeclarationsMatchAndroid() throws {
        // NikonCamera.pump reads the 64-bit field as signed Long. A negative
        // declaration is not a positive expected length (including all-ones).
        for declaration in [UInt64.max, UInt64.max - 1, UInt64(Int64.max) + 1] {
            for borrowed in [false, true] {
                var phase = PTPIPDownloadPhase(transactionID: 7)
                let sink = PTPDataSink(started: { XCTAssertNil($0) }, received: { XCTAssertEqual($0, Data([1, 2, 3])) })
                let start = Data(UInt32(7).littleEndianBytes + declaration.littleEndianBytes)
                if borrowed {
                    XCTAssertNil(try start.withUnsafeBytes { try phase.consume(type: .startData, payload: $0, sink: sink) })
                } else {
                    XCTAssertNil(try phase.consume(.init(type: .startData, payload: start), sink: sink))
                }
                let end = Data(UInt32(7).littleEndianBytes + [1, 2, 3])
                XCTAssertNil(try phase.consume(.init(type: .endData, payload: end), sink: sink))
                let response = Data(UInt16(0x2001).littleEndianBytes + UInt32(7).littleEndianBytes)
                let result = try XCTUnwrap(phase.consume(.init(type: .commandResponse, payload: response), sink: sink))
                XCTAssertEqual(result.receivedByteCount, 3)
                XCTAssertNil(result.declaredByteCount)
            }
        }
    }

    func testNonnegativeDownloadDeclarationsRetainAndroidValidationBoundaries() throws {
        // Do not erase the separate 32-bit SIZE_UNKNOWN marker: Android's
        // full-object and partial-object paths intentionally check it differently.
        for declaration in [UInt64(0), 3, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64(Int64.max)] {
            var phase = PTPIPDownloadPhase(transactionID: 7)
            let sink = PTPDataSink(started: { XCTAssertEqual($0, declaration) }, received: { _ in })
            let start = Data(UInt32(7).littleEndianBytes + declaration.littleEndianBytes)
            XCTAssertNil(try phase.consume(.init(type: .startData, payload: start), sink: sink))
            XCTAssertEqual(phase.declaredByteCount, declaration)
        }
        var phase = PTPIPDownloadPhase(transactionID: 7)
        let sink = PTPDataSink(started: { XCTAssertEqual($0, UInt64(UInt32.max)) }, received: { _ in })
        let shortStart = Data(UInt32(7).littleEndianBytes + UInt32.max.littleEndianBytes)
        XCTAssertNil(try phase.consume(.init(type: .startData, payload: shortStart), sink: sink))
        XCTAssertEqual(phase.declaredByteCount, UInt64(UInt32.max))
    }

    func testBorrowedPhaseRejectsTruncatedAndMismatchedDataBeforeCallingSink() throws {
        var phase = PTPIPDownloadPhase(transactionID: 7)
        let sink = PTPDataSink(started: { _ in }, received: { _ in XCTFail("Invalid bytes escaped") },
                               receivedBorrowed: { _ in XCTFail("Invalid borrowed bytes escaped") })
        for payload in [Data([7, 0, 0]), Data([8, 0, 0, 0, 1])] {
            XCTAssertThrowsError(try payload.withUnsafeBytes {
                try phase.consume(type: .data, payload: $0, sink: sink)
            }) { XCTAssertEqual($0 as? PTPSessionError, .invalidResponse) }
        }
        XCTAssertEqual(phase.receivedByteCount, 0)
    }

    func testBorrowedDataHasNoTransactionPrefixAndWaitsForResponse() throws {
        var phase = PTPIPDownloadPhase(transactionID: 7)
        let sink = PTPDataSink(started: { _ in }, received: { _ in XCTFail("Unexpected owned payload") },
                               receivedBorrowed: { XCTAssertEqual(Data($0), Data([9, 8])) })
        let packet = Data([7, 0, 0, 0, 9, 8])
        XCTAssertNil(try packet.withUnsafeBytes { try phase.consume(type: .endData, payload: $0, sink: sink) })
        XCTAssertEqual(phase.receivedByteCount, 2)
        let response = Data([1, 0x20, 7, 0, 0, 0])
        let completed = try response.withUnsafeBytes { try phase.consume(type: .commandResponse, payload: $0, sink: sink) }
        XCTAssertEqual(completed?.receivedByteCount, 2)
    }

    func testPacketLimitAcceptsAndroidHighThroughputChunkWithFraming() {
        XCTAssertEqual(PTPIPCodec.maxPacketLength, 256 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(PTPIPCodec.maxPacketLength, 64 * 1024 * 1024 + 12)
    }

    func testStreamingReadWindowCoalescesHeaderAndAllowsLargeBodyChunks() {
        let header = ptpipReadWindow(remaining: 8, coalesce: false)
        XCTAssertEqual(header.minimum, 1)
        XCTAssertEqual(header.maximum, 64 * 1024)
        let body = ptpipReadWindow(remaining: 12 * 1024 * 1024, coalesce: false)
        XCTAssertEqual(body.minimum, 1)
        XCTAssertEqual(body.maximum, 4 * 1024 * 1024)
        let ordinary = ptpipReadWindow(remaining: 128 * 1024, coalesce: true)
        XCTAssertEqual(ordinary.minimum, 64 * 1024)
        XCTAssertEqual(ordinary.maximum, 64 * 1024)
    }
    func testDownloadPhaseConsumesEndDataThenCommandResponseAndRetainsDeclaration() throws {
        let sink = PTPDataSink(started: { _ in }, received: { _ in })
        var phase = PTPIPDownloadPhase(transactionID: 7)
        let start = Data(UInt32(7).littleEndianBytes + UInt64(6).littleEndianBytes)
        XCTAssertNil(try phase.consume(PTPIPPacket(type: .startData, payload: start), sink: sink))
        let end = Data(UInt32(7).littleEndianBytes + [1, 2, 3])
        XCTAssertNil(try phase.consume(PTPIPPacket(type: .endData, payload: end), sink: sink))
        let response = Data(UInt16(0x2001).littleEndianBytes + UInt32(7).littleEndianBytes)
        let completed = try XCTUnwrap(phase.consume(PTPIPPacket(type: .commandResponse, payload: response), sink: sink))
        XCTAssertEqual(completed.receivedByteCount, 3)
        XCTAssertEqual(completed.declaredByteCount, 6)
    }

    func testDrainBudgetCountsWholePayloadsAndIgnoresPing() throws {
        var budget = PTPIPDrainBudget(maximum: 20)
        XCTAssertFalse(try budget.consume(.init(type: .startData, payload: Data(repeating: 0, count: 12))))
        XCTAssertFalse(try budget.consume(.init(type: .data, payload: Data(repeating: 0, count: 8))))
        XCTAssertFalse(try budget.consume(.init(type: .ping, payload: Data(repeating: 0, count: 100))))
        XCTAssertEqual(budget.drained, 20)
        XCTAssertTrue(try budget.consume(.init(type: .commandResponse, payload: Data(repeating: 0, count: 6))))
    }

    func testDrainRejectsAnotherPacketAfterBudgetIsExceeded() throws {
        var budget = PTPIPDrainBudget(maximum: 8)
        XCTAssertThrowsError(try budget.consume(.init(type: .endData, payload: Data(repeating: 0, count: 9))))
        XCTAssertTrue(budget.exceeded)
        XCTAssertThrowsError(try budget.consume(.init(type: .commandResponse, payload: Data())))
    }

    func testDownloadPhaseRejectsMismatchedStartAndResponseTransaction() throws {
        let sink = PTPDataSink(started: { _ in }, received: { _ in })
        var phase = PTPIPDownloadPhase(transactionID: 7)
        let start = Data(UInt32(8).littleEndianBytes + UInt64(6).littleEndianBytes)
        XCTAssertThrowsError(try phase.consume(PTPIPPacket(type: .startData, payload: start), sink: sink))
        let response = Data(UInt16(0x2001).littleEndianBytes + UInt32(8).littleEndianBytes)
        XCTAssertThrowsError(try phase.consume(PTPIPPacket(type: .commandResponse, payload: response), sink: sink))
    }
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

    func testCancelRequestContainsOnlyTheActiveTransactionID() throws {
        let packet = try PTPIPCodec.decode(try PTPIPCodec.cancelRequest(transactionID: 0xA1B2C3D4))
        XCTAssertEqual(packet.type, .cancel)
        XCTAssertEqual(packet.payload.count, 4)
        XCTAssertEqual(packet.payload.readUInt32LE(at: 0), 0xA1B2C3D4)
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

    func testSplitHeaderAndBodyDecodeWithoutRejoiningPacket() throws {
        let body = Data([4, 3, 2, 1, 9, 8, 7])
        var header = Data()
        header.append(contentsOf: UInt32(PTPIPCodec.headerSize + body.count).littleEndianBytes)
        header.append(contentsOf: PTPIPPacketType.data.rawValue.littleEndianBytes)
        let packet = try PTPIPCodec.decode(header: header, body: body)
        XCTAssertEqual(packet, PTPIPPacket(type: .data, payload: body))

        XCTAssertThrowsError(try PTPIPCodec.decode(header: header, body: body.dropLast()))
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
