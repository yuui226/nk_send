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
                      intensityPercent: Int, adjustments: LUTAdjustments = .init(),
                      execution: PhotoFilterExecution = .preview) throws -> CGImage {
        try apply(image, parameters: .flexible(parameters), intensityPercent: intensityPercent,
                  adjustments: adjustments, execution: execution)
    }

    static func apply(_ image: CGImage, parameters: PhotoNp3Parameters,
                      intensityPercent: Int, adjustments: LUTAdjustments = .init(),
                      execution: PhotoFilterExecution = .preview) throws -> CGImage {
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
        let engine = Np3FilterEngine(parameters: parameters, intensityPercent: intensityPercent,
                                     adjustments: adjustments)
        let workerCount = execution.workers(width: image.width, height: image.height)
        let rowChunk = max(1, (image.height + workerCount - 1) / workerCount)
        let pixelBuffer = Np3ConcurrentPixelBuffer(
            bytes: data.assumingMemoryBound(to: UInt8.self)
        )
        // Android's original export memoizes exact RGB results. Preview stays at
        // most two workers and each worker keeps a private table so a collision
        // still recomputes instead of mixing two recipes.
        let memoKey = Np3ExactMemoKey(parameters: parameters,
                                      intensityPercent: engine.normalizedIntensityPercent,
                                      adjustments: adjustments.normalized)
        let sharedMemo = workerCount == 1 ? Np3ExactMemoCache.shared.borrow(memoKey) : nil
        defer { if let sharedMemo { Np3ExactMemoCache.shared.recycle(memoKey, sharedMemo) } }
        try withUnsafeCurrentTask { renderTask in
            let context = Np3ApplyContext(engine: engine, cancellation: Np3TaskCancellationProbe(task: renderTask))
            let process: @Sendable (Int) -> Void = { chunk in
                let memo = (chunk == 0 ? sharedMemo : nil) ?? Np3ExactMemo()
                let firstRow = chunk * rowChunk
                let lastRow = min(image.height, firstRow + rowChunk)
                // `concurrentPerform` executes these rows on GCD worker threads,
                // where `Task.isCancelled` does not refer to the detached preview
                // task. The probe keeps that task handle for this synchronous call.
                let contextPointer = Unmanaged.passUnretained(context).toOpaque()
                _ = zt_np3_apply_rgba(pixelBuffer.bytes, Int32(image.width), Int32(image.height), Int32(rowBytes),
                                      Int32(firstRow), Int32(lastRow), memo.entries, Int32(Np3ExactMemo.mask),
                                      np3MapStraightRGB, contextPointer, np3RenderIsCancelled, contextPointer)
            }
            if workerCount == 1 { process(0) }
            else { DispatchQueue.concurrentPerform(iterations: workerCount, execute: process) }
            if context.cancellation.isCancelled { throw CancellationError() }
        }
        guard let result = context.makeImage() else { throw PhotoEffectsRenderError.invalidBitmap }
        return result
    }
}

@_silgen_name("zt_np3_apply_rgba")
private func zt_np3_apply_rgba(
    _ bytes: UnsafeMutablePointer<UInt8>, _ width: Int32, _ height: Int32, _ rowBytes: Int32,
    _ firstRow: Int32, _ lastRow: Int32, _ memo: UnsafeMutablePointer<UInt64>, _ memoMask: Int32,
    _ map: @convention(c) (UInt32, UnsafeMutableRawPointer) -> UInt32, _ mapContext: UnsafeMutableRawPointer,
    _ cancelled: @convention(c) (UnsafeMutableRawPointer) -> Int32, _ cancelContext: UnsafeMutableRawPointer
) -> Int32

private let np3MapStraightRGB: @convention(c) (UInt32, UnsafeMutableRawPointer) -> UInt32 = { rgb, raw in
    // Alpha is restored by the caller. RGB does not depend on it once the pixel is visible.
    Unmanaged<Np3ApplyContext>.fromOpaque(raw).takeUnretainedValue().engine.filterPixel(0xff00_0000 | rgb) & 0x00ff_ffff
}

private let np3RenderIsCancelled: @convention(c) (UnsafeMutableRawPointer) -> Int32 = { raw in
    Unmanaged<Np3ApplyContext>.fromOpaque(raw).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
}

private final class Np3ApplyContext: @unchecked Sendable {
    let engine: Np3FilterEngine
    let cancellation: Np3TaskCancellationProbe
    init(engine: Np3FilterEngine, cancellation: Np3TaskCancellationProbe) {
        self.engine = engine
        self.cancellation = cancellation
    }
}

private struct Np3ExactMemoKey: Equatable {
    let parameters: PhotoNp3Parameters
    let intensityPercent: Int
    let adjustments: LUTAdjustments
}

/// Android ExactRgbMemo: 2^20 slots, 8 bytes each. A later image with the same
/// recipe reuses learned colors. Callers borrow exclusively so two exports never
/// write one table.
private final class Np3ExactMemo: @unchecked Sendable {
    static let bits = 20
    static let count = 1 << bits
    static let mask = count - 1
    let entries: UnsafeMutablePointer<UInt64>
    init() {
        entries = .allocate(capacity: Self.count)
        entries.initialize(repeating: 0, count: Self.count)
    }
    deinit { entries.deallocate() }
}

private final class Np3ExactMemoCache: @unchecked Sendable {
    static let shared = Np3ExactMemoCache()
    private let lock = NSLock()
    private var stored: (key: Np3ExactMemoKey, memo: Np3ExactMemo)?

    func borrow(_ key: Np3ExactMemoKey) -> Np3ExactMemo {
        lock.lock()
        defer { lock.unlock() }
        if let stored, stored.key == key {
            let memo = stored.memo
            self.stored = nil
            return memo
        }
        self.stored = nil
        return Np3ExactMemo()
    }

    func recycle(_ key: Np3ExactMemoKey, _ memo: Np3ExactMemo) {
        lock.lock()
        stored = (key, memo)
        lock.unlock()
    }
}
