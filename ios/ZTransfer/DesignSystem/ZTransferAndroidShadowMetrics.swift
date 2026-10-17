// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// Skia android-15.0.0_r1 SkDrawShadowInfo.h / ShadowRRectOp.cpp.
/// All inputs and outputs are device pixels, as in HWUI. These are projection
/// parameters, not Core Animation blur radii. Rendering is integrated separately.
enum ZTransferAndroidShadowMetrics {
    struct Projection: Equatable {
        let ambientOutset: Float
        let ambientBlurWidth: Float
        let spotOutset: Float
        let spotBlurWidth: Float
        let spotScale: Float
        let spotTranslationX: Float
        let spotTranslationY: Float
    }

    static func ambientOutset(height: Float) -> Float { min(height * (1 / 128) * 64, 150) }
    static func ambientReciprocalAlpha(height: Float) -> Float { 1 + max(height * (1 / 128), 0) }

    static func projection(height: Float, lightX: Float, lightY: Float,
                           lightZ: Float, lightRadius: Float) -> Projection {
        let ambientOutset = Self.ambientOutset(height: height)
        let ambientReciprocalAlpha = Self.ambientReciprocalAlpha(height: height)
        let ratio = min(max(height / (lightZ - height), 0), 0.95)
        let scale = min(max(lightZ / (lightZ - height), 1), 1.95)
        let spotOutset = lightRadius * ratio
        return Projection(ambientOutset: ambientOutset,
            ambientBlurWidth: ambientOutset * ambientReciprocalAlpha,
            spotOutset: spotOutset, spotBlurWidth: 2 * spotOutset,
            spotScale: scale, spotTranslationX: -ratio * lightX,
            spotTranslationY: -ratio * lightY)
    }

    /// GPU path's A8 falloff texture, with SkScalar (Float) intermediate math.
    /// Values are normalized by the sampler when the renderer consumes it.
    static let falloff: [UInt8] = (0..<128).map { index in
        let d: Float = 1 - Float(index) / 127
        let value = (exp(-4 * d * d) - Float(0.018)) * 255
        return UInt8(value.rounded(.toNearestOrAwayFromZero))
    }
}

extension ZTransferAndroidShadowMetrics {
    struct Vertex: Equatable {
        let position: SIMD2<Float>
        let offset: SIMD2<Float>
        let distanceCorrection: Float
    }

    struct RoundedRectMesh {
        enum Kind: Int { case fill, stroke, overstroke }
        let kind: Kind
        let vertices: [Vertex]
        let indices: [UInt16]
    }

    /// ShadowCircularRRectOp's non-circle path. Bounds and radius already include
    /// the projection's outset. A circle uses a separate octagon mesh in Skia.
    /// Invalid/empty inputs produce no geometry; the caller must skip drawing.
    static func roundedRectMesh(left: Float, top: Float, right: Float, bottom: Float,
                                radius: Float, blurWidth: Float,
                                insetWidth: Float) -> RoundedRectMesh? {
        guard [left, top, right, bottom, radius, blurWidth, insetWidth].allSatisfy(\.isFinite),
              right > left, bottom > top, radius >= 0, blurWidth > 0, insetWidth > 0 else { return nil }
        let halfMinimum = min(right - left, bottom - top) * 0.5
        // Device mapping can round the bounds differently from the scaled
        // radius. ShadowCircularRRectOp permits that; only umbra is capped below.
        // Type selection uses the original umbra inset, before vertex generation
        // clamps it to the available half-size. Moving this clamp changes topology.
        let originalUmbra = max(radius, blurWidth)
        let innerRadius = max(insetWidth - originalUmbra, 0)
        let kind: RoundedRectMesh.Kind = insetWidth > halfMinimum ? .fill
            : (innerRadius > 0 ? .overstroke : .stroke)
        let umbra = min(originalUmbra, halfMinimum)
        let correction = umbra / blurWidth
        let outer = SIMD2<Float>(radius - umbra, -radius - umbra)
        let outerVector = outer / sqrt(outer.x * outer.x + outer.y * outer.y)
        let diagonal = umbra / (sqrt(Float(2)) * (radius - umbra) - radius)
        var vertices: [Vertex] = []
        vertices.reserveCapacity(kind == .overstroke ? 28 : 24)
        for corner in 0..<4 {
            let isRight = corner % 2 == 1
            let isBottom = corner >= 2
            let xOuter = isRight ? right : left
            let yOuter = isBottom ? bottom : top
            let xInner = xOuter + (isRight ? -umbra : umbra)
            let yInner = yOuter + (isBottom ? -umbra : umbra)
            let xMid = xOuter + (isRight ? -radius : radius)
            let yMid = yOuter + (isBottom ? -radius : radius)
            let positions: [SIMD2<Float>] = [
                .init(xInner, yInner), .init(xOuter, yInner), .init(xOuter, yMid),
                .init(xOuter, yOuter), .init(xMid, yOuter), .init(xInner, yOuter)
            ]
            let offsets: [SIMD2<Float>] = [
                .zero, .init(0, -1), outerVector, .init(repeating: diagonal), outerVector, .init(0, -1)
            ]
            vertices += zip(positions, offsets).map {
                Vertex(position: $0, offset: $1, distanceCorrection: correction)
            }
        }
        if kind == .overstroke {
            let inset = umbra + innerRadius
            for corner in 0..<4 {
                vertices.append(Vertex(position: .init(
                    corner % 2 == 1 ? right - inset : left + inset,
                    corner >= 2 ? bottom - inset : top + inset),
                    offset: .zero, distanceCorrection: correction))
            }
        }
        let first = kind == .overstroke ? 0 : 24
        let end = kind == .fill ? roundedRectIndices.count : roundedRectIndices.count - 6
        return RoundedRectMesh(kind: kind, vertices: vertices, indices: Array(roundedRectIndices[first..<end]))
    }

    private static let roundedRectIndices: [UInt16] = [
        0,6,25, 0,25,24, 6,18,27, 6,27,25, 18,12,26, 18,26,27, 12,0,24, 12,24,26,
        0,1,2, 0,2,3, 0,3,4, 0,4,5,
        6,11,10, 6,10,9, 6,9,8, 6,8,7,
        12,17,16, 12,16,15, 12,15,14, 12,14,13,
        18,19,20, 18,20,21, 18,21,22, 18,22,23,
        0,5,11, 0,11,6, 6,7,19, 6,19,18, 18,23,17, 18,17,12, 12,13,1, 12,1,0,
        0,6,18, 0,18,12
    ]
}

extension ZTransferAndroidShadowMetrics {
    /// ShadowCircularRRectOp's circle geometry. Preserve upstream's literal inner
    /// ring constants (including 0.923579533); recomputing cos(pi/8) changes it.
    static func circleMesh(center: SIMD2<Float>, radius: Float, blurWidth: Float,
                           insetWidth: Float) -> RoundedRectMesh? {
        guard [center.x, center.y, radius, blurWidth, insetWidth].allSatisfy(\.isFinite),
              radius > 0, blurWidth > 0, insetWidth > 0 else { return nil }
        let innerRadius = radius - insetWidth
        let stroked = innerRadius > 0
        let correction = radius / blurWidth
        let oct: Float = 0.41421356237
        let outer: [SIMD2<Float>] = [
            .init(-oct, -1), .init(oct, -1), .init(1, -oct), .init(1, oct),
            .init(oct, 1), .init(-oct, 1), .init(-1, oct), .init(-1, -oct)
        ]
        var vertices = outer.map {
            Vertex(position: center + $0 * radius, offset: $0, distanceCorrection: correction)
        }
        if stroked {
            let c: Float = 0.923579533
            let s: Float = 0.382683432
            let normalized = innerRadius / radius
            let inner: [SIMD2<Float>] = [
                .init(-s, -c), .init(s, -c), .init(c, -s), .init(c, s),
                .init(s, c), .init(-s, c), .init(-c, s), .init(-c, -s)
            ]
            vertices += inner.map {
                Vertex(position: center + $0 * innerRadius, offset: $0 * normalized,
                       distanceCorrection: correction)
            }
        } else {
            vertices.append(Vertex(position: center, offset: .zero, distanceCorrection: correction))
        }
        var indices: [UInt16] = []
        for i: UInt16 in 0..<8 {
            let next = (i + 1) % 8
            if stroked {
                indices += [i, next, next + 8, i, next + 8, i + 8]
            } else {
                indices += [i, next, 8]
            }
        }
        return RoundedRectMesh(kind: stroked ? .stroke : .fill, vertices: vertices, indices: indices)
    }
}

extension ZTransferAndroidShadowMetrics {
    enum QuarterTurn: Int, CaseIterable {
        case zero, clockwise, half, counterclockwise
        func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
            switch self {
            case .zero: return point
            case .clockwise: return .init(-point.y, point.x)
            case .half: return -point
            case .counterclockwise: return .init(point.y, -point.x)
            }
        }
        var inverse: QuarterTurn { QuarterTurn(rawValue: (4 - rawValue) % 4)! }
    }

    struct Caster {
        let minimum: SIMD2<Float>
        let maximum: SIMD2<Float>
        let radius: Float
    }

    /// The axis-preserving similarity branch of SurfaceDrawContext.drawFastShadow.
    /// Caster coordinates are local; light is already in device coordinates.
    /// Other rotation, perspective and noncircular corners need the separate path route.
    struct ShadowGeometry {
        let caster: Caster
        let blurWidth: Float
        let insetWidth: Float
        let isCircle: Bool

        func mesh() -> RoundedRectMesh? {
            if isCircle {
                return circleMesh(center: .init(Float(0.5 * (Double(caster.minimum.x) + Double(caster.maximum.x))),
                                               Float(0.5 * (Double(caster.minimum.y) + Double(caster.maximum.y)))),
                                  radius: caster.radius, blurWidth: blurWidth, insetWidth: insetWidth)
            }
            return roundedRectMesh(left: caster.minimum.x, top: caster.minimum.y,
                right: caster.maximum.x, bottom: caster.maximum.y, radius: caster.radius,
                blurWidth: blurWidth, insetWidth: insetWidth)
        }
    }

    struct ShadowPair {
        let ambient: ShadowGeometry
        let spot: ShadowGeometry
    }

    /// SkRRect rules needed by drawFastShadow: circular input, uniform spot
    /// projection, and penumbra outset. Type is retained independently of radius.
    private struct AnalyticRRect {
        let minimum, maximum: SIMD2<Float>
        let radius: Float
        let isOval: Bool

        init(minimum: SIMD2<Float>, maximum: SIMD2<Float>, radius: Float, oval: Bool = false) {
            self.minimum = minimum
            self.maximum = maximum
            let size = maximum - minimum
            if oval {
                // MakeOval uses a Double midpoint; transform uses Float width/2.
                self.radius = Float(0.5 * (Double(maximum.x) - Double(minimum.x)))
                isOval = self.radius > 0 && maximum.y > minimum.y
            } else {
                var r = radius
                if size.x < r + r || size.y < r + r {
                    r *= min(size.x / (r + r), size.y / (r + r))
                }
                self.radius = max(0, r)
                isOval = r > 0 && r >= size.x * 0.5 && r >= size.y * 0.5
            }
        }

        private init(minimum: SIMD2<Float>, maximum: SIMD2<Float>, radius: Float, isOval: Bool) {
            self.minimum = minimum
            self.maximum = maximum
            self.radius = radius
            self.isOval = isOval
        }

        func outset(_ amount: Float) -> Self {
            Self(minimum: minimum - SIMD2(repeating: amount), maximum: maximum + SIMD2(repeating: amount),
                 radius: radius + amount, oval: isOval)
        }

        func projected(scale: Float, offset: SIMD2<Float>) -> Self? {
            if scale == 1 && offset == .zero { return self }
            let low = minimum * scale + offset, high = maximum * scale + offset
            guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite,
                  high.x > low.x, high.y > low.y else { return nil }
            if radius == 0 { return Self(minimum: low, maximum: high, radius: 0, isOval: false) }
            if isOval {
                return Self(minimum: low, maximum: high, radius: (high.x - low.x) * 0.5, isOval: true)
            }
            let r = radius * scale
            // AreRectAndRadiiValid precedes scaleRadii in SkRRect::transform.
            for axis in 0..<2 {
                guard r <= high[axis] - low[axis], low[axis] + r <= high[axis],
                      high[axis] - r >= low[axis], r >= 0 else { return nil }
            }
            var radii = [SIMD2<Float>](repeating: .init(repeating: r), count: 4)
            let width = Double(high.x) - Double(low.x), height = Double(high.y) - Double(low.y)
            let sum = Double(r) + Double(r)
            let factor = min(1, width / sum, height / sum)
            if factor < 1 {
                // AdjustRadii can make the two members differ by one ULP. Keep
                // all four corners until computeType has observed that result.
                for (a, b, axis, limit) in [(0, 1, 0, width), (1, 2, 1, height),
                                          (2, 3, 0, width), (3, 0, 1, height)] {
                    var first = Float(Double(radii[a][axis]) * factor)
                    var second = Float(Double(radii[b][axis]) * factor)
                    if Double(first + second) > limit {
                        if first > second {
                            first = Float(limit - Double(second))
                            while Double(first + second) > limit { first = first.nextDown }
                        } else {
                            second = Float(limit - Double(first))
                            while Double(first + second) > limit { second = second.nextDown }
                        }
                    }
                    radii[a][axis] = first
                    radii[b][axis] = second
                }
            }
            for i in radii.indices where radii[i].x <= 0 || radii[i].y <= 0 { radii[i] = .zero }
            let equal = radii.dropFirst().allSatisfy { $0 == radii[0] }
            let oval = equal && radii[0].x > 0 && radii[0].y > 0
                && radii[0].x >= (high.x - low.x) * 0.5 && radii[0].y >= (high.y - low.y) * 0.5
            return Self(minimum: low, maximum: high, radius: radii[0].x, isOval: oval)
        }
    }

    static func shadowGeometry(caster: Caster, height: Float, light: SIMD3<Float>,
                               lightRadius: Float, scale: Float = 1,
                               translation: SIMD2<Float> = .zero,
                               rotation: QuarterTurn = .zero, reflected: Bool = false,
                               transparent: Bool) -> ShadowPair? {
        guard scale.isFinite, scale > 0 else { return nil }
        let basisX = rotation.apply(SIMD2<Float>(reflected ? -scale : scale, 0))
        let basisY = rotation.apply(SIMD2<Float>(0, scale))
        return shadowGeometry(caster: caster, height: height, light: light, lightRadius: lightRadius,
            transform: .init(x: .init(basisX.x, basisY.x, translation.x),
                             y: .init(basisX.y, basisY.y, translation.y), perspective: .init(0, 0, 1)),
            transparent: transparent)
    }

    /// Retains both original axes, including Skia's accepted near-similar scales.
    static func shadowGeometry(caster: Caster, height: Float, light: SIMD3<Float>,
                               lightRadius: Float, transform: ZTransferShadowTransform,
                               transparent: Bool) -> ShadowPair? {
        guard transform.supportsAnalyticShadow, let inverse = transform.inverted() else { return nil }
        let devToSrcScale: Float = transform.x.y == 0 && transform.y.x == 0
            ? 1 / abs(transform.x.x)
            : 1 / sqrt(transform.x.x * transform.x.x + transform.x.y * transform.x.y)
        let matrixFactor = transform.x.x + transform.x.y
        let values = [caster.minimum.x, caster.minimum.y, caster.maximum.x, caster.maximum.y,
                      caster.radius, height, light.x, light.y, light.z, lightRadius,
                      devToSrcScale, matrixFactor]
        let size = caster.maximum - caster.minimum
        guard values.allSatisfy(\.isFinite), size.x > 0, size.y > 0,
              caster.radius >= 0, caster.radius <= min(size.x, size.y) * 0.5,
              height > 0, lightRadius > 0 else { return nil }
        let metrics = projection(height: height, lightX: light.x, lightY: light.y,
                                 lightZ: light.z, lightRadius: lightRadius)
        let ambientOutset = metrics.ambientOutset * devToSrcScale
        let original = AnalyticRRect(minimum: caster.minimum, maximum: caster.maximum, radius: caster.radius)
        let ambient = original.outset(ambientOutset)
        // Upstream passes a device-space inset to Make, which scales it once more.
        // Preserve this behavior rather than simplifying the apparent unit mismatch.
        let ambientInset = transparent ? ambient.maximum.x - ambient.minimum.x : metrics.ambientOutset
        var spotOffset = SIMD2(metrics.spotTranslationX, metrics.spotTranslationY)
        spotOffset.x += metrics.spotScale * transform.x.z
        spotOffset.y += metrics.spotScale * transform.y.z
        spotOffset = inverse.map(spotOffset)
        guard let projected = original.projected(scale: metrics.spotScale, offset: spotOffset) else { return nil }
        let blurOutset = metrics.spotOutset * devToSrcScale
        var inset = blurOutset
        if transparent {
            inset += projected.maximum.x - projected.minimum.x
        } else {
            let minDelta = projected.minimum - caster.minimum
            let maxDelta = projected.maximum - caster.maximum
            let maximumOffset: Float
            if original.radius == 0 {
                maximumOffset = max(abs(minDelta.x), abs(minDelta.y), abs(maxDelta.x), abs(maxDelta.y))
            } else {
                let dr = projected.radius - original.radius
                let upper = minDelta + SIMD2(repeating: dr)
                let lower = maxDelta - SIMD2(repeating: dr)
                maximumOffset = sqrt(max(upper.x * upper.x + upper.y * upper.y,
                                         lower.x * lower.x + lower.y * lower.y)) + dr
            }
            inset += max(blurOutset, maximumOffset)
        }
        let spot = projected.outset(blurOutset)
        func mapped(_ shape: AnalyticRRect, blur: Float, inset: Float) -> ShadowGeometry {
            let first = transform.map(shape.minimum)
            let second = transform.map(shape.maximum)
            let minimum = SIMD2<Float>(min(first.x, second.x), min(first.y, second.y))
            let maximum = SIMD2<Float>(max(first.x, second.x), max(first.y, second.y))
            return ShadowGeometry(caster: .init(minimum: minimum, maximum: maximum,
                                               radius: abs(shape.radius * matrixFactor)),
                                  blurWidth: blur, insetWidth: abs(inset * matrixFactor),
                                  isCircle: shape.isOval)
        }
        return ShadowPair(ambient: mapped(ambient, blur: metrics.ambientBlurWidth, inset: ambientInset),
                          spot: mapped(spot, blur: metrics.spotBlurWidth, inset: inset))
    }
}

// Lighting calculations follow AOSP Android 15; attribution in
// Resources/licenses/AOSP-shadow-NOTICE.txt (Apache-2.0).
extension ZTransferAndroidShadowMetrics {
    struct Lighting {
        let center: SIMD3<Float>
        let radius: Float
        let ambientAlpha: UInt8
        let spotAlpha: UInt8
    }

    struct Opacity {
        let ambient: UInt8
        let spot: UInt8
        let transparentOccluder: Bool
    }

    /// AOSP Material defaults and ThreadedRenderer.setLightCenter. Display size
    /// and window origin are physical pixels; density maps Android dp to pixels.
    /// OEM theme/debug light overrides are not inferred from iOS display data.
    static func materialLighting(displayPixels: SIMD2<Float>, density: Float,
                                 windowOriginPixels: SIMD2<Float> = .zero) -> Lighting? {
        guard [displayPixels.x, displayPixels.y, density,
               windowOriginPixels.x, windowOriginPixels.y].allSatisfy(\.isFinite),
              displayPixels.x > 0, displayPixels.y > 0, density > 0 else { return nil }
        let zRatio = min(displayPixels.x, displayPixels.y) / (450 * density)
        return Lighting(center: .init(displayPixels.x / 2 - windowOriginPixels.x,
                                      -windowOriginPixels.y,
                                      500 * density * ((zRatio + 2) / 3)),
                        radius: 800 * density,
                        ambientAlpha: UInt8(Float(255) * 0.039),
                        spotAlpha: UInt8(Float(255) * 0.19))
    }

    /// Mirrors HWUI's theme-byte -> float -> color-byte sequence. The outline's
    /// alpha is a RenderNode property, not the Surface background paint opacity.
    static func opacity(lighting: Lighting, nodeAlpha: Float, outlineAlpha: Float) -> Opacity? {
        guard nodeAlpha.isFinite, outlineAlpha.isFinite,
              (0...1).contains(nodeAlpha), (0...1).contains(outlineAlpha) else { return nil }
        let casterAlpha = nodeAlpha * outlineAlpha
        return Opacity(ambient: UInt8((Float(lighting.ambientAlpha) / 255) * casterAlpha * 255),
                       spot: UInt8((Float(lighting.spotAlpha) / 255) * casterAlpha * 255),
                       transparentOccluder: casterAlpha < 1)
    }
}
