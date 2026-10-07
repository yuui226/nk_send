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
            soundLevels: soundLevels(in: bytes, headerSize: jpegOffset),
            attitude: compactAttitude(in: bytes, headerSize: jpegOffset)
        )
    }

    /// LiveViewMetadata.kt: only the verified 0x9428 compact-v1 layout.
    static func compactAttitude(in bytes: [UInt8], headerSize: Int) -> RemoteLiveViewAttitude? {
        guard headerSize == 512, bytes.count >= headerSize,
              be16(bytes, 0) == 1, be16(bytes, 2) == 0, be32(bytes, 8) == 512 else { return nil }
        let roll = be32(bytes, 404)
        let landscapePitch = be32(bytes, 408)
        let rollDegrees = Double(roll) / 65536
        let portrait = (45...135).contains(rollDegrees) || (225...315).contains(rollDegrees)
        let alternate = landscapePitch == UInt32.max && portrait
        let pitch = alternate ? be32(bytes, 412) : landscapePitch
        guard roll != 0 || pitch != 0, roll < 360 * 65536, pitch < 360 * 65536 else { return nil }
        func degrees(_ value: UInt32) -> Float {
            let result = Float(value) / 65536
            return result > 180 ? result - 360 : result
        }
        let reversePortrait = alternate && (225...315).contains(rollDegrees)
        let invertedLandscape = !alternate && (135...225).contains(rollDegrees) && be32(bytes, 412) == UInt32.max
        let p = reversePortrait || invertedLandscape ? 180 - Float(pitch) / 65536 : degrees(pitch)
        guard abs(p) <= 90 else { return nil }
        return RemoteLiveViewAttitude(roll: degrees(roll), pitch: p)
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

struct RemoteLiveViewAttitude: Equatable, Sendable {
    let roll: Float
    let pitch: Float
}

struct RemoteLiveViewMetadata: Equatable, Sendable {
    let focusJudgement: RemoteLiveViewFocusJudgement
    let selectedFocusFrame: RemoteLiveViewFocusFrame?
    let trackingCoordinateWidth: Int
    let trackingCoordinateHeight: Int
    let focusCoordinateWidth: Int?
    let focusCoordinateHeight: Int?
    let soundLevels: RemoteLiveViewSoundLevels?
    let attitude: RemoteLiveViewAttitude?

    init(focusJudgement: RemoteLiveViewFocusJudgement, selectedFocusFrame: RemoteLiveViewFocusFrame?,
         trackingCoordinateWidth: Int, trackingCoordinateHeight: Int,
         focusCoordinateWidth: Int?, focusCoordinateHeight: Int?, soundLevels: RemoteLiveViewSoundLevels?,
         attitude: RemoteLiveViewAttitude? = nil) {
        self.focusJudgement = focusJudgement
        self.selectedFocusFrame = selectedFocusFrame
        self.trackingCoordinateWidth = trackingCoordinateWidth
        self.trackingCoordinateHeight = trackingCoordinateHeight
        self.focusCoordinateWidth = focusCoordinateWidth
        self.focusCoordinateHeight = focusCoordinateHeight
        self.soundLevels = soundLevels
        self.attitude = attitude
    }
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
    let histogramRGB: [[Int]]?
    let waveform: [[Int]]?
    let falseColorPixels: [UInt32]?
    let falseColorWidth: Int
    let falseColorHeight: Int
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
    private var waveformEnabled = false
    private var waveformRGB = false
    private var cachedWaveform: [[Int]]?
    private var waveformCalculatedAt: ContinuousClock.Instant?
    private var falseColorEnabled = false
    private var histogramRGB = false
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

    func setAnalysis(histogram: Bool, zebra: Bool, waveform: Bool = false, waveformRGB: Bool = false, falseColor: Bool = false, histogramRGB: Bool = false) {
        let waveformModeChanged = self.waveformRGB != waveformRGB
        histogramEnabled = histogram
        zebraEnabled = zebra
        waveformEnabled = waveform
        self.waveformRGB = waveformRGB
        falseColorEnabled = falseColor
        self.histogramRGB = histogramRGB
        if !waveform || waveformModeChanged { cachedWaveform = nil; waveformCalculatedAt = nil }
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
            let calculateWaveform = waveformEnabled && (
                cachedWaveform == nil || waveformCalculatedAt.map { $0.duration(to: now) >= .milliseconds(125) } == true
            )
            let currentWaveformRGB = waveformRGB
            let currentFalseColor = falseColorEnabled
            let currentHistogramRGB = histogramRGB
            isDecoding = true
            let delay = decodeDelayNanoseconds
            let decoded = await Task.detached(priority: .userInitiated) {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                return Self.decode(request, histogram: calculateHistogram, histogramRGB: currentHistogramRGB, zebra: calculateZebra, waveform: calculateWaveform, waveformRGB: currentWaveformRGB, falseColor: currentFalseColor)
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
            if calculateWaveform {
                cachedWaveform = decoded.waveform
                waveformCalculatedAt = now
            }
            let result = RemoteDecodedFrame(
                image: decoded.image,
                jpeg: decoded.jpeg,
                metadata: decoded.metadata,
                histogram: histogramEnabled ? (calculateHistogram ? decoded.histogram : cachedHistogram) : nil,
                histogramRGB: histogramEnabled ? decoded.histogramRGB : nil,
                waveform: waveformEnabled ? (calculateWaveform ? decoded.waveform : cachedWaveform) : nil,
                falseColorPixels: falseColorEnabled ? decoded.falseColorPixels : nil,
                falseColorWidth: decoded.falseColorWidth,
                falseColorHeight: decoded.falseColorHeight,
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
        histogram: Bool, histogramRGB: Bool,
        zebra: Bool, waveform: Bool, waveformRGB: Bool, falseColor: Bool
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
            histogramRGB: histogramRGB ? cg.flatMap(rgbHistogramBins) : nil,
            waveform: waveform ? cg.flatMap { waveformBins($0, rgb: waveformRGB) } : nil,
            falseColorPixels: falseColor ? cg.flatMap { falseColorPixels($0) } : nil,
            falseColorWidth: cg?.width ?? 0,
            falseColorHeight: cg?.height ?? 0,
            zebraMask: zebra ? cg.flatMap(zebraMask) : nil,
            fps: request.fps,
            generation: request.generation,
            receivedAtUptime: request.packet.receivedAtUptime
        )
    }

    private nonisolated static func waveformBins(_ cg: CGImage, rgb: Bool) -> [[Int]]? {
        guard let pixels = rgbaPixels(cg) else { return nil }
        var packed = [UInt32](repeating: 0, count: pixels.width * pixels.height)
        for i in packed.indices {
            let o = i * 4
            packed[i] = UInt32(pixels.bytes[o]) << 16 | UInt32(pixels.bytes[o + 1]) << 8 | UInt32(pixels.bytes[o + 2])
        }
        return RemoteExposureAnalysis.waveformBins(pixels: packed, width: pixels.width, height: pixels.height, rgb: rgb)
    }

    private nonisolated static func falseColorPixels(_ cg: CGImage) -> [UInt32]? {
        guard let pixels = rgbaPixels(cg) else { return nil }
        var packed = [UInt32](repeating: 0, count: pixels.width * pixels.height)
        for i in packed.indices {
            let o = i * 4
            packed[i] = UInt32(pixels.bytes[o]) << 16 | UInt32(pixels.bytes[o + 1]) << 8 | UInt32(pixels.bytes[o + 2]
            )
        }
        return RemoteExposureAnalysis.falseColorPixels(pixels: packed, width: pixels.width, height: pixels.height)
    }

    private nonisolated static func histogramBins(_ cg: CGImage) -> [Int]? {
        guard let pixels = rgbaPixels(cg) else { return nil }
        let bytes = pixels.bytes
        let channels = 4
        // Android keeps the full 256-bin Rec.709 histogram and samples at most
        // roughly 24,000 pixels. Keep the bin identity; the drawing layer owns
        // any visual reduction to chart columns.
        var bins = Array(repeating: 0, count: 256)
        let pixelCount = max(1, pixels.width * pixels.height)
        let stepPixels = max(1, Int(ceil(sqrt(Double(pixelCount) / 24_000.0))))
        let step = max(channels, stepPixels * channels)
        var index = 0
        while index + 2 < bytes.count {
            let luminance = (54 * Int(bytes[index]) + 183 * Int(bytes[index + 1]) + 19 * Int(bytes[index + 2])) >> 8
            bins[luminance] += 1
            index += step
        }
        return bins
    }

    private nonisolated static func rgbHistogramBins(_ cg: CGImage) -> [[Int]]? {
        guard let pixels = rgbaPixels(cg) else { return nil }
        var channels = Array(repeating: Array(repeating: 0, count: 256), count: 3)
        let step = max(4, Int(ceil(sqrt(Double(pixels.width * pixels.height) / 24_000.0))) * 4)
        for index in stride(from: 0, to: pixels.bytes.count - 2, by: step) {
            channels[0][Int(pixels.bytes[index])] += 1
            channels[1][Int(pixels.bytes[index + 1])] += 1
            channels[2][Int(pixels.bytes[index + 2])] += 1
        }
        return channels
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
