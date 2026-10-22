import UIKit

/// Grain runs on photo tiles, after color and before frame/watermark. Coordinates
/// remain in the full upright photo so tile boundaries never change the noise.
enum PhotoGrainRenderer {
    static func apply(_ image: CGImage, settings: PhotoGrainSettings, seed: Int32,
                      fullWidth: Int? = nil, fullHeight: Int? = nil, originY: Int = 0) throws -> CGImage {
        guard settings.isEnabled else { return image }
        try Task.checkCancellation()
        let width = fullWidth ?? image.width, height = fullHeight ?? image.height
        let (count, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, count <= Int(Int32.max), width == image.width, height > 0,
              width <= Int(Int32.max), height <= Int(Int32.max), originY >= 0,
              originY <= height - image.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw PhotoEffectsRenderError.invalidBitmap }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for start in stride(from: 0, to: count, by: 16_384) {
            try Task.checkCancellation()
            zt_photo_grain_rgba(data.assumingMemoryBound(to: UInt8.self), Int32(image.width), Int32(start),
                Int32(min(16_384, count - start)), Int32(width), Int32(height), Int32(originY),
                Int32(settings.normalizedIntensity), seed, settings.style.nativeIndex)
        }
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw PhotoEffectsRenderError.invalidBitmap }
        return result
    }
}

@_silgen_name("zt_photo_grain_rgba")
private func zt_photo_grain_rgba(_ pixels: UnsafeMutablePointer<UInt8>, _ width: Int32, _ start: Int32, _ count: Int32,
                                _ fullWidth: Int32, _ fullHeight: Int32, _ originY: Int32,
                                _ intensity: Int32, _ seed: Int32, _ style: Int32)
