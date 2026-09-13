import Foundation

struct Np3ColorBand: Codable, Equatable, Sendable {
    let centerDegrees: Float
    let hue: Int
    let chroma: Int
    let brightness: Int
}

/// Android's supported Flexible Color values. No display-name interpretation or
/// platform photo effect participates in this model or its pixel transform.
struct Np3FilterParameters: Codable, Equatable, Sendable {
    static let colorBandCenters: [Float] = [0, 30, 60, 120, 180, 240, 280, 320]
    static let toneCurvePointCount = 257
    static let toneCurveMaximum: UInt16 = 0x7fff

    let contrast: Int
    let highlights: Int
    let shadows: Int
    let whites: Int
    let blacks: Int
    let saturation: Int
    let colorBands: [Np3ColorBand]
    let toneCurve: [UInt16]?

    init(contrast: Int = 0, highlights: Int = 0, shadows: Int = 0,
         whites: Int = 0, blacks: Int = 0, saturation: Int = 0,
         colorBands: [Np3ColorBand], toneCurve: [UInt16]? = nil) {
        precondition([contrast, highlights, shadows, whites, blacks, saturation].allSatisfy { (-100...100).contains($0) })
        precondition(colorBands.count == Self.colorBandCenters.count)
        precondition(zip(colorBands, Self.colorBandCenters).allSatisfy { band, center in
            band.centerDegrees == center && [band.hue, band.chroma, band.brightness].allSatisfy { (-100...100).contains($0) }
        })
        if let toneCurve {
            precondition(toneCurve.count == Self.toneCurvePointCount)
            precondition(toneCurve.allSatisfy { $0 <= Self.toneCurveMaximum })
        }
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.saturation = saturation
        self.colorBands = colorBands
        self.toneCurve = toneCurve
    }

    /// CuratedNp3Filters stores three unsigned bytes per color band with neutral
    /// at 128, and 257 big-endian UInt16 curve points in the range 0...32767.
    init(contrast: Int = 0, highlights: Int = 0, shadows: Int = 0,
         whites: Int = 0, blacks: Int = 0, saturation: Int = 0,
         colorMixerBase64: String, toneCurveBase64: String? = nil) {
        guard let mixerData = Data(base64Encoded: colorMixerBase64) else {
            preconditionFailure("Invalid curated NP3 color mixer")
        }
        let mixer = Array(mixerData)
        precondition(mixer.count == Self.colorBandCenters.count * 3)
        let bands = Self.colorBandCenters.enumerated().map { index, center in
            let offset = index * 3
            return Np3ColorBand(centerDegrees: center,
                                hue: Int(mixer[offset]) - 128,
                                chroma: Int(mixer[offset + 1]) - 128,
                                brightness: Int(mixer[offset + 2]) - 128)
        }
        let curve: [UInt16]? = toneCurveBase64.map { encoded in
            guard let data = Data(base64Encoded: encoded) else {
                preconditionFailure("Invalid curated NP3 tone curve")
            }
            let bytes = Array(data)
            precondition(bytes.count == Self.toneCurvePointCount * 2)
            return stride(from: 0, to: bytes.count, by: 2).map {
                UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
            }
        }
        self.init(contrast: contrast, highlights: highlights, shadows: shadows,
                  whites: whites, blacks: blacks, saturation: saturation,
                  colorBands: bands, toneCurve: curve)
    }
}

/// A direct Float-for-Float port of Android PhotoFilterRenderer's NP3 transform.
/// Input/output pixels are unpremultiplied 8-bit sRGB ARGB values. Image decoding,
/// orientation and Core Graphics premultiplication belong to the platform adapter.
struct Np3FilterEngine: Sendable {
    static let defaultIntensityPercent = 80
    static let neutralProtectionChromaStart: Float = 4 / 255
    static let neutralProtectionChromaEnd: Float = 16 / 255
    private static let cancellationCheckInterval = 4 * 1024

    let normalizedIntensityPercent: Int
    private let parameters: Np3FilterParameters
    private let strength: Float
    private let preserveAlpha: Bool
    private let normalizedToneCurve: [Float]?
    private let saturationAdjustment: Float
    private let blacksScale: Float
    private let shadowsScale: Float
    private let highlightsScale: Float
    private let whitesScale: Float
    private let contrastScale: Float

    init(parameters: Np3FilterParameters, intensityPercent: Int,
         preserveAlpha: Bool = true) {
        self.parameters = parameters
        normalizedIntensityPercent = Self.normalizeIntensity(intensityPercent)
        strength = Float(normalizedIntensityPercent) / 100
        self.preserveAlpha = preserveAlpha
        normalizedToneCurve = parameters.toneCurve?.map { Float($0) / Float(Np3FilterParameters.toneCurveMaximum) }
        saturationAdjustment = Float(parameters.saturation) / 100
        blacksScale = Float(parameters.blacks) / 100 * 0.12
        shadowsScale = Float(parameters.shadows) / 100 * 0.18
        highlightsScale = Float(parameters.highlights) / 100 * 0.18
        whitesScale = Float(parameters.whites) / 100 * 0.12
        // Kotlin Float.pow computes through java.lang.Math.pow then casts back.
        contrastScale = Float(pow(2.0, Double(Float(parameters.contrast) / 100)))
    }

    static func normalizeIntensity(_ value: Int) -> Int {
        let clamped = min(max(value, 2), 100)
        return min((clamped + 1) / 2 * 2, 100)
    }

    /// The complete effect is quantized to RGB first; strength blends those
    /// channels with the original. Scaling NP3 controls instead changes pixels.
    func filterPixel(_ color: UInt32) -> UInt32 {
        let alpha = preserveAlpha ? color >> 24 & 0xff : 0xff
        if alpha == 0 { return color }
        let originalR = Int(color >> 16 & 0xff)
        let originalG = Int(color >> 8 & 0xff)
        let originalB = Int(color & 0xff)
        let red = Float(originalR) / 255
        let green = Float(originalG) / 255
        let blue = Float(originalB) / 255
        let maximum = max(red, max(green, blue))
        let minimum = min(red, min(green, blue))
        let delta = maximum - minimum
        var lightness = (maximum + minimum) / 2
        var saturation: Float = delta == 0 ? 0 : delta / max(1 - abs(2 * lightness - 1), 0.0001)
        let originalHue: Float
        if delta == 0 {
            originalHue = 0
        } else if maximum == red {
            originalHue = Self.normalizeHue(60 * ((green - blue) / delta))
        } else if maximum == green {
            originalHue = Self.normalizeHue(60 * ((blue - red) / delta + 2))
        } else {
            originalHue = Self.normalizeHue(60 * ((red - green) / delta + 4))
        }
        let colorWeight = Self.neutralProtectionWeight(delta)
        let leftIndex: Int
        switch originalHue {
        case ..<30: leftIndex = 0
        case ..<60: leftIndex = 1
        case ..<120: leftIndex = 2
        case ..<180: leftIndex = 3
        case ..<240: leftIndex = 4
        case ..<280: leftIndex = 5
        case ..<320: leftIndex = 6
        default: leftIndex = 7
        }
        let rightIndex = leftIndex == 7 ? 0 : leftIndex + 1
        let start = Np3FilterParameters.colorBandCenters[leftIndex]
        let end: Float = rightIndex == 0 ? 360 : Np3FilterParameters.colorBandCenters[rightIndex]
        let progress = Self.unit((originalHue - start) / (end - start))
        let inverse = 1 - progress
        let left = parameters.colorBands[leftIndex]
        let right = parameters.colorBands[rightIndex]
        let hueShift = (Float(left.hue) * inverse + Float(right.hue) * progress) / 100 * 30
        let chroma = Float(left.chroma) * inverse + Float(right.chroma) * progress
        let brightness = Float(left.brightness) * inverse + Float(right.brightness) * progress
        let hue = Self.normalizeHue(originalHue + hueShift * colorWeight)
        saturation *= 1 + chroma / 100 * colorWeight
        if saturationAdjustment != 0 {
            saturation *= 1 + (saturationAdjustment > 0 ? saturationAdjustment * colorWeight : saturationAdjustment)
        }
        lightness += brightness / 100 * 0.20 * colorWeight
        if let normalizedToneCurve {
            lightness = Self.mapToneCurve(lightness, curve: normalizedToneCurve)
        } else {
            lightness = applyTonalControls(lightness)
        }
        let filtered = Self.hslToRGB(hue: hue, saturation: Self.unit(saturation), lightness: Self.unit(lightness))
        let r = mixChannel(originalR, filtered: Int(filtered >> 16 & 0xff))
        let g = mixChannel(originalG, filtered: Int(filtered >> 8 & 0xff))
        let b = mixChannel(originalB, filtered: Int(filtered & 0xff))
        return alpha << 24 | r << 16 | g << 8 | b
    }

    /// Bounded callers may pass a stripe rather than allocating another image.
    /// Like Android, cancellation is observed before work and every 4096 pixels.
    func filterPixels(_ pixels: inout [UInt32], isCancelled: () -> Bool = { false }) throws {
        try pixels.withUnsafeMutableBufferPointer { buffer in
            try filterPixels(buffer, isCancelled: isCancelled)
        }
    }

    func filterPixels(_ pixels: UnsafeMutableBufferPointer<UInt32>, isCancelled: () -> Bool = { false }) throws {
        var nextCancellationCheck = 0
        for index in pixels.indices {
            if index == nextCancellationCheck {
                if isCancelled() { throw CancellationError() }
                nextCancellationCheck += Self.cancellationCheckInterval
            }
            pixels[index] = filterPixel(pixels[index])
        }
        if isCancelled() { throw CancellationError() }
    }

    static func exactLookupOutputColor(originalColor: UInt32, mappedRGB: UInt32,
                                       preserveAlpha: Bool) -> UInt32 {
        let alpha = preserveAlpha ? originalColor >> 24 & 0xff : 0xff
        return alpha == 0 ? originalColor : alpha << 24 | mappedRGB & 0x00ff_ffff
    }

    private func applyTonalControls(_ value: Float) -> Float {
        var lightness = Self.unit(value)
        // Both weights use the original pre-adjustment lightness in Android.
        let shadowWeight: Float = shadowsScale != 0 ? 1 - Self.smoothStep(0.18, 0.72, lightness) : 0
        let highlightWeight: Float = highlightsScale != 0 ? Self.smoothStep(0.28, 0.82, lightness) : 0
        if blacksScale != 0 {
            let inverse = 1 - lightness
            lightness += blacksScale * inverse * inverse * inverse
        }
        if shadowsScale != 0 { lightness += shadowsScale * shadowWeight }
        if highlightsScale != 0 { lightness += highlightsScale * highlightWeight }
        if whitesScale != 0 { lightness += whitesScale * lightness * lightness * lightness }
        return Self.unit((lightness - 0.5) * contrastScale + 0.5)
    }

    static func mapToneCurve(_ value: Float, curve: [Float]) -> Float {
        precondition(curve.count == Np3FilterParameters.toneCurvePointCount)
        let position = unit(value) * Float(Np3FilterParameters.toneCurvePointCount - 1)
        let left = min(max(Int(position), 0), Np3FilterParameters.toneCurvePointCount - 1)
        let right = min(left + 1, Np3FilterParameters.toneCurvePointCount - 1)
        let progress = position - Float(left)
        return unit(curve[left] + (curve[right] - curve[left]) * progress)
    }

    static func neutralProtectionWeight(_ chroma: Float) -> Float {
        smoothStep(neutralProtectionChromaStart, neutralProtectionChromaEnd, chroma)
    }

    static func normalizeHue(_ value: Float) -> Float {
        if value < 0 { return value + 360 }
        if value >= 360 { return value - 360 }
        return value
    }

    static func hslSecondaryComponent(section: Float, sector: Int, chroma: Float) -> Float {
        let fraction = section - Float(sector)
        return chroma * (sector & 1 == 0 ? fraction : 1 - fraction)
    }

    private static func hslToRGB(hue: Float, saturation: Float, lightness: Float) -> UInt32 {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let section = hue / 60
        let sector = Int(section)
        let x = hslSecondaryComponent(section: section, sector: sector, chroma: chroma)
        let r: Float, g: Float, b: Float
        switch sector {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let match = lightness - chroma / 2
        return channel((r + match) * 255) << 16 |
            channel((g + match) * 255) << 8 |
            channel((b + match) * 255)
    }

    private func mixChannel(_ original: Int, filtered: Int) -> UInt32 {
        Self.channel(Float(original) + Float(filtered - original) * strength)
    }

    private static func channel(_ value: Float) -> UInt32 {
        UInt32(min(max(Int(value.rounded(.toNearestOrAwayFromZero)), 0), 255))
    }

    private static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let x = unit((value - edge0) / (edge1 - edge0))
        return x * x * (3 - 2 * x)
    }

    private static func unit(_ value: Float) -> Float { min(max(value, 0), 1) }
}
