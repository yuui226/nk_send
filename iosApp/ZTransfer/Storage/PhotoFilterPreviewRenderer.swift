import Foundation
import CoreGraphics
import Accelerate
import ZTransferShared

enum PhotoFilterPreviewError: Error { case invalidSize, allocationFailed, invalidImage, conversionFailed, invalidChunk }

/// Preview-only 4MP bound. Full-resolution export/stripe scheduling remains a separate task.
/// The input is already orientation-corrected. CoreGraphics develops to sRGB, Accelerate handles
/// alpha representation, and Kotlin performs every filter pixel operation using Android's kernel.
actor PhotoFilterPreviewRenderer {
    static let maximumPixels = 4 * 1024 * 1024
    /// Export keeps a bounded in-memory buffer while allowing common 12–24MP camera JPEGs.
    /// The output remains at source dimensions; the work is split into scanline tiles below.
    static let maximumExportPixels = 100 * 1024 * 1024
    private static let chunkPixels = 4096

    func render(_ source: CGImage, selection: PhotoFilterSelection) throws -> CGImage {
        try render(source, selection: selection, maximumPixels: Self.maximumPixels)
    }

    func renderExport(_ source: CGImage, selection: PhotoFilterSelection) throws -> CGImage {
        try renderTiled(source, selection: selection)
    }

    private func renderTiled(_ source: CGImage, selection: PhotoFilterSelection) throws -> CGImage {
        try Task.checkCancellation()
        let width = source.width, height = source.height
        guard width > 0, height > 0, width <= Self.maximumExportPixels,
              height <= Self.maximumExportPixels / width else { throw PhotoFilterPreviewError.invalidSize }
        let rowBytes = width * 4
        guard let output = calloc(width * height, 4),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PhotoFilterPreviewError.allocationFailed
        }
        defer { free(output) }
        let preserveAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(source.alphaInfo)
        let tileHeight = max(1, min(256, height))
        var y = 0
        while y < height {
            try Task.checkCancellation()
            let currentHeight = min(tileHeight, height - y)
            guard let tile = calloc(width * currentHeight, 4),
                  let context = CGContext(data: tile, width: width, height: currentHeight,
                      bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw PhotoFilterPreviewError.allocationFailed
            }
            do {
                defer { free(tile) }
                guard let cropped = source.cropping(to: CGRect(x: 0, y: y, width: width, height: currentHeight)) else {
                    throw PhotoFilterPreviewError.invalidImage
                }
                context.setBlendMode(.copy)
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: currentHeight))
                var input = vImage_Buffer(data: tile, height: vImagePixelCount(currentHeight),
                                          width: vImagePixelCount(width), rowBytes: rowBytes)
                var converted = input
                guard vImageUnpremultiplyData_ARGB8888(&input, &converted, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                    throw PhotoFilterPreviewError.conversionFailed
                }
                try Self.filter(tile.assumingMemoryBound(to: UInt8.self), count: width * currentHeight,
                                selection: selection, preserveAlpha: preserveAlpha)
                guard vImagePremultiplyData_ARGB8888(&input, &converted, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                    throw PhotoFilterPreviewError.conversionFailed
                }
                memcpy(output.advanced(by: y * rowBytes), tile, currentHeight * rowBytes)
            }
            y += currentHeight
        }
        let bytes = Data(bytes: output, count: width * height * 4)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: rowBytes, space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PhotoFilterPreviewError.invalidImage
        }
        return image
    }

    private func render(_ source: CGImage, selection: PhotoFilterSelection, maximumPixels: Int) throws -> CGImage {
        try Task.checkCancellation()
        let width = source.width, height = source.height
        guard width > 0, height > 0, width <= maximumPixels,
              height <= maximumPixels / width else { throw PhotoFilterPreviewError.invalidSize }
        let count = width * height, stride = width * 4
        guard let storage = calloc(count, 4) else { throw PhotoFilterPreviewError.allocationFailed }
        defer { free(storage) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw PhotoFilterPreviewError.invalidImage }
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: storage, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: stride, space: colorSpace, bitmapInfo: info) else { throw PhotoFilterPreviewError.invalidImage }
        context.setBlendMode(.copy)
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Task.checkCancellation()
        let preserveAlpha: Bool
        switch source.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: preserveAlpha = false
        default: preserveAlpha = true
        }
        // Separate buffer structs share storage; Apple documents these alpha conversions in-place.
        var input = vImage_Buffer(data: storage, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
        var output = input
        guard vImageUnpremultiplyData_ARGB8888(&input, &output, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw PhotoFilterPreviewError.conversionFailed
        }
        try Self.filter(storage.assumingMemoryBound(to: UInt8.self), count: count, selection: selection, preserveAlpha: preserveAlpha)
        guard vImagePremultiplyData_ARGB8888(&input, &output, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw PhotoFilterPreviewError.conversionFailed
        }
        try Task.checkCancellation()
        // Provider owns an immutable copy. No image can outlive a pointer to the freed scratch data.
        let bytes = Data(bytes: storage, count: count * 4)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PhotoFilterPreviewError.invalidImage }
        return image
    }

    /// Straight ARGB byte seam for bridge golden tests. Never mutates the caller's original bytes.
    func renderArgb(_ bytes: Data, selection: PhotoFilterSelection, preserveAlpha: Bool) throws -> Data {
        guard !bytes.isEmpty, bytes.count % 4 == 0, bytes.count / 4 <= Self.maximumPixels else {
            throw PhotoFilterPreviewError.invalidSize
        }
        try Task.checkCancellation()
        var result = bytes
        let count = bytes.count / 4
        try result.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw PhotoFilterPreviewError.allocationFailed }
            try Self.filter(base.assumingMemoryBound(to: UInt8.self), count: count, selection: selection, preserveAlpha: preserveAlpha)
        }
        return result
    }

    private static func filter(_ bytes: UnsafeMutablePointer<UInt8>, count: Int,
                               selection: PhotoFilterSelection, preserveAlpha: Bool) throws {
        let compiled = NativePhotoFilter(selection: selection, preserveAlpha: preserveAlpha)
        let chunk = KotlinIntArray(size: Int32(chunkPixels))
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let length = min(chunkPixels, count - offset)
            for index in 0..<length {
                let byte = (offset + index) * 4
                let value = UInt32(bytes[byte]) << 24 | UInt32(bytes[byte + 1]) << 16 |
                    UInt32(bytes[byte + 2]) << 8 | UInt32(bytes[byte + 3])
                chunk.set(index: Int32(index), value: Int32(bitPattern: value))
            }
            guard compiled.render(pixels: chunk, count: Int32(length)) else { throw PhotoFilterPreviewError.invalidChunk }
            for index in 0..<length {
                let value = UInt32(bitPattern: chunk.get(index: Int32(index)))
                let byte = (offset + index) * 4
                bytes[byte] = UInt8(truncatingIfNeeded: value >> 24)
                bytes[byte + 1] = UInt8(truncatingIfNeeded: value >> 16)
                bytes[byte + 2] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[byte + 3] = UInt8(truncatingIfNeeded: value)
            }
            offset += length
        }
        try Task.checkCancellation()
    }
}
