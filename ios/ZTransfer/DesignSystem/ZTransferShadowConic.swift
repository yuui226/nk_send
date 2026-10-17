// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// Android 15 SkConic's non-legacy chop path, used by shadow conics at 0.25px
/// tolerance. Points are already in device space; perspective weight mapping
/// belongs to the path transform stage, not this approximation.
enum ZTransferShadowConic {
    private struct Conic {
        var a, b, c: SIMD2<Float>
        let weight: Float

        func split() -> (Conic, Conic) {
            let scale = 1 / (1 + weight)
            let t0 = a * scale, t1 = b * (weight * scale), t2 = c * scale
            let p1 = t0 + t1, p3 = t1 + t2
            let middle = 0.5 * t0 + t1 + 0.5 * t2
            let w = sqrt(0.5 + weight * 0.5)
            return (Conic(a: a, b: p1, c: middle, weight: w),
                    Conic(a: middle, b: p3, c: c, weight: w))
        }
    }

    /// Shared-endpoint representation: a, control0, end0, control1, end1, ...
    static func quadratics(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>,
                           weight: Float) -> [SIMD2<Float>]? {
        guard [a, b, c].allSatisfy(finite), weight.isFinite, weight >= 0 else { return nil }
        let conic = Conic(a: a, b: b, c: c, weight: weight)
        let difference = weight - 1
        let k = difference / (4 * (2 + difference))
        let errorVector = k * (a - 2 * b + c)
        var error = sqrt(errorVector.x * errorVector.x + errorVector.y * errorVector.y)
        var level = 0
        while level < 5 {
            if error <= 0.25 { break }
            error *= 0.25
            level += 1
        }
        var result = [a]
        if level == 5 {
            let (left, right) = conic.split()
            if equivalent(left.b, left.c), equivalent(right.a, right.b) {
                result += [left.b, left.b, left.b, right.c]
            }
        }
        if result.count == 1 {
            result.reserveCapacity(1 + 2 * (1 << level))
            subdivide(conic, level: level, into: &result)
        }
        if !result.allSatisfy(finite) {
            for index in 1..<(result.count - 1) { result[index] = b }
        }
        return result
    }

    /// SkShadowTessellator.handleConic: feed each generated quad through the
    /// Ganesh subdivision, retaining the original conic's final endpoint.
    static func polyline(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>,
                         weight: Float) -> [SIMD2<Float>]? {
        guard let quads = quadratics(a, b, c, weight: weight) else { return nil }
        var result: [SIMD2<Float>] = []
        var previous = quads[0]
        for index in stride(from: 1, to: quads.count - 1, by: 2) {
            let end = index == quads.count - 2 ? c : quads[index + 1]
            guard let points = ZTransferShadowCurve.quadratic(previous, quads[index], end) else { return nil }
            result += points
            previous = end
        }
        return result
    }

    private static func subdivide(_ conic: Conic, level: Int, into result: inout [SIMD2<Float>]) {
        if level == 0 { result += [conic.b, conic.c]; return }
        var (left, right) = conic.split()
        let start = conic.a.y, end = conic.c.y
        if between(start, conic.b.y, end) {
            let middle = left.c.y
            if !between(start, middle, end) {
                let closer = abs(middle - start) < abs(middle - end) ? start : end
                left.c.y = closer
                right.a.y = closer
            }
            if !between(start, left.b.y, left.c.y) { left.b.y = start }
            if !between(right.a.y, right.b.y, end) { right.b.y = end }
        }
        subdivide(left, level: level - 1, into: &result)
        subdivide(right, level: level - 1, into: &result)
    }

    private static func between(_ a: Float, _ b: Float, _ c: Float) -> Bool { (a - b) * (c - b) <= 0 }
    private static func finite(_ point: SIMD2<Float>) -> Bool { point.x.isFinite && point.y.isFinite }
    private static func equivalent(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        let d = a - b
        return !finite(d) || (d.x == 0 && d.y == 0)
    }
}
