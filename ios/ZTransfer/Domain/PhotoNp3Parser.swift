import Foundation
import CryptoKit

enum PhotoNp3Failure: Equatable, Sendable { case invalid, unsupported, tooLarge }
struct PhotoNp3Error: LocalizedError, Equatable, Sendable {
    let reason: PhotoNp3Failure
    let message: String
    var errorDescription: String? { message }
}
struct ParsedPhotoNp3: Equatable, Sendable {
    let sourceSha256: String
    let recipe: PhotoNp3Recipe
    let ignoredDetailControls: Bool
}

func requireNp3(_ condition: Bool, _ message: String, reason: PhotoNp3Failure = .invalid) throws {
    if !condition { throw PhotoNp3Error(reason: reason, message: message) }
}

/// Shared TLV access preserves Android's invalid/unsupported distinction. No
/// absolute field offsets or document-provider buffers become recipe storage.
struct PhotoNp3Fields {
    let values: [UInt32: [UInt8]]
    let prefix: String
    func field(_ tag: UInt32, size: Int = 2) throws -> [UInt8] {
        guard let bytes = values[tag] else {
            throw PhotoNp3Error(reason: .invalid, message: "Missing \(prefix) field 0x\(String(tag, radix: 16))")
        }
        try requireNp3(bytes.count == size, "Invalid \(prefix) field length 0x\(String(tag, radix: 16))")
        return bytes
    }
    func known(through lastTag: UInt32) throws {
        let known = Set(stride(from: UInt32(0x100), through: lastTag, by: 0x100)).union([0x02, 0x10100])
        try requireNp3(values.keys.allSatisfy { known.contains($0) }, "Unsupported \(prefix) field", reason: .unsupported)
    }
    func toneCurve(classic: Bool) throws -> [UInt16]? {
        guard let bytes = values[2] else { return nil }
        try requireNp3(bytes.count == 578, "Invalid \(prefix) tone curve length")
        try requireNp3(bytes[0] == 0x49 && bytes[1] == 0x30, "Unsupported \(prefix) tone curve layout", reason: .unsupported)
        try requireNp3(bytes[8] <= 20, "Invalid \(prefix) tone curve point count")
        if !classic {
            try requireNp3(bytes[49..<64].allSatisfy { $0 == 0 }, "Unsupported NP3 tone curve metadata", reason: .unsupported)
        }
        // Levels/gamma/control points describe the editor. The samples already
        // contain them; applying that header again changes the recorded curve.
        return try (0..<Np3FilterParameters.toneCurvePointCount).map { index in
            let offset = 64 + index * 2
            let value = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            try requireNp3(value <= Np3FilterParameters.toneCurveMaximum,
                classic ? "Invalid classic NP3 tone curve sample" : "NP3 tone curve sample is out of range")
            return value
        }
    }
    func validateComment() throws {
        guard let bytes = values[0x10100] else { return }
        try requireNp3(!bytes.isEmpty && bytes.count % 2 == 0, "Invalid \(prefix) comment length")
        guard let end = bytes.firstIndex(of: 0), bytes[end...].allSatisfy({ $0 == 0 }) else {
            throw PhotoNp3Error(reason: .invalid, message: "Invalid \(prefix) comment terminator")
        }
    }
}

/// Port of Android PhotoNp3Parser. Reading is capped at 64 KiB + one overflow
/// byte and checks cancellation before each provider request and before parse.
enum PhotoNp3Parser {
    static let maximumBytes = 64 * 1024
    static let converterVersion = "np3-srgb-v1"
    static let classicConverterVersion = "np3-classic-srgb-v1"

    /// The IO owner retains/closes the handle and its security-scoped lease.
    /// FileHandle represents EOF with nil/empty Data, unlike InputStream's -1.
    static func read(from handle: FileHandle, checkpoint: () throws -> Void = { try Task.checkCancellation() }) throws -> ParsedPhotoNp3 {
        try read(chunk: { count in
            let bytes = try handle.read(upToCount: count)
            return bytes?.isEmpty == false ? bytes : nil
        }, checkpoint: checkpoint)
    }

    /// nil means EOF; a nonnil empty chunk is a stalled provider.
    static func read(chunk: (Int) throws -> Data?, checkpoint: () throws -> Void = { try Task.checkCancellation() }) throws -> ParsedPhotoNp3 {
        var output = Data()
        while true {
            try checkpoint()
            guard let bytes = try chunk(min(4096, maximumBytes + 1 - output.count)) else { break }
            try requireNp3(!bytes.isEmpty, "NP3 stream made no progress")
            try requireNp3(bytes.count <= maximumBytes - output.count, "NP3 exceeds size limit", reason: .tooLarge)
            output.append(bytes)
        }
        try checkpoint()
        return try parse(output)
    }

    static func parse(_ data: Data) throws -> ParsedPhotoNp3 {
        try requireNp3(data.count <= maximumBytes, "NP3 exceeds size limit", reason: .tooLarge)
        let source = Array(data)
        let fields = PhotoNp3Fields(values: try container(source), prefix: "NP3")
        let versionBytes = try fields.field(0x0100, size: 4)
        try requireNp3(versionBytes.allSatisfy { (48...57).contains($0) }, "Invalid NP3 version")
        let version = String(decoding: versionBytes, as: UTF8.self)
        let name = try parseName(fields.field(0x0200, size: 20))
        let base = try fields.field(0x0300)
        let digest = SHA256.hash(data: Data(source)).map { String(format: "%02x", $0) }.joined()
        // Every imported document is parsed from its own contents. No bundled
        // source-hash overrides or third-party recipe parameters are shipped.
        if base != [0, 0x20] {
            let parameters = try ClassicPhotoNp3Parser.parse(fields.values, version: version)
            return ParsedPhotoNp3(sourceSha256: digest,
                recipe: .init(preset: .init(id: "np3:\(digest):\(classicConverterVersion)", name: name), parameters: .classic(parameters)),
                ignoredDetailControls: true)
        }
        try requireNp3(version == "0310", "Unsupported NP3 version or base Picture Control", reason: .unsupported)
        try fields.known(through: 0x2000)
        func scalar(_ tag: UInt32, encoding: UInt8, range: ClosedRange<Int>) throws -> Int {
            let value = try fields.field(tag)
            try requireNp3(value[1] == encoding, "Unsupported NP3 field encoding 0x\(String(tag, radix: 16))", reason: .unsupported)
            let decoded = Int(value[0]) - 128
            try requireNp3(range.contains(decoded), "NP3 value is out of range 0x\(String(tag, radix: 16))")
            return decoded
        }
        func fixed(_ tag: UInt32, _ value: UInt8, _ encoding: UInt8) throws {
            try requireNp3(fields.field(tag) == [value, encoding], "Unsupported NP3 adjustment 0x\(String(tag, radix: 16))", reason: .unsupported)
        }
        try fixed(0x0400, 0, 0); try fixed(0x0500, 255, 1)
        for tag in stride(from: UInt32(0x0800), through: 0x0b00, by: 0x100) { try fixed(tag, 255, 4) }
        for tag in [UInt32(0x0c00), 0x0d00] { try fixed(tag, 255, 0) }
        try fixed(0x0e00, 255, 4)
        for tag in stride(from: UInt32(0x0f00), through: 0x1300, by: 0x100) { try fixed(tag, 255, 1) }
        try fixed(0x1500, 255, 10); try fixed(0x1700, 255, 4); try fixed(0x1800, 255, 4)
        let quick = try fields.field(0x1400)
        try requireNp3(quick[1] == 1, "Unsupported NP3 field encoding 0x1400", reason: .unsupported)
        let quickSharp = Int(quick[0])
        try requireNp3(quickSharp == 0 || quickSharp == 255 || (-2...2).contains(quickSharp - 128), "NP3 quick sharpening is out of range")
        let detail = try [scalar(0x0600, encoding: 4, range: -12...36), scalar(0x0700, encoding: 4, range: -20...20), scalar(0x1600, encoding: 4, range: -20...20)]
        let curve = try fields.toneCurve(classic: false)
        let tonal = try stride(from: UInt32(0x1900), through: 0x1d00, by: 0x100).map { tag -> Int in
            if curve != nil {
                let value = try fields.field(tag)
                try requireNp3(value[1] == 1, "Unsupported NP3 field encoding 0x\(String(tag, radix: 16))", reason: .unsupported)
                try requireNp3(value[0] == 1 || (-100...100).contains(Int(value[0]) - 128), "Invalid curve-controlled NP3 value 0x\(String(tag, radix: 16))")
                return 0
            }
            return try scalar(tag, encoding: 1, range: -100...100)
        }
        let saturation = try scalar(0x1e00, encoding: 1, range: -100...100)
        let mixer = try fields.field(0x1f00, size: 28)
        try requireNp3(Array(mixer[24..<28]) == [1, 1, 1, 0], "Unsupported NP3 color mixer encoding", reason: .unsupported)
        let bands = try Np3FilterParameters.colorBandCenters.enumerated().map { index, center in
            let offset = index * 3
            let values = mixer[offset..<(offset + 3)].map { Int($0) - 128 }
            try requireNp3(values.allSatisfy { (-100...100).contains($0) }, "NP3 color mixer value is out of range")
            return Np3ColorBand(centerDegrees: center, hue: values[0], chroma: values[1], brightness: values[2])
        }
        let grading = try parseGrading(fields.field(0x2000, size: 20))
        try fields.validateComment()
        let parameters = Np3FilterParameters(contrast: tonal[0], highlights: tonal[1], shadows: tonal[2],
            whites: tonal[3], blacks: tonal[4], saturation: saturation, colorBands: bands, toneCurve: curve, colorGrading: grading)
        return ParsedPhotoNp3(sourceSha256: digest,
            recipe: .init(preset: .init(id: "np3:\(digest):\(converterVersion)", name: name), parameters: .flexible(parameters)),
            ignoredDetailControls: detail.contains { $0 != 0 } || (quickSharp != 128 && quickSharp != 255))
    }

    private static func container(_ source: [UInt8]) throws -> [UInt32: [UInt8]] {
        try requireNp3(source.count >= 8 && Array(source.prefix(4)) == [78, 67, 80, 0], "Invalid NP3 signature")
        var cursor = 4, fields: [UInt32: [UInt8]] = [:]
        func integer(_ start: Int) -> UInt32 {
            UInt32(source[start]) << 24 | UInt32(source[start + 1]) << 16 | UInt32(source[start + 2]) << 8 | UInt32(source[start + 3])
        }
        while source.count - cursor >= 4 {
            let tag = integer(cursor); cursor += 4
            if tag == 0 { try requireNp3(cursor == source.count, "Trailing NP3 data"); return fields }
            try requireNp3(source.count - cursor >= 4, "Truncated NP3 field header")
            let length = Int(integer(cursor)); cursor += 4
            try requireNp3(length <= source.count - cursor, "Truncated NP3 field")
            try requireNp3(fields[tag] == nil, "Duplicate NP3 field")
            fields[tag] = Array(source[cursor..<(cursor + length)]); cursor += length
        }
        throw PhotoNp3Error(reason: .invalid, message: "Missing NP3 terminator")
    }
    private static func parseName(_ bytes: [UInt8]) throws -> String {
        guard let end = bytes.firstIndex(of: 0), (1...19).contains(end), bytes[end...].allSatisfy({ $0 == 0 }) else {
            throw PhotoNp3Error(reason: .invalid, message: "Invalid NP3 name")
        }
        try requireNp3(bytes[..<end].allSatisfy { (32...126).contains($0) }, "Unsupported NP3 name encoding", reason: .unsupported)
        let name = String(decoding: bytes[..<end], as: UTF8.self)
        try requireNp3(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty NP3 name")
        return name
    }
    private static func parseGrading(_ bytes: [UInt8]) throws -> Np3ColorGrading {
        try requireNp3(Array(bytes[12..<16]) == [1, 1, 1, 0] && bytes[17] == 1 && bytes[19] == 1,
            "Unsupported NP3 color grading encoding", reason: .unsupported)
        func region(_ offset: Int) throws -> Np3ColorGradingRegion {
            try requireNp3((128...129).contains(bytes[offset]), "Unsupported NP3 grading hue encoding", reason: .unsupported)
            let value = Np3ColorGradingRegion(hue: (Int(bytes[offset]) - 128) << 8 | Int(bytes[offset + 1]),
                chroma: Int(bytes[offset + 2]) - 128, brightness: Int(bytes[offset + 3]) - 128)
            try requireNp3(value.isValid, "NP3 color grading value is out of range")
            return value
        }
        let blending = Int(bytes[16]) - 128, balance = Int(bytes[18]) - 128
        try requireNp3((0...100).contains(blending) && (-100...100).contains(balance), "NP3 color grading blend is out of range")
        let grading = try Np3ColorGrading(highlights: region(0), midtones: region(4), shadows: region(8), blending: blending, balance: balance)
        return grading.isNeutral ? Np3ColorGrading() : grading
    }
}
