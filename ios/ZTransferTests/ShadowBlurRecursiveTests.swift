import XCTest
import Metal
@testable import ZTransfer

/// Scalar reference deliberately uses full intermediate rows and no production
/// plans, kernels or shader code. Its Gaussian weights are computed in Double.
final class ShadowBlurRecursiveTests: XCTestCase {
    private struct Mask {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func sample(_ x: Float, _ y: Float) -> Float {
            let px = x - 0.5, py = y - 0.5
            let l = Int(floor(px)), t = Int(floor(py)), fx = px - floor(px), fy = py - floor(py)
            func at(_ x: Int, _ y: Int) -> Float {
                Float(bytes[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]) / 255
            }
            let top = at(l, t) * (1 - fx) + at(l + 1, t) * fx
            let bottom = at(l, t + 1) * (1 - fx) + at(l + 1, t + 1) * fx
            return Float(Float16(top * (1 - fy) + bottom * fy))
        }
    }

    private func mask(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> Float) -> Mask {
        var bytes: [UInt8] = []
        for y in 0..<height { for x in 0..<width {
            bytes.append(UInt8(min(max((pixel(x, y) * 255).rounded(), 0), 255)))
        } }
        return Mask(width: width, height: height, bytes: bytes)
    }

    private func taps(_ sigma: Float) -> [(Float, Float)] {
        if sigma <= 0.03 { return [(0, 1)] }
        let radius = Int(ceil(3 * sigma))
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * Double(sigma) * Double(sigma))) }
        let sum = weights.reduce(0, +)
        let normalized = weights.map { $0 / sum }
        var positive: [(Float, Float)] = []
        var index = radius
        if radius % 2 == 1 {
            let a = normalized[index] / 2, b = normalized[index + 1]
            positive.append((Float(b / (a + b)), Float(a + b)))
            index += 2
        } else {
            positive.append((0, Float(normalized[index])))
            index += 1
        }
        while index < normalized.count {
            let a = normalized[index], b = normalized[index + 1]
            positive.append((Float(index - radius) + Float(b / (a + b)), Float(a + b)))
            index += 2
        }
        let negative = positive.filter { $0.0 != 0 }.reversed().map { (-$0.0, $0.1) }
        return negative + positive
    }

    private func reference(_ source: Mask, _ bounds: SIMD4<Int>, _ requested: SIMD2<Float>, _ padded: Bool) -> Mask {
        let sigma = SIMD2<Float>(source.width == 1 ? 0 : requested.x, source.height == 1 ? 0 : requested.y)
        let width = bounds.z - bounds.x, height = bounds.w - bounds.y
        if sigma.x <= 4 && sigma.y <= 4 {
            // These recursive fixtures end in one-dimensional or separable kernels;
            // tiny 2D kernels are covered by AndroidShadowMetricsTests instead.
            let xt = taps(sigma.x), yt = taps(sigma.y)
            let horizontal = mask(width, source.height) { x, y in
                var total: Float16 = 0
                for (offset, weight) in xt {
                    total += Float16(weight) * Float16(source.sample(Float(x + bounds.x) + 0.5 + Float(Float16(offset)), Float(y) + 0.5))
                }
                return Float(total)
            }
            return mask(width, height) { x, y in
                var total: Float16 = 0
                for (offset, weight) in yt {
                    total += Float16(weight) * Float16(horizontal.sample(Float(x) + 0.5, Float(y + bounds.y) + 0.5 + Float(Float16(offset))))
                }
                return Float(total)
            }
        }
        let rw = max(Int(floor(Float(source.width) * min(1, 4 / sigma.x))), 1)
        let rh = max(Int(floor(Float(source.height) * min(1, 4 / sigma.y))), 1)
        let scale = SIMD2<Float>(Float(rw) / Float(source.width), Float(rh) / Float(source.height))
        var interior = source
        while interior.width != rw || interior.height != rh {
            let w = max((interior.width + 1) / 2, rw), h = max((interior.height + 1) / 2, rh)
            let previous = interior
            interior = mask(w, h) { x, y in
                previous.sample((Float(x) + 0.5) * Float(previous.width) / Float(w),
                                (Float(y) + 0.5) * Float(previous.height) / Float(h))
            }
        }
        let reduced = mask(rw + 2, rh + 2) { x, y in
            if x > 0 && x <= rw && y > 0 && y <= rh { return Float(interior.bytes[(y - 1) * rw + x - 1]) / 255 }
            let sx: Float = x == 0 ? 0.5 : (x == rw + 1 ? Float(source.width) - 0.5 : (Float(x) - 0.5) / scale.x)
            let sy: Float = y == 0 ? 0.5 : (y == rh + 1 ? Float(source.height) - 0.5 : (Float(y) - 0.5) / scale.y)
            return source.sample(sx, sy)
        }
        let fractional = SIMD4<Float>(Float(bounds.x) * scale.x + 1, Float(bounds.y) * scale.y + 1,
                                     Float(bounds.z) * scale.x + 1, Float(bounds.w) * scale.y + 1)
        let padding = padded ? 1 : 0
        let integer = SIMD4<Int>(Int(floor(fractional.x)) - padding, Int(floor(fractional.y)) - padding,
                                 Int(ceil(fractional.z)) + padding, Int(ceil(fractional.w)) + padding)
        let blurred = reference(reduced, integer, sigma * scale, padded)
        let b = fractional - SIMD4(Float(integer.x), Float(integer.y), Float(integer.x), Float(integer.y))
        func coordinate(_ position: Float, _ low: Float, _ high: Float, _ limit: Int) -> Float {
            if padded { return min(max(position, 0.5), Float(limit) - 0.5) }
            if high - low < 1 { return (low + high) / 2 }
            return min(max(position, low + 0.5), high - 0.5)
        }
        return mask(width, height) { x, y in
            let sx = b.x + (Float(x) + 0.5) * (b.z - b.x) / Float(width)
            let sy = b.y + (Float(y) + 0.5) * (b.w - b.y) / Float(height)
            return blurred.sample(coordinate(sx, b.x, b.z, blurred.width), coordinate(sy, b.y, b.w, blurred.height))
        }
    }

    func testLargeSigmaReachCropAndDisjointAxis() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(_ side: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
            d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let source = try texture(64), output = try texture(4)
        let input = mask(64, 64) { x, y in Float((x * 71 + y * 37 + 83) % 256) / 255 }
        input.bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 64) }
        for disjoint in [false, true] {
            // sigma8 has radius24. Interior reach is [6,58) on both axes.
            // A completely disjoint X instead retains only original column63;
            // the original Y range stays intact in Skia's no-intersection branch.
            let cropped = mask(disjoint ? 1 : 52, disjoint ? 64 : 52) { x, y in
                let sx = disjoint ? 63 : x + 6, sy = disjoint ? y : y + 6
                return Float(input.bytes[sy * 64 + sx]) / 255
            }
            let target: SIMD4<Int> = disjoint ? .init(100, 30, 104, 34) : .init(30, 30, 34, 34)
            let relative: SIMD4<Int> = disjoint ? .init(37, 30, 41, 34) : .init(24, 24, 28, 28)
            for padded in [false, true] {
                let expected = reference(cropped, relative, .init(8, 8), padded).bytes
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                try renderer.encodeGaussian(source: source, sourceBounds: .init(0, 0, 64, 64), destination: output,
                    destinationBounds: target, sigma: .init(8, 8), paddedUpscale: padded, commandBuffer: command)
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                var actual = [UInt8](repeating: 0, count: 16)
                actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 4,
                    from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
                XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 3,
                    "disjoint \(disjoint), padded \(padded)")
            }
        }
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        for sigma: SIMD2<Float> in [.init(.infinity, 8), .init(-1, 8), .init(Float.greatestFiniteMagnitude, 8)] {
            XCTAssertThrowsError(try renderer.encodeGaussian(source: source, sourceBounds: .init(0, 0, 64, 64),
                destination: output, destinationBounds: .init(30, 30, 34, 34), sigma: sigma,
                paddedUpscale: false, commandBuffer: command))
        }
    }

    func testLargeSigmaRecursivePixelsAndRetainedSubset() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try ZTransferShadowBlurRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(_ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let input = mask(16, 16) { x, y in Float((x * 71 + y * 37 + 83) % 256) / 255 }
        let output = try texture(16, 16)
        for inset in [0, 2] {
            let source = try texture(16 + 2 * inset, 16 + 2 * inset)
            var backing = [UInt8](repeating: 255, count: source.width * source.height)
            for y in 0..<16 { for x in 0..<16 { backing[(y + inset) * source.width + x + inset] = input.bytes[y * 16 + x] } }
            backing.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, source.width, source.height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: source.width) }
            for sigma: SIMD2<Float> in [.init(8, 8), .init(16, 16), .init(8, 0), .init(800, 1200)] {
                for padded in [false, true] {
                    let expected = reference(input, .init(0, 0, 16, 16), sigma, padded).bytes
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    let bounds = SIMD4(inset, inset, inset + 16, inset + 16)
                    try renderer.encodeGaussian(source: source, sourceBounds: bounds, destination: output,
                        destinationBounds: bounds, sigma: sigma, paddedUpscale: padded, commandBuffer: command)
                    command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    var actual = [UInt8](repeating: 0, count: 256)
                    actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 16,
                        from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
                    XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 3,
                        "sigma \(sigma), padded \(padded), inset \(inset)")
                }
            }
        }
    }
}
