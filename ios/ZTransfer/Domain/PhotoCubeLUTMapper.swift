import UIKit

enum PhotoCubeLUTMapper {
    static func apply(_ image: CGImage, lut: CubeLUT, intensityPercent: Int, adjustments: LUTAdjustments = .init(),
                      checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> CGImage? {
        try checkCancelled()
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let intensity = Float(min(max(intensityPercent, 0), 100)) / 100
        let finishing = LUTColorPipeline.Prepared(adjustments: adjustments)
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
            let finished = finishing.apply(mixed, preserveAlpha: true)
            buffer[offset] = UInt8((((finished >> 16) & 255) * alpha + 127) / 255)
            buffer[offset + 1] = UInt8((((finished >> 8) & 255) * alpha + 127) / 255)
            buffer[offset + 2] = UInt8(((finished & 255) * alpha + 127) / 255)
        }
        try checkCancelled()
        return context.makeImage()
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}
