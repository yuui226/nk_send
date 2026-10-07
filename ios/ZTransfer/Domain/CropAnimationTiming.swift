import Foundation

enum CropAnimationTiming {
    static let layoutSeconds: Double = 0.220
    static let toolsFadeSeconds: Double = 0.180
    static let queueRiseFastSeconds: Double = 0.105
    static let queueRiseNormalSeconds: Double = 0.155
    static let ghostFadeInSeconds: Double = 0.120
    static let ghostFadeOutSeconds: Double = 0.060
    static func queueRise(for upwardDrag: Bool) -> Double { upwardDrag ? queueRiseFastSeconds : queueRiseNormalSeconds }
    static func ghostAlpha(progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        let fadeIn = min(p / 0.12, 1)
        let fadeOut = p > 0.94 ? (1 - p) / 0.06 : 1
        return fadeIn * fadeOut
    }
}
