import UIKit

@_silgen_name("zt_photo_lut_prepare")
private func zt_photo_lut_prepare(_ offsets: UnsafeMutablePointer<Int32>, _ weights: UnsafeMutablePointer<Float>,
                                  _ size: Int32, _ min0: Float, _ max0: Float, _ min1: Float, _ max1: Float,
                                  _ min2: Float, _ max2: Float)

@_silgen_name("zt_photo_lut_apply")
private func zt_photo_lut_apply(_ pixels: UnsafeMutablePointer<UInt8>, _ pixelCount: Int32,
                                _ offsets: UnsafePointer<Int32>, _ weights: UnsafePointer<Float>,
                                _ rgb: UnsafePointer<Float>, _ strength: Float, _ finishing: Int32,
                                _ shadowScale: Float, _ highlightScale: Float, _ contrast: Float,
                                _ saturation: Float) -> Int32

enum PhotoCubeLUTMapper {
    static func apply(_ image: CGImage, lut: CubeLUT, intensityPercent: Int, adjustments: LUTAdjustments = .init(),
                      checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> CGImage? {
        try checkCancelled()
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let intensity = Float(min(max(intensityPercent, 0), 100)) / 100
        let normalized = adjustments.normalized
        let finishing = LUTColorPipeline.Prepared(adjustments: normalized)
        // Same coefficients as LUTColorPipeline.Prepared. Opaque pixels apply them
        // in the native batch; translucent pixels keep the Swift pipeline below.
        let shadowScale = -Float(normalized.shadows) / 100 * 0.28
        let highlightScale = Float(normalized.highlights) / 100 * 0.28
        let contrast = 1 + Float(normalized.contrast) / 100 * 0.75
        let saturation = 1 + Float(normalized.saturation) / 100
        let useFinishing: Int32 = normalized.isNeutral ? 0 : 1
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: width * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixelCount = width * height
        var offsets = [Int32](repeating: 0, count: 6 * 256)
        var weights = [Float](repeating: 0, count: 6 * 256)
        var sawPartial = false
        offsets.withUnsafeMutableBufferPointer { offsetBuffer in
            weights.withUnsafeMutableBufferPointer { weightBuffer in
                zt_photo_lut_prepare(offsetBuffer.baseAddress!, weightBuffer.baseAddress!, Int32(lut.size),
                                     lut.domainMin.x, lut.domainMax.x, lut.domainMin.y, lut.domainMax.y,
                                     lut.domainMin.z, lut.domainMax.z)
            }
        }
        try lut.rgb.withUnsafeBufferPointer { rgb in
            try offsets.withUnsafeBufferPointer { offsetBuffer in
                try weights.withUnsafeBufferPointer { weightBuffer in
                    // Android checks between 16K native batches. Keep the existing
                    // 4096-pixel cadence: entry, each batch start, then publication.
                    for start in stride(from: 0, to: pixelCount, by: 4096) {
                        try checkCancelled()
                        let count = min(4096, pixelCount - start)
                        let partial = zt_photo_lut_apply(buffer.advanced(by: start * 4), Int32(count),
                                                         offsetBuffer.baseAddress!, weightBuffer.baseAddress!,
                                                         rgb.baseAddress!, intensity, useFinishing,
                                                         shadowScale, highlightScale, contrast, saturation)
                        if partial != 0 { sawPartial = true }
                    }
                }
            }
        }
        if sawPartial {
            // Premultiplied partial alpha is not an integer lattice point.
            // Keep the original float sampler for those pixels only.
            func mix(_ input: Float, _ output: Float) -> UInt32 {
                let originalByte = input * 255
                let mappedByte = min(max(output, 0), 1) * 255
                return UInt32(min(max(originalByte + (mappedByte - originalByte) * intensity, 0), 255).rounded())
            }
            for offset in stride(from: 0, to: pixelCount * 4, by: 4) {
                if offset % (4096 * 4) == 0 { try checkCancelled() }
                let alpha = UInt32(buffer[offset + 3])
                guard alpha != 0, alpha != 255 else { continue }
                let original = SIMD3(Float(buffer[offset]), Float(buffer[offset + 1]), Float(buffer[offset + 2])) / Float(alpha)
                let mapped = lut.sample(original)
                let mixed = (alpha << 24) | (mix(original.x, mapped.x) << 16) |
                    (mix(original.y, mapped.y) << 8) | mix(original.z, mapped.z)
                let finished = finishing.apply(mixed, preserveAlpha: true)
                buffer[offset] = UInt8((((finished >> 16) & 255) * alpha + 127) / 255)
                buffer[offset + 1] = UInt8((((finished >> 8) & 255) * alpha + 127) / 255)
                buffer[offset + 2] = UInt8(((finished & 255) * alpha + 127) / 255)
            }
        }
        try checkCancelled()
        return context.makeImage()
    }
}
