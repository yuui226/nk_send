import CoreGraphics
import Foundation

/// Android `GeniePopupGeometry.kt`, expressed in iOS points. The same progress
/// drives the inlet width, the bowed body and the distance from the Z button.
enum GeniePopupMotion {
    static let expandDuration: TimeInterval = 0.32
    static let collapseDuration: TimeInterval = 0.35
    static let renderBands = 12
    static let zMarkWidth: CGFloat = 27.2

    struct Row {
        let left: CGFloat
        let right: CGFloat
        let y: CGFloat
        let tilt: CGFloat
        var leftY: CGFloat { y + tilt / 2 }
        var rightY: CGFloat { y - tilt / 2 }
    }

    static func progress(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    static func length(_ value: CGFloat) -> CGFloat {
        let p = progress(value)
        return p * (2 - p)
    }

    static func smoothStep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    static func panelAlpha(_ value: CGFloat) -> CGFloat {
        smoothStep((length(value) - 0.002) / 0.028)
    }

    static func validAnchor(_ anchor: CGRect, panel: CGRect) -> Bool {
        let values = [anchor.minX, anchor.minY, anchor.maxX, anchor.maxY,
                      panel.minX, panel.minY, panel.maxX, panel.maxY]
        return values.allSatisfy(\.isFinite) && anchor.width > 0 && anchor.height > 0 &&
            panel.width > 0 && panel.height > 0 && anchor.maxY <= panel.minY
    }

    static func row(progress rawProgress: CGFloat, fraction rawFraction: CGFloat,
                    anchor: CGRect, panel: CGRect, mouthWidth: CGFloat = zMarkWidth) -> Row {
        let p = progress(rawProgress)
        let v = progress(rawFraction)
        if p == 1 { return Row(left: 0, right: panel.width, y: panel.height * v, tilt: 0) }

        if anchor.midX > panel.midX {
            let mirrored = CGRect(
                x: panel.minX + panel.maxX - anchor.maxX,
                y: anchor.minY, width: anchor.width, height: anchor.height
            )
            let reflected = row(progress: p, fraction: v, anchor: mirrored,
                                panel: panel, mouthWidth: mouthWidth)
            return Row(left: panel.width - reflected.right,
                       right: panel.width - reflected.left,
                       y: reflected.y, tilt: -reflected.tilt)
        }

        let dockX = anchor.midX - panel.minX
        let dockY = anchor.maxY - panel.minY
        let travel = length(p)
        let spread = pow(p, 0.85 + 2.1 * pow(1 - v, 2))
        let seedWidth = min(min(anchor.width, panel.width),
                            mouthWidth.isFinite && mouthWidth > 0 ? mouthWidth : anchor.width * 0.5)
        let width = mix(seedWidth, panel.width, spread)
        let envelope = 16 * p * p * pow(1 - p, 2)
        let drift = seedWidth * 0.22 * envelope * (1 - spread) * (0.35 + 0.65 * v)
        let center = mix(dockX, panel.width / 2, spread) + drift
        let bowPhase = max(0, sin(.pi * v))
        let bow = min(min(min(panel.width * 0.075, anchor.width * 0.5), width * 0.2) *
                          envelope * bowPhase * bowPhase,
                      (width - seedWidth) * 0.3)
        let left = center - width / 2 + bow
        let right = center + width / 2 - bow * 0.15
        let bentV = v + 0.4 * (1 - p) * (v * v - v)
        let mouthTilt = min(seedWidth * 0.14, panel.width * 0.045) * (1 - travel)
        let y = dockY * (1 - travel) + panel.height * travel * bentV + mouthTilt / 2
        let bodyTilt = min(min((right - left) * 0.07, panel.width * 0.035),
                           panel.height * travel * 0.12) * envelope * v * v
        let tilt = min(min(mouthTilt + bodyTilt, (right - left) * 0.14),
                       panel.width * 0.045)
        return Row(left: left, right: right, y: y, tilt: tilt)
    }

    /// Solve the same cubic Bézier as Compose's CubicBezierEasing. Core
    /// Animation's timing curve cannot be applied to the custom GPU mesh.
    static func ease(_ time: CGFloat, expanding: Bool) -> CGFloat {
        let t = progress(time)
        let x1: CGFloat = expanding ? 0.16 : 0.30
        let y1: CGFloat = expanding ? 0.40 : 0.18
        let x2: CGFloat = expanding ? 0.22 : 0.60
        let y2: CGFloat = 1
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<16 {
            let mid = (lower + upper) / 2
            let x = cubic(mid, first: x1, second: x2)
            if x < t { lower = mid } else { upper = mid }
        }
        return cubic((lower + upper) / 2, first: y1, second: y2)
    }

    private static func cubic(_ t: CGFloat, first: CGFloat, second: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first +
            3 * inverse * t * t * second + t * t * t
    }

    private static func mix(_ start: CGFloat, _ end: CGFloat, _ amount: CGFloat) -> CGFloat {
        start + (end - start) * amount
    }
}
