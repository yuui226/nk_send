import Foundation

/// Nikon's GetLiveViewImg payload can contain a proprietary prefix and trailing
/// bytes around the JPEG. Android locates the JPEG SOI before decoding; keep the
/// same rule here instead of passing the whole PTP payload to UIImage.
enum RemoteFrameParser {
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
