import Foundation

/// Android CompiledNp3ColorGrading: four 1025-float tables per active recipe.
/// No allocation/trigonometry in the preview/export pixel loop; neutral recipes
/// allocate no tables. Apply to quantized RGB before filter-strength blending.
struct CompiledNp3ColorGrading: Sendable {
    private static let tableSize = 1024
    private typealias Math = Np3FilterEngine
    private let red, green, blue, brightness: [Float]

    init?(grading: Np3ColorGrading) {
        guard !grading.isNeutral else { return nil }
        var red = [Float](repeating: 0, count: Self.tableSize + 1)
        var green = red, blue = red, brightness = red
        let shadow = Self.tint(grading.shadows), mid = Self.tint(grading.midtones), high = Self.tint(grading.highlights)
        let radius: Float = 0.5 + Float(grading.blending) / 200
        let balance = Float(grading.balance) / 400
        for index in 0...Self.tableSize {
            let luminance = Float(index) / Float(Self.tableSize)
            let tone = Math.unit(luminance + balance)
            let sw = Self.mask(tone, radius), mw = Self.mask(abs(tone - 0.5), radius), hw = Self.mask(1 - tone, radius)
            let total = sw + mw + hw
            let s = sw / total, m = mw / total, h = hw / total
            let lift = (Float(grading.shadows.brightness) * s + Float(grading.midtones.brightness) * m +
                        Float(grading.highlights.brightness) * h) / 100 * 0.25
            let target = Math.unit(luminance + lift * 4 * luminance * (1 - luminance))
            brightness[index] = target > luminance ? (target - luminance) / (1 - luminance)
                : target < luminance ? (target - luminance) / luminance : 0
            let envelope = 4 * target * (1 - target)
            red[index] = (shadow.0 * s + mid.0 * m + high.0 * h) * envelope
            green[index] = (shadow.1 * s + mid.1 * m + high.1 * h) * envelope
            blue[index] = (shadow.2 * s + mid.2 * m + high.2 * h) * envelope
        }
        self.red = red; self.green = green; self.blue = blue; self.brightness = brightness
    }

    func apply(_ rgb: UInt32) -> UInt32 {
        var r = Float(rgb >> 16 & 255) / 255, g = Float(rgb >> 8 & 255) / 255, b = Float(rgb & 255) / 255
        let position = min(max((r * 0.2126 + g * 0.7152 + b * 0.0722) * Float(Self.tableSize), 0), Float(Self.tableSize))
        let left = Int(position), right = min(left + 1, Self.tableSize), fraction = position - Float(left)
        let lift = Self.sample(brightness, left, right, fraction)
        if lift >= 0 {
            r += (1 - r) * lift; g += (1 - g) * lift; b += (1 - b) * lift
        } else {
            r *= 1 + lift; g *= 1 + lift; b *= 1 + lift
        }
        let dr = Self.sample(red, left, right, fraction), dg = Self.sample(green, left, right, fraction)
        let db = Self.sample(blue, left, right, fraction)
        // Fit the complete tint vector, retaining its hue and zero luminance.
        let amount = min(1, min(Self.gamutLimit(r, dr), min(Self.gamutLimit(g, dg), Self.gamutLimit(b, db))))
        return Self.channel(r + dr * amount) << 16 | Self.channel(g + dg * amount) << 8 | Self.channel(b + db * amount)
    }

    private static func mask(_ distance: Float, _ radius: Float) -> Float {
        let t = Math.unit(distance / radius)
        return 1 - t * t * (3 - 2 * t)
    }

    private static func tint(_ region: Np3ColorGradingRegion) -> (Float, Float, Float) {
        let hue = Float(region.hue % 360) / 60
        let secondary = 1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)
        let r: Float, g: Float, b: Float
        switch Int(hue) {
        case 0: (r, g, b) = (1, secondary, 0)
        case 1: (r, g, b) = (secondary, 1, 0)
        case 2: (r, g, b) = (0, 1, secondary)
        case 3: (r, g, b) = (0, secondary, 1)
        case 4: (r, g, b) = (secondary, 0, 1)
        default: (r, g, b) = (1, 0, secondary)
        }
        let luma = r * 0.2126 + g * 0.7152 + b * 0.0722
        let amount = Float(region.chroma) / 100 * 0.4
        return ((r - luma) * amount, (g - luma) * amount, (b - luma) * amount)
    }

    private static func sample(_ values: [Float], _ left: Int, _ right: Int, _ t: Float) -> Float {
        values[left] + (values[right] - values[left]) * t
    }
    private static func gamutLimit(_ value: Float, _ offset: Float) -> Float {
        offset > 0 ? (1 - value) / offset : offset < 0 ? -value / offset : 1
    }
    private static func channel(_ value: Float) -> UInt32 { UInt32(min(max((value * 255).rounded(), 0), 255)) }
}
