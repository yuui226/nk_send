// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// Android 15 SkPolyUtils' convex inset. Integer links retain removed edges'
/// neighbours, as the original linked-list walk needs them to step backwards.
/// A failed result may contain a degenerate ring; callers must check isValid.
enum ZTransferShadowInset {
    typealias Point = SIMD2<Float>
    struct Result {
        let points: [Point]
        let isValid: Bool
    }
    private struct Segment { let origin, vector: Point }
    private struct Edge {
        var previous, next: Int
        let segment: Segment
        var intersection: Point
        var parameter: Float = -.greatestFiniteMagnitude
    }
    private static let nearlyZero: Float = 1 / 4096
    private static let crossTolerance = nearlyZero * nearlyZero
    private static func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
    private static func dot(_ a: Point, _ b: Point) -> Float { a.x * b.x + a.y * b.y }
    private static func finite(_ p: Point) -> Bool { p.x.isFinite && p.y.isFinite }
    private static func close(_ a: Point, _ b: Point, tolerance: Float) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
    private static func side(_ origin: Point, _ vector: Point, _ p: Point) -> Int {
        let value = cross(vector, p - origin)
        return abs(value) <= crossTolerance ? 0 : (value > 0 ? 1 : -1)
    }
    private static func winding(_ points: [Point]) -> Int {
        var area: Float = 0
        var previous = points[1] - points[0]
        for point in points.dropFirst(2) {
            let next = point - points[0]
            area += cross(previous, next)
            previous = next
        }
        return abs(area) <= crossTolerance ? 0 : (area > 0 ? 1 : -1)
    }
    /// SkPoint::setLength uses Double magnitude and multiplication even for
    /// ordinary coordinates. Float normalization changes intersection order.
    private static func withLength(_ point: Point, _ length: Float) -> Point {
        let x = Double(point.x), y = Double(point.y)
        let scale = Double(length) / sqrt(x * x + y * y)
        let result = Point(Float(x * scale), Float(y * scale))
        return finite(result) && result != .zero ? result : .zero
    }
    private static func outside(_ numerator: Float, _ denominator: Float, positive: Bool) -> Bool {
        positive ? (numerator < 0 || numerator > denominator) : (numerator > 0 || numerator < denominator)
    }
    private static func zeroLength(_ vector: Point, _ squaredLength: Float) -> Bool {
        !finite(vector) || squaredLength == 0
    }
    private static func intersection(_ a: Segment, _ b: Segment) -> (point: Point, s: Float, t: Float)? {
        let v0 = a.vector, v1 = b.vector, w = b.origin - a.origin
        var denominator = cross(v0, v1)
        let positive = denominator > 0
        var sNumerator: Float, tNumerator: Float
        if abs(denominator) <= crossTolerance {
            guard abs(cross(w, v0)) <= crossTolerance, abs(cross(w, v1)) <= crossTolerance else { return nil }
            let length0 = dot(v0, v0)
            if zeroLength(v0, length0) {
                let length1 = dot(v1, v1)
                if zeroLength(v1, length1) {
                    return !finite(w) || w == .zero ? (a.origin, 0, 0) : nil
                }
                tNumerator = dot(v1, -w)
                denominator = length1
                guard !outside(tNumerator, denominator, positive: true) else { return nil }
                sNumerator = 0
            } else {
                sNumerator = dot(v0, w)
                denominator = length0
                tNumerator = 0
                if outside(sNumerator, denominator, positive: true) {
                    let length1 = dot(v1, v1)
                    guard !zeroLength(v1, length1) else { return nil }
                    let previous = sNumerator
                    sNumerator = dot(v0, w + v1)
                    tNumerator = denominator
                    if outside(sNumerator, denominator, positive: true) {
                        if sNumerator * previous > 0 { return nil }
                        sNumerator = 0
                        tNumerator = dot(v1, -w)
                        denominator = length1
                    }
                }
            }
        } else {
            sNumerator = cross(w, v1)
            guard !outside(sNumerator, denominator, positive: positive) else { return nil }
            tNumerator = cross(w, v0)
            guard !outside(tNumerator, denominator, positive: positive) else { return nil }
        }
        let s = sNumerator / denominator, t = tNumerator / denominator
        return (a.origin + v0 * s, s, t)
    }
    private static func convex(_ points: [Point]) -> Bool {
        guard points.count >= 3 else { return false }
        var v0 = points[0] - points[points.count - 1]
        var v1 = points[1] - points[0]
        var lastCross: Float = 0
        var lastX = v0.x, lastY = v0.y
        var xChanges = 0, yChanges = 0
        for index in points.indices {
            guard finite(points[index]) else { return false }
            let value = cross(v0, v1)
            if lastCross * value < 0 { return false }
            if value != 0 { lastCross = value }
            if lastX * v1.x < 0 { xChanges += 1 }
            if lastY * v1.y < 0 { yChanges += 1 }
            if xChanges > 2 || yChanges > 2 { return false }
            if v1.x != 0 { lastX = v1.x }
            if v1.y != 0 { lastY = v1.y }
            v0 = v1
            v1 = points[(index + 2) % points.count] - points[(index + 1) % points.count]
        }
        return true
    }
    static func inset(_ points: [Point], by distance: Float) -> Result {
        let failed = Result(points: [], isValid: false)
        guard points.count >= 3, points.count <= Int(UInt16.max),
              distance.isFinite, distance >= -nearlyZero else { return failed }
        if distance <= nearlyZero { return Result(points: points, isValid: true) }
        let direction = winding(points)
        guard direction != 0 else { return failed }
        var edges: [Edge] = []
        edges.reserveCapacity(points.count)
        for index in points.indices {
            let previous = (index + points.count - 1) % points.count
            let next = (index + 1) % points.count
            guard finite(points[index]),
                  side(points[previous], points[index] - points[previous], points[next]) * direction >= 0 else { return failed }
            let vector = points[next] - points[index]
            let normal = withLength(Point(-vector.y, vector.x), distance * Float(direction))
            let segment = Segment(origin: points[index] + normal, vector: vector)
            edges.append(Edge(previous: previous, next: next, segment: segment, intersection: segment.origin))
        }
        var head: Int? = 0
        var current = 0, previous = edges[0].previous
        var iterations = 0
        // Keep links on the removed node intact for the next traversal step.
        func remove(_ index: Int) {
            let before = edges[index].previous, after = edges[index].next
            edges[before].next = after
            edges[after].previous = before
            if head == index { head = after == index ? nil : after }
        }
        while head != nil && previous != current {
            iterations += 1
            guard iterations <= points.count * points.count else { return failed }
            if let hit = intersection(edges[previous].segment, edges[current].segment) {
                if hit.s < edges[previous].parameter {
                    remove(previous)
                    previous = edges[previous].previous
                } else if edges[current].parameter > -.greatestFiniteMagnitude,
                          close(hit.point, edges[current].intersection, tolerance: 1e-6) {
                    break
                } else {
                    edges[current].intersection = hit.point
                    edges[current].parameter = hit.t
                    previous = current
                    current = edges[current].next
                }
            } else {
                let segment = edges[current].segment, prior = edges[previous].segment
                let originSide = direction * side(segment.origin, segment.vector, prior.origin)
                if originSide < 0 && originSide == direction * side(segment.origin, segment.vector, prior.origin + prior.vector) {
                    remove(previous)
                    previous = edges[previous].previous
                } else {
                    remove(current)
                    current = edges[current].next
                }
            }
        }
        guard let first = head else { return failed }
        var result = [edges[first].intersection]
        current = edges[first].next
        while current != first {
            if !close(edges[current].intersection, result[result.count - 1], tolerance: 0.01) {
                result.append(edges[current].intersection)
            }
            current = edges[current].next
        }
        if result.count >= 2, close(result[0], result[result.count - 1], tolerance: 0.01) { result.removeLast() }
        return Result(points: result, isValid: convex(result))
    }
}
