import Foundation

/// Android TipLightbulbButton.kt: 900 ms FastOutSlowIn, repeated in reverse.
/// Reverse traverses the same eased timeline backwards, rather than easing
/// a new 1 → 0 interpolation. All three values share this clock.
struct TipAttentionValues: Equatable {
    let buttonScale: Double
    let dotScale: Double
    let dotOpacity: Double

    static let read = Self(buttonScale: 1, dotScale: 1, dotOpacity: 0)

    init(elapsed: TimeInterval) {
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        let phase = time.truncatingRemainder(dividingBy: 1.8) / 0.9
        let progress = Self.fastOutSlowIn(phase <= 1 ? phase : 2 - phase)
        buttonScale = 1 + 0.09 * progress
        dotScale = 0.72 + 0.40 * progress
        dotOpacity = 0.58 + 0.42 * progress
    }

    private init(buttonScale: Double, dotScale: Double, dotOpacity: Double) {
        self.buttonScale = buttonScale
        self.dotScale = dotScale
        self.dotOpacity = dotOpacity
    }

    private static func fastOutSlowIn(_ time: Double) -> Double {
        guard time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        // Compose FastOutSlowInEasing = cubic-bezier(0.4, 0, 0.2, 1).
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<24 {
            let t = (lower + upper) / 2
            let u = 1 - t
            let x = 3 * u * u * t * 0.4 + 3 * u * t * t * 0.2 + t * t * t
            if x < time { lower = t } else { upper = t }
        }
        let t = (lower + upper) / 2
        return t * t * (3 - 2 * t)
    }
}
