import Foundation

/// Android LutColorPipeline: finishing in the sRGB byte domain, after LUT mixing.
enum LUTColorPipeline {
    static func apply(_ color: UInt32, adjustments: LUTAdjustments, preserveAlpha: Bool) -> UInt32 {
        Prepared(adjustments: adjustments).apply(color, preserveAlpha: preserveAlpha)
    }

    /// One immutable preparation per bitmap. Keep Android's operation order
    /// and Float arithmetic, including byte rounding, inside the pixel pass.
    struct Prepared: Sendable {
        private let neutral: Bool
        private let shadowScale: Float
        private let highlightScale: Float
        private let contrast: Float
        private let saturation: Float

        init(adjustments: LUTAdjustments) {
            let adjustments = adjustments.normalized
            neutral = adjustments.isNeutral
            shadowScale = -Float(adjustments.shadows) / 100 * 0.28
            highlightScale = Float(adjustments.highlights) / 100 * 0.28
            contrast = 1 + Float(adjustments.contrast) / 100 * 0.75
            saturation = 1 + Float(adjustments.saturation) / 100
        }

        func apply(_ color: UInt32, preserveAlpha: Bool) -> UInt32 {
            guard !neutral else { return color }
            let alpha = preserveAlpha ? (color >> 24) & 255 : 255
            guard alpha != 0 else { return color }
            var r = Float((color >> 16) & 255) / 255
            var g = Float((color >> 8) & 255) / 255
            var b = Float(color & 255) / 255
            let luma = (r * 0.2126 + g * 0.7152 + b * 0.0722).lutClamped(to: 0...1)
            let shadows = shadowScale * smoothStep(0, 0.68, 1 - luma)
            let highlights = highlightScale * smoothStep(0.32, 1, luma)
            r = (r + shadows + highlights).lutClamped(to: 0...1)
            g = (g + shadows + highlights).lutClamped(to: 0...1)
            b = (b + shadows + highlights).lutClamped(to: 0...1)
            r = ((r - 0.5) * contrast + 0.5).lutClamped(to: 0...1)
            g = ((g - 0.5) * contrast + 0.5).lutClamped(to: 0...1)
            b = ((b - 0.5) * contrast + 0.5).lutClamped(to: 0...1)
            let postLuma = (r * 0.2126 + g * 0.7152 + b * 0.0722).lutClamped(to: 0...1)
            r = (postLuma + (r - postLuma) * saturation).lutClamped(to: 0...1)
            g = (postLuma + (g - postLuma) * saturation).lutClamped(to: 0...1)
            b = (postLuma + (b - postLuma) * saturation).lutClamped(to: 0...1)
            return (alpha << 24) | (UInt32(r * 255 + 0.5) << 16) |
                (UInt32(g * 255 + 0.5) << 8) | UInt32(b * 255 + 0.5)
        }
    }

    private static func smoothStep(_ lower: Float, _ upper: Float, _ value: Float) -> Float {
        let t = ((value - lower) / (upper - lower)).lutClamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}

private extension Float {
    func lutClamped(to range: ClosedRange<Float>) -> Float { min(max(self, range.lowerBound), range.upperBound) }
}
