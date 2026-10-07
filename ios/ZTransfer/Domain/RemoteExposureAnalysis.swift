import Foundation

/// Display-referred monitor exposure math copied from Android's
/// RemoteExposureAnalysis. This intentionally uses integer Rec.709 math so
/// threshold membership is identical at every 8-bit boundary.
enum RemoteExposureAnalysis {
    static let waveformWidth = 256
    static let waveformHeight = 128
    static func luma(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        (54 * Int(red) + 183 * Int(green) + 19 * Int(blue)) >> 8
    }

    static func falseColor(forLuma value: Int) -> UInt32 {
        switch value {
        case ..<13: return 0xFF6B39B8
        case 13..<38: return 0xFF2874D7
        case 38..<102: return 0xFF50555B
        case 102..<115: return 0xFF5ABE87
        case 115..<140: return 0xFFE792AE
        case 140..<204: return 0xFFB9BDC2
        case 204..<242: return 0xFFF0D55D
        default: return 0xFFF14D4D
        }
    }

    static func falseColor(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        falseColor(forLuma: luma(red: red, green: green, blue: blue))
    }

    static func falseColorPixels(pixels: [UInt32], width: Int, height: Int) -> [UInt32]? {
        guard width > 0, height > 0, pixels.count >= width * height else { return nil }
        return pixels.map {
            falseColor(red: UInt8(($0 >> 16) & 255), green: UInt8(($0 >> 8) & 255), blue: UInt8($0 & 255))
        }
    }

    /// Returns one count buffer per channel, using Android's nearest sampled
    /// x coordinate and bottom-origin 256×128 waveform grid.
    static func waveformBins(pixels: [UInt32], width: Int, height: Int, rgb: Bool) -> [[Int]] {
        guard width > 0, height > 0, pixels.count >= width * height else { return [] }
        let channels = rgb ? 3 : 1
        var result = Array(repeating: Array(repeating: 0, count: waveformWidth * waveformHeight), count: channels)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels[y * width + x]
                let red = Int((pixel >> 16) & 255), green = Int((pixel >> 8) & 255), blue = Int(pixel & 255)
                let values = rgb ? [red, green, blue] : [luma(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))]
                let column = min(waveformWidth - 1, x * waveformWidth / width)
                for channel in 0..<channels {
                    let row = waveformHeight - 1 - values[channel] * (waveformHeight - 1) / 255
                    result[channel][row * waveformWidth + column] += 1
                }
            }
        }
        return result
    }

    static func waveformAlpha(count: Int, sampleHeight: Int) -> Int {
        guard count > 0, sampleHeight > 0 else { return 0 }
        return min(255, max(0, Int((255.0 * log1p(Double(count)) / log1p(Double(sampleHeight))).rounded())))
    }
}
