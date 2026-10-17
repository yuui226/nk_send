// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// SkShadowTessellator's device-space polygon preparation. Curves must be
/// subdivided before this step; this type does not substitute a bounding box.
struct ZTransferShadowPolygon {
    let points: [SIMD2<Float>]
    let centroid: SIMD2<Float>
    let doubledArea: Float
    let isConvex: Bool
    let direction: Float

    static func prepare(_ points: [SIMD2<Float>]) -> Self? {
        var builder = Builder()
        for point in points {
            // sk_float_round converts to Double before adding 0.5: negative
            // half ties round toward +infinity, unlike Swift's default rounding.
            let scaled = point * 16
            guard scaled.x.isFinite, scaled.y.isFinite else { return nil }
            let sanitized = SIMD2<Float>(Float(floor(Double(scaled.x) + 0.5)),
                                         Float(floor(Double(scaled.y) + 0.5))) * 0.0625
            builder.append(sanitized)
        }
        return builder.finish()
    }

    private struct Builder {
        var points: [SIMD2<Float>] = []
        var centroid: SIMD2<Float> = .zero
        var area: Float = 0
        var lastArea: Float = 0
        var lastCross: Float = 0
        var convex = true

        func duplicate(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
            let d = a - b
            return d.x * d.x + d.y * d.y < 0.0625 * 0.0625
        }
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

        mutating func accumulate(_ current: SIMD2<Float>, _ next: SIMD2<Float>) -> Bool {
            guard !duplicate(current, next) else { return false }
            let a = current - points[0]
            let b = next - points[0]
            let triangleArea = cross(a, b)
            centroid += (a + b) * triangleArea
            area += triangleArea
            if triangleArea * lastArea < 0 { convex = false }
            if triangleArea != 0 { lastArea = triangleArea }
            return true
        }
        mutating func checkConvexity(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            let value = cross(b - a, c - b)
            guard abs(value) > 1 / 4096 else { return false }
            if lastCross * value < 0 { convex = false }
            if value != 0 { lastCross = value }
            return true
        }
        mutating func append(_ point: SIMD2<Float>) {
            if let last = points.last, !accumulate(last, point) { return }
            if points.count > 1, !checkConvexity(points[points.count - 2], points[points.count - 1], point) {
                points.removeLast()
                if let last = points.last, duplicate(last, point) { points.removeLast() }
            }
            points.append(point)
        }
        mutating func finish() -> ZTransferShadowPolygon {
            if points.count > 1, !accumulate(points[points.count - 1], points[0]) { points.removeLast() }
            if points.count > 2 {
                centroid *= 1 / (3 * area)
                centroid += points[0]
                if !checkConvexity(points[points.count - 2], points[points.count - 1], points[0]) {
                    points[0] = points[points.count - 1]
                    points.removeLast()
                }
            }
            return ZTransferShadowPolygon(points: points, centroid: centroid,
                                          doubledArea: area, isConvex: convex, direction: area > 0 ? -1 : 1)
        }
    }
}

/// Ganesh quadratic/cubic subdivision used by SkShadowTessellator. Inputs are
/// already transformed to device pixels; output omits the starting point.
enum ZTransferShadowCurve {
    private static let tolerance: Float = 0.2

    static func quadratic(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> [SIMD2<Float>]? {
        guard finite([a, b, c]) else { return nil }
        let u = b - a, v = c - a
        if abs(u.x * v.y - u.y * v.x) <= 1 / 4096 { return [] }
        let delta = -2 * b + a + c
        let limit = pointLimit(squaredLength(delta) * 1.5625)
        var output: [SIMD2<Float>] = []
        output.reserveCapacity(limit)
        func generate(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ remaining: Int) {
            if remaining < 2 || distanceSquared(b, a, c) < tolerance * tolerance {
                output.append(c)
                return
            }
            let q0 = (a + b) * 0.5, q1 = (b + c) * 0.5
            let middle = (q0 + q1) * 0.5
            generate(a, q0, middle, remaining >> 1)
            generate(middle, q1, c, remaining >> 1)
        }
        generate(a, b, c, limit)
        return output
    }

    static func cubic(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> [SIMD2<Float>]? {
        guard finite([a, b, c, d]) else { return nil }
        let first = -2 * b + a + c
        let second = -2 * c + b + d
        let limit = pointLimit(max(squaredLength(first), squaredLength(second)) * 14.0625)
        var output: [SIMD2<Float>] = []
        output.reserveCapacity(limit)
        func generate(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>, _ remaining: Int) {
            if remaining < 2 || (distanceSquared(b, a, d) < tolerance * tolerance
                                 && distanceSquared(c, a, d) < tolerance * tolerance) {
                output.append(d)
                return
            }
            let q0 = (a + b) * 0.5, q1 = (b + c) * 0.5, q2 = (c + d) * 0.5
            let r0 = (q0 + q1) * 0.5, r1 = (q1 + q2) * 0.5
            let middle = (r0 + r1) * 0.5
            generate(a, q0, r0, middle, remaining >> 1)
            generate(middle, r1, q2, d, remaining >> 1)
        }
        generate(a, b, c, d, limit)
        return output
    }

    private static func finite(_ points: [SIMD2<Float>]) -> Bool {
        points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
    private static func squaredLength(_ p: SIMD2<Float>) -> Float { p.x * p.x + p.y * p.y }
    fileprivate static func distanceSquared(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let u = b - a, v = p - a
        let length = squaredLength(u)
        let dot = u.x * v.x + u.y * v.y
        if dot <= 0 { return squaredLength(v) }
        if dot > length { return squaredLength(b - p) }
        let determinant = u.x * v.y - u.y * v.x
        let distance = (determinant / length) * determinant
        return distance.isFinite ? distance : squaredLength(v)
    }
    /// Wang's formula nextlog16 and GrPathUtils' ten-chop allocation ceiling.
    private static func pointLimit(_ fourthPower: Float) -> Int {
        let exponent: Int
        if fourthPower <= 1 { exponent = 0 }
        else {
            let bits = fourthPower.bitPattern &+ ((1 << 23) - 1)
            exponent = max(Int((bits >> 23) & 255) - 127, 0)
        }
        return 1 << min((exponent + 3) >> 2, 10)
    }
}

/// The convex tessellator backs off a collapsing inner ring and reduces its
/// vertex alpha. This precedes polygon insetting; it does not generate a mesh.
struct ZTransferShadowUmbra {
    let inset: Float
    let alpha: UInt8

    static func prepare(polygon: ZTransferShadowPolygon, inset: Float) -> Self? {
        guard polygon.isConvex, polygon.points.count >= 3,
              polygon.centroid.x.isFinite, polygon.centroid.y.isFinite,
              inset.isFinite, inset >= 0 else { return nil }
        let points = polygon.points
        var minimum = ZTransferShadowCurve.distanceSquared(polygon.centroid, points[0], points[1])
        for index in 1..<points.count {
            let distance = ZTransferShadowCurve.distanceSquared(polygon.centroid, points[index],
                                                               points[(index + 1) % points.count])
            if distance < minimum { minimum = distance }
        }
        let tolerance: Float = 0.01
        if inset > 1 / 4096, minimum < (inset + tolerance) * (inset + tolerance) {
            let adjusted = sqrt(minimum) - tolerance
            let ratio = 128 * (adjusted / inset + 1)
            // SkPMLerp uses an integer 0...256 weight, then truncates the
            // resulting byte. Do not replace this with Float alpha blending.
            guard ratio.isFinite, ratio >= 0, ratio <= 256 else { return nil }
            return Self(inset: adjusted, alpha: UInt8((255 * UInt32(ratio)) >> 8))
        }
        return Self(inset: inset, alpha: 255)
    }
}
