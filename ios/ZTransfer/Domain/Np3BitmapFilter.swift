import CoreGraphics
import Foundation

enum PhotoEffectsRenderError: Error {
    case unknownFilter
    case invalidWatermarkImage
    case invalidBitmap
}

/// Android PhotoFilterRenderer reserves parallel filtering for previews only.
enum PhotoFilterExecution: Sendable {
    case original, preview

    func workers(width: Int, height: Int, processors: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        guard self == .preview, Int64(width) * Int64(height) >= 512 * 512 else { return 1 }
        return min(max(processors - 1, 1), 2)
    }
}

/// `concurrentPerform` requires Sendable captures even though it joins every
/// worker before returning. These wrappers document the two values that are
/// intentionally shared only for that bounded synchronous region: disjoint
/// pixel rows and a read-only handle to the originating Swift task.
private struct Np3ConcurrentPixelBuffer: @unchecked Sendable {
    let bytes: UnsafeMutablePointer<UInt8>
}

private struct Np3TaskCancellationProbe: @unchecked Sendable {
    let task: UnsafeCurrentTask?
    var isCancelled: Bool { task?.isCancelled == true }
}

/// The platform boundary for the shared NP3 pixel transform. Core Graphics
/// converts any source profile to 8-bit sRGB; the algorithm receives straight
/// alpha ARGB values, never misinterpreted premultiplied RGBA bytes.
enum Np3BitmapFilter {
    static func apply(_ image: CGImage, parameters: Np3FilterParameters,
                      intensityPercent: Int, execution: PhotoFilterExecution = .preview) throws -> CGImage {
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
        let engine = Np3FilterEngine(parameters: parameters, intensityPercent: intensityPercent)
        let workerCount = execution.workers(width: image.width, height: image.height)
        let rowChunk = max(1, (image.height + workerCount - 1) / workerCount)
        let pixelBuffer = Np3ConcurrentPixelBuffer(
            bytes: data.assumingMemoryBound(to: UInt8.self)
        )
        try withUnsafeCurrentTask { renderTask in
            let cancellation = Np3TaskCancellationProbe(task: renderTask)
            let process: @Sendable (Int) -> Void = { chunk in
                let bytes = pixelBuffer.bytes
                let firstRow = chunk * rowChunk
                let lastRow = min(image.height, firstRow + rowChunk)
                for y in firstRow..<lastRow {
                    // `concurrentPerform` executes these rows on GCD worker
                    // threads, where `Task.isCancelled` does not refer to the
                    // detached preview task that entered this function. Keep
                    // its task handle scoped to this synchronous call so a
                    // cancelled filter prefetch releases the shared preview
                    // render gate immediately instead of blocking the newly
                    // selected frame for the rest of a full pixel pass.
                    if cancellation.isCancelled { return }
                    for x in 0..<image.width {
                        if x % 4096 == 0, cancellation.isCancelled { return }
                        let offset = y * rowBytes + x * 4
                        let alpha = UInt32(bytes[offset + 3])
                        guard alpha != 0 else { continue }
                        let original = alpha << 24 |
                            min(255, (UInt32(bytes[offset]) * 255 + alpha / 2) / alpha) << 16 |
                            min(255, (UInt32(bytes[offset + 1]) * 255 + alpha / 2) / alpha) << 8 |
                            min(255, (UInt32(bytes[offset + 2]) * 255 + alpha / 2) / alpha)
                        let filtered = engine.filterPixel(original)
                        bytes[offset] = UInt8(((filtered >> 16 & 255) * alpha + 127) / 255)
                        bytes[offset + 1] = UInt8(((filtered >> 8 & 255) * alpha + 127) / 255)
                        bytes[offset + 2] = UInt8(((filtered & 255) * alpha + 127) / 255)
                    }
                }
            }
            if workerCount == 1 { process(0) }
            else { DispatchQueue.concurrentPerform(iterations: workerCount, execute: process) }
            if cancellation.isCancelled { throw CancellationError() }
        }
        guard let result = context.makeImage() else { throw PhotoEffectsRenderError.invalidBitmap }
        return result
    }
}
