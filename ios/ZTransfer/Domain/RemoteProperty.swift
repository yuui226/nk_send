import Foundation

/// Nikon DevicePropDesc data reduced to the fields RemoteScreen exposes.
/// The wire layout and scalar widths follow Android's `parsePropDescData` and
/// `encodeScalar`; unsupported compound/string values are deliberately ignored.
struct ParsedRemoteProperty: Equatable, Sendable {
    let code: UInt16
    let dataType: UInt16
    let writable: Bool
    var current: Int64
    let values: [Int64]
}

enum RemotePropertyCodec {
    static func parseDescription(_ data: Data) -> ParsedRemoteProperty? {
        var reader = ScalarReader(data)
        guard let code = reader.readUInt16(),
              let type = reader.readUInt16(),
              let getSet = reader.readUInt8(),
              let factory = readScalar(&reader, type),
              let current = readScalar(&reader, type),
              let form = reader.readUInt8() else { return nil }
        _ = factory
        var values: [Int64] = []
        switch form {
        case 1:
            guard let minimum = readScalar(&reader, type),
                  let maximum = readScalar(&reader, type),
                  let step = readScalar(&reader, type),
                  minimum == 0, maximum == 1, step == 1 else { break }
            values = [0, 1]
        case 2:
            guard let count = reader.readUInt16(), count <= 256 else { return nil }
            values = (0..<count).compactMap { _ in readScalar(&reader, type) }
            guard values.count == count else { return nil }
        default:
            break
        }
        return ParsedRemoteProperty(code: code, dataType: type, writable: getSet != 0,
                              current: current, values: values)
    }

    static func encode(_ value: Int64, dataType: UInt16) -> Data? {
        let width: Int
        switch dataType {
        case 0x0001, 0x0002: width = 1
        case 0x0003, 0x0004: width = 2
        case 0x0005, 0x0006: width = 4
        case 0x0007, 0x0008: width = 8
        default: return nil
        }
        var output = Data(capacity: width)
        var raw = UInt64(bitPattern: value)
        for _ in 0..<width {
            output.append(UInt8(truncatingIfNeeded: raw))
            raw >>= 8
        }
        return output
    }

    private static func readScalar(_ reader: inout ScalarReader, _ type: UInt16) -> Int64? {
        switch type {
        case 0x0001: return reader.readUInt8().map { Int64(Int8(bitPattern: $0)) }
        case 0x0002: return reader.readUInt8().map(Int64.init)
        case 0x0003: return reader.readUInt16().map { Int64(Int16(bitPattern: $0)) }
        case 0x0004: return reader.readUInt16().map(Int64.init)
        case 0x0005: return reader.readUInt32().map { Int64(Int32(bitPattern: $0)) }
        case 0x0006: return reader.readUInt32().map(Int64.init)
        case 0x0007: return reader.readUInt64().map { Int64(bitPattern: $0) }
        case 0x0008: return reader.readUInt64().map { Int64(bitPattern: $0) }
        default: return nil
        }
    }
}

private struct ScalarReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    init(_ data: Data) { self.data = data }
    mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func readUInt16() -> UInt16? { readFixed(UInt16.self) }
    mutating func readUInt32() -> UInt32? { readFixed(UInt32.self) }
    mutating func readUInt64() -> UInt64? { readFixed(UInt64.self) }
    mutating func readFixed<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        guard remaining >= MemoryLayout<T>.size else { return nil }
        defer { offset += MemoryLayout<T>.size }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
}
