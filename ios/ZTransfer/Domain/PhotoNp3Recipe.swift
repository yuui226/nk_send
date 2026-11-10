import Foundation

/// Android Np3ColorGrading: neutral chroma/brightness makes hue and mask
/// controls inactive. Parsing canonicalizes those inactive values.
struct Np3ColorGradingRegion: Codable, Equatable, Sendable {
    var hue = 0
    var chroma = 0
    var brightness = 0
    var isNeutral: Bool { chroma == 0 && brightness == 0 }
    var isValid: Bool { (0...360).contains(hue) && (-100...100).contains(chroma) && (-100...100).contains(brightness) }
}

struct Np3ColorGrading: Codable, Equatable, Sendable {
    var highlights = Np3ColorGradingRegion()
    var midtones = Np3ColorGradingRegion()
    var shadows = Np3ColorGradingRegion()
    var blending = 50
    var balance = 0
    var isNeutral: Bool { highlights.isNeutral && midtones.isNeutral && shadows.isNeutral }
    var isValid: Bool {
        highlights.isValid && midtones.isValid && shadows.isValid &&
            (0...100).contains(blending) && (-100...100).contains(balance)
    }
}

/// NP3 tag 0300 IDs, not camera-selectable Picture Control indices.
enum ClassicNp3Style: Int, CaseIterable, Sendable {
    case standard = 0x0001, neutral = 0x03c2, vivid = 0x00c3, portrait = 0x0486
    case landscape = 0x04c7, flat = 0x028e, auto = 0x02cf, monochrome = 0x064d
    case flatMonochrome = 0x0654, deepToneMonochrome = 0x0655, richTonePortrait = 0x0493
    case dream = 0x0801, morning = 0x0802, pop = 0x0803, sunday = 0x0804
    case somber = 0x0805, dramatic = 0x0806, silence = 0x0807, bleached = 0x0808
    case melancholic = 0x0809, pure = 0x080a, denim = 0x080b, toy = 0x080c
    case sepia = 0x080d, blue = 0x080e, red = 0x080f, pink = 0x0810
    case charcoal = 0x0811, graphite = 0x0812, binary = 0x0813, carbon = 0x0814

    var isCreative: Bool { (0x0801...0x0814).contains(rawValue) }
    var isMonochrome: Bool {
        self == .monochrome || self == .flatMonochrome || self == .deepToneMonochrome ||
            (0x080d...0x0814).contains(rawValue)
    }
}

/// ClassicPhotoNp3Parser retains quarter steps, the Auto sentinel, and the
/// recorded curve. Detail adjustments belong to camera development, not this
/// recipe for already developed sRGB pixels.
struct ClassicNp3FilterParameters: Equatable, Sendable {
    static let automatic = -128
    let base: ClassicNp3Style
    let contrastQuarter: Int
    let brightnessQuarter: Int
    let saturationQuarter: Int
    let hueQuarter: Int
    let filterEffect: Int
    let toningEffect: Int
    let toningDensityQuarter: Int
    let effectLevel: Int
    let toneCurve: [UInt16]?

    init(base: ClassicNp3Style, contrastQuarter: Int, brightnessQuarter: Int,
         saturationQuarter: Int, hueQuarter: Int, filterEffect: Int,
         toningEffect: Int, toningDensityQuarter: Int, effectLevel: Int, toneCurve: [UInt16]?) throws {
        self.base = base; self.contrastQuarter = contrastQuarter; self.brightnessQuarter = brightnessQuarter
        self.saturationQuarter = saturationQuarter; self.hueQuarter = hueQuarter
        self.filterEffect = filterEffect; self.toningEffect = toningEffect
        self.toningDensityQuarter = toningDensityQuarter; self.effectLevel = effectLevel; self.toneCurve = toneCurve
        try requireNp3(isValid, "Invalid classic NP3 parameters")
    }

    var isValid: Bool {
        (contrastQuarter == Self.automatic || (-12...12).contains(contrastQuarter)) &&
        (-6...6).contains(brightnessQuarter) &&
        (saturationQuarter == Self.automatic || (-12...12).contains(saturationQuarter)) &&
        (-12...12).contains(hueQuarter) && (0...4).contains(filterEffect) &&
        (0...9).contains(toningEffect) && (0...28).contains(toningDensityQuarter) &&
        (0...100).contains(effectLevel) && Np3FilterParameters.validToneCurve(toneCurve)
    }
}

enum PhotoNp3Parameters: Equatable, Sendable {
    case flexible(Np3FilterParameters)
    case classic(ClassicNp3FilterParameters)
}

/// Immutable render data is separate from the UI's persisted preset descriptor.
/// Both imported documents and private snapshots use this same recipe shape.
struct PhotoNp3Recipe: Equatable, Sendable {
    let preset: PhotoFilterPreset
    let parameters: PhotoNp3Parameters
}
