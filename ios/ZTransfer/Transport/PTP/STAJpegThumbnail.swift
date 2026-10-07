import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Android StaJpegThumbnail.kt: one independent MPF image, at most 256 KiB,
/// no EXIF rotation, no upscale, 640-pixel long edge and JPEG quality 90.
enum STAJpegThumbnail {
    static let edge = 640
    static let maximumBytes = 256 * 1024

    static func select(_ references: [STAMediaMetadata.Preview]) -> STAMediaMetadata.Preview? {
        references.filter {
            $0.offset > 0 && (0x010001...0x010005).contains($0.imageType)
                && (4...maximumBytes).contains($0.length)
        }.min { $0.length < $1.length }
    }

    static func longEdge(_ bytes: Data?) -> Int {
        guard let bytes, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return 0 }
        return max(width, height)
    }

    static func create(_ bytes: Data, fallbackLongEdge: Int) -> Data? {
        guard (4...maximumBytes).contains(bytes.count), bytes.starts(with: [255, 216]),
              bytes.suffix(2) == Data([255, 217]),
              min(longEdge(bytes), edge) > fallbackLongEdge else { return nil }
        let sourceEdge = longEdge(bytes)
        var sample = 1
        while sourceEdge / sample > edge * 2 { sample *= 2 }
        guard let source = CGImageSourceCreateWithData(bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: sourceEdge / sample,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image: CGImage
        let decodedEdge = max(decoded.width, decoded.height)
        if decodedEdge > edge {
            let ratio = Double(edge) / Double(decodedEdge)
            let width = max(1, Int((Double(decoded.width) * ratio).rounded()))
            let height = max(1, Int((Double(decoded.height) * ratio).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .low // Android filter=true: bilinear scaling.
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            image = scaled
        } else { image = decoded }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
            UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
