// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// Float, row-major SkMatrix arithmetic. Transform control points before curve
/// subdivision, and transform conic weights in homogeneous coordinates.
struct ZTransferShadowTransform {
    let x, y, perspective: SIMD3<Float>
    static let identity = Self(x: .init(1, 0, 0), y: .init(0, 1, 0), perspective: .init(0, 0, 1))
    var isFinite: Bool { [x, y, perspective].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } }
    var hasPerspective: Bool { perspective != SIMD3<Float>(0, 0, 1) }
    func map(_ p: SIMD2<Float>) -> SIMD2<Float> {
        if !hasPerspective && x.y == 0 && y.x == 0 {
            return .init(p.x * x.x + x.z, p.y * y.y + y.z)
        }
        let mapped = SIMD2<Float>((p.x * x.x + p.y * x.y) + x.z,
                                  (p.x * y.x + p.y * y.y) + y.z)
        guard hasPerspective else { return mapped }
        let z = (p.x * perspective.x + p.y * perspective.y) + perspective.z
        return mapped * (z == 0 ? z : 1 / z)
    }
    func conicWeight(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, weight: Float) -> Float {
        guard hasPerspective else { return weight }
        func homogeneousZ(_ p: SIMD2<Float>, weight: Float) -> Float {
            // The weighted point is rounded to Float before matrix mapping.
            let point = p * weight
            return (point.x * perspective.x + point.y * perspective.y) + weight * perspective.z
        }
        let w0 = Double(homogeneousZ(a, weight: 1))
        let w1 = Double(homogeneousZ(b, weight: weight))
        let w2 = Double(homogeneousZ(c, weight: 1))
        return Float(sqrt((w1 * w1) / (w0 * w2)))
    }
}

/// A single path contour, following SkPath::Iter(forceClose: true). Move points
/// are not emitted as polygon vertices; the closing line supplies the start.
enum ZTransferShadowPath {
    typealias Point = SIMD2<Float>
    enum Element {
        case move(Point)
        case line(Point)
        case quadratic(Point, Point)
        case cubic(Point, Point, Point)
        case conic(Point, Point, weight: Float)
        case close
    }
    struct Prepared {
        let polygon: ZTransferShadowPolygon
        /// Spot clipping is sampled separately from the shadow's tessellation.
        let clip: [Point]
    }
    static func prepare(_ elements: [Element], transform: ZTransferShadowTransform,
                        clipTransform: ZTransferShadowTransform? = nil) -> Prepared? {
        guard transform.isFinite, clipTransform?.isFinite != false else { return nil }
        var points: [Point] = [], clip: [Point] = []
        var first: Point?, current: Point?
        var closed = false
        func finite(_ p: Point) -> Bool { p.x.isFinite && p.y.isFinite }
        func addClip(_ p: Point) {
            if let last = clip.last {
                let delta = p - last
                if delta.x * delta.x + delta.y * delta.y < 0.0625 * 0.0625 { return }
            }
            clip.append(p)
        }
        func line(_ p: Point) {
            points.append(transform.map(p))
            if let clipTransform { addClip(clipTransform.map(p)) }
        }
        for (index, element) in elements.enumerated() {
            // SkPath::Iter drops a trailing move, including after a close.
            if case .move = element, index == elements.count - 1 { break }
            guard !closed else { return nil }
            switch element {
            case .move(let point):
                guard first == nil, finite(point) else { return nil }
                first = point; current = point
            case .close:
                guard let first, let current else { return nil }
                if current != first { line(first) }
                closed = true
            case .line(let end):
                guard current != nil, finite(end) else { return nil }
                line(end); current = end
            case .quadratic(let control, let end):
                guard let start = current, finite(control), finite(end),
                      let curve = ZTransferShadowCurve.quadratic(transform.map(start), transform.map(control), transform.map(end)) else { return nil }
                points.append(contentsOf: curve)
                if let clipTransform {
                    let a = clipTransform.map(start), b = clipTransform.map(control), c = clipTransform.map(end)
                    addClip(a * 0.25 + b * 0.5 + c * 0.25)
                    addClip(c)
                }
                current = end
            case .conic(let control, let end, let weight):
                guard let start = current, finite(control), finite(end), weight.isFinite, weight >= 0,
                      let curve = ZTransferShadowConic.polyline(transform.map(start), transform.map(control), transform.map(end),
                        weight: transform.conicWeight(start, control, end, weight: weight)) else { return nil }
                points.append(contentsOf: curve)
                if let clipTransform {
                    let a = clipTransform.map(start), b = clipTransform.map(control), c = clipTransform.map(end)
                    // Original clip sampling intentionally uses the path weight,
                    // independently of the shadow transform's perspective weight.
                    addClip((a * 0.25 + b * (weight * 0.5) + c * 0.25) * (1 / (0.5 + 0.5 * weight)))
                    addClip(c)
                }
                current = end
            case .cubic(let control1, let control2, let end):
                guard let start = current, finite(control1), finite(control2), finite(end),
                      let curve = ZTransferShadowCurve.cubic(transform.map(start), transform.map(control1), transform.map(control2), transform.map(end)) else { return nil }
                points.append(contentsOf: curve)
                if let clipTransform {
                    let a = clipTransform.map(start), b = clipTransform.map(control1)
                    let c = clipTransform.map(control2), d = clipTransform.map(end)
                    let kA: Float = 0.32495117187, kB: Float = 0.44311523437
                    let kC: Float = 0.20141601562, kD: Float = 0.03051757812
                    addClip(a * kA + b * kB + c * kC + d * kD)
                    addClip(a * kD + b * kC + c * kB + d * kA)
                    addClip(d)
                }
                current = end
            }
        }
        if !closed, let first, let current, current != first { line(first) }
        guard clip.allSatisfy(finite), let polygon = ZTransferShadowPolygon.prepare(points) else { return nil }
        return Prepared(polygon: polygon, clip: clip)
    }
}

extension ZTransferShadowTransform {
    /// SkMatrix::setConcat preserves a Double intermediate only for affine
    /// two-product sums; perspective rows and scale/translate use Float.
    func concatenating(_ other: Self) -> Self {
        if x == Self.identity.x && y == Self.identity.y && perspective == Self.identity.perspective { return other }
        if other.x == Self.identity.x && other.y == Self.identity.y && other.perspective == Self.identity.perspective { return self }
        if !hasPerspective && !other.hasPerspective && x.y == 0 && y.x == 0 && other.x.y == 0 && other.y.x == 0 {
            return Self(x: .init(x.x * other.x.x, 0, x.x * other.x.z + x.z),
                        y: .init(0, y.y * other.y.y, y.y * other.y.z + y.z), perspective: .init(0, 0, 1))
        }
        if hasPerspective || other.hasPerspective {
            func row(_ a: SIMD3<Float>) -> SIMD3<Float> {
                .init((a.x * other.x.x + a.y * other.y.x) + a.z * other.perspective.x,
                      (a.x * other.x.y + a.y * other.y.y) + a.z * other.perspective.y,
                      (a.x * other.x.z + a.y * other.y.z) + a.z * other.perspective.z)
            }
            return Self(x: row(x), y: row(y), perspective: row(perspective))
        }
        func sum(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
            Float(Double(a) * Double(b) + Double(c) * Double(d))
        }
        return Self(x: .init(sum(x.x, other.x.x, x.y, other.y.x), sum(x.x, other.x.y, x.y, other.y.y),
                            sum(x.x, other.x.z, x.y, other.y.z) + x.z),
                    y: .init(sum(y.x, other.x.x, y.y, other.y.x), sum(y.x, other.x.y, y.y, other.y.y),
                            sum(y.x, other.x.z, y.y, other.y.z) + y.z), perspective: .init(0, 0, 1))
    }
}

extension ZTransferShadowPath {
    /// SkRRect::setRectXY followed by SkPath::addRRect, including rectangle and
    /// oval specializations. The default starts at legacy index 6 (CW) or 7 (CCW).
    static func roundedRect(minimum: Point, maximum: Point, radii: Point,
                            clockwise: Bool = true, startIndex: Int? = nil) -> [Element]? {
        if let startIndex, startIndex < 0 { return nil }
        guard [minimum.x, minimum.y, maximum.x, maximum.y].allSatisfy(\.isFinite) else { return nil }
        let left = min(minimum.x, maximum.x), top = min(minimum.y, maximum.y)
        let right = max(minimum.x, maximum.x), bottom = max(minimum.y, maximum.y)
        let width = right - left, height = bottom - top
        var radius = radii
        if !radius.x.isFinite || !radius.y.isFinite || width <= 0 || height <= 0 { radius = .zero }
        if width < radius.x + radius.x || height < radius.y + radius.y {
            let scale = min(width / (radius.x + radius.x), height / (radius.y + radius.y))
            radius *= scale
        }
        let start = (startIndex ?? (clockwise ? 6 : 7)) % 8
        let corners: [Point] = [.init(left, top), .init(right, top), .init(right, bottom), .init(left, bottom)]
        let step = clockwise ? 1 : -1
        func advanced(_ index: Int, count: Int) -> Int { (index + step + count) % count }
        if radius.x <= 0 || radius.y <= 0 {
            var index = ((start + 1) / 2) % 4
            var result: [Element] = [.move(corners[index])]
            for _ in 0..<3 { index = advanced(index, count: 4); result.append(.line(corners[index])) }
            result.append(.close)
            return result
        }
        let weight: Float = 0.707106781
        if radius.x >= width * 0.5 && radius.y >= height * 0.5 {
            let cx = Float(0.5 * (Double(left) + Double(right)))
            let cy = Float(0.5 * (Double(top) + Double(bottom)))
            let oval: [Point] = [.init(cx, top), .init(right, cy), .init(cx, bottom), .init(left, cy)]
            var index = start / 2
            var corner = (index + (clockwise ? 0 : 1)) % 4
            var result: [Element] = [.move(oval[index])]
            for _ in 0..<4 {
                corner = advanced(corner, count: 4)
                index = advanced(index, count: 4)
                result.append(.conic(corners[corner], oval[index], weight: weight))
            }
            result.append(.close)
            return result
        }
        let round: [Point] = [.init(left + radius.x, top), .init(right - radius.x, top),
            .init(right, top + radius.y), .init(right, bottom - radius.y),
            .init(right - radius.x, bottom), .init(left + radius.x, bottom),
            .init(left, bottom - radius.y), .init(left, top + radius.y)]
        var index = start
        var corner = (start / 2 + (clockwise ? 0 : 1)) % 4
        var result: [Element] = [.move(round[index])]
        let startsWithConic = (start & 1) == (clockwise ? 1 : 0)
        for turn in 0..<4 {
            if !startsWithConic {
                index = advanced(index, count: 8)
                result.append(.line(round[index]))
            }
            corner = advanced(corner, count: 4)
            index = advanced(index, count: 8)
            result.append(.conic(corners[corner], round[index], weight: weight))
            if startsWithConic && turn < 3 {
                index = advanced(index, count: 8)
                result.append(.line(round[index]))
            }
        }
        result.append(.close)
        return result
    }
}

extension ZTransferShadowTransform {
    /// GrQuad::MakeFromRect (affine subset), whose operation grouping differs
    /// from SkMatrix::mapPoints. Keep TL, BL, TR, BR triangle-strip order.
    func rectangleQuad(bounds: SIMD4<Float>) -> [SIMD2<Float>]? {
        guard isFinite, !hasPerspective, (0..<4).allSatisfy({ bounds[$0].isFinite }),
              bounds.z > bounds.x, bounds.w > bounds.y else { return nil }
        let points: [SIMD2<Float>] = [.init(bounds.x,bounds.y), .init(bounds.x,bounds.w),
                                     .init(bounds.z,bounds.y), .init(bounds.z,bounds.w)]
        let result = points.map { p -> SIMD2<Float> in
            if x.y == 0 && y.x == 0 { return .init(p.x * x.x + x.z, p.y * y.y + y.z) }
            return .init(x.x * p.x + (x.y * p.y + x.z), y.x * p.x + (y.y * p.y + y.z))
        }
        return result.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) ? result : nil
    }

    /// SkMatrix::isSimilarity with its default SK_ScalarNearlyZero tolerance.
    /// Retain Float determinant order and the distinct diagonal/affine checks.
    var isSimilarity: Bool {
        guard isFinite, !hasPerspective else { return false }
        let tolerance: Float = 1 / 4096
        if x.y == 0 && y.x == 0 {
            return abs(x.x) > tolerance && abs(abs(x.x) - abs(y.y)) <= tolerance
        }
        guard abs(x.x * y.y - x.y * y.x) > tolerance * tolerance else { return false }
        return (abs(x.x - y.y) <= tolerance && abs(x.y + y.x) <= tolerance)
            || (abs(x.x + y.y) <= tolerance && abs(x.y - y.x) <= tolerance)
    }

    /// SkMatrix::preservesRightAngles default tolerance, including nonuniform scale.
    var preservesRightAngles: Bool {
        guard isFinite, !hasPerspective else { return false }
        let tolerance: Float = 1 / 4096
        guard abs(x.x * y.y - x.y * y.x) > tolerance * tolerance else { return false }
        return abs(x.x * x.y + y.x * y.y) <= tolerance * tolerance
    }

    /// SkMatrix::rectStaysRect + isSimilarity. Near-equal axes are accepted,
    /// but their original values must be retained by the analytic geometry.
    var supportsAnalyticShadow: Bool {
        guard isFinite, !hasPerspective else { return false }
        let tolerance: Float = 1 / 4096
        if x.y == 0 && y.x == 0 {
            return abs(x.x) > tolerance && abs(abs(x.x) - abs(y.y)) <= tolerance
                && x.x != 0 && y.y != 0
        }
        guard x.x == 0, y.y == 0, x.y != 0, y.x != 0,
              abs(x.x * y.y - x.y * y.x) > tolerance * tolerance else { return false }
        return abs(x.y + y.x) <= tolerance || abs(x.y - y.x) <= tolerance
    }

    /// SkMatrix inversion: scale/translation uses Float reciprocals, general
    /// matrices use a Double determinant and source-specific cofactor precision.
    func inverted() -> Self? {
        guard isFinite else { return nil }
        if !hasPerspective && x.y == 0 && y.x == 0 {
            let inverseX: Float = 1 / x.x, inverseY: Float = 1 / y.y
            let result = Self(x: .init(inverseX, 0, -x.z * inverseX),
                              y: .init(0, inverseY, -y.z * inverseY), perspective: .init(0, 0, 1))
            return result.isFinite ? result : nil
        }
        let a = x, b = y, c = perspective
        func doubleCross(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Double {
            Double(a) * Double(b) - Double(c) * Double(d)
        }
        let determinant: Double
        if hasPerspective {
            determinant = Double(a.x) * doubleCross(b.y, c.z, b.z, c.y)
                + Double(a.y) * doubleCross(b.z, c.x, b.x, c.z)
                + Double(a.z) * doubleCross(b.x, c.y, b.y, c.x)
        } else {
            determinant = doubleCross(a.x, b.y, a.y, b.x)
        }
        let tolerance: Float = 1 / 4096
        guard abs(Float(determinant)) > tolerance * tolerance * tolerance else { return nil }
        let inverse = 1 / determinant
        let result: Self
        if hasPerspective {
            // ComputeInv deliberately evaluates perspective cofactors in Float
            // before applying the Double reciprocal determinant.
            func cofactor(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
                Float(Double(a * b - c * d) * inverse)
            }
            result = Self(x: .init(cofactor(b.y, c.z, b.z, c.y), cofactor(a.z, c.y, a.y, c.z), cofactor(a.y, b.z, a.z, b.y)),
                          y: .init(cofactor(b.z, c.x, b.x, c.z), cofactor(a.x, c.z, a.z, c.x), cofactor(a.z, b.x, a.x, b.z)),
                          perspective: .init(cofactor(b.x, c.y, b.y, c.x), cofactor(a.y, c.x, a.x, c.y), cofactor(a.x, b.y, a.y, b.x)))
        } else {
            result = Self(x: .init(Float(Double(b.y) * inverse), Float(Double(-a.y) * inverse),
                                  Float(doubleCross(a.y, b.z, b.y, a.z) * inverse)),
                          y: .init(Float(Double(-b.x) * inverse), Float(Double(a.x) * inverse),
                                  Float(doubleCross(b.x, a.z, a.x, b.z) * inverse)), perspective: .init(0, 0, 1))
        }
        return result.isFinite ? result : nil
    }
}
