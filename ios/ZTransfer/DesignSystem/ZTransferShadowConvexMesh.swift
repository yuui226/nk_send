// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// SkBaseShadowTessellator's convex ring/fan construction. Coordinates and
/// clipping polygon are already in device space; path transforms are separate.
enum ZTransferShadowConvexMesh {
    typealias Point = SIMD2<Float>
    struct Mesh {
        let points: [Point]
        let alphas: [UInt8]
        let indices: [UInt16]
    }
    static func make(polygon: ZTransferShadowPolygon, inset: Float, outset: Float,
                     transparent: Bool, clip: [Point]? = nil) -> Mesh? {
        if let clip {
            guard clip.count >= 3, clip.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        }
        guard polygon.points.count >= 3, polygon.points.count <= Int(UInt16.max),
              polygon.isConvex, inset.isFinite, inset >= 0, outset.isFinite, outset >= 0,
              polygon.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let umbra = ZTransferShadowUmbra.prepare(polygon: polygon, inset: inset) else { return nil }
        var builder = Builder(polygon: polygon, transparent: transparent, clip: clip ?? [])
        return builder.build(umbra: umbra, originalInset: inset, outset: outset, doClip: clip != nil)
    }
    private static func cross(_ a: Point, _ b: Point) -> Float { a.x * b.y - a.y * b.x }
    private static func distance(_ a: Point, _ b: Point) -> Float {
        let delta = a - b
        return delta.x * delta.x + delta.y * delta.y
    }
    private static func duplicate(_ a: Point, _ b: Point) -> Bool { distance(a, b) < 0.0625 * 0.0625 }
    private static func normal(_ a: Point, _ b: Point, direction: Float) -> Point? {
        let value = Point(a.y - b.y, b.x - a.x) * direction
        let x = Double(value.x), y = Double(value.y)
        let scale = 1 / sqrt(x * x + y * y)
        let result = Point(Float(x * scale), Float(y * scale))
        return result.x.isFinite && result.y.isFinite && result != .zero ? result : nil
    }
    /// SkComputeRadialSteps, including its loss-of-precision fallback.
    private static func radialSteps(_ a: Point, _ b: Point, offset: Float) -> (Int, Float, Float) {
        let cosine = a.x * b.x + a.y * b.y, sine = cross(a, b)
        guard cosine.isFinite, sine.isFinite else { return (0, 0, 1) }
        let theta = atan2(sine, cosine)
        let steps = abs(offset * theta * 0.25)
        guard steps.isFinite, steps < Float(UInt16.max) else { return (0, 0, 1) }
        let count = Int(floor(Double(steps) + 0.5))
        let delta = count > 0 ? theta / Float(count) : 0
        let rotationSine = sin(delta), rotationCosine = cos(delta)
        guard count == 0 || (rotationSine != 0 && rotationCosine != 1) else { return (0, 0, 1) }
        return (count, rotationSine, rotationCosine)
    }
    private struct Builder {
        let polygon: ZTransferShadowPolygon
        var transparent: Bool
        let clip: [Point]
        var clipVectors: [Point] = []
        var points: [Point] = []
        var alphas: [UInt8] = []
        var indices: [UInt16] = []
        var validUmbra = true
        var currentUmbra = 0, currentClip = 0
        var firstVertex = 0, previousUmbra = -1
        var firstOutside = false, previousOutside = false
        var previousPoint = Point.zero, previousOutset = Point.zero
        var failed = false

        mutating func vertex(_ point: Point, _ alpha: UInt8) {
            // Unlike unchecked uint16 conversion, reject a mesh whose vertices
            // cannot be addressed. The caller can select the general fallback.
            guard points.count < Int(UInt16.max) + 1, point.x.isFinite, point.y.isFinite else {
                failed = true
                return
            }
            points.append(point)
            alphas.append(alpha)
        }
        mutating func triangle(_ a: Int, _ b: Int, _ c: Int) {
            guard !failed, a >= 0, b >= 0, c >= 0, a < points.count, b < points.count, c < points.count else {
                failed = true
                return
            }
            indices.append(contentsOf: [UInt16(a), UInt16(b), UInt16(c)])
        }
        mutating func prepareClip() {
            currentClip = clip.count - 1
            let initial = cross(clip[1] - clip[0], polygon.centroid - clip[0])
            var hidden = true
            for index in clip.indices {
                let vector = clip[(index + 1) % clip.count] - clip[index]
                clipVectors.append(vector)
                if index > 0 && initial * cross(vector, polygon.centroid - clip[index]) <= 0 { hidden = false }
            }
            transparent = transparent || !hidden
        }
        mutating func clipPoint(_ umbra: Point) -> Point? {
            let vector = polygon.centroid - umbra
            let start = currentClip
            repeat {
                let delta = umbra - clip[currentClip]
                let denominator = cross(clipVectors[currentClip], vector)
                let t = cross(delta, vector)
                if abs(denominator) <= 1 / 4096 {
                    if abs(t) <= 1 / 4096 { return nil }
                } else if t >= 0 && t <= denominator {
                    let s = cross(delta, clipVectors[currentClip])
                    if s >= 0 && s <= denominator { return umbra + vector * (s / denominator) }
                }
                currentClip = (currentClip + 1) % clip.count
            } while currentClip != start
            return nil
        }
        mutating func closest(_ point: Point, ring: [Point]) -> Point {
            var minimum = distance(point, ring[currentUmbra])
            var index = currentUmbra, direction = 1
            var next = (index + direction) % ring.count
            var value = distance(point, ring[next])
            if value < minimum { index = next; minimum = value }
            else { direction = ring.count - 1 }
            next = (index + direction) % ring.count
            value = distance(point, ring[next])
            while value < minimum {
                index = next; minimum = value
                next = (index + direction) % ring.count
                value = distance(point, ring[next])
            }
            currentUmbra = index
            return ring[index]
        }
        mutating func inner(_ point: Point, alpha: UInt8, ring: [Point]) -> (index: Int, duplicate: Bool) {
            let innerPoint = validUmbra ? closest(point, ring: ring) : point + (polygon.centroid - point) * 0.95
            previousPoint = point
            if previousUmbra == -1 || !duplicate(innerPoint, points[previousUmbra]) {
                if previousUmbra >= 0 && duplicate(innerPoint, points[firstVertex]) { return (firstVertex, false) }
                let index = points.count
                vertex(innerPoint, alpha)
                return (index, false)
            }
            return (previousUmbra, true)
        }
        mutating func edge(_ point: Point, normal: Point, alpha: UInt8, ring: [Point], last: Bool, doClip: Bool) {
            let current: (index: Int, duplicate: Bool)
            if last { current = (firstVertex, false); previousPoint = point }
            else { current = inner(point, alpha: alpha, ring: ring) }
            guard !failed else { return }
            let penumbra = current.duplicate || current.index == firstVertex ? points.count - 1 : points.count - 2
            if !current.duplicate {
                if transparent { triangle(0, previousUmbra, current.index) }
                else if doClip {
                    let clipped = last ? nil : clipPoint(points[current.index])
                    let outside = last ? firstOutside : clipped != nil
                    if outside {
                        if let clipped { vertex(clipped, alpha) }
                        triangle(previousUmbra, current.index, current.index + 1)
                        if previousOutside { triangle(previousUmbra, current.index + 1, previousUmbra + 1) }
                    } else if previousOutside { triangle(previousUmbra, current.index, previousUmbra + 1) }
                    previousOutside = outside
                }
            }
            vertex(point + normal, 0)
            if !current.duplicate { triangle(previousUmbra, penumbra, current.index) }
            triangle(penumbra, points.count - 1, current.index)
            previousUmbra = current.index
            previousOutset = normal
        }
        mutating func arc(_ next: Point, offset: Float, finish: Bool) -> Bool {
            let (count, sine, cosine) = radialSteps(previousOutset, next, offset: offset)
            var normal = previousOutset
            if count > 1 {
                for _ in 0..<(count - 1) {
                    let current = Point(normal.x * cosine - normal.y * sine, normal.y * cosine + normal.x * sine)
                    vertex(previousPoint + current, 0)
                    triangle(previousUmbra, points.count - 1, points.count - 2)
                    if failed { return false }
                    normal = current
                }
            }
            if finish && count > 0 {
                vertex(previousPoint + next, 0)
                triangle(previousUmbra, points.count - 1, points.count - 2)
            }
            previousOutset = next
            return count > 0
        }
        mutating func build(umbra: ZTransferShadowUmbra, originalInset: Float, outset: Float, doClip: Bool) -> Mesh? {
            if doClip { prepareClip() }
            let ring: [Point]
            if originalInset > 1 / 4096 {
                let result = ZTransferShadowInset.inset(polygon.points, by: umbra.inset)
                validUmbra = result.isValid
                ring = umbra.inset > 1 / 4096 ? result.points : polygon.points
            } else { ring = polygon.points }
            if transparent { vertex(polygon.centroid, umbra.alpha) }
            let path = polygon.points
            guard let normal = normal(path[path.count - 1], path[0], direction: polygon.direction) else { return nil }
            let firstOutset = normal * outset
            firstVertex = points.count
            previousOutset = firstOutset
            let firstPoint = path[path.count - 1]
            previousPoint = firstPoint
            previousUmbra = inner(firstPoint, alpha: umbra.alpha, ring: ring).index
            guard !failed else { return nil }
            if !transparent && doClip {
                let clipped = clipPoint(points[firstVertex])
                if let clipped { vertex(clipped, umbra.alpha) }
                firstOutside = clipped != nil
                previousOutside = firstOutside
            }
            vertex(firstPoint + firstOutset, 0)
            edge(path[0], normal: firstOutset, alpha: umbra.alpha, ring: ring, last: false, doClip: doClip)
            for index in 1..<path.count {
                guard !failed, let normal = ZTransferShadowConvexMesh.normal(previousPoint, path[index], direction: polygon.direction) else { return nil }
                let outsetNormal = normal * outset
                _ = arc(outsetNormal, offset: outset, finish: true)
                guard !failed else { return nil }
                edge(path[index], normal: outsetNormal, alpha: umbra.alpha, ring: ring, last: index == path.count - 1, doClip: doClip)
            }
            guard !failed else { return nil }
            let firstPenumbra = firstVertex + (firstOutside ? 2 : 1)
            if arc(firstOutset, offset: outset, finish: false) { triangle(firstVertex, points.count - 1, firstPenumbra) }
            else { points[firstPenumbra] = points[points.count - 1] }
            guard !failed else { return nil }
            return Mesh(points: points, alphas: alphas, indices: indices)
        }
    }
}
