import UIKit

enum PhotoCubeLUTMapper {
    static func apply(_ image: CGImage, lut: CubeLUT, intensityPercent: Int) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let intensity = Float(min(max(intensityPercent, 0), 100)) / 100
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: width * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let original = SIMD3(Float(buffer[offset]) / 255, Float(buffer[offset + 1]) / 255, Float(buffer[offset + 2]) / 255)
            let mapped = lut.sample(original)
            buffer[offset] = UInt8(((original.x + (mapped.x - original.x) * intensity).clamped(to: 0...1) * 255).rounded())
            buffer[offset + 1] = UInt8(((original.y + (mapped.y - original.y) * intensity).clamped(to: 0...1) * 255).rounded())
            buffer[offset + 2] = UInt8(((original.z + (mapped.z - original.z) * intensity).clamped(to: 0...1) * 255).rounded())
        }
        return context.makeImage()
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}
