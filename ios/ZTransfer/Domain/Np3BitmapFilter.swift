import CoreGraphics
import Foundation

enum PhotoEffectsRenderError: Error {
    case unknownFilter
    case invalidBitmap
}

/// The platform boundary for the shared NP3 pixel transform. Core Graphics
/// converts any source profile to 8-bit sRGB; the algorithm receives straight
/// alpha ARGB values, never misinterpreted premultiplied RGBA bytes.
enum Np3BitmapFilter {
    static func apply(_ image: CGImage, parameters: Np3FilterParameters,
                      intensityPercent: Int) throws -> CGImage {
        try Task.checkCancellation()
        let (rowBytes, overflow) = image.width.multipliedReportingOverflow(by: 4)
        let (_, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: image.height)
        guard !overflow, !sizeOverflow, image.width > 0, image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                        CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw PhotoEffectsRenderError.invalidBitmap }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let engine = Np3FilterEngine(parameters: parameters, intensityPercent: intensityPercent)
        for y in 0..<image.height {
            try Task.checkCancellation()
            for x in 0..<image.width {
                let offset = y * rowBytes + x * 4
                let alpha = UInt32(bytes[offset + 3])
                guard alpha != 0 else { continue }
                func straight(_ component: UInt8) -> UInt32 {
                    min(255, (UInt32(component) * 255 + alpha / 2) / alpha)
                }
                let original = alpha << 24 | straight(bytes[offset]) << 16 |
                    straight(bytes[offset + 1]) << 8 | straight(bytes[offset + 2])
                let filtered = engine.filterPixel(original)
                bytes[offset] = UInt8(((filtered >> 16 & 255) * alpha + 127) / 255)
                bytes[offset + 1] = UInt8(((filtered >> 8 & 255) * alpha + 127) / 255)
                bytes[offset + 2] = UInt8(((filtered & 255) * alpha + 127) / 255)
            }
        }
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw PhotoEffectsRenderError.invalidBitmap }
        return result
    }
}
