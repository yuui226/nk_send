import Foundation

/// PTP wire constants shared by the USB and IP transports.
enum PTPContainerType: UInt16, Sendable {
    case undefined = 0x0000
    case command = 0x0001
    case data = 0x0002
    case response = 0x0003
    case event = 0x0004
}

struct PTPContainer: Equatable, Sendable {
    let type: PTPContainerType
    let code: UInt16
    let transactionID: UInt32
    let payload: Data
}

enum PTPCodecError: Error, Equatable, Sendable {
    case truncatedHeader
    case invalidLength(UInt32)
    case invalidType(UInt16)
    case truncatedPayload(expected: Int, actual: Int)
    case transactionMismatch(expected: UInt32, actual: UInt32)
}

enum PTPCodec {
    static let headerSize = 12
    static let maxContainerSize = UInt32.max

    static func encode(type: PTPContainerType, code: UInt16, transactionID: UInt32, payload: Data = Data()) -> Data {
        var result = Data(capacity: headerSize + payload.count)
        result.appendLittleEndian(UInt32(headerSize + payload.count))
        result.appendLittleEndian(type.rawValue)
        result.appendLittleEndian(code)
        result.appendLittleEndian(transactionID)
        result.append(payload)
        return result
    }

    static func encodeCommand(code: UInt16, transactionID: UInt32, parameters: [UInt32] = []) -> Data {
        encode(type: .command, code: code, transactionID: transactionID,
               payload: parameters.prefix(5).reduce(into: Data()) { $0.appendLittleEndian($1) })
    }

    static func decode(_ data: Data) throws -> PTPContainer {
        guard data.count >= headerSize else { throw PTPCodecError.truncatedHeader }
        let length = data.readLittleEndian(UInt32.self, at: 0)
        guard length >= UInt32(headerSize), length <= UInt32(maxContainerSize) else { throw PTPCodecError.invalidLength(length) }
        let typeRaw = data.readLittleEndian(UInt16.self, at: 4)
        guard let type = PTPContainerType(rawValue: typeRaw) else { throw PTPCodecError.invalidType(typeRaw) }
        let payloadLength = Int(length) - headerSize
        guard data.count >= Int(length) else { throw PTPCodecError.truncatedPayload(expected: Int(length), actual: data.count) }
        let code = data.readLittleEndian(UInt16.self, at: 6)
        let transactionID = data.readLittleEndian(UInt32.self, at: 8)
        let payloadStart = data.startIndex + headerSize
        return PTPContainer(type: type, code: code, transactionID: transactionID,
                            payload: data.subdata(in: payloadStart..<(payloadStart + payloadLength)))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
}
