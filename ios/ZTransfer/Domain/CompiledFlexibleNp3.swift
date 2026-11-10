import Foundation

/// Android Flexible Color coefficients are prepared once per bitmap.
struct CompiledFlexibleNp3: Sendable {
    private let parameters: Np3FilterParameters
    private let normalizedToneCurve: [Float]?
    private let saturationAdjustment: Float
    private let blacksScale: Float
    private let shadowsScale: Float
    private let highlightsScale: Float
    private let whitesScale: Float
    private let contrastScale: Float

    private let grading: CompiledNp3ColorGrading?

    init(parameters: Np3FilterParameters) {
        self.parameters = parameters
        grading = CompiledNp3ColorGrading(grading: parameters.colorGrading)
        normalizedToneCurve = parameters.toneCurve?.map { Float($0) / Float(Np3FilterParameters.toneCurveMaximum) }
        saturationAdjustment = Float(parameters.saturation) / 100
        blacksScale = Float(parameters.blacks) / 100 * 0.12
        shadowsScale = Float(parameters.shadows) / 100 * 0.18
        highlightsScale = Float(parameters.highlights) / 100 * 0.18
        whitesScale = Float(parameters.whites) / 100 * 0.12
        // Kotlin Float.pow computes through java.lang.Math.pow then casts back.
        contrastScale = Float(pow(2.0, Double(Float(parameters.contrast) / 100)))
    }

    func filter(hue originalHue: Float, saturation: Float, lightness: Float, colorWeight: Float) -> UInt32 {
        var saturation = saturation, lightness = lightness
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
        let progress = Np3FilterEngine.unit((originalHue - start) / (end - start))
        let inverse = 1 - progress
        let left = parameters.colorBands[leftIndex]
        let right = parameters.colorBands[rightIndex]
        let hueShift = (Float(left.hue) * inverse + Float(right.hue) * progress) / 100 * 30
        let chroma = Float(left.chroma) * inverse + Float(right.chroma) * progress
        let brightness = Float(left.brightness) * inverse + Float(right.brightness) * progress
        let hue = Np3FilterEngine.normalizeHue(originalHue + hueShift * colorWeight)
        saturation *= 1 + chroma / 100 * colorWeight
        if saturationAdjustment != 0 {
            saturation *= 1 + (saturationAdjustment > 0 ? saturationAdjustment * colorWeight : saturationAdjustment)
        }
        lightness += brightness / 100 * 0.20 * colorWeight
        if let normalizedToneCurve {
            lightness = Np3FilterEngine.mapToneCurve(lightness, curve: normalizedToneCurve)
        } else {
            lightness = applyTonalControls(lightness)
        }
        let filtered = Np3FilterEngine.hslToRGB(hue: hue, saturation: Np3FilterEngine.unit(saturation), lightness: Np3FilterEngine.unit(lightness))
        return grading?.apply(filtered) ?? filtered
    }

    private func applyTonalControls(_ value: Float) -> Float {
        var lightness = Np3FilterEngine.unit(value)
        // Both weights use the original pre-adjustment lightness in Android.
        let shadowWeight: Float = shadowsScale != 0 ? 1 - Np3FilterEngine.smoothStep(0.18, 0.72, lightness) : 0
        let highlightWeight: Float = highlightsScale != 0 ? Np3FilterEngine.smoothStep(0.28, 0.82, lightness) : 0
        if blacksScale != 0 {
            let inverse = 1 - lightness
            lightness += blacksScale * inverse * inverse * inverse
        }
        if shadowsScale != 0 { lightness += shadowsScale * shadowWeight }
        if highlightsScale != 0 { lightness += highlightsScale * highlightWeight }
        if whitesScale != 0 { lightness += whitesScale * lightness * lightness * lightness }
        return Np3FilterEngine.unit((lightness - 0.5) * contrastScale + 0.5)
    }

}
