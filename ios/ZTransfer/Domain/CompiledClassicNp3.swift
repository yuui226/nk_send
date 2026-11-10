import Foundation

/// Android PhotoFilterRenderer.compileClassic. NP3 does not contain Nikon's RAW
/// look tables: keep Android's explicit developed-sRGB mappings, including the
/// quarter steps and recorded curve, separate from Flexible Color conversion.
struct CompiledClassicNp3: Sendable {
    private typealias Math = Np3FilterEngine
    private let hueShift, saturationAdjustment, contrast, brightness, blackLift: Float
    private let monochrome, redWeight, greenWeight, blueWeight: Float
    private let toningHue, toningSaturation, binaryAmount: Float
    private let curve: [Float]?

    private struct Look {
        var contrast: Float = 1, saturation: Float = 1, brightness: Float = 0
        var hue: Float = 0, blackLift: Float = 0
        var toningHue: Float? = nil
        var binaryAmount: Float = 0
    }

    init(parameters p: ClassicNp3FilterParameters) {
        let look: Look
        switch p.base {
        case .standard, .auto: look = .init()
        case .neutral: look = .init(contrast: 0.95, saturation: 0.94)
        case .vivid: look = .init(contrast: 1.08, saturation: 1.12)
        case .portrait: look = .init(saturation: 0.96, brightness: 0.012, hue: 1)
        case .landscape: look = .init(contrast: 1.05, saturation: 1.10, hue: -1.5)
        case .flat: look = .init(contrast: 0.86, saturation: 0.92, blackLift: 0.012)
        case .monochrome: look = .init()
        case .flatMonochrome: look = .init(contrast: 0.85)
        case .deepToneMonochrome: look = .init(contrast: 1.18)
        case .richTonePortrait: look = .init(contrast: 1.04, saturation: 1.04, brightness: 0.005)
        case .dream: look = .init(contrast: 0.88, saturation: 0.82, brightness: 0.035, blackLift: 0.025)
        case .morning: look = .init(contrast: 0.94, saturation: 0.90, brightness: 0.025, hue: 4)
        case .pop: look = .init(contrast: 1.12, saturation: 1.20)
        case .sunday: look = .init(contrast: 0.98, saturation: 1.07, brightness: 0.020, hue: 2)
        case .somber: look = .init(contrast: 1.08, saturation: 0.78, brightness: -0.040, hue: -2)
        case .dramatic: look = .init(contrast: 1.25, saturation: 0.82, brightness: -0.010)
        case .silence: look = .init(contrast: 0.93, saturation: 0.72, hue: -3, blackLift: 0.020)
        case .bleached: look = .init(contrast: 0.83, saturation: 0.60, brightness: 0.035, blackLift: 0.040)
        case .melancholic: look = .init(contrast: 0.96, saturation: 0.78, brightness: -0.015, hue: -7)
        case .pure: look = .init(contrast: 0.92, saturation: 0.94, brightness: 0.040)
        case .denim: look = .init(contrast: 1.04, saturation: 0.80, brightness: -0.010, hue: -10, blackLift: 0.015)
        case .toy: look = .init(contrast: 1.18, saturation: 1.18, brightness: -0.020, hue: 3)
        case .sepia: look = .init(contrast: 1.02, toningHue: 35)
        case .blue: look = .init(contrast: 1.04, toningHue: 220)
        case .red: look = .init(contrast: 1.05, toningHue: 0)
        case .pink: look = .init(contrast: 0.94, brightness: 0.025, toningHue: 330)
        case .charcoal: look = .init(contrast: 1.30)
        case .graphite: look = .init(contrast: 1.15, blackLift: 0.025)
        case .binary: look = .init(binaryAmount: 0.85)
        case .carbon: look = .init(contrast: 1.40, blackLift: -0.020)
        }
        let baseStrength: Float = p.base.isCreative ? Float(p.effectLevel) / 100 : 1
        let manualContrast: Float = p.contrastQuarter == ClassicNp3FilterParameters.automatic ? 0 : Float(p.contrastQuarter) / 12
        let manualSaturation: Float = p.saturationQuarter == ClassicNp3FilterParameters.automatic ? 0 : Float(p.saturationQuarter) / 12
        let weights: (Float, Float, Float)
        switch p.filterEffect {
        case 1: weights = (0.30, 0.65, 0.05)
        case 2: weights = (0.45, 0.52, 0.03)
        case 3: weights = (0.70, 0.28, 0.02)
        case 4: weights = (0.15, 0.80, 0.05)
        default: weights = (0.2126, 0.7152, 0.0722)
        }
        let tone: Float?
        switch p.toningEffect {
        case 1: tone = 35
        case 2: tone = 205
        case 3: tone = 0
        case 4: tone = 55
        case 5: tone = 120
        case 6: tone = 170
        case 7: tone = 230
        case 8: tone = 275
        case 9: tone = 325
        default: tone = look.toningHue
        }
        hueShift = look.hue * baseStrength + Float(p.hueQuarter) / 12 * 30
        saturationAdjustment = (1 + (look.saturation - 1) * baseStrength) * (1 + manualSaturation) - 1
        contrast = (1 + (look.contrast - 1) * baseStrength) *
            (p.toneCurve == nil ? Float(pow(2.0, Double(manualContrast))) : 1)
        brightness = look.brightness * baseStrength + (p.toneCurve == nil ? Float(p.brightnessQuarter) / 6 * 0.12 : 0)
        blackLift = look.blackLift * baseStrength
        monochrome = p.base.isMonochrome ? baseStrength : 0
        (redWeight, greenWeight, blueWeight) = weights
        toningHue = tone ?? 0
        toningSaturation = tone == nil ? 0 : Float(p.toningDensityQuarter) / 28 * 0.42
        binaryAmount = look.binaryAmount * baseStrength
        curve = p.toneCurve?.map { Float($0) / Float(Np3FilterParameters.toneCurveMaximum) }
    }

    func filter(red: Float, green: Float, blue: Float, hue originalHue: Float,
                saturation: Float, lightness: Float, colorWeight: Float) -> UInt32 {
        var hue = Math.normalizeHue(originalHue + hueShift * colorWeight)
        var saturation = saturation * (1 + (saturationAdjustment > 0 ? saturationAdjustment * colorWeight : saturationAdjustment))
        var lightness = lightness
        if monochrome > 0 {
            let gray = red * redWeight + green * greenWeight + blue * blueWeight
            lightness += (gray - lightness) * monochrome
            saturation += (toningSaturation - saturation) * monochrome
            if toningSaturation > 0 {
                var distance = toningHue - hue
                if distance > 180 { distance -= 360 }
                if distance < -180 { distance += 360 }
                hue = Math.normalizeHue(hue + distance * monochrome)
            }
        }
        lightness = Math.unit((lightness - 0.5) * contrast + 0.5)
        lightness += brightness * 4 * lightness * (1 - lightness)
        lightness = Math.unit(blackLift + lightness * (1 - blackLift))
        if binaryAmount > 0 {
            lightness += (Math.smoothStep(0.42, 0.58, lightness) - lightness) * binaryAmount
        }
        if let curve { lightness = Math.mapToneCurve(lightness, curve: curve) }
        return Math.hslToRGB(hue: hue, saturation: Math.unit(saturation), lightness: Math.unit(lightness))
    }
}
