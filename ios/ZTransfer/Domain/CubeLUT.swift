import Foundation
import CryptoKit

enum CubeLUTFailure: Error, Equatable { case invalid, unsupported, tooLarge, read }

struct CubeLUT: Equatable, Sendable {
    let size: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    let rgb: [Float]
    let digest: String

    /// RGBA values in the exact R-fastest order consumed by the Android 3D texture.
    /// The renderer may upload this buffer as RGBA16F; alpha is always one.
    var rgba16FloatUploadValues: [Float16] {
        var result = [Float16](); result.reserveCapacity(size * size * size * 4)
        var index = 0
        while index < rgb.count {
            result.append(Float16(rgb[index])); result.append(Float16(rgb[index + 1]))
            result.append(Float16(rgb[index + 2])); result.append(Float16(1))
            index += 3
        }
        return result
    }

    func sample(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let p = SIMD3(
            ((color.x - domainMin.x) / (domainMax.x - domainMin.x)).clamped(to: 0...1) * Float(size - 1),
            ((color.y - domainMin.y) / (domainMax.y - domainMin.y)).clamped(to: 0...1) * Float(size - 1),
            ((color.z - domainMin.z) / (domainMax.z - domainMin.z)).clamped(to: 0...1) * Float(size - 1)
        )
        let lo = SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
        let hi = SIMD3(min(lo.x + 1, size - 1), min(lo.y + 1, size - 1), min(lo.z + 1, size - 1))
        let f = SIMD3(p.x - Float(lo.x), p.y - Float(lo.y), p.z - Float(lo.z))
        func value(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let index = ((b * size + g) * size + r) * 3
            return SIMD3(rgb[index], rgb[index + 1], rgb[index + 2])
        }
        var result = SIMD3<Float>(repeating: 0)
        for bz in 0...1 { for gy in 0...1 { for rx in 0...1 {
            let weight = (rx == 0 ? 1 - f.x : f.x) * (gy == 0 ? 1 - f.y : f.y) * (bz == 0 ? 1 - f.z : f.z)
            result += value(rx == 0 ? lo.x : hi.x, gy == 0 ? lo.y : hi.y, bz == 0 ? lo.z : hi.z) * weight
        }}}
        return result
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}

enum CubeLUTParser {
    static let maxBytes = 32 * 1024 * 1024
    static let maxLine = 8 * 1024
    static let maxSize = 65

    static func parse(_ data: Data, checkCancelled: () throws -> Void = {}) throws -> CubeLUT {
        guard data.count <= maxBytes else { throw CubeLUTFailure.tooLarge }
        var size: Int?
        var minimum: SIMD3<Float>?
        var maximum: SIMD3<Float>?
        var values: [Float] = []
        var dataStarted = false
        var titleSeen = false
        for (lineNumber, raw) in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            try checkCancelled()
            guard raw.count <= maxLine else { throw CubeLUTFailure.tooLarge }
            var line = String(decoding: raw, as: UTF8.self)
            if lineNumber == 0 { line = line.replacingOccurrences(of: "\u{FEFF}", with: "") }
            line = String(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first ?? "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let first = tokens.first, first.first?.isLetter == false {
                guard size != nil, tokens.count == 3, tokens.allSatisfy({ Float($0)?.isFinite == true }) else { throw CubeLUTFailure.invalid }
                guard let size, values.count + 3 <= size * size * size * 3 else { throw CubeLUTFailure.invalid }
                values.append(contentsOf: tokens.compactMap(Float.init))
                guard tokens.allSatisfy({
                    guard let value = Float($0), value.isFinite else { return false }
                    return value >= -65504 && value <= 65504
                }) else { throw CubeLUTFailure.invalid }
                dataStarted = true
                continue
            }
            guard let command = tokens.first else { continue }
            switch command {
            case "TITLE":
                guard !dataStarted, !titleSeen, tokens.count >= 2 else { throw CubeLUTFailure.invalid }
                titleSeen = true
            case "LUT_3D_SIZE":
                guard !dataStarted, size == nil, tokens.count == 2, let parsed = Int(tokens[1]), (2...maxSize).contains(parsed) else { throw CubeLUTFailure.unsupported }
                size = parsed; values.reserveCapacity(parsed * parsed * parsed * 3)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard !dataStarted, tokens.count == 4,
                      let a = Float(tokens[1]), let b = Float(tokens[2]), let c = Float(tokens[3]),
                      a.isFinite, b.isFinite, c.isFinite else { throw CubeLUTFailure.invalid }
                let value = SIMD3(a, b, c)
                if command == "DOMAIN_MIN" { guard minimum == nil else { throw CubeLUTFailure.invalid }; minimum = value }
                else { guard maximum == nil else { throw CubeLUTFailure.invalid }; maximum = value }
            default: throw CubeLUTFailure.unsupported
            }
        }
        guard let size, values.count == size * size * size * 3 else { throw CubeLUTFailure.invalid }
        let low = minimum ?? SIMD3(repeating: 0), high = maximum ?? SIMD3(repeating: 1)
        let validDomain = (0..<3).allSatisfy { index in
            let a = low[index], b = high[index]
            let range = b - a
            // The Android renderer uploads the table as half floats and computes
            // 1 / range in the shader; reject values that cannot be represented
            // reliably by either operation.
            return a.isFinite && b.isFinite && b > a &&
                range >= Float.leastNormalMagnitude && (1 / range).isFinite &&
                (a == 0 || abs(a) >= Float.leastNormalMagnitude) &&
                (b == 0 || abs(b) >= Float.leastNormalMagnitude)
        }
        guard validDomain else { throw CubeLUTFailure.invalid }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CubeLUT(size: size, domainMin: low, domainMax: high, rgb: values, digest: digest)
    }
}
