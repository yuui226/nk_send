import Foundation
import CoreGraphics
import ImageIO

enum PreviewImageError: Error { case invalidImage, invalidSize }

/// Decodes away from the main actor, with a fixed output bound and embedded orientation transform.
/// Encoded files are not modified. This does not replace shared RAW/MPF/video preview extraction.
actor PreviewImageDecoder {
    /// Bounded, orientation-normalized bytes for the Compose bitmap boundary. Work stays off UI.
    func queueThumbnailPNG(_ data: Data) throws -> Data {
        try thumbnailPNG(data, maximumPixelSize: 128, maximumBytes: 1_048_576)
    }

    /// Grid images retain more detail than queue cards, but still have a strict bridge payload cap.
    func gridThumbnailPNG(_ data: Data) throws -> Data {
        try thumbnailPNG(data, maximumPixelSize: 512, maximumBytes: 4 * 1024 * 1024)
    }

    private func thumbnailPNG(_ data: Data, maximumPixelSize: Int, maximumBytes: Int) throws -> Data {
        let decoded = try decode(data, maximumPixelSize: maximumPixelSize)
        return try encodePNG(decoded, maximumBytes: maximumBytes)
    }

    /// Only already-normalized, bounded images cross the single-photo Compose boundary.
    func singlePhotoPNG(_ image: CGImage) throws -> Data {
        guard (1...2048).contains(image.width), (1...2048).contains(image.height) else { throw PreviewImageError.invalidSize }
        return try encodePNG(image, maximumBytes: 20 * 1024 * 1024)
    }

    /// Android loadFhdPreview preserves camera pixel orientation and caps the long edge at 1920.
    /// Diagnostic/grid/effect images keep their existing orientation-normalized path.
    func fhdPreviewPNG(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PreviewImageError.invalidImage }
        let decoded = try image(source, maximumPixelSize: 1920, honorOrientation: false)
        return try encodePNG(decoded, maximumBytes: 20 * 1024 * 1024)
    }

    private func encodePNG(_ decoded: CGImage, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw PreviewImageError.invalidImage
        }
        CGImageDestinationAddImage(destination, decoded, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw PreviewImageError.invalidImage }
        try Task.checkCancellation()
        return output as Data
    }

    func decode(_ data: Data, maximumPixelSize: Int = 2048) throws -> CGImage {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PreviewImageError.invalidImage }
        return try image(source, maximumPixelSize: maximumPixelSize)
    }

    func decodeFile(_ url: URL, maximumPixelSize: Int = 2048) throws -> CGImage {
        try Task.checkCancellation()
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PreviewImageError.invalidImage }
        return try image(source, maximumPixelSize: maximumPixelSize)
    }

    private func image(_ source: CGImageSource, maximumPixelSize: Int, honorOrientation: Bool = true) throws -> CGImage {
        guard (1...4096).contains(maximumPixelSize) else { throw PreviewImageError.invalidSize }
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: honorOrientation,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw PreviewImageError.invalidImage }
        try Task.checkCancellation()
        return image
    }
}
