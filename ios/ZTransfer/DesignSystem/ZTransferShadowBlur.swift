// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// Android 15 SkShaderBlurAlgorithm kernels. Large sigmas must be downsampled
/// by the caller; these functions do not silently change the requested blur.
enum ZTransferShadowBlur {
    static let coverageCircleIndices: [UInt16] = [0,1,8,1,2,8,2,3,8,3,4,8,4,5,8,5,6,8,6,7,8,7,0,8]

    /// CircleOp fill: circumscribed octagon plus center, not an rrect grid.
    static func coverageCircleVertices(center: SIMD2<Float>, radius: Float) -> [SIMD4<Float>] {
        let outer = radius + 0.5
        let low = center - SIMD2(repeating: outer), high = center + SIMD2(repeating: outer)
        let midpoint = SIMD2<Float>(Float((Double(low.x) + Double(high.x)) * 0.5),
                                    Float((Double(low.y) + Double(high.y)) * 0.5))
        let halfWidth = (high.x - low.x) * 0.5
        let k: Float = 0.41421356237
        let offsets: [SIMD2<Float>] = [.init(-k,-1), .init(k,-1), .init(1,-k), .init(1,k),
            .init(k,1), .init(-k,1), .init(-1,k), .init(-1,-k), .zero]
        return offsets.map { offset in
            let point = midpoint + offset * halfWidth
            return .init(point.x, point.y, offset.x, offset.y)
        }
    }

    static let coverageRoundedRectangleIndices: [UInt16] = [0,1,5,0,5,4, 2,3,7,2,7,6,
        8,9,13,8,13,12, 10,11,15,10,15,14, 1,2,6,1,6,5, 4,5,9,4,9,8,
        6,7,11,6,11,10, 9,10,14,9,14,13, 5,6,10,5,10,9]

    /// CircularRRectOp's filled 16-vertex grid, shared by A8 and direct color draws.
    static func coverageRoundedRectangleVertices(bounds rect: SIMD4<Float>, radius: Float) -> [SIMD4<Float>] {
        let bounds = rect + SIMD4<Float>(-0.5, -0.5, 0.5, 0.5)
        let outer = radius + 0.5
        let xs = [bounds.x, bounds.x + outer, bounds.z - outer, bounds.z]
        let ys = [bounds.y, bounds.y + outer, bounds.w - outer, bounds.w]
        let offsets: [Float] = [-1, 0, 0, 1]
        return (0..<16).map { i in .init(xs[i % 4], ys[i / 4], offsets[i % 4], offsets[i / 4]) }
    }

    static let coverageRectangleIndices: [UInt16] = [0, 1, 2, 1, 3, 2, 0, 4, 1, 4, 5, 1,
        0, 6, 4, 0, 2, 6, 2, 3, 6, 3, 7, 6, 1, 5, 3, 3, 5, 7]

    /// Axis-aligned specialization of GrQuadUtils::TessellationHelper. Keep the
    /// normalize/reciprocal and edge-equation operations rather than replacing
    /// them with width/height formulas: Float rounding is visible near collapse.
    static func coverageRectangleVertices(_ rect: SIMD4<Float>) -> [SIMD4<Float>] {
        coverageRectilinearVertices([.init(rect.x,rect.y), .init(rect.x,rect.w), .init(rect.z,rect.y), .init(rect.z,rect.w)])
    }

    /// Caller establishes GrQuad::kRectilinear or kAxisAligned. Not a general
    /// quadrilateral tessellator; shear/perspective need different angle handling.
    static func coverageRectilinearVertices(_ quad: [SIMD2<Float>]) -> [SIMD4<Float>] {
        guard quad.count == 4 else { return [] }
        typealias V = SIMD4<Float>
        func cw(_ v: V) -> V { .init(v.z, v.x, v.w, v.y) }
        func ccw(_ v: V) -> V { .init(v.y, v.w, v.x, v.z) }
        func minimum(_ a: V, _ b: V) -> V { .init(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z), min(a.w, b.w)) }
        func maximum(_ a: V, _ b: V) -> V { .init(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z), max(a.w, b.w)) }
        let x = V(quad[0].x, quad[1].x, quad[2].x, quad[3].x), y = V(quad[0].y, quad[1].y, quad[2].y, quad[3].y)
        let edgeX = ccw(x) - x, edgeY = ccw(y) - y
        let squared = edgeX * edgeX + edgeY * edgeY
        let inverse = V(repeating: 1) / V(squared.x.squareRoot(), squared.y.squareRoot(), squared.z.squareRoot(), squared.w.squareRoot())
        let dx = edgeX * inverse, dy = edgeY * inverse
        func moved(_ distance: V) -> (V, V) {
            let along = -cw(distance)
            return (x + (distance * cw(dx) + along * dx), y + (distance * cw(dy) + along * dy))
        }
        let degenerate = inverse.y > 1 || inverse.x > 1
        let inset = degenerate ? maximum(V(repeating: -0.5) / cw(inverse), V(repeating: -0.5)) : V(repeating: -0.5)
        let (innerX, innerY) = moved(inset)
        var coverage = V(repeating: 1)
        if degenerate {
            var correctedX = dx, correctedY = dy
            let oppositeX = V(dx.w,dx.z,dx.y,dx.x), oppositeY = V(dy.w,dy.z,dy.y,dy.x)
            for i in 0..<4 where inverse[i] >= 100 {
                correctedX[i] = -oppositeX[i]; correctedY[i] = -oppositeY[i]
            }
            var a = correctedY, b = -correctedX, c = correctedX * y - correctedY * x
            let test = correctedY * cw(x) + (-correctedX * cw(y) + c)
            if (0..<4).contains(where: { test[$0] < -0.01 }) { a = -a; b = -b; c = -c }
            let d0 = a.x * innerX + (b.x * innerY + V(repeating: c.x))
            let d1 = a.y * innerX + (b.y * innerY + V(repeating: c.y))
            let d2 = a.z * innerX + (b.z * innerY + V(repeating: c.z))
            let d3 = a.w * innerX + (b.w * innerY + V(repeating: c.w))
            coverage = maximum(.zero, minimum(V(repeating: 1), d0 + d3)) * maximum(.zero, minimum(V(repeating: 1), d1 + d2))
        }
        var outset = V(repeating: 0.5)
        if (0..<4).allSatisfy({ coverage[$0] < 1 }) {
            let lengths = V(repeating: 1) / inverse
            let maxWH = maximum(V(lengths.y, lengths.x, lengths.w, lengths.z), V(lengths.z, lengths.w, lengths.x, lengths.y))
            outset *= maximum(V(repeating: 1), V(repeating: 2) - maxWH)
        }
        let (outerX, outerY) = moved(outset)
        return (0..<4).map { V(innerX[$0], innerY[$0], coverage[$0], 0) }
             + (0..<4).map { V(outerX[$0], outerY[$0], 0, 0) }
    }

    static let maximumSigma: Float = 4
    static let maximumSamples = 28

    /// ComputeIntegralTableWidth for an already-limited effective device sigma.
    /// Only seven profile widths (32...2048) are possible in this range.
    static func integralTableWidth(sigma: Float) -> Int? {
        guard sigma.isFinite, sigma > 0.03, sigma <= 128 else { return nil }
        let sixSigma = 6 * sigma
        let minimumWidth = 2 * Int(ceil(sixSigma))
        var width = 32
        while width < minimumWidth { width *= 2 }
        return width
    }

    /// Integral LUT shared by Skia's direct rectangle and rounded-rectangle blur.
    static func integralTable(sigma: Float, maximumWorkingBytes: Int) -> [UInt8]? {
        guard let width = integralTableWidth(sigma: sigma), width <= maximumWorkingBytes else { return nil }
        var table = [UInt8](repeating: 0, count: width)
        table[0] = 255
        let inverseWidth: Float = 1 / Float(width)
        for i in 1..<(width - 1) {
            var x = (Float(i) + 0.5) * inverseWidth
            x = (-6 * x + 3) * 0.707106781
            let integral: Float = 0.5 * (erff(x) + 1)
            table[i] = UInt8(floor(255 * integral + 0.5))
        }
        return table
    }

    struct CircleProfile {
        let key: Int
        let solidRadius: Float
        let textureRadius: Float
        let pixels: [UInt8]
    }

    /// Cheap per-draw geometry; the profile cache key does not own these radii.
    struct CircleProfilePlan {
        let key: Int
        let solidRadius: Float
        let textureRadius: Float
        fileprivate let halfPlane: Bool
        fileprivate let kernelSigma: Float
        fileprivate let circleRadius: Float
        fileprivate let count: Int
        let workingBytes: Int
    }

    static func circleProfilePlan(radius: Float, sigma: Float) -> CircleProfilePlan? {
        guard radius.isFinite, radius >= 1 / 4096, sigma.isFinite, sigma > 0.03, sigma <= 128 else { return nil }
        let width = 512
        let ratio = min(sigma / radius, 8)
        let halfPlane = ratio <= 0.1
        let key = halfPlane ? 0 : Int(ratio * 65536) & ~255
        let effectiveSigma = halfPlane ? sigma : radius * (Float(key) / 65536)
        let solidRadius = halfPlane ? radius - 3 * sigma : 0
        let textureRadius = halfPlane ? 6 * sigma : radius + 3 * effectiveSigma
        guard textureRadius.isFinite, textureRadius > 0 else { return nil }
        let scale = Float(width) / textureRadius
        let kernelSigma = halfPlane ? Float(width) / 6 : effectiveSigma * scale
        let circleRadius = radius * scale
        guard kernelSigma.isFinite, kernelSigma > 0, kernelSigma <= Float(width) else { return nil }
        let count = halfPlane ? width / 2 : ((Int(ceil(6 * kernelSigma)) + 1) & ~1) >> 1
        let workingBytes = width + (halfPlane ? count : 4 * count + width) * MemoryLayout<Float>.stride
        return CircleProfilePlan(key: key, solidRadius: solidRadius, textureRadius: textureRadius,
            halfPlane: halfPlane, kernelSigma: kernelSigma, circleRadius: circleRadius, count: count, workingBytes: workingBytes)
    }

    static func circleProfile(radius: Float, sigma: Float, maximumWorkingBytes: Int) -> CircleProfile? {
        guard let plan = circleProfilePlan(radius: radius, sigma: sigma) else { return nil }
        return circleProfile(plan: plan, maximumWorkingBytes: maximumWorkingBytes)
    }

    /// Expensive profile generation is separate so cache hits do not build arrays.
    static func circleProfile(plan: CircleProfilePlan, maximumWorkingBytes: Int) -> CircleProfile? {
        guard plan.workingBytes <= maximumWorkingBytes else { return nil }
        let width = 512, count = plan.count
        let halfPlane = plan.halfPlane, kernelSigma = plan.kernelSigma, circleRadius = plan.circleRadius
        var kernel = [Float](repeating: 0, count: count)
        let inverseSigma: Float = 1 / kernelSigma
        let b: Float = -0.5 * inverseSigma * inverseSigma
        var total: Float = 0, t: Float = 0.5
        for i in 0..<count {
            kernel[i] = expf(t * t * b)
            total += kernel[i]; t += 1
        }
        total *= 2
        var pixels = [UInt8](repeating: 0, count: width)
        func byte(_ value: Float) -> UInt8 { UInt8(Double(min(1, max(0, value)) * 255) + 0.5) }
        if halfPlane {
            var sum: Float = 0
            for i in 0..<count {
                kernel[count - i - 1] /= total
                sum += kernel[count - i - 1]
                pixels[width - i - 1] = byte(sum)
            }
            for i in 0..<count {
                sum += kernel[i]
                pixels[count - i - 1] = byte(sum)
            }
        } else {
            var summed = [Float](repeating: 0, count: count)
            var sum: Float = 0
            for i in 0..<count {
                kernel[i] /= total; sum += kernel[i]; summed[i] = sum
            }
            var vertical = [Float](repeating: 0, count: width + 2 * count)
            var x = -Float(count) + 0.5
            for i in vertical.indices {
                defer { x += 1 }
                if x < -circleRadius || x > circleRadius { continue }
                let y = sqrtf(circleRadius * circleRadius - x * x) - 0.5
                let integer = Int(floor(y))
                if y < 0 { vertical[i] = (y + 0.5) * summed[0] }
                else if integer >= count - 1 { vertical[i] = 0.5 }
                else {
                    let fraction = y - Float(integer)
                    vertical[i] = (1 - fraction) * summed[integer] + fraction * summed[integer + 1]
                }
            }
            for i in 0..<(width - 1) {
                var acc: Float = 0
                var x = Float(i) + 0.5 - Float(count)
                for j in 0..<count {
                    if x >= -circleRadius && x <= circleRadius { acc += vertical[i + j] * kernel[count - j - 1] }
                    x += 1
                }
                for j in 0..<count {
                    if x >= -circleRadius && x <= circleRadius { acc += vertical[i + j + count] * kernel[j] }
                    x += 1
                }
                pixels[i] = byte(2 * acc)
            }
        }
        pixels[width - 1] = 0
        return CircleProfile(key: plan.key, solidRadius: plan.solidRadius, textureRadius: plan.textureRadius, pixels: pixels)
    }

    struct RoundedRectanglePlan {
        /// Actual filter sigma; the cache key is quantized independently.
        let sigma: Float
        let sigmaKey: Int
        let roundedCorner: Int
        let blurRadius: Int
        let textureSize: SIMD2<Int>
        let maskRectangle: SIMD4<Float>
        let proxyRectangle: SIMD4<Float>
        /// ignoreXform uses fillPixelsWithLocalMatrix on roundOut(proxyBounds).
        /// Sampling retains the fractional proxyRectangle independently.
        var drawRectangle: SIMD4<Float> {
            .init(floor(proxyRectangle.x), floor(proxyRectangle.y), ceil(proxyRectangle.z), ceil(proxyRectangle.w))
        }
        func translated(by offset: SIMD2<Float>) -> Self {
            Self(sigma: sigma, sigmaKey: sigmaKey, roundedCorner: roundedCorner, blurRadius: blurRadius,
                 textureSize: textureSize, maskRectangle: maskRectangle,
                 proxyRectangle: proxyRectangle + .init(offset.x, offset.y, offset.x, offset.y), shaderCorner: shaderCorner)
        }
        /// Keep the original fractional corner here; the texture uses ceil(radius).
        let shaderCorner: Float
    }

    /// Simple circular rrect specialization of ComputeBlurredRRectParams.
    /// A nil result requires the general mask route; equality at the interior
    /// boundary is rejected, as in Skia. Rectangles/circles have earlier routes.
    static func roundedRectanglePlan(bounds: SIMD4<Float>, radius: Float, sigma: Float) -> RoundedRectanglePlan? {
        guard (0..<4).allSatisfy({ bounds[$0].isFinite && abs(bounds[$0]) < 8_000_000 }),
              radius.isFinite, radius > 0, sigma.isFinite, sigma > 0.03, sigma <= 128 else { return nil }
        let width = bounds.z - bounds.x, height = bounds.w - bounds.y
        guard width > 0, height > 0, radius <= min(width, height) / 2,
              !(width == height && radius == width / 2) else { return nil }
        let sigmaKey = Int(ceil(sigma - Float(1) / 6))
        let blur = 3 * sigmaKey, corner = Int(ceil(radius))
        // Preserve source operation order (do not replace this with a width test).
        guard bounds.x + Float(corner) + Float(blur) < bounds.z - Float(corner) - Float(blur),
              bounds.y + Float(corner) + Float(blur) < bounds.w - Float(corner) - Float(blur) else { return nil }
        let innerSize = 2 * blur + 2 * corner + 1
        let dimension = innerSize + 2 * blur
        return RoundedRectanglePlan(sigma: sigma, sigmaKey: sigmaKey, roundedCorner: corner, blurRadius: blur,
            textureSize: .init(dimension, dimension),
            maskRectangle: .init(Float(blur), Float(blur), Float(blur + innerSize), Float(blur + innerSize)),
            proxyRectangle: bounds + .init(-Float(blur), -Float(blur), Float(blur), Float(blur)), shaderCorner: radius)
    }

    static func radius(sigma: Float) -> Int? {
        guard sigma.isFinite, sigma >= 0, sigma <= maximumSigma else { return nil }
        return sigma <= 0.03 ? 0 : Int(ceil(3 * sigma))
    }

    /// Row-major storage, with the original x-then-y accumulation order.
    static func kernel(sigma: SIMD2<Float>) -> [Float]? {
        guard let rx = radius(sigma: sigma.x), let ry = radius(sigma: sigma.y) else { return nil }
        let width = 2 * rx + 1, height = 2 * ry + 1
        guard width * height <= maximumSamples else { return nil }
        let dx: Float = rx > 0 ? 1 / (2 * sigma.x * sigma.x) : 1
        let dy: Float = ry > 0 ? 1 / (2 * sigma.y * sigma.y) : 1
        var weights = [Float](repeating: 0, count: width * height)
        var sum: Float = 0
        for x in 0..<width {
            let distance = Float(x - rx)
            let xTerm = distance * distance * dx
            for y in 0..<height {
                let yTerm = Float(y - ry)
                let weight = exp(-(xTerm + yTerm * yTerm * dy))
                weights[y * width + x] = weight
                sum += weight
            }
        }
        let scale: Float = 1 / sum
        for i in weights.indices { weights[i] *= scale }
        return weights
    }

    /// Each SIMD2 is (texel offset, weight). Trailing samples retain the final
    /// offset with zero weight, matching Skia's fixed uniform array.
    static func linearKernel(sigma: Float) -> [SIMD2<Float>]? {
        guard let radius = radius(sigma: sigma), let full = kernel(sigma: .init(sigma, 0)) else { return nil }
        let count = radius + 1, middle = count / 2
        var samples = [SIMD2<Float>](repeating: .zero, count: maximumSamples)
        var index = radius, low = middle - 1
        func combined(_ first: Float, _ second: Float) -> SIMD2<Float> {
            let weight = first + second
            return .init(second / weight, weight)
        }
        if radius & 1 != 0 {
            samples[middle] = combined(full[index] * 0.5, full[index + 1])
            samples[low] = .init(-samples[middle].x, samples[middle].y)
            index += 1
            low -= 1
        } else {
            samples[middle] = .init(0, full[index])
        }
        index += 1
        for i in (middle + 1)..<count {
            samples[i] = combined(full[index], full[index + 1])
            samples[i].x += Float(index - radius)
            samples[low] = .init(-samples[i].x, samples[i].y)
            index += 2
            low -= 1
        }
        for i in count..<maximumSamples { samples[i].x = samples[count - 1].x }
        return samples
    }
}

extension ZTransferShadowBlur {
    /// One recursive level of GrBlurUtils::GaussianBlur's large-sigma clamp
    /// path. Source bounds start at zero; destination may be offset or expanded.
    struct RescalePlan {
        let size: SIMD2<Int>
        let paddedSize: SIMD2<Int>
        let scale: SIMD2<Float>
        let sigma: SIMD2<Float>
        let repeatedLinearSizes: [SIMD2<Int>]
        let blurBounds: SIMD4<Int>
        let reexpandBounds: SIMD4<Float>
    }

    static func rescalePlan(sourceSize: SIMD2<Int>, destinationBounds: SIMD4<Int>,
                            sigma: SIMD2<Float>, paddedUpscale: Bool) -> RescalePlan? {
        let limit = Int(Int32.max) - 2
        guard sourceSize.x > 0, sourceSize.y > 0, sourceSize.x <= limit, sourceSize.y <= limit,
              destinationBounds.z > destinationBounds.x, destinationBounds.w > destinationBounds.y,
              sigma.x.isFinite, sigma.y.isFinite, sigma.x >= 0, sigma.y >= 0,
              sigma.x > maximumSigma || sigma.y > maximumSigma else { return nil }
        let requestedScale = SIMD2<Float>(sigma.x > maximumSigma ? maximumSigma / sigma.x : 1,
                                         sigma.y > maximumSigma ? maximumSigma / sigma.y : 1)
        let size = SIMD2<Int>(max(Int(floor(Float(sourceSize.x) * requestedScale.x)), 1),
                             max(Int(floor(Float(sourceSize.y) * requestedScale.y)), 1))
        guard size.x <= limit, size.y <= limit else { return nil }
        let scale = SIMD2<Float>(Float(size.x) / Float(sourceSize.x), Float(size.y) / Float(sourceSize.y))
        // Clamp mode pads both axes, even when only one of them is reduced.
        let scaled = SIMD4<Float>(Float(destinationBounds.x) * scale.x + 1,
                                  Float(destinationBounds.y) * scale.y + 1,
                                  Float(destinationBounds.z) * scale.x + 1,
                                  Float(destinationBounds.w) * scale.y + 1)
        let padding: Float = paddedUpscale ? 1 : 0
        let low = SIMD2<Float>(floor(scaled.x) - padding, floor(scaled.y) - padding)
        let high = SIMD2<Float>(ceil(scaled.z) + padding, ceil(scaled.w) + padding)
        guard [low.x, low.y, high.x, high.y].allSatisfy({ $0.isFinite && $0 > Float(Int32.min) && $0 < Float(Int32.max) }) else { return nil }
        let bounds = SIMD4<Int>(Int(low.x), Int(low.y), Int(high.x), Int(high.y))
        var steps: [SIMD2<Int>] = []
        var current = sourceSize
        repeat {
            current = .init(current.x > size.x ? max((current.x + 1) / 2, size.x) : size.x,
                            current.y > size.y ? max((current.y + 1) / 2, size.y) : size.y)
            steps.append(current)
        } while current != size
        return RescalePlan(size: size, paddedSize: .init(size.x + 2, size.y + 2), scale: scale,
            sigma: sigma * scale, repeatedLinearSizes: steps, blurBounds: bounds,
            reexpandBounds: scaled - .init(low.x, low.y, low.x, low.y))
    }
}

extension ZTransferShadowBlur {
    struct ClampPlan {
        let sourceBounds: SIMD4<Int>
        let sigma: SIMD2<Float>
        let radius: SIMD2<Int>
        /// X-pass bounds in original texture coordinates; nil for a single pass.
        let horizontalBounds: SIMD4<Int>?
    }

    /// GaussianBlur entry and, for small sigma, two_pass_gaussian clamp bounds.
    /// Restrict coordinates to exactly representable Float integers, including halos.
    static func clampPlan(sourceBounds: SIMD4<Int>, destinationBounds: SIMD4<Int>,
                          sigma: SIMD2<Float>) -> ClampPlan? {
        func reachRadius(_ value: Float) -> Int? {
            guard value.isFinite, value >= 0, 3 * value < Float(Int32.max) else { return nil }
            return value <= 0.03 ? 0 : Int(ceil(3 * value))
        }
        guard let originalX = reachRadius(sigma.x), let originalY = reachRadius(sigma.y),
              [sourceBounds, destinationBounds].allSatisfy({ r in
                  r.x < r.z && r.y < r.w && (0..<4).allSatisfy { r[$0] > -8_000_000 && r[$0] < 8_000_000 }
              }) else { return nil }
        let reach = destinationBounds &+ SIMD4(-originalX, -originalY, originalX, originalY)
        var source = sourceBounds
        let intersection = SIMD4(max(reach.x, source.x), max(reach.y, source.y),
                                 min(reach.z, source.z), min(reach.w, source.w))
        if intersection.x < intersection.z && intersection.y < intersection.w {
            source = intersection
        } else {
            if reach.x >= source.z { source.x = source.z - 1 }
            else if reach.z <= source.x { source.z = source.x + 1 }
            if reach.y >= source.w { source.y = source.w - 1 }
            else if reach.w <= source.y { source.w = source.y + 1 }
        }
        let sx: Float = source.z - source.x == 1 ? 0 : sigma.x
        let sy: Float = source.w - source.y == 1 ? 0 : sigma.y
        let rx = source.z - source.x == 1 ? 0 : originalX
        let ry = source.w - source.y == 1 ? 0 : originalY
        var horizontal: SIMD4<Int>?
        if sx <= maximumSigma && sy <= maximumSigma && rx > 0 && ry > 0 && (2 * rx + 1) * (2 * ry + 1) > maximumSamples {
            var bounds = destinationBounds &+ SIMD4(0, -ry, 0, ry)
            if bounds.w <= source.y {
                bounds.y = source.y; bounds.w = source.y + 1
            } else if bounds.y >= source.w {
                bounds.w = source.w; bounds.y = source.w - 1
            } else {
                bounds.y = max(bounds.y, source.y); bounds.w = min(bounds.w, source.w)
            }
            let left = source.x - rx + 1, right = source.z + rx - 1
            bounds.x = bounds.z <= left ? bounds.z - 1 : max(bounds.x, left)
            bounds.z = bounds.x >= right ? bounds.x + 1 : min(bounds.z, right)
            horizontal = bounds
        }
        return ClampPlan(sourceBounds: source, sigma: .init(sx, sy), radius: .init(rx, ry), horizontalBounds: horizontal)
    }
}


extension ZTransferShadowBlur {
    enum MaskPlan: Equatable {
        case empty
        case identity(bounds: SIMD4<Int>)
        case software(bounds: SIMD4<Int>)
        case gpu(bounds: SIMD4<Int>)
    }

    /// GrBlurUtils::can_filter_mask, after styled device-space bounds and sigma
    /// are established. This chooses the general-mask route; analytic shape
    /// filters are attempted separately before reaching this decision.
    static func maskPlan(shapeBounds: SIMD4<Int>, clipBounds: SIMD4<Int>, sigma: Float) -> MaskPlan? {
        guard sigma.isFinite, sigma >= 0, 3 * sigma < 8_000_000,
              [shapeBounds, clipBounds].allSatisfy({ r in
                  r.x < r.z && r.y < r.w && (0..<4).allSatisfy { r[$0] > -8_000_000 && r[$0] < 8_000_000 }
              }) else { return nil }
        let identity = sigma <= 0.03
        // SkIRect::makeOutset takes int32: the source's sigma3 float is truncated,
        // unlike BlurSigmaRadius's ceil. Preserve this distinction at fractional sigma.
        let outset = identity ? 0 : Int(3 * sigma)
        let delta = SIMD4(-outset, -outset, outset, outset)
        let shape = shapeBounds &+ delta, clip = clipBounds &+ delta
        let bounds = SIMD4(max(shape.x, clip.x), max(shape.y, clip.y), min(shape.z, clip.z), min(shape.w, clip.w))
        guard bounds.x < bounds.z && bounds.y < bounds.w else { return .empty }
        if identity { return .identity(bounds: bounds) }
        if shapeBounds.z - shapeBounds.x <= 64 && shapeBounds.w - shapeBounds.y <= 64 && sigma <= 32 {
            return .software(bounds: bounds)
        }
        return .gpu(bounds: bounds)
    }
}

extension ZTransferShadowBlur {
    /// skgpu::GetApproxSize used by create_mask_GPU. The transparent backing
    /// beyond content is part of the blur input, not an arbitrary extra border.
    static func maskBackingSize(_ content: SIMD2<Int>) -> SIMD2<Int>? {
        guard content.x > 0, content.y > 0, content.x <= 1 << 30, content.y <= 1 << 30 else { return nil }
        func adjust(_ value: Int) -> Int {
            let value = max(16, value)
            if value & (value - 1) == 0 { return value }
            var ceiling = 16
            while ceiling < value { ceiling <<= 1 }
            if value <= 1024 { return ceiling }
            let floor = ceiling >> 1
            let midpoint = floor + (floor >> 1)
            return value <= midpoint ? midpoint : ceiling
        }
        return .init(adjust(content.x), adjust(content.y))
    }
}
