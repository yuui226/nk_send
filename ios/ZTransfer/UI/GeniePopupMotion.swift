import SwiftUI
import QuartzCore

/// Shared timing, attachment and cross-section geometry for all three popups.
/// The equations mirror Android's GeniePopupGeometry.kt. The live renderer
/// samples 12 bands while tests may sample the 48-section geometry grid.
enum GeniePopupMotion {
    static let renderBandCount = 12
    static let geometryBandCount = 48
    static let zMarkWidth: CGFloat = 20 * (0.62 + 0.30 + 0.44)

    private static let expandDuration = 0.32
    private static let collapseDuration = 0.35

    static func progress(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    static func duration(expanding: Bool) -> TimeInterval {
        expanding ? expandDuration : collapseDuration
    }

    /// Invert the x component of Android's CubicBezierEasing and evaluate y.
    static func timing(_ fraction: Double, expanding: Bool) -> CGFloat {
        let x = min(1, max(0, fraction))
        let controls = expanding
            ? (x1: 0.16, y1: 0.40, x2: 0.22, y2: 1.0)
            : (x1: 0.30, y1: 0.18, x2: 0.60, y2: 1.0)
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let t = (low + high) / 2
            if cubic(t, controls.x1, controls.x2) < x { low = t } else { high = t }
        }
        return CGFloat(cubic((low + high) / 2, controls.y1, controls.y2))
    }

    struct Row: Equatable {
        let left: CGFloat
        let right: CGFloat
        let y: CGFloat
        /// Positive tilt lifts the right endpoint, matching Android.
        let tilt: CGFloat

        init(left: CGFloat, right: CGFloat, y: CGFloat, tilt: CGFloat = 0) {
            self.left = left
            self.right = right
            self.y = y
            self.tilt = tilt
        }

        var leftY: CGFloat { y + tilt / 2 }
        var rightY: CGFloat { y - tilt / 2 }

        func padded(by fraction: CGFloat) -> Row {
            let padding = (right - left) * fraction
            return Row(left: left - padding, right: right + padding, y: y, tilt: tilt)
        }
    }

    /// Android's cross-section state. Fractions may be outside 0...1 because
    /// the captured image includes a small source padding around the panel.
    struct CrossSection: Equatable {
        let fraction: CGFloat
        let spreadExponent: CGFloat
        let bend: CGFloat

        init(fraction: CGFloat) {
            self.fraction = fraction
            let v = min(1, max(0, fraction))
            spreadExponent = 0.85 + 2.1 * (1 - v) * (1 - v)
            bend = v * v - v
        }
    }

    /// Quantities shared by every cross-section of one animation frame.
    struct FrameGeometry {
        private let progress: CGFloat
        private let anchor: CGRect
        private let panel: CGRect
        private let mouthWidth: CGFloat

        init(progress: CGFloat, source: CGRect, size: CGSize,
             mouthWidth: CGFloat = GeniePopupMotion.zMarkWidth) {
            self.progress = GeniePopupMotion.progress(progress)
            self.anchor = source
            self.panel = CGRect(origin: .zero, size: size)
            self.mouthWidth = mouthWidth
        }

        init(progress: CGFloat, anchor: CGRect, panel: CGRect,
             mouthWidth: CGFloat = GeniePopupMotion.zMarkWidth) {
            self.progress = GeniePopupMotion.progress(progress)
            self.anchor = anchor
            self.panel = panel
            self.mouthWidth = mouthWidth
        }

        func row(at section: CrossSection) -> Row {
            GeniePopupMotion.row(progress: progress, fraction: section.fraction,
                                 anchor: anchor, panel: panel, mouthWidth: mouthWidth)
        }
    }

    /// Convenience form used by the geometry tests and UIKit panel.
    static func row(progress: CGFloat, fraction: CGFloat, source: CGRect, size: CGSize,
                    mouthWidth: CGFloat = GeniePopupMotion.zMarkWidth) -> Row {
        row(progress: progress, fraction: fraction, anchor: source,
            panel: CGRect(origin: .zero, size: size), mouthWidth: mouthWidth)
    }

    /// Port of Android `genieRow`; panel coordinates are local to the popup.
    static func row(progress: CGFloat, fraction: CGFloat, anchor: CGRect, panel: CGRect,
                    mouthWidth: CGFloat = GeniePopupMotion.zMarkWidth) -> Row {
        let p = Self.progress(progress)
        let v = Self.progress(fraction)
        if p == 1 {
            return Row(left: panel.minX, right: panel.maxX,
                       y: panel.minY + panel.height * v)
        }

        // Mirror right-hand triggers before evaluating the funnel, then mirror
        // the resulting row (including its tilt) back to the original side.
        if anchor.midX > panel.midX {
            let mirrored = CGRect(
                x: panel.minX + panel.maxX - anchor.maxX,
                y: anchor.minY,
                width: anchor.width,
                height: anchor.height
            )
            let row = Self.row(progress: p, fraction: v, anchor: mirrored,
                               panel: panel, mouthWidth: mouthWidth)
            return Row(left: panel.minX + panel.maxX - row.right,
                       right: panel.minX + panel.maxX - row.left,
                       y: row.y, tilt: -row.tilt)
        }

        let dockX = anchor.midX - panel.minX
        let dockY = anchor.maxY - panel.minY
        let length = p * (2 - p)
        let spread = pow(p, 0.85 + 2.1 * (1 - v) * (1 - v))
        let seedWidth = min(anchor.width, panel.width,
                            (mouthWidth.isFinite && mouthWidth > 0)
                                ? mouthWidth : anchor.width * 0.5)
        let width = seedWidth + (panel.width - seedWidth) * spread

        let envelope = 16 * p * p * (1 - p) * (1 - p)
        let drift = seedWidth * 0.22 * envelope * (1 - spread) * (0.35 + 0.65 * v)
        let center = dockX + (panel.width / 2 - dockX) * spread + drift
        let bowPhase = max(0, sin(.pi * v))
        let bow = min(
            min(panel.width * 0.075, min(anchor.width * 0.5, width * 0.2))
                * envelope * bowPhase * bowPhase,
            (width - seedWidth) * 0.3
        )
        let left = center - width / 2 + bow
        let right = center + width / 2 - bow * 0.15
        let bentV = v + 0.4 * (1 - p) * (v * v - v)
        let mouthTilt = min(seedWidth * 0.14, panel.width * 0.045) * (1 - length)
        let bodyTilt = min(
            min((right - left) * 0.07, panel.width * 0.035),
            panel.height * length * 0.12
        ) * envelope * v * v
        let tilt = min(
            min(mouthTilt + bodyTilt, (right - left) * 0.14),
            panel.width * 0.045
        )
        let y = dockY * (1 - length) + panel.height * length * bentV + mouthTilt / 2
        return Row(left: panel.minX + left, right: panel.minX + right,
                   y: panel.minY + y, tilt: tilt)
    }

    /// Above-anchor reflection from Android `genieRowAbove`.
    static func rowAbove(progress: CGFloat, fraction: CGFloat, anchor: CGRect,
                         panel: CGRect, mouthWidth: CGFloat = GeniePopupMotion.zMarkWidth) -> Row {
        func mirrored(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
        }
        let row = Self.row(progress: progress, fraction: 1 - fraction,
                           anchor: mirrored(anchor), panel: mirrored(panel),
                           mouthWidth: mouthWidth)
        return Row(left: row.left, right: row.right,
                   y: panel.maxY - row.y, tilt: -row.tilt)
    }

    static func opacity(_ progress: CGFloat) -> CGFloat {
        let p = Self.progress(progress)
        let t = min(1, max(0, (p * (2 - p) - 0.002) / 0.028))
        return t * t * (3 - 2 * t)
    }

    /// Android's affine matrix for one of the two triangles making up a band.
    /// The source texture passed to Core Animation is cropped to this band,
    /// so its local y range is 0...size.height.
    static func bandTransform(size: CGSize, top: Row, bottom: Row,
                              upper: Bool = true) -> CATransform3D {
        let sourceWidth = max(0.0001, size.width)
        let sourceHeight = max(0.0001, size.height)
        let xAcross: CGFloat
        let yAcross: CGFloat
        let xDown: CGFloat
        let yDown: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        if upper {
            xAcross = (top.right - top.left) / sourceWidth
            yAcross = (top.rightY - top.leftY) / sourceWidth
            xDown = (bottom.left - top.left) / sourceHeight
            yDown = (bottom.leftY - top.leftY) / sourceHeight
            originX = top.left
            originY = top.leftY
        } else {
            xAcross = (bottom.right - bottom.left) / sourceWidth
            yAcross = (bottom.rightY - bottom.leftY) / sourceWidth
            xDown = (bottom.right - top.right) / sourceHeight
            yDown = (bottom.rightY - top.rightY) / sourceHeight
            originX = bottom.left - xDown * sourceHeight
            originY = bottom.leftY - yDown * sourceHeight
        }
        var transform = CATransform3DIdentity
        transform.m11 = xAcross
        transform.m12 = yAcross
        transform.m21 = xDown
        transform.m22 = yDown
        transform.m41 = originX
        transform.m42 = originY
        return transform
    }

    /// Compatibility entry point for callers that only need the upper triangle.
    static func bandTransform(size: CGSize, top: Row, bottom: Row) -> CATransform3D {
        bandTransform(size: size, top: top, bottom: bottom, upper: true)
    }

    /// The Genie mouth is the straight part of the button's lower edge.
    static func attachmentAnchor(for button: CGRect, cornerRadius: CGFloat) -> CGRect {
        guard button.width > 0, button.height > 0 else { return .zero }
        let radius = min(max(0, cornerRadius), button.width / 2, button.height / 2)
        let width = max(1, button.width - radius)
        return CGRect(x: button.midX - width / 2, y: button.maxY - 1,
                      width: width, height: 1)
    }
}
