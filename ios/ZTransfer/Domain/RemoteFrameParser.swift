import Foundation
import UIKit

/// Keep the wire operation alongside its payload: standard frames must never
/// be interpreted as enhanced AF metadata (RemoteLab.labGrabFrame).
struct RemoteLiveViewPacket: Sendable {
    let bytes: Data
    let jpegOffset: Int
    let operation: UInt16
    let receivedAtUptime: TimeInterval

    init(bytes: Data, jpegOffset: Int, operation: UInt16,
         receivedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.bytes = bytes
        self.jpegOffset = jpegOffset
        self.operation = operation
        self.receivedAtUptime = receivedAtUptime
    }
}

/// Nikon's GetLiveViewImg payload can contain a proprietary prefix and trailing
/// bytes around the JPEG. Android locates the JPEG SOI before decoding; keep the
/// same rule here instead of passing the whole PTP payload to UIImage.
enum RemoteFrameParser {
    static func jpegStart(in payload: Data) -> Int? {
        guard payload.count >= 3 else { return nil }
        return (payload.startIndex..<(payload.endIndex - 2)).first {
            payload[$0] == 0xFF && payload[$0 + 1] == 0xD8 && payload[$0 + 2] == 0xFF
        }
    }
    static func jpegData(from payload: Data) -> Data? {
        guard let range = jpegRange(in: payload) else { return nil }
        return Data(payload[range])
    }

    static func jpegRange(in payload: Data) -> Range<Data.Index>? {
        guard payload.count >= 4 else { return nil }
        let start = payload.indices.dropLast().first { index in
            payload[index] == 0xFF && payload[payload.index(after: index)] == 0xD8
        }
        guard let start else { return nil }
        var index = payload.index(start, offsetBy: 2)
        while index < payload.index(before: payload.endIndex) {
            if payload[index] == 0xFF {
                let next = payload.index(after: index)
                if payload[next] == 0xD9 {
                    return start..<payload.index(next, offsetBy: 1)
                }
            }
            index = payload.index(after: index)
        }
        return nil
    }

    /// Metadata carried by Nikon's 0x9428 Display Information Data header.
    /// The layout and validation rules mirror Android's LiveViewMetadata parser.
    static func metadata(from payload: Data, jpegOffset: Int, operation: UInt16) -> RemoteLiveViewMetadata? {
        guard operation == PTPConstants.getLiveViewImageEx else { return nil }
        let bytes = [UInt8](payload)
        guard jpegOffset == 512 || jpegOffset == 1024,
              bytes.count >= jpegOffset + 3,
              be16(bytes, 0) == 1,
              be16(bytes, 2) == 0,
              be32(bytes, 8) == UInt32(jpegOffset),
              be32(bytes, 12) == UInt32(bytes.count - jpegOffset),
              bytes[jpegOffset] == 0xFF,
              bytes[jpegOffset + 1] == 0xD8,
              bytes[jpegOffset + 2] == 0xFF else { return nil }

        let coordinateWidth = be16(bytes, 16)
        let coordinateHeight = be16(bytes, 18)
        guard coordinateWidth > 0, coordinateHeight > 0 else { return nil }

        let focusWidth = be16(bytes, 28)
        let focusHeight = be16(bytes, 30)
        let validFocusGrid = focusWidth >= 1 && focusWidth <= coordinateWidth &&
            focusHeight >= 1 && focusHeight <= coordinateHeight

        let judgement: RemoteLiveViewFocusJudgement
        switch bytes[42] {
        case 0: judgement = .none
        case 1: judgement = .notFocused
        case 2: judgement = .focused
        default: return nil
        }

        let frameCount = Int(bytes[44])
        let selectedIndex = Int(bytes[45])
        let frameOffset = 48
        let frameStride = 8
        let maxFrameCount = (jpegOffset - frameOffset) / frameStride
        let completeFrameTable = frameCount >= 1 && frameCount <= maxFrameCount &&
            selectedIndex < frameCount && frameOffset + frameCount * frameStride <= jpegOffset

        var selectedFrame: RemoteLiveViewFocusFrame?
        if completeFrameTable {
            let offset = frameOffset + selectedIndex * frameStride
            let width = be16(bytes, offset)
            let height = be16(bytes, offset + 2)
            let centerX = be16(bytes, offset + 4)
            let centerY = be16(bytes, offset + 6)
            let valid = width >= 1 && width <= coordinateWidth &&
                height >= 1 && height <= coordinateHeight &&
                centerX <= coordinateWidth && centerY <= coordinateHeight &&
                centerX * 2 >= width && centerY * 2 >= height &&
                (coordinateWidth - centerX) * 2 >= width &&
                (coordinateHeight - centerY) * 2 >= height
            if valid {
                selectedFrame = RemoteLiveViewFocusFrame(
                    centerX: Float(centerX) / Float(coordinateWidth),
                    centerY: Float(centerY) / Float(coordinateHeight),
                    width: Float(width) / Float(coordinateWidth),
                    height: Float(height) / Float(coordinateHeight)
                )
            }
        }

        return RemoteLiveViewMetadata(
            focusJudgement: judgement,
            selectedFocusFrame: selectedFrame,
            trackingCoordinateWidth: coordinateWidth,
            trackingCoordinateHeight: coordinateHeight,
            focusCoordinateWidth: validFocusGrid ? focusWidth : nil,
            focusCoordinateHeight: validFocusGrid ? focusHeight : nil,
            soundLevels: soundLevels(in: bytes, headerSize: jpegOffset)
        )
    }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 1 < bytes.count else { return 0 }
        return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < bytes.count else { return 0 }
        return (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])
    }

    private static func soundLevels(in bytes: [UInt8], headerSize: Int) -> RemoteLiveViewSoundLevels? {
        let offset: Int
        switch headerSize {
        case 512: offset = 388
        case 1024: offset = 824
        default: return nil
        }
        guard offset + 3 < bytes.count else { return nil }
        let values = Array(bytes[offset..<(offset + 4)])
        guard values.allSatisfy({ $0 <= RemoteLiveViewSoundLevels.maxSegment }) else { return nil }
        return RemoteLiveViewSoundLevels(peakLeft: Int(values[0]), peakRight: Int(values[1]),
                                         currentLeft: Int(values[2]), currentRight: Int(values[3]))
    }
}

enum RemoteLiveViewFocusJudgement: Equatable, Sendable { case none, notFocused, focused }

struct RemoteLiveViewFocusFrame: Equatable, Sendable {
    let centerX: Float
    let centerY: Float
    let width: Float
    let height: Float
}

struct RemoteLiveViewSoundLevels: Equatable, Sendable {
    static let maxSegment = UInt8(14)
    let peakLeft: Int
    let peakRight: Int
    let currentLeft: Int
    let currentRight: Int
}

struct RemoteLiveViewMetadata: Equatable, Sendable {
    let focusJudgement: RemoteLiveViewFocusJudgement
    let selectedFocusFrame: RemoteLiveViewFocusFrame?
    let trackingCoordinateWidth: Int
    let trackingCoordinateHeight: Int
    let focusCoordinateWidth: Int?
    let focusCoordinateHeight: Int?
    let soundLevels: RemoteLiveViewSoundLevels?
}

struct RemoteZebraMask: Equatable, Sendable {
    let cols: Int
    let rows: Int
    let cells: [Bool]
}

struct RemoteDecodedFrame: @unchecked Sendable {
    let image: UIImage
    let jpeg: Data
    let metadata: RemoteLiveViewMetadata?
    let histogram: [Int]?
    let zebraMask: RemoteZebraMask?
    let fps: Double
    let generation: UInt64
    let receivedAtUptime: TimeInterval
}

/// Mirrors Android's conflated frame channel: camera I/O immediately continues
/// while decoding runs on a worker; if decoding falls behind, only the newest
/// waiting packet is retained. Histogram and zebra work share the same 250 ms
/// worker-side throttle and cost nothing while their overlays are disabled.
actor RemoteFrameDecodePipeline {
    struct Request: Sendable {
        let packet: RemoteLiveViewPacket
        let fps: Double
        let generation: UInt64
    }

    private let publish: @MainActor @Sendable (RemoteDecodedFrame) -> Void
    private let decodeDelayNanoseconds: UInt64
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var histogramEnabled = false
    private var zebraEnabled = false
    private var cachedHistogram: [Int]?
    private var cachedZebra: RemoteZebraMask?
    private var histogramCalculatedAt: ContinuousClock.Instant?
    private var zebraCalculatedAt: ContinuousClock.Instant?
    private(set) var isDecoding = false

    init(decodeDelayNanoseconds: UInt64 = 0,
         publish: @escaping @MainActor @Sendable (RemoteDecodedFrame) -> Void) {
        self.decodeDelayNanoseconds = decodeDelayNanoseconds
        self.publish = publish
    }

    func reset(generation: UInt64) {
        self.generation = generation
        pending = nil
    }

    func setAnalysis(histogram: Bool, zebra: Bool) {
        histogramEnabled = histogram
        zebraEnabled = zebra
        if !histogram { cachedHistogram = nil; histogramCalculatedAt = nil }
        if !zebra { cachedZebra = nil; zebraCalculatedAt = nil }
    }

    func submit(_ request: Request) {
        guard request.generation == generation else { return }
        pending = request
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            let now = ContinuousClock.now
            let calculateHistogram = histogramEnabled && (
                cachedHistogram == nil || histogramCalculatedAt.map { $0.duration(to: now) >= .milliseconds(250) } == true
            )
            let calculateZebra = zebraEnabled && (
                cachedZebra == nil || zebraCalculatedAt.map { $0.duration(to: now) >= .milliseconds(250) } == true
            )
            isDecoding = true
            let delay = decodeDelayNanoseconds
            let decoded = await Task.detached(priority: .userInitiated) {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                return Self.decode(request, histogram: calculateHistogram, zebra: calculateZebra)
            }.value
            isDecoding = false
            guard request.generation == generation, let decoded else { continue }
            if calculateHistogram {
                cachedHistogram = decoded.histogram
                histogramCalculatedAt = now
            }
            if calculateZebra {
                cachedZebra = decoded.zebraMask
                zebraCalculatedAt = now
            }
            let result = RemoteDecodedFrame(
                image: decoded.image,
                jpeg: decoded.jpeg,
                metadata: decoded.metadata,
                histogram: histogramEnabled ? (calculateHistogram ? decoded.histogram : cachedHistogram) : nil,
                zebraMask: zebraEnabled ? (calculateZebra ? decoded.zebraMask : cachedZebra) : nil,
                fps: request.fps,
                generation: request.generation,
                receivedAtUptime: request.packet.receivedAtUptime
            )
            await publish(result)
        }
        worker = nil
        // An enqueue can run after the loop observed nil but before worker is
        // cleared because actor methods interleave at awaits. Re-arm it here.
        if pending != nil {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    private nonisolated static func decode(
        _ request: Request,
        histogram: Bool,
        zebra: Bool
    ) -> RemoteDecodedFrame? {
        let payload = request.packet.bytes
        guard request.packet.jpegOffset >= 0, request.packet.jpegOffset < payload.count else { return nil }
        let jpeg = Data(payload[request.packet.jpegOffset...])
        guard let image = UIImage(data: jpeg) else { return nil }
        let cg = image.cgImage
        return RemoteDecodedFrame(
            image: image,
            jpeg: jpeg,
            metadata: RemoteFrameParser.metadata(from: payload,
                                                 jpegOffset: request.packet.jpegOffset,
                                                 operation: request.packet.operation),
            histogram: histogram ? cg.flatMap(histogramBins) : nil,
            zebraMask: zebra ? cg.flatMap(zebraMask) : nil,
            fps: request.fps,
            generation: request.generation,
            receivedAtUptime: request.packet.receivedAtUptime
        )
    }

    private nonisolated static func histogramBins(_ cg: CGImage) -> [Int]? {
        guard let pixels = rgbaPixels(cg) else { return nil }
        let bytes = pixels.bytes
        let channels = 4
        var bins = Array(repeating: 0, count: 24)
        let step = max(channels, bytes.count / 4096)
        var index = 0
        while index + 2 < bytes.count {
            let luminance = (Int(bytes[index]) * 299 + Int(bytes[index + 1]) * 587 + Int(bytes[index + 2]) * 114) / 1000
            bins[min(23, luminance * 24 / 256)] += 1
            index += step
        }
        return bins
    }

    private nonisolated static func zebraMask(_ cg: CGImage) -> RemoteZebraMask? {
        guard let pixels = rgbaPixels(cg) else { return nil }
        let width = pixels.width
        let height = pixels.height
        let cellWidth = max(1, (width + 119) / 120)
        let cellHeight = max(1, (height + 79) / 80)
        let cols = (width + cellWidth - 1) / cellWidth
        let rows = (height + cellHeight - 1) / cellHeight
        var cells = Array(repeating: false, count: cols * rows)
        for row in 0..<rows {
            let y = min(height - 1, row * cellHeight + cellHeight / 2)
            for column in 0..<cols {
                let x = min(width - 1, column * cellWidth + cellWidth / 2)
                let offset = y * pixels.rowBytes + x * 4
                let red = Int(pixels.bytes[offset])
                let green = Int(pixels.bytes[offset + 1])
                let blue = Int(pixels.bytes[offset + 2])
                cells[row * cols + column] = ((54 * red + 183 * green + 19 * blue) >> 8) >= 242
            }
        }
        return RemoteZebraMask(cols: cols, rows: rows, cells: cells)
    }

    private nonisolated static func rgbaPixels(
        _ cg: CGImage
    ) -> (bytes: [UInt8], width: Int, height: Int, rowBytes: Int)? {
        let width = max(1, cg.width)
        let height = max(1, cg.height)
        let rowBytes = width * 4
        var bytes = Array(repeating: UInt8(0), count: rowBytes * height)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? (bytes, width, height, rowBytes) : nil
    }
}
