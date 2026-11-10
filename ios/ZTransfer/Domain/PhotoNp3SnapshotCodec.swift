import CryptoKit
import Foundation

enum PhotoNp3RecipeKind: String, Sendable {
    case flexible = "np3-srgb-v1", classic = "np3-classic-srgb-v1"

    static func from(id: String) -> Self? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "np3", isDigest(parts[1]) else { return nil }
        return Self(rawValue: String(parts[2]))
    }
    static func sourceDigest(_ id: String) -> String? {
        guard from(id: id) != nil else { return nil }
        return String(id.split(separator: ":")[1])
    }
    static func isDigest(_ text: some StringProtocol) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func matches(_ parameters: PhotoNp3Parameters) -> Bool {
        switch (self, parameters) {
        case (.flexible, .flexible), (.classic, .classic): true
        default: false
        }
    }
}

enum PhotoNp3SnapshotError: Error { case invalid }

/// Android PhotoNp3SnapshotCodec: private, bounded, independently owned recipe.
/// v1 bytes stay unchanged; Classic uses v2/type=1, grading uses v3. No provider
/// access or mutable global catalog is needed when a queued recipe is restored.
enum PhotoNp3SnapshotCodec {
    static let maximumBytes = 4096
    static let maximumBase64Length = maximumBytes * 4 / 3 + 4
    private static let magic = 0x4e503353

    static func encode(_ recipe: PhotoNp3Recipe) throws -> Data {
        guard let kind = PhotoNp3RecipeKind.from(id: recipe.preset.id), kind.matches(recipe.parameters),
              validName(recipe.preset.name) else { throw PhotoNp3SnapshotError.invalid }
        let version: Int
        switch recipe.parameters {
        case .classic(let p):
            guard p.isValid else { throw PhotoNp3SnapshotError.invalid }
            version = 2
        case .flexible(let p):
            guard p.isValid else { throw PhotoNp3SnapshotError.invalid }
            // Even inactive hue/mask metadata is retained by snapshot v3.
            version = p.colorGrading == .init() ? 1 : 3
        }
        var writer = Writer()
        writer.int(magic); writer.int(version)
        if kind == .classic { writer.bytes.append(1) }
        writer.utf(recipe.preset.id); writer.utf(recipe.preset.name)
        switch recipe.parameters {
        case .flexible(let p):
            [p.contrast, p.highlights, p.shadows, p.whites, p.blacks, p.saturation].forEach { writer.int($0) }
            for band in p.colorBands { [band.hue, band.chroma, band.brightness].forEach { writer.int($0) } }
            writer.curve(p.toneCurve)
            if version == 3 {
                for region in [p.colorGrading.highlights, p.colorGrading.midtones, p.colorGrading.shadows] {
                    [region.hue, region.chroma, region.brightness].forEach { writer.int($0) }
                }
                writer.int(p.colorGrading.blending); writer.int(p.colorGrading.balance)
            }
        case .classic(let p):
            [p.base.rawValue, p.contrastQuarter, p.brightnessQuarter, p.saturationQuarter, p.hueQuarter,
             p.filterEffect, p.toningEffect, p.toningDensityQuarter, p.effectLevel].forEach { writer.int($0) }
            writer.curve(p.toneCurve)
        }
        let payload = Data(writer.bytes)
        let result = payload + Data(SHA256.hash(data: payload))
        guard result.count <= maximumBytes else { throw PhotoNp3SnapshotError.invalid }
        return result
    }

    static func decode(_ data: Data) throws -> PhotoNp3Recipe {
        guard (40...maximumBytes).contains(data.count) else { throw PhotoNp3SnapshotError.invalid }
        let payload = Data(data.dropLast(32))
        let difference = zip(SHA256.hash(data: payload), data.suffix(32)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { throw PhotoNp3SnapshotError.invalid }
        var reader = Reader(bytes: Array(payload))
        guard try reader.int() == magic else { throw PhotoNp3SnapshotError.invalid }
        let version = try reader.int()
        let kind: PhotoNp3RecipeKind
        switch version {
        case 1, 3: kind = .flexible
        case 2:
            guard try reader.byte() == 1 else { throw PhotoNp3SnapshotError.invalid }
            kind = .classic
        default: throw PhotoNp3SnapshotError.invalid
        }
        let id = try reader.utf(), name = try reader.utf()
        guard PhotoNp3RecipeKind.from(id: id) == kind, validName(name) else { throw PhotoNp3SnapshotError.invalid }
        let parameters: PhotoNp3Parameters
        switch kind {
        case .flexible:
            let controls = try (0..<6).map { _ in try reader.int() }
            let bands = try Np3FilterParameters.colorBandCenters.map { center in
                Np3ColorBand(centerDegrees: center, hue: try reader.int(), chroma: try reader.int(), brightness: try reader.int())
            }
            let curve = try reader.curve()
            let grading: Np3ColorGrading = version == 3 ? try reader.grading() : .init()
            guard controls.allSatisfy({ (-100...100).contains($0) }), grading.isValid,
                  bands.allSatisfy({ [$0.hue, $0.chroma, $0.brightness].allSatisfy { (-100...100).contains($0) } })
            else { throw PhotoNp3SnapshotError.invalid }
            parameters = .flexible(.init(contrast: controls[0], highlights: controls[1], shadows: controls[2],
                whites: controls[3], blacks: controls[4], saturation: controls[5], colorBands: bands,
                toneCurve: curve, colorGrading: grading))
        case .classic:
            guard let base = ClassicNp3Style(rawValue: try reader.int()) else { throw PhotoNp3SnapshotError.invalid }
            parameters = .classic(try .init(base: base, contrastQuarter: reader.int(), brightnessQuarter: reader.int(),
                saturationQuarter: reader.int(), hueQuarter: reader.int(), filterEffect: reader.int(),
                toningEffect: reader.int(), toningDensityQuarter: reader.int(), effectLevel: reader.int(), toneCurve: reader.curve()))
        }
        guard reader.offset == reader.bytes.count else { throw PhotoNp3SnapshotError.invalid }
        return .init(preset: .init(id: id, name: name), parameters: parameters)
    }

    private static func validName(_ name: String) -> Bool {
        (1...256).contains(name.utf16.count) && name.unicodeScalars.contains { !$0.properties.isWhitespace } &&
            name.utf16.allSatisfy { $0 > 31 && !(127...159).contains($0) }
    }

    private struct Writer {
        var bytes: [UInt8] = []
        mutating func int(_ value: Int) {
            let bits = UInt32(truncatingIfNeeded: value)
            bytes += [UInt8(bits >> 24), UInt8(bits >> 16 & 255), UInt8(bits >> 8 & 255), UInt8(bits & 255)]
        }
        mutating func short(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 255)] }
        mutating func curve(_ values: [UInt16]?) {
            int(values?.count ?? 0)
            values?.forEach { short($0) }
        }
        mutating func utf(_ string: String) {
            // DataOutputStream.writeUTF encodes UTF-16 units, so supplementary
            // characters use six bytes, unlike ordinary four-byte UTF-8.
            var encoded: [UInt8] = []
            for c in string.utf16 {
                if (1...127).contains(c) { encoded.append(UInt8(c)) }
                else if c <= 0x7ff { encoded += [UInt8(0xc0 | c >> 6), UInt8(0x80 | c & 63)] }
                else { encoded += [UInt8(0xe0 | c >> 12), UInt8(0x80 | c >> 6 & 63), UInt8(0x80 | c & 63)] }
            }
            short(UInt16(encoded.count)); bytes += encoded
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw PhotoNp3SnapshotError.invalid }
            defer { offset += 1 }; return bytes[offset]
        }
        mutating func int() throws -> Int {
            let bits = try UInt32(byte()) << 24 | UInt32(byte()) << 16 | UInt32(byte()) << 8 | UInt32(byte())
            return Int(Int32(bitPattern: bits))
        }
        mutating func short() throws -> UInt16 { try UInt16(byte()) << 8 | UInt16(byte()) }
        mutating func curve() throws -> [UInt16]? {
            let count = try int()
            guard count == 0 || count == 257 else { throw PhotoNp3SnapshotError.invalid }
            guard count != 0 else { return nil }
            let result = try (0..<count).map { _ in try short() }
            guard Np3FilterParameters.validToneCurve(result) else { throw PhotoNp3SnapshotError.invalid }
            return result
        }
        mutating func grading() throws -> Np3ColorGrading {
            let high = try region(), mid = try region(), shadow = try region()
            return try .init(highlights: high, midtones: mid, shadows: shadow, blending: int(), balance: int())
        }
        mutating func region() throws -> Np3ColorGradingRegion {
            try .init(hue: int(), chroma: int(), brightness: int())
        }
        mutating func utf() throws -> String {
            let count = Int(try short())
            guard count <= bytes.count - offset else { throw PhotoNp3SnapshotError.invalid }
            let end = offset + count
            var utf16: [UInt16] = []
            while offset < end {
                let first = try byte()
                if first <= 127 { utf16.append(UInt16(first)) }
                else if first >> 5 == 6 {
                    guard offset < end else { throw PhotoNp3SnapshotError.invalid }
                    let next = try byte()
                    guard next & 0xc0 == 0x80 else { throw PhotoNp3SnapshotError.invalid }
                    utf16.append(UInt16(first & 31) << 6 | UInt16(next & 63))
                } else if first >> 4 == 14 {
                    guard end - offset >= 2 else { throw PhotoNp3SnapshotError.invalid }
                    let second = try byte(), third = try byte()
                    guard second & 0xc0 == 0x80, third & 0xc0 == 0x80 else { throw PhotoNp3SnapshotError.invalid }
                    utf16.append(UInt16(first & 15) << 12 | UInt16(second & 63) << 6 | UInt16(third & 63))
                } else { throw PhotoNp3SnapshotError.invalid }
            }
            // This is text, not a BOM-bearing UTF-16 stream. Preserve an
            // embedded U+FEFF; reject malformed surrogate pairs instead of
            // silently repairing a damaged private recipe.
            var index = 0
            while index < utf16.count {
                let unit = utf16[index]
                if (0xd800...0xdbff).contains(unit) {
                    guard index + 1 < utf16.count, (0xdc00...0xdfff).contains(utf16[index + 1]) else {
                        throw PhotoNp3SnapshotError.invalid
                    }
                    index += 2
                } else {
                    guard !(0xdc00...0xdfff).contains(unit) else { throw PhotoNp3SnapshotError.invalid }
                    index += 1
                }
            }
            return String(decoding: utf16, as: UTF16.self)
        }
    }
}
