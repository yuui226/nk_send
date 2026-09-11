import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import AVFoundation
import ZTransferShared

enum PreviewImageError: Error { case invalidImage, invalidSize }

enum PreviewMediaDate {
    static func video(_ data: Data, timeZone: TimeZone = .current) -> String? {
        guard let seconds = NativeStaDirectBridge.shared.videoCaptureSeconds(data: data as NSData)?.int64Value else { return nil }
        // Match Android's local Gregorian DateTimeFormatter, independent of user Buddhist calendar.
        // Foundation cannot represent the Java Instant extreme years; reject instead of inventing a date.
        guard seconds > 0, seconds <= 253_402_300_799 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

/// Decodes away from the main actor. Bounded thumbnails/FHD are separate from full-size originals.
/// Encoded files are not modified. This does not replace the original RAW/MPF/video extraction rules.
actor PreviewImageDecoder {
    private let thumbnailPolicy = NativePreviewPolicy()
    /// Platform counterpart of Android's bounded-prefix MediaMetadataRetriever fallback.
    /// Only this private temporary is opened by AVFoundation; original/provider URLs never escape.
    func videoThumbnail(_ prefix: Data, fileExtension: String) async throws -> Data? {
        try Task.checkCancellation()
        guard !prefix.isEmpty, prefix.count <= 8 * 1024 * 1024,
              [".mov", ".mp4"].contains(fileExtension) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sta_video_" + UUID().uuidString + fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        try prefix.write(to: url, options: [.atomic, .completeFileProtection])
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 4096, height: 4096)
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await generator.image(at: .zero)
            } onCancel: { generator.cancelAllCGImageGeneration() }
            try Task.checkCancellation()
            return try encodePNG(result.image, maximumBytes: 16 * 1024 * 1024)
        } catch {
            try Task.checkCancellation()
            return nil // A complete prefix without a decodable frame is a confirmed camera miss.
        }
    }
    /// Only camera-supplied embedded thumbnail bytes; never synthesize one from a primary image.
    func embeddedExifThumbnailPNG(_ envelope: Data) throws -> Data? {
        try Task.checkCancellation()
        guard !envelope.isEmpty, envelope.count <= 128 * 1024 else { return nil }
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(envelope as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: false,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return try encodePNG(image, maximumBytes: 4 * 1024 * 1024)
        }
    }

    /// Android camera-generated FHD/LargeThumb validates SOI and bounds, not a RAW envelope.
    nonisolated static func cameraPreviewDimensions(_ data: Data) throws -> (width: Int32, height: Int32)? {
        try Task.checkCancellation()
        guard data.count >= 2, data.count <= 32 * 1024 * 1024,
              data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
            return dimensions(properties)
        }
    }

    func exifMetadata(_ header: Data) throws -> PhotoExif? {
        try PreviewExifReader.metadata(header: header)
    }

    /// Bounds-only candidate probe, equivalent to Android inJustDecodeBounds; no RAW render.
    nonisolated static func rawPreviewPixels(_ data: Data) throws -> Int64 {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard data.count <= Int(Int32.max), NativeRawPreviewBridge.shared.isCompleteJpeg(data: data as NSData),
                  let source = CGImageSourceCreateWithData(data as CFData,
                      [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let dimensions = Self.dimensions(properties) else { return -1 }
            try Task.checkCancellation()
            return LocalRawPreviewPolicy.shared.pixelCount(width: dimensions.width, height: dimensions.height)
        }
    }

    /// Header values must fit the existing shared Int representation, without NSNumber truncation.
    /// This is not a product resolution limit or a downsampling policy.
    nonisolated static func dimensions(_ properties: [CFString: Any]) -> (width: Int32, height: Int32)? {
        func edge(_ key: CFString) -> Int32? {
            guard let number = properties[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 1, value <= Double(Int32.max), value.rounded(.towardZero) == value else { return nil }
            return Int32(value)
        }
        guard let width = edge(kCGImagePropertyPixelWidth), let height = edge(kCGImagePropertyPixelHeight) else { return nil }
        return (width, height)
    }

    /// DIRECT_BITMAP route only: full resolution, no EXIF transform, no thumbnail API.
    /// RAW embedded-JPEG selection and TIFF's camera fallback are separate routes.
    func originalBitmapPNG(_ data: Data) throws -> Data {
        try withDataSource(data, maximumBytes: Int(Int32.max)) { source in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let dimensions = Self.dimensions(properties) else { throw PreviewImageError.invalidSize }
            let pixels = Int(dimensions.width).multipliedReportingOverflow(by: Int(dimensions.height))
            guard !pixels.overflow, !pixels.partialValue.multipliedReportingOverflow(by: 4).overflow,
                  thumbnailPolicy.originalPixelsAllowed(width: dimensions.width, height: dimensions.height) else {
                throw PreviewImageError.invalidSize
            }
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw PreviewImageError.invalidImage }
            // Encoding without source metadata strips orientation while preserving the decoded pixel grid.
            return try encodePNG(image, maximumBytes: Int(Int32.max))
        }
    }

    /// Camera bitmap orientation, as on Android. EXIF/user rotation belongs to the preview coordinator.
    func queueThumbnailPNG(_ data: Data, file: CameraFileInfo? = nil) throws -> Data {
        try thumbnailPNG(data, maximumPixelSize: 128, maximumBytes: 1_048_576, file: file)
    }

    /// Grid images retain more detail than queue cards, but still have a strict bridge payload cap.
    func gridThumbnailPNG(_ data: Data, file: CameraFileInfo? = nil) throws -> Data {
        try thumbnailPNG(data, maximumPixelSize: 512, maximumBytes: 4 * 1024 * 1024, file: file)
    }

    private func thumbnailPNG(_ data: Data, maximumPixelSize: Int, maximumBytes: Int, file: CameraFileInfo?) throws -> Data {
        try withDataSource(data, maximumBytes: 32 * 1024 * 1024) { source in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let bounds = Self.dimensions(properties),
                  thumbnailPolicy.thumbnailPixelsAllowed(width: bounds.width, height: bounds.height),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw PreviewImageError.invalidImage }
            // Detect/crop in the camera's original pixel grid BEFORE display downsampling; the
            // original 1px transition and symmetry thresholds must not depend on cell size.
            let cropped = try cropThumbnail(decoded, video: file.map { thumbnailPolicy.isVideo(file: $0) } ?? false)
            let output = try resizeThumbnail(cropped, maximumPixelSize: maximumPixelSize)
            return try encodePNG(output, maximumBytes: maximumBytes)
        }
    }

    private func resizeThumbnail(_ source: CGImage, maximumPixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        let longEdge = max(source.width, source.height)
        if longEdge <= maximumPixelSize { return source }
        let scale = Double(maximumPixelSize) / Double(longEdge)
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        let space = source.colorSpace?.model == .rgb ? source.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PreviewImageError.invalidImage }
        context.setBlendMode(.copy); context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw PreviewImageError.invalidImage }
        return image
    }

    /// Detection uses the shared Android math. Crop the source image, not the sRGB scratch buffer,
    /// preserving its color space, pixels and alpha. This never touches FHD or originalBitmapPNG.
    func cropThumbnail(_ source: CGImage, video: Bool) throws -> CGImage {
        try Task.checkCancellation()
        let width = source.width, height = source.height
        if width < 16 || height < 16 { return source }
        guard width <= 32 * 1024 * 1024 / height else { throw PreviewImageError.invalidSize }
        let count = width * height * 4, stride = width * 4
        guard let storage = calloc(count, 1) else { throw PreviewImageError.invalidSize }
        defer { free(storage) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: storage, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: stride, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw PreviewImageError.invalidImage
        }
        context.setBlendMode(.copy)
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var input = vImage_Buffer(data: storage, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
        var output = input
        guard vImageUnpremultiplyData_ARGB8888(&input, &output, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw PreviewImageError.invalidImage
        }
        try Task.checkCancellation()
        let crop = NativeThumbnailCropBridge.shared.crop(data: NSData(bytes: storage, length: count),
            width: Int32(width), height: Int32(height), video: video)
        try Task.checkCancellation()
        guard let crop else { return source }
        guard let image = source.cropping(to: CGRect(x: Int(crop.left), y: Int(crop.top),
            width: Int(crop.width), height: Int(crop.height))) else { throw PreviewImageError.invalidImage }
        return image
    }

    /// Only already-normalized, bounded images cross the single-photo Compose boundary.
    func singlePhotoPNG(_ image: CGImage) throws -> Data {
        guard (1...2048).contains(image.width), (1...2048).contains(image.height) else { throw PreviewImageError.invalidSize }
        return try encodePNG(image, maximumBytes: 20 * 1024 * 1024)
    }

    /// Android loadFhdPreview preserves camera pixel orientation and caps the long edge at 1920.
    /// Diagnostic/grid/effect images keep their existing orientation-normalized path.
    func fhdPreviewPNG(_ data: Data) throws -> Data {
        try withDataSource(data, maximumBytes: 32 * 1024 * 1024) { source in
            let decoded = try image(source, maximumPixelSize: 1920, honorOrientation: false)
            return try encodePNG(decoded, maximumBytes: 20 * 1024 * 1024)
        }
    }

    private func encodePNG(_ decoded: CGImage, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        return try autoreleasepool {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                throw PreviewImageError.invalidImage
            }
            CGImageDestinationAddImage(destination, decoded, nil)
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw PreviewImageError.invalidImage }
            try Task.checkCancellation()
            return output as Data
        }
    }

    /// ImageIO temporaries have a per-operation lifetime even on long-lived Swift concurrency threads.
    /// Native output owners retain only the returned CGImage/Data, never an autoreleased source cache.
    private func withDataSource<T>(_ data: Data, maximumBytes: Int, body: (CGImageSource) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes else { throw PreviewImageError.invalidImage }
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0 else {
                throw PreviewImageError.invalidImage
            }
            try Task.checkCancellation()
            let value = try body(source)
            try Task.checkCancellation()
            return value
        }
    }

    func decode(_ data: Data, maximumPixelSize: Int = 2048) throws -> CGImage {
        try Task.checkCancellation()
        guard (1...4096).contains(maximumPixelSize) else { throw PreviewImageError.invalidSize }
        return try withDataSource(data, maximumBytes: 32 * 1024 * 1024) {
            try image($0, maximumPixelSize: maximumPixelSize)
        }
    }

    func decodeFile(_ url: URL, maximumPixelSize: Int = 2048) throws -> CGImage {
        try Task.checkCancellation()
        guard (1...4096).contains(maximumPixelSize) else { throw PreviewImageError.invalidSize }
        return try autoreleasepool {
            guard url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let source = CGImageSourceCreateWithURL(url as CFURL,
                      [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PreviewImageError.invalidImage }
            return try image(source, maximumPixelSize: maximumPixelSize)
        }
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
