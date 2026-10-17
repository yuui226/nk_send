import UIKit

enum PhotoCubeLUTMapper {
    static func apply(_ image: CGImage, lut: CubeLUT, intensityPercent: Int, adjustments: LUTAdjustments = .init(),
                      checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> CGImage? {
        try checkCancelled()
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let intensity = Float(min(max(intensityPercent, 0), 100)) / 100
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: width * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            // Android's non-native mapper checks each 4096-pixel batch, including
            // transparent pixels. Never publish a partially processed image.
            if offset % (4096 * 4) == 0 { try checkCancelled() }
            let alpha = UInt32(buffer[offset + 3])
            guard alpha != 0 else { continue }
            // CoreGraphics stores premultiplied bytes; Android's color Int is
            // straight-alpha. Perform LUT + finishing there, then premultiply.
            let original = SIMD3(Float(buffer[offset]), Float(buffer[offset + 1]), Float(buffer[offset + 2])) / Float(alpha)
            let mapped = lut.sample(original)
            func mix(_ input: Float, _ output: Float) -> UInt32 {
                // Android clamps extended LUT output before strength mixing.
                let originalByte = input * 255
                let mappedByte = output.clamped(to: 0...1) * 255
                return UInt32((originalByte + (mappedByte - originalByte) * intensity)
                    .clamped(to: 0...255).rounded())
            }
            let mixed = (alpha << 24) | (mix(original.x, mapped.x) << 16) |
                (mix(original.y, mapped.y) << 8) | mix(original.z, mapped.z)
            let finished = LUTColorPipeline.apply(mixed, adjustments: adjustments, preserveAlpha: true)
            for (channel, shift) in [16, 8, 0].enumerated() {
                let straight = (finished >> shift) & 255
                buffer[offset + channel] = UInt8((straight * alpha + 127) / 255)
            }
        }
        try checkCancelled()
        return context.makeImage()
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}

/// Android LutColorPipeline: finishing in the sRGB byte domain, after LUT mixing.
enum LUTColorPipeline {
    static func apply(_ color: UInt32, adjustments: LUTAdjustments, preserveAlpha: Bool) -> UInt32 {
        let adjustments = adjustments.normalized
        guard !adjustments.isNeutral else { return color }
        let alpha = preserveAlpha ? (color >> 24) & 255 : 255
        guard alpha != 0 else { return color }
        var r = Float((color >> 16) & 255) / 255
        var g = Float((color >> 8) & 255) / 255
        var b = Float(color & 255) / 255
        let luma = (r * 0.2126 + g * 0.7152 + b * 0.0722).clamped(to: 0...1)
        let shadows = -Float(adjustments.shadows) / 100 * 0.28 * smoothStep(0, 0.68, 1 - luma)
        let highlights = Float(adjustments.highlights) / 100 * 0.28 * smoothStep(0.32, 1, luma)
        r = (r + shadows + highlights).clamped(to: 0...1)
        g = (g + shadows + highlights).clamped(to: 0...1)
        b = (b + shadows + highlights).clamped(to: 0...1)
        let contrast = 1 + Float(adjustments.contrast) / 100 * 0.75
        r = ((r - 0.5) * contrast + 0.5).clamped(to: 0...1)
        g = ((g - 0.5) * contrast + 0.5).clamped(to: 0...1)
        b = ((b - 0.5) * contrast + 0.5).clamped(to: 0...1)
        let postLuma = (r * 0.2126 + g * 0.7152 + b * 0.0722).clamped(to: 0...1)
        let saturation = 1 + Float(adjustments.saturation) / 100
        r = (postLuma + (r - postLuma) * saturation).clamped(to: 0...1)
        g = (postLuma + (g - postLuma) * saturation).clamped(to: 0...1)
        b = (postLuma + (b - postLuma) * saturation).clamped(to: 0...1)
        return (alpha << 24) | (UInt32(r * 255 + 0.5) << 16) |
            (UInt32(g * 255 + 0.5) << 8) | UInt32(b * 255 + 0.5)
    }

    private static func smoothStep(_ lower: Float, _ upper: Float, _ value: Float) -> Float {
        let t = ((value - lower) / (upper - lower)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}
