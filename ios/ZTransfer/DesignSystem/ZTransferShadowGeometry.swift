// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// Assembles the general rounded-rectangle tessellation path. An empty mesh is
/// a successful degenerate shadow; nil is a failed component requiring fallback.
/// Ambient and spot failures stay independent, as in SkShadowUtils.
enum ZTransferShadowGeometry {
    typealias Mesh = ZTransferShadowConvexMesh.Mesh
    struct Pair {
        let ambient: Mesh?
        let spot: Mesh?
    }
    static func roundedRect(minimum: SIMD2<Float>, maximum: SIMD2<Float>, radii: SIMD2<Float>,
                            transform: ZTransferShadowTransform, heightPlane: SIMD3<Float>,
                            light: SIMD3<Float>, lightRadius: Float,
                            transparent: Bool, directional: Bool = false) -> Pair? {
        guard transform.isFinite, [heightPlane.x, heightPlane.y, heightPlane.z].allSatisfy(\.isFinite),
              let path = ZTransferShadowPath.roundedRect(minimum: minimum, maximum: maximum, radii: radii) else { return nil }
        let low = SIMD2<Float>(min(minimum.x, maximum.x), min(minimum.y, maximum.y))
        let high = SIMD2<Float>(max(minimum.x, maximum.x), max(minimum.y, maximum.y))
        let center = SIMD2<Float>(Float(0.5 * (Double(low.x) + Double(high.x))),
                                  Float(0.5 * (Double(low.y) + Double(high.y))))
        let baseHeight = (heightPlane.x * center.x + heightPlane.y * center.y) + heightPlane.z
        let metrics = ZTransferAndroidShadowMetrics.projection(height: baseHeight,
            lightX: light.x, lightY: light.y, lightZ: light.z, lightRadius: lightRadius)
        func mesh(_ prepared: ZTransferShadowPath.Prepared, inset: Float, outset: Float, clipped: Bool) -> Mesh? {
            let polygon = prepared.polygon
            if polygon.points.count < 3 || !polygon.doubledArea.isFinite || (clipped && prepared.clip.count < 3) {
                return Mesh(points: [], alphas: [], indices: [])
            }
            // A convex source may become nonconvex after quantization. Leave
            // that failure visible to the caller until the concave path exists.
            return ZTransferShadowConvexMesh.make(polygon: polygon, inset: inset, outset: outset,
                transparent: transparent, clip: clipped ? prepared.clip : nil)
        }
        let ambient = ZTransferShadowPath.prepare(path, transform: transform).flatMap {
            mesh($0, inset: metrics.ambientBlurWidth - metrics.ambientOutset,
                 outset: metrics.ambientOutset, clipped: false)
        }
        var spot: Mesh?
        if [light.x, light.y, light.z, lightRadius].allSatisfy(\.isFinite),
           light.z >= 1 / 4096, lightRadius >= 1 / 4096,
           let projection = ZTransferShadowProjection.spot(boundsMinimum: low, boundsMaximum: high,
                transform: transform, heightPlane: heightPlane, light: light, lightRadius: lightRadius,
                directional: directional),
           let prepared = ZTransferShadowPath.prepare(path, transform: projection.transform, clipTransform: transform) {
            spot = mesh(prepared, inset: projection.outset, outset: projection.outset, clipped: true)
        }
        return Pair(ambient: ambient, spot: spot)
    }
}

extension ZTransferShadowGeometry {
    /// SkShadowUtils' last-resort paint recipe. It must be rasterized before a
    /// preparation with pending blur layers can be presented as a complete shadow.
    /// Sigma is device-space for both components. Ambient pretransforms its
    /// path before applying device-space stroke; spot keeps the original path
    /// and installs its projection as the drawing matrix (SkShadowUtils).
    struct BlurFallback {
        enum Style: Equatable {
            case fill
            case strokeAndFill(width: Float)
        }
        enum TransformApplication {
            case pathBeforeStyle
            case drawingMatrix
        }
        let transform: ZTransferShadowTransform
        let transformApplication: TransformApplication
        let sigma: Float
        let style: Style

        var pathTransform: ZTransferShadowTransform {
            switch transformApplication {
            case .pathBeforeStyle: transform
            case .drawingMatrix: .identity
            }
        }
        var drawingTransform: ZTransferShadowTransform {
            switch transformApplication {
            case .pathBeforeStyle: .identity
            case .drawingMatrix: transform
            }
        }

        struct DeviceRectangle {
            let bounds: SIMD4<Float>
            let sigma: Float
        }

        func rotatedIdentityRectangle(caster: ZTransferAndroidShadowMetrics.Caster) -> [SIMD4<Float>]? {
            guard transformApplication == .drawingMatrix, style == .fill, caster.radius == 0,
                  sigma.isFinite, sigma >= 0, sigma <= 0.03, transform.preservesRightAngles,
                  let quad = transform.rectangleQuad(bounds: .init(caster.minimum.x, caster.minimum.y, caster.maximum.x, caster.maximum.y))
            else { return nil }
            let vertices = ZTransferShadowBlur.coverageRectilinearVertices(quad)
            return vertices.count == 8 && vertices.allSatisfy({ v in (0..<4).allSatisfy { v[$0].isFinite } }) ? vertices : nil
        }

        struct OrientedRectangle {
            let bounds: SIMD4<Float>
            let inverse: ZTransferShadowTransform
            let proxy: [SIMD2<Float>]
            let sigma: Float
        }

        /// make_rect_blur factors scale into the rectangle, leaving rotation and
        /// translation to invert for fragment coordinates. Sigma stays device-space.
        func rotatedBlurredRectangle(caster: ZTransferAndroidShadowMetrics.Caster) -> OrientedRectangle? {
            guard transformApplication == .drawingMatrix, style == .fill, caster.radius == 0,
                  transform.preservesRightAngles, sigma.isFinite, sigma > 0.03,
                  caster.maximum.x > caster.minimum.x, caster.maximum.y > caster.minimum.y else { return nil }
            let sx = sqrt(transform.x.x * transform.x.x + transform.y.x * transform.y.x)
            let sy = sqrt(transform.x.y * transform.x.y + transform.y.y * transform.y.y)
            guard sx.isFinite, sy.isFinite, sx > 1 / 4096, sy > 1 / 4096 else { return nil }
            let ix = 1 / sx, iy = 1 / sy
            let rotation = ZTransferShadowTransform(x: .init(transform.x.x * ix, transform.x.y * iy, transform.x.z),
                y: .init(transform.y.x * ix, transform.y.y * iy, transform.y.z), perspective: .init(0,0,1))
            guard let inverse = rotation.inverted() else { return nil }
            let bounds = SIMD4(caster.minimum.x * sx, caster.minimum.y * sy, caster.maximum.x * sx, caster.maximum.y * sy)
            let outset = SIMD2(3 * filterSigma / sx, 3 * filterSigma / sy)
            let low = caster.minimum - outset, high = caster.maximum + outset
            guard let proxy = transform.rectangleQuad(bounds: .init(low.x,low.y,high.x,high.y)),
                  (0..<4).allSatisfy({ bounds[$0].isFinite }) else { return nil }
            return OrientedRectangle(bounds: bounds, inverse: inverse, proxy: proxy, sigma: filterSigma)
        }

        struct DeviceCircle {
            let center: SIMD2<Float>
            let radius: Float
            let sigma: Float
            var proxy: [SIMD2<Float>]? = nil
        }

        /// direct_filter_mask's device circle route, with an axis-preserving
        /// proxy. Arbitrary rotations need the original transformed proxy quad.
        /// A stroked circle cannot use the simple-fill optimization.
        func axisAlignedCircle(caster: ZTransferAndroidShadowMetrics.Caster) -> DeviceCircle? {
            guard style == .fill, caster.radius.isFinite, caster.radius > 0,
                  caster.maximum.x - caster.minimum.x == caster.maximum.y - caster.minimum.y,
                  caster.radius == (caster.maximum.x - caster.minimum.x) / 2 else { return nil }
            let rectangleCaster = ZTransferAndroidShadowMetrics.Caster(
                minimum: caster.minimum, maximum: caster.maximum, radius: 0)
            guard let rectangle = axisAlignedRectangle(caster: rectangleCaster), rectangle.sigma > 0.03,
                  rectangle.bounds.z - rectangle.bounds.x == rectangle.bounds.w - rectangle.bounds.y else { return nil }
            let bounds = rectangle.bounds
            let center = SIMD2<Float>(Float((Double(bounds.x) + Double(bounds.z)) * 0.5),
                                      Float((Double(bounds.y) + Double(bounds.w)) * 0.5))
            let radius = (bounds.z - bounds.x) / 2
            guard radius >= 1 / 4096 else { return nil }
            return DeviceCircle(center: center, radius: radius, sigma: rectangle.sigma)
        }

        /// direct_filter_mask: source circle + similarity, retaining the rotated
        /// source proxy quad. This differs from CircleOp's mapRadius formula.
        func rotatedBlurredCircle(caster: ZTransferAndroidShadowMetrics.Caster) -> DeviceCircle? {
            guard transformApplication == .drawingMatrix, style == .fill, transform.isSimilarity,
                  xformedCircleSource(caster), sigma.isFinite, sigma > 0.03 else { return nil }
            let sx = sqrt(transform.x.x * transform.x.x + transform.y.x * transform.y.x)
            let sy = sqrt(transform.x.y * transform.x.y + transform.y.y * transform.y.y)
            guard sx.isFinite, sy.isFinite, sx > 1 / 4096, sy > 1 / 4096 else { return nil }
            let effective = filterSigma
            let sourceCenter = SIMD2<Float>(Float((Double(caster.minimum.x) + Double(caster.maximum.x)) * 0.5),
                                            Float((Double(caster.minimum.y) + Double(caster.maximum.y)) * 0.5))
            let center = transform.map(sourceCenter)
            let vector = SIMD2(transform.x.y, transform.y.y) * caster.radius
            let radius = sqrt(vector.x * vector.x + vector.y * vector.y)
            guard radius.isFinite, radius >= 1 / 4096 else { return nil }
            let outset = SIMD2(3 * effective / sx, 3 * effective / sy)
            let low = caster.minimum - outset, high = caster.maximum + outset
            guard let quad = transform.rectangleQuad(bounds: .init(low.x,low.y,high.x,high.y)) else { return nil }
            return DeviceCircle(center: center, radius: radius, sigma: effective, proxy: quad)
        }

        private func xformedCircleSource(_ caster: ZTransferAndroidShadowMetrics.Caster) -> Bool {
            caster.radius.isFinite && caster.radius > 0
                && caster.maximum.x - caster.minimum.x == caster.maximum.y - caster.minimum.y
                && caster.radius == (caster.maximum.x - caster.minimum.x) / 2
        }

        /// CircleOp maps source center and mapRadius for drawingMatrix, while
        /// a pretransformed circle is drawn with the identity matrix.
        func identityCircle(caster: ZTransferAndroidShadowMetrics.Caster) -> DeviceCircle? {
            guard style == .fill, sigma.isFinite, sigma >= 0, sigma <= 0.03,
                  caster.radius.isFinite, caster.radius > 0,
                  caster.maximum.x - caster.minimum.x == caster.maximum.y - caster.minimum.y,
                  caster.radius == (caster.maximum.x - caster.minimum.x) / 2 else { return nil }
            let center: SIMD2<Float>
            let radius: Float
            if transformApplication == .pathBeforeStyle {
                guard let shape = axisAlignedRoundedRectangle(caster: caster),
                      shape.bounds.z - shape.bounds.x == shape.bounds.w - shape.bounds.y else { return nil }
                center = .init(Float((Double(shape.bounds.x) + Double(shape.bounds.z)) * 0.5),
                               Float((Double(shape.bounds.y) + Double(shape.bounds.w)) * 0.5))
                radius = (shape.bounds.z - shape.bounds.x) / 2
            } else {
                guard transform.isSimilarity else { return nil }
                center = transform.map(.init(Float((Double(caster.minimum.x) + Double(caster.maximum.x)) * 0.5),
                                             Float((Double(caster.minimum.y) + Double(caster.maximum.y)) * 0.5)))
                let a = SIMD2(transform.x.x, transform.y.x) * caster.radius
                let b = SIMD2(transform.x.y, transform.y.y) * caster.radius
                radius = sqrt(sqrt(a.x * a.x + a.y * a.y) * sqrt(b.x * b.x + b.y * b.y))
            }
            guard radius.isFinite, radius > 0, center.x.isFinite, center.y.isFinite else { return nil }
            return DeviceCircle(center: center, radius: radius, sigma: sigma)
        }

        /// Simple circular device rrect for the coverage-AA nine-patch route.
        /// Spot retains its drawing matrix, which direct_filter_mask requires to
        /// be scale/translate; a pretransformed path uses the identity draw matrix.
        struct DeviceRoundedRectangle {
            let bounds: SIMD4<Float>
            let radius: Float
            let sigma: Float
        }

        func axisAlignedRoundedRectangle(caster: ZTransferAndroidShadowMetrics.Caster) -> DeviceRoundedRectangle? {
            guard style == .fill, caster.radius.isFinite, caster.radius > 0,
                  caster.radius <= min(caster.maximum.x - caster.minimum.x, caster.maximum.y - caster.minimum.y) / 2
            else { return nil }
            let rectangleCaster = ZTransferAndroidShadowMetrics.Caster(minimum: caster.minimum, maximum: caster.maximum, radius: 0)
            guard let rectangle = axisAlignedRectangle(caster: rectangleCaster) else { return nil }
            let scaleX = transform.x.x == 0 ? abs(transform.x.y) : abs(transform.x.x)
            let scaleY = transform.y.y == 0 ? abs(transform.y.x) : abs(transform.y.y)
            let radiusX = caster.radius * scaleX, radiusY = caster.radius * scaleY
            guard radiusX == radiusY else { return nil }
            return DeviceRoundedRectangle(bounds: rectangle.bounds, radius: radiusX, sigma: rectangle.sigma)
        }

        func roundedRectanglePlan(caster: ZTransferAndroidShadowMetrics.Caster) -> ZTransferShadowBlur.RoundedRectanglePlan? {
            guard transformApplication == .pathBeforeStyle || (transform.x.y == 0 && transform.y.x == 0),
                  let shape = axisAlignedRoundedRectangle(caster: caster) else { return nil }
            return ZTransferShadowBlur.roundedRectanglePlan(bounds: shape.bounds, radius: shape.radius, sigma: shape.sigma)
        }

        /// GrStyledShape::simplifyStroke reduces a default-miter stroke+filled
        /// rectangle to an outset fill. Ambient's stroke is applied AFTER path
        /// mapping. Rotated/sheared/perspective paths and rounded corners need
        /// other routes; do not replace them with their bounding rectangle.
        func axisAlignedRectangle(caster: ZTransferAndroidShadowMetrics.Caster) -> DeviceRectangle? {
            guard caster.radius == 0, transform.isFinite, !transform.hasPerspective,
                  caster.minimum.x.isFinite, caster.minimum.y.isFinite,
                  caster.maximum.x.isFinite, caster.maximum.y.isFinite,
                  caster.maximum.x > caster.minimum.x, caster.maximum.y > caster.minimum.y,
                  sigma.isFinite, sigma >= 0 else { return nil }
            let diagonal = transform.x.y == 0 && transform.y.x == 0 && transform.x.x != 0 && transform.y.y != 0
            let quarterTurn = transform.x.x == 0 && transform.y.y == 0 && transform.x.y != 0 && transform.y.x != 0
            guard diagonal || quarterTurn else { return nil }
            let a = transform.map(caster.minimum), b = transform.map(caster.maximum)
            var bounds = SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
            switch style {
            case .fill: break
            case .strokeAndFill(let width):
                // Only ambient currently provides this style. A drawing-matrix
                // stroke cannot use this device-space simplification.
                guard transformApplication == .pathBeforeStyle, width.isFinite, width >= 0 else { return nil }
                let outset = width / 2
                bounds += .init(-outset, -outset, outset, outset)
            }
            guard (0..<4).allSatisfy({ bounds[$0].isFinite }), bounds.z > bounds.x, bounds.w > bounds.y else { return nil }
            return DeviceRectangle(bounds: bounds, sigma: filterSigma)
        }

        /// The paint keeps the requested sigma, but SkBlurMaskFilterImpl caps
        /// the effective filter at 128. Shadow paints set respectCTM=false.
        var filterSigma: Float { min(sigma, 128) }
    }

    private static func blurSigma(radius: Float) -> Float {
        // SkBlurMask::ConvertRadiusToSigma, not the tessellated Gaussian curve.
        radius > 0 ? 0.57735 * radius + 0.5 : 0
    }

    static func ambientFallback(transform: ZTransferShadowTransform, height: Float) -> BlurFallback? {
        guard transform.isFinite, height.isFinite else { return nil }
        let outset = ZTransferAndroidShadowMetrics.ambientOutset(height: height)
        let reciprocalAlpha = ZTransferAndroidShadowMetrics.ambientReciprocalAlpha(height: height)
        let radius = 0.5 * outset * reciprocalAlpha
        // A new SkPaint starts at zero; setStrokeWidth ignores negative widths.
        let stroke = max(0, 0.5 * (outset - radius))
        let sigma = blurSigma(radius: radius)
        guard sigma.isFinite, stroke.isFinite else { return nil }
        return BlurFallback(transform: transform, transformApplication: .pathBeforeStyle, sigma: sigma, style: .strokeAndFill(width: stroke))
    }

    static func spotFallback(minimum: SIMD2<Float>, maximum: SIMD2<Float>,
                             transform: ZTransferShadowTransform, heightPlane: SIMD3<Float>,
                             light: SIMD3<Float>, lightRadius: Float,
                             directional: Bool = false) -> BlurFallback? {
        let low = SIMD2<Float>(min(minimum.x, maximum.x), min(minimum.y, maximum.y))
        let high = SIMD2<Float>(max(minimum.x, maximum.x), max(minimum.y, maximum.y))
        guard let projection = ZTransferShadowProjection.spot(boundsMinimum: low, boundsMaximum: high,
            transform: transform, heightPlane: heightPlane, light: light, lightRadius: lightRadius,
            directional: directional) else { return nil }
        let sigma = blurSigma(radius: projection.outset)
        guard sigma.isFinite else { return nil }
        return BlurFallback(transform: projection.transform, transformApplication: .drawingMatrix, sigma: sigma, style: .fill)
    }
}
