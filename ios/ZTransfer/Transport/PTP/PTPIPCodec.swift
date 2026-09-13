import Foundation

/// PTP/IP framing used by Nikon's command and event sockets.  The codec is
/// deliberately transport-agnostic so discovery and socket lifecycle can be
/// tested without a camera or a live network.
enum PTPIPPacketType: UInt32, Sendable {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case commandRequest = 6
    case commandResponse = 7
    case event = 8
    case startData = 9
    case data = 10
    case cancel = 11
    case endData = 12
    case ping = 13
    case pong = 14
}

struct PTPIPPacket: Equatable, Sendable {
    let type: PTPIPPacketType
    let payload: Data
}

enum PTPIPCodecError: Error, Equatable, Sendable {
    case malformedLength
    case unsupportedPacketType(UInt32)
    case packetTooLarge
    case malformedCommand
}

enum PTPIPCodec {
    static let headerSize = 8
    static let maxPacketLength = 64 * 1024 * 1024

    static func encode(type: PTPIPPacketType, payload: Data = Data()) throws -> Data {
        let length = headerSize + payload.count
        guard length >= headerSize else { throw PTPIPCodecError.malformedLength }
        guard length <= maxPacketLength else { throw PTPIPCodecError.packetTooLarge }
        var data = Data(capacity: length)
        data.append(contentsOf: UInt32(length).littleEndianBytes)
        data.append(contentsOf: type.rawValue.littleEndianBytes)
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) throws -> PTPIPPacket {
        guard data.count >= headerSize else { throw PTPIPCodecError.malformedLength }
        let length = data.readUInt32LE(at: 0)
        guard length >= headerSize, length <= maxPacketLength, Int(length) == data.count else {
            throw PTPIPCodecError.malformedLength
        }
        let rawType = data.readUInt32LE(at: 4)
        guard let type = PTPIPPacketType(rawValue: rawType) else { throw PTPIPCodecError.unsupportedPacketType(rawType) }
        return PTPIPPacket(type: type, payload: data.subdata(in: headerSize..<data.count))
    }

    /// Nikon's INIT_COMMAND_REQUEST: GUID + UTF-16LE host name + protocol version.
    static func initCommandRequest(hostName: String = "NikonPTP", guid: Data = UUID().uuidData) throws -> Data {
        guard guid.count == 16 else { throw PTPIPCodecError.malformedCommand }
        var name = Data(hostName.utf16.flatMap { $0.littleEndianBytes })
        name.append(contentsOf: [0, 0])
        var payload = Data()
        payload.append(guid)
        payload.append(name)
        payload.append(contentsOf: UInt16(1).littleEndianBytes)
        return try encode(type: .initCommandRequest, payload: payload)
    }

    /// Wraps a standard PTP command container into Nikon's PTP/IP command packet.
    static func commandRequest(from ptpCommand: Data, dataPhase: UInt32 = 0) throws -> Data {
        guard ptpCommand.count >= 12,
              ptpCommand.readUInt32LE(at: 0) == UInt32(ptpCommand.count),
              ptpCommand.readUInt16LE(at: 4) == 1 else { throw PTPIPCodecError.malformedCommand }
        let code = ptpCommand.readUInt16LE(at: 6)
        let transaction = ptpCommand.readUInt32LE(at: 8)
        var payload = Data()
        payload.append(contentsOf: dataPhase.littleEndianBytes)
        payload.append(contentsOf: code.littleEndianBytes)
        payload.append(contentsOf: transaction.littleEndianBytes)
        if ptpCommand.count > 12 { payload.append(ptpCommand.subdata(in: 12..<ptpCommand.count)) }
        return try encode(type: .commandRequest, payload: payload)
    }

    static func initEventRequest(connectionNumber: UInt32) throws -> Data {
        var payload = Data(); payload.append(contentsOf: connectionNumber.littleEndianBytes)
        return try encode(type: .initEventRequest, payload: payload)
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) |
            UInt32(self[startIndex + offset + 1]) << 8 |
            UInt32(self[startIndex + offset + 2]) << 16 |
            UInt32(self[startIndex + offset + 3]) << 24
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}

private extension UUID {
    var uuidData: Data {
        var value = self.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
