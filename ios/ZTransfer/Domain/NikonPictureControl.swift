import CryptoKit
import Foundation

enum NikonPictureControlError: Error, LocalizedError, Equatable {
    case invalid(String)
    case flexibleColorUnsupported
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .flexibleColorUnsupported: "Flexible Color Picture Controls are not supported"
        }
    }
}

private func pictureControlRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw NikonPictureControlError.invalid(message) }
}

/// Android NikonPictureControlData/ToneCurve: preserve the complete wire dataset,
/// including QuickSharpFlag and curve control points, for lossless restoration.
struct NikonPictureControlToneCurve: Equatable, Sendable {
    struct Point: Equatable, Sendable { let x: Int; let y: Int }
    let data: Data
    var points: [Point] {
        let bytes = [UInt8](data)
        return (0..<Int(bytes[8])).map { Point(x: Int(bytes[9 + $0 * 2]), y: Int(bytes[10 + $0 * 2])) }
    }
    var samples: [Int] {
        let bytes = [UInt8](data)
        return (0..<257).map { Int(bytes[64 + $0 * 2]) << 8 | Int(bytes[65 + $0 * 2]) }
    }
    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        try pictureControlRequire(bytes.count == 578 && bytes[0] == 0x49 && bytes[1] == 0x30,
                                  "Unrecognized Picture Control tone curve")
        try pictureControlRequire(bytes[8] <= 20, "Invalid Picture Control curve point count")
        self.data = Data(bytes)
        try pictureControlRequire(samples.allSatisfy { $0 <= 32767 }, "Invalid Picture Control curve sample")
    }
}

struct NikonPictureControlData: Equatable, Sendable {
    static let customSlots = 201...209
    let requestedItem: Int
    let baseItem: Int
    let name: String
    let isEmpty: Bool
    let curve: NikonPictureControlToneCurve?
    let data: Data
    var parameterBytes: Data { data.subdata(in: 22..<35) }

    init(item: Int, responseCode: UInt16, data: Data?) throws {
        try pictureControlRequire((1...65535).contains(item), "Invalid Picture Control item")
        try pictureControlRequire(responseCode == 0x2001,
                                  String(format: "Picture Control read failed: 0x%04X", responseCode))
        guard let data else { throw NikonPictureControlError.invalid("Missing Picture Control data") }
        let source = [UInt8](data)
        try pictureControlRequire(source.count == 36 || source.count == 614, "Unrecognized Picture Control dataset size")
        requestedItem = item
        self.data = Data(source)
        isEmpty = source.allSatisfy { $0 == 0 }
        if isEmpty {
            try pictureControlRequire(Self.customSlots.contains(item) && source.count == 36,
                                      "Invalid empty Picture Control data")
            baseItem = 0; name = ""; curve = nil
            return
        }
        baseItem = Int(source[0]) | Int(source[1]) << 8
        try pictureControlRequire(baseItem != 0, "Missing Picture Control base")
        let nameBytes = Array(source[2..<22])
        let length = nameBytes.firstIndex(of: 0) ?? nameBytes.count
        try pictureControlRequire((1...19).contains(length) && nameBytes.prefix(length).allSatisfy { (32...126).contains($0) },
                                  "Unrecognized Picture Control name encoding")
        try pictureControlRequire(nameBytes.dropFirst(length).allSatisfy { $0 == 0 }, "Invalid Picture Control name padding")
        name = String(decoding: nameBytes.prefix(length), as: UTF8.self)
        switch source[35] {
        case 0:
            try pictureControlRequire(source.count == 36, "Unexpected data after Picture Control header")
            curve = nil
        case 1:
            try pictureControlRequire(source.count == 614, "Truncated Picture Control curve")
            curve = try NikonPictureControlToneCurve(Data(source[36...]))
        default: throw NikonPictureControlError.invalid("Unrecognized Picture Control curve flag")
        }
    }
}

/// NP3 container and camera datasets are deliberately separate representations.
struct NikonPictureControlFile: Equatable, Sendable {
    static let maximumBytes = 64 * 1024
    let name: String
    let version: String
    let data: Data
    private let fields: [UInt32: Data]
    var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var fieldTags: Set<UInt32> { Set(fields.keys) }
    func field(_ tag: UInt32) -> Data? { fields[tag] }

    static func read(_ input: InputStream, checkpoint: () throws -> Void = {}) throws -> Self {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try checkpoint()
            let count = input.read(&buffer, maxLength: min(buffer.count, maximumBytes + 1 - output.count))
            if count < 0 { throw input.streamError ?? NikonPictureControlError.invalid("Picture Control stream read failed") }
            if count == 0 {
                // Foundation represents EOF as zero; the stream owns open/close.
                if input.streamStatus == .atEnd { break }
                throw NikonPictureControlError.invalid("Picture Control stream made no progress")
            }
            try pictureControlRequire(output.count + count <= maximumBytes, "Picture Control file exceeds size limit")
            output.append(contentsOf: buffer.prefix(count))
        }
        try checkpoint()
        return try Self(output)
    }

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        try pictureControlRequire((44...Self.maximumBytes).contains(bytes.count), "Invalid Picture Control file size")
        try pictureControlRequire(Array(bytes.prefix(4)) == [78, 67, 80, 0], "Invalid Picture Control file signature")
        var offset = 4
        func u32(_ position: Int) -> UInt32 {
            bytes[position..<position + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        var fields: [UInt32: Data] = [:]
        var terminated = false
        while bytes.count - offset >= 4 {
            let tag = u32(offset); offset += 4
            if tag == 0 {
                try pictureControlRequire(offset == bytes.count, "Trailing Picture Control file data")
                terminated = true; break
            }
            try pictureControlRequire(bytes.count - offset >= 4, "Truncated Picture Control field header")
            let length = Int(u32(offset)); offset += 4
            try pictureControlRequire(length <= bytes.count - offset, "Truncated Picture Control field")
            try pictureControlRequire(fields[tag] == nil, "Duplicate Picture Control field")
            fields[tag] = Data(bytes[offset..<offset + length]); offset += length
        }
        try pictureControlRequire(terminated, "Missing Picture Control file terminator")
        guard let versionData = fields[0x100] else { throw NikonPictureControlError.invalid("Missing Picture Control version") }
        try pictureControlRequire(versionData.count == 4 && versionData.allSatisfy { (48...57).contains($0) }, "Invalid Picture Control version")
        version = String(decoding: versionData, as: UTF8.self)
        try pictureControlRequire(version.hasPrefix("03"), "Not an NP3 Picture Control file")
        if version == "0310", fields[0x300] == Data([0, 0x20]), fields[0x1F00]?.count == 28,
           fields[0x2000]?.count == 20 { throw NikonPictureControlError.flexibleColorUnsupported }
        guard let nameData = fields[0x200] else { throw NikonPictureControlError.invalid("Missing Picture Control name") }
        let nameBytes = [UInt8](nameData)
        try pictureControlRequire(nameBytes.count == 20, "Invalid Picture Control name field")
        let end = nameBytes.firstIndex(of: 0) ?? nameBytes.count
        try pictureControlRequire(end > 0 && nameBytes.prefix(end).allSatisfy { (32...126).contains($0) }, "Invalid Picture Control name")
        name = String(decoding: nameBytes.prefix(end), as: UTF8.self)
        self.data = Data(bytes)
        self.fields = fields
    }

    func encodeClassicPictureControl() throws -> Data {
        try pictureControlRequire(version == "0300", "Unsupported NP3 version: \(version)")
        let allowed = Set(stride(from: UInt32(0x100), through: 0x1600, by: 0x100)).union([2, 0x10100])
        try pictureControlRequire(fieldTags.isSubset(of: allowed), "Unsupported NP3 fields")
        func pair(_ tag: UInt32) throws -> [UInt8] {
            guard let data = fields[tag], data.count == 2 else {
                throw NikonPictureControlError.invalid(String(format: "Invalid NP3 field 0x%04X", tag))
            }
            return [UInt8](data)
        }
        func value(_ tag: UInt32, _ encoding: UInt8) throws -> Int {
            let bytes = try pair(tag)
            try pictureControlRequire(bytes[1] == encoding, "Unsupported NP3 field encoding")
            return Int(bytes[0])
        }
        func fixed(_ tag: UInt32, _ first: Int, _ second: UInt8) throws {
            try pictureControlRequire(try value(tag, second) == first,
                                      String(format: "Unsupported NP3 adjustment 0x%04X", tag))
        }
        let idBytes = try pair(0x300)
        let id = Int(idBytes[0]) << 8 | Int(idBytes[1])
        guard let base = [0x0001: 1, 0x03C2: 2, 0x00C3: 3, 0x080B: 111, 0x080C: 112][id] else {
            throw NikonPictureControlError.invalid(String(format: "Unsupported NP3 base identifier: 0x%04X", id))
        }
        try fixed(0x400, 0, 0); try fixed(0x500, 255, 1)
        for tag in stride(from: UInt32(0xF00), through: 0x1300, by: 0x100) { try fixed(tag, 255, 1) }
        try fixed(0x1400, 128, 1)
        try fixed(0xC00, 255, 0); try fixed(0xD00, 255, 0); try fixed(0xE00, 255, 4)
        let nameBytes = [UInt8](fields[0x200]!) // Validated container invariant.
        try pictureControlRequire(nameBytes.last == 0 && name.count <= 19, "Picture Control name exceeds 19 ASCII characters")
        try pictureControlRequire(nameBytes.dropFirst(name.count).allSatisfy { $0 == 0 }, "Invalid NP3 name padding")
        let curve = try fields[2].map { try NikonPictureControlToneCurve($0) }
        var output = [UInt8](repeating: 0, count: 36)
        output[0] = UInt8(base & 255); output[1] = UInt8(base >> 8)
        output.replaceSubrange(2..<22, with: nameBytes)
        let effect = try value(0x1500, 10)
        if base < 100 {
            try pictureControlRequire(effect == 255, "Unexpected effect level on a standard Picture Control")
        } else {
            try pictureControlRequire((128...138).contains(effect), "Invalid Picture Control effect level")
            output[22] = UInt8((effect - 128) * 10)
        }
        // Explicit sharpness values require QuickSharpFlag OFF.
        func scalar(_ tag: UInt32, _ offset: Int, _ range: ClosedRange<Int>,
                    auto: Bool = false, curveControlled: Bool = false, unavailable: Bool = false) throws {
            let raw = try value(tag, 4)
            let decoded: Int
            if raw == 1 && curveControlled && curve != nil { decoded = 0 }
            else if raw == 255 && unavailable { decoded = 0 }
            else if raw == 0 && auto { decoded = -128 }
            else {
                decoded = raw - 128
                try pictureControlRequire(range.contains(decoded), String(format: "Unsupported NP3 value in 0x%04X", tag))
            }
            output[offset] = UInt8(truncatingIfNeeded: decoded)
        }
        try scalar(0x600, 25, -12...36); try scalar(0x1600, 26, -20...20); try scalar(0x700, 27, -20...20)
        try scalar(0x800, 28, -12...12, auto: base < 100, curveControlled: true)
        try scalar(0x900, 29, base < 100 ? -6...6 : 0...0, curveControlled: true, unavailable: base >= 100)
        try scalar(0xA00, 30, -12...12, auto: base < 100)
        try scalar(0xB00, 31, base < 100 ? -12...12 : 0...0, unavailable: base >= 100)
        output[35] = curve == nil ? 0 : 1
        if let curve { output.append(contentsOf: curve.data) }
        let result = Data(output)
        _ = try NikonPictureControlData(item: base, responseCode: 0x2001, data: result)
        return result
    }
}

func validatePictureControlCapabilities(dataset: Data, capabilities: Data) throws {
    let values = [UInt8](dataset), flags = [UInt8](capabilities)
    try pictureControlRequire(values.count == 36 || values.count == 614, "Unrecognized Picture Control dataset size")
    try pictureControlRequire(flags.count == 28, "Unsupported Picture Control capability layout")
    try pictureControlRequire(flags.prefix(12).allSatisfy { [0, 1, 128, 129].contains($0) }, "Invalid Picture Control capabilities")
    for (index, offset) in [22, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34].enumerated() {
        if values[offset] == 128 {
            try pictureControlRequire(flags[index] & 1 != 0, "Camera does not support this automatic adjustment")
        } else if flags[index] & 128 == 0 {
            try pictureControlRequire(values[offset] == 0, "Camera does not support this adjustment")
        }
    }
}
