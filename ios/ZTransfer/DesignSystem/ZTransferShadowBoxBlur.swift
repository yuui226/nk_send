// Adapted from Skia, Copyright Google Inc.; BSD license in Resources/licenses/Skia-BSD.txt.
import Foundation

/// SkMaskBlurFilter's normal A8 software paths. Small sigma uses the discrete
/// SkGaussFilter kernel; larger sigma uses the integer three-box scan.
enum ZTransferShadowBoxBlur {
    enum Failure: Error { case invalidInput, workingSetExceeded }
    struct Mask {
        let width: Int
        let height: Int
        let border: Int
        let pixels: [UInt8]
    }

    /// Normal A8 mask-filter entry. SkMaskBlurFilter's identity threshold is
    /// 3*sigma <= 1, distinct from the GPU threshold. The paint caller supplies
    /// its already transformed/capped sigma.
    static func filterNormal(_ pixels: [UInt8], width: Int, height: Int, sigma: Double,
                             maximumWorkingBytes: Int) throws -> Mask {
        guard width > 0, height > 0, width <= Int32.max, height <= Int32.max,
              width <= Int.max / height, pixels.count == width * height,
              sigma.isFinite, sigma >= 0, sigma <= 135, maximumWorkingBytes >= 0 else { throw Failure.invalidInput }
        if 3 * sigma <= 1 {
            return Mask(width: width, height: height, border: 0, pixels: pixels)
        }
        if sigma < 2 {
            return try filterSmall(pixels, width: width, height: height, sigma: sigma, maximumWorkingBytes: maximumWorkingBytes)
        }
        return try filter(pixels, width: width, height: height, sigma: sigma, maximumWorkingBytes: maximumWorkingBytes)
    }

    static func filter(_ pixels: [UInt8], width: Int, height: Int, sigma: Double,
                       maximumWorkingBytes: Int) throws -> Mask {
        guard width > 0, height > 0, sigma.isFinite, sigma >= 2, sigma <= 135,
              width <= Int32.max, height <= Int32.max,
              width <= Int.max / height, pixels.count == width * height else { throw Failure.invalidInput }
        var scan = Scan(sigma: sigma)
        let outWidth = width + 2 * scan.border, outHeight = height + 2 * scan.border
        guard outWidth <= Int.max / outHeight, outWidth <= Int.max / height else { throw Failure.invalidInput }
        let outputCount = outWidth * outHeight, intermediateCount = outWidth * height
        let ringBytes = scan.rings.reduce(0) { $0 + $1.count * MemoryLayout<UInt32>.stride }
        guard maximumWorkingBytes >= ringBytes,
              outputCount <= maximumWorkingBytes - ringBytes,
              intermediateCount <= maximumWorkingBytes - ringBytes - outputCount else { throw Failure.workingSetExceeded }
        var intermediate = [UInt8](repeating: 0, count: intermediateCount)
        var output = [UInt8](repeating: 0, count: outputCount)
        pixels.withUnsafeBufferPointer { source in
            intermediate.withUnsafeMutableBufferPointer { target in
                for y in 0..<height {
                    scan.apply(source: source, start: y * width, count: width,
                               destination: target, start: y, stride: height)
                }
            }
        }
        intermediate.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                for x in 0..<outWidth {
                    scan.apply(source: source, start: x * height, count: height,
                               destination: target, start: x, stride: outWidth)
                }
            }
        }
        return Mask(width: outWidth, height: outHeight, border: scan.border, pixels: output)
    }

    private struct Scan {
        let border: Int
        let weight: UInt64
        var rings: [[UInt32]]

        init(sigma: Double) {
            let window = max(1, Int(floor(sigma * 3 * sqrt(2 * Double.pi) / 4 + 0.5)))
            let odd = window & 1 == 1
            border = odd ? 3 * ((window - 1) / 2) : 3 * (window / 2) - 1
            let divisor = window * window * (odd ? window : window + 1)
            weight = UInt64((1 / Double(divisor) * 4_294_967_296).rounded())
            rings = [Array(repeating: 0, count: window - 1), Array(repeating: 0, count: window - 1),
                     Array(repeating: 0, count: odd ? window - 1 : window)]
        }

        mutating func apply(source: UnsafeBufferPointer<UInt8>, start: Int, count: Int,
                            destination: UnsafeMutableBufferPointer<UInt8>, start outputStart: Int, stride: Int) {
            var cursors = [0, 0, 0]
            var sums: [UInt32] = [0, 0, 0]
            func clear() {
                for ring in rings.indices { for i in rings[ring].indices { rings[ring][i] = 0 } }
                sums = [0, 0, 0]
            }
            func step(_ leading: UInt32) -> UInt8 {
                sums[0] += leading
                sums[1] += sums[0]
                sums[2] += sums[1]
                let result = UInt8((weight * UInt64(sums[2]) + (1 << 31)) >> 32)
                // Update in reverse order: each ring stores the unmodified prior sum.
                for index in (0...2).reversed() {
                    sums[index] -= rings[index][cursors[index]]
                    rings[index][cursors[index]] = index == 0 ? leading : sums[index - 1]
                    cursors[index] = (cursors[index] + 1) % rings[index].count
                }
                return result
            }
            clear()
            let forwardCount = max(count, 2 * border + 1)
            for i in 0..<forwardCount {
                let leading = i < count ? UInt32(source[start + i]) : 0
                destination[outputStart + i * stride] = step(leading)
            }
            clear()
            var right = count + 2 * border, sourceIndex = count
            while right > forwardCount {
                right -= 1; sourceIndex -= 1
                destination[outputStart + right * stride] = step(UInt32(source[start + sourceIndex]))
            }
        }

    }
}

extension ZTransferShadowBoxBlur {
    /// SkGaussFilter's discrete Bessel kernel, encoded as unsigned 0.16 factors.
    static func smallFactors(sigma: Double) -> [UInt16]? {
        guard sigma.isFinite, 3 * sigma > 1, sigma < 2 else { return nil }
        let variance = sigma * sigma
        let squaredOverFour = variance * variance / 4
        func bessel(firstOrder: Bool) -> Double {
            var term = firstOrder ? variance / 2 : 1
            var sum = term, k = 1
            while term > 0.000001 {
                term *= squaredOverFour / Double(firstOrder ? k * (k + 1) : k * k)
                sum += term
                k += 1
            }
            return sum
        }
        let denominator = exp(variance)
        var besselValues = [Double](repeating: 0, count: 6)
        var basis = [Double](repeating: 0, count: 6)
        besselValues[0] = bessel(firstOrder: false)
        besselValues[1] = bessel(firstOrder: true)
        basis[0] = besselValues[0] / denominator
        basis[1] = besselValues[1] / denominator
        var count = 1
        while basis[count] > 0.01 {
            guard count + 1 < basis.count else { return nil }
            besselValues[count + 1] = -(Double(2 * count) / variance) * besselValues[count] + besselValues[count - 1]
            basis[count + 1] = besselValues[count + 1] / denominator
            count += 1
        }
        var sum: Double = 0
        for i in (1..<count).reversed() { sum += 2 * basis[i] }
        sum += basis[0]
        for i in 0..<count { basis[i] /= sum }
        sum = 0
        for i in (1..<count).reversed() { sum += 2 * basis[i] }
        basis[0] = 1 - sum
        return basis.prefix(count).map { UInt16(($0 * 65536).rounded()) }
    }

    /// Small normal A8 software blur: per-product mulhi truncation, 8.8 sum,
    /// half-byte rounding, vertical then horizontal with an A8 intermediate.
    static func filterSmall(_ pixels: [UInt8], width: Int, height: Int, sigma: Double,
                            maximumWorkingBytes: Int) throws -> Mask {
        guard width > 0, height > 0, width <= Int32.max, height <= Int32.max,
              width <= Int.max / height, pixels.count == width * height,
              let factors = smallFactors(sigma: sigma) else { throw Failure.invalidInput }
        let radius = factors.count - 1
        let outWidth = width + 2 * radius, outHeight = height + 2 * radius
        guard outWidth <= Int.max / outHeight else { throw Failure.invalidInput }
        let count = outWidth * outHeight, intermediateCount = width * outHeight
        guard maximumWorkingBytes >= count, intermediateCount <= maximumWorkingBytes - count else { throw Failure.workingSetExceeded }
        var vertical = [UInt8](repeating: 0, count: intermediateCount)
        var output = [UInt8](repeating: 0, count: count)
        for y in 0..<outHeight { for x in 0..<width {
            var sum: UInt32 = 128
            for offset in -radius...radius {
                let sy = y - radius + offset
                if sy >= 0 && sy < height {
                    sum += (UInt32(pixels[sy * width + x]) * UInt32(factors[abs(offset)])) >> 8
                }
            }
            vertical[y * width + x] = UInt8(sum >> 8)
        } }
        for y in 0..<outHeight { for x in 0..<outWidth {
            var sum: UInt32 = 128
            for offset in -radius...radius {
                let sx = x - radius + offset
                if sx >= 0 && sx < width {
                    sum += (UInt32(vertical[y * width + sx]) * UInt32(factors[abs(offset)])) >> 8
                }
            }
            output[y * outWidth + x] = UInt8(sum >> 8)
        } }
        return Mask(width: outWidth, height: outHeight, border: radius, pixels: output)
    }
}
