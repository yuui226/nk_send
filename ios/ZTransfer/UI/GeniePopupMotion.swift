import SwiftUI
import QuartzCore

/// Small shared contract for the three popup entrances. Geometry lives in the
/// SwiftUI transition itself; this type contains only timing and anchor math.
enum GeniePopupMotion {
    private static let expandDuration = 0.36
    private static let collapseDuration = 0.28

    static func progress(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    static func duration(expanding: Bool) -> TimeInterval {
        expanding ? expandDuration : collapseDuration
    }

    static func timing(_ fraction: Double, expanding: Bool) -> CGFloat {
        let x = min(1, max(0, fraction))
        let controls = expanding ? (0.28, 0.15, 0.22, 1.0) : (0.35, 0.10, 0.65, 1.0)
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<20 {
            let t = (low + high) / 2
            if cubic(t, controls.0, controls.2) < x { low = t } else { high = t }
        }
        return CGFloat(cubic((low + high) / 2, controls.1, controls.3))
    }

    struct Row {
        let left: CGFloat
        let right: CGFloat
        let y: CGFloat

        func padded(by fraction: CGFloat) -> Row {
            let padding = (right - left) * fraction
            return Row(left: left - padding, right: right + padding, y: y)
        }
    }

    /// Android GeniePopupGeometry: the mouth narrows before the far edge is
    /// pulled in. Each cross-section has its own width AND horizontal travel,
    /// so the whole surface bends instead of scaling behind a curved mask.
    static func row(progress: CGFloat, fraction: CGFloat, source: CGRect, size: CGSize) -> Row {
        let p = Self.progress(progress)
        let v = min(1, max(0, fraction))
        let length = p * (2 - p)
        let spread = pow(p, 0.85 + 2.1 * (1 - v) * (1 - v))
        let width = source.width + (size.width - source.width) * spread
        let center = source.midX + (size.width / 2 - source.midX) * spread
        let bent = fraction + 0.4 * (1 - p) * (v * v - v)
        return Row(left: center - width / 2, right: center + width / 2,
                   y: source.maxY * (1 - length) + size.height * length * bent)
    }

    static func opacity(_ progress: CGFloat) -> CGFloat {
        let p = Self.progress(progress)
        let t = min(1, max(0, (p * (2 - p) - 0.002) / 0.028))
        return t * t * (3 - 2 * t)
    }

    /// Public Core Animation projective transform: map one small rectangular
    /// texture band onto its two horizontal cross-sections, with no mask or
    /// overlapping full-size offscreen layers.
    static func bandTransform(size: CGSize, top: Row, bottom: Row) -> CATransform3D {
        let topWidth = max(0.0001, top.right - top.left)
        let bottomWidth = max(0.0001, bottom.right - bottom.left)
        let ratio = topWidth / bottomWidth
        let height = max(0.0001, size.height)
        var transform = CATransform3DIdentity
        transform.m11 = topWidth / max(0.0001, size.width)
        transform.m21 = (bottom.left * ratio - top.left) / height
        transform.m22 = (bottom.y * ratio - top.y) / height
        transform.m24 = (ratio - 1) / height
        transform.m41 = top.left
        transform.m42 = top.y
        return transform
    }

    /// The Genie mouth is the straight part of the button's lower edge. The
    /// two corner radii are excluded so a round filter button converges to its
    /// bottom centre while a wide GPS capsule retains its long straight edge.
    static func attachmentAnchor(for button: CGRect, cornerRadius: CGFloat) -> CGRect {
        guard button.width > 0, button.height > 0 else { return .zero }
        let radius = min(max(0, cornerRadius), button.width / 2, button.height / 2)
        // "Button width minus the rounded-corner width": one effective radius
        // in total. For the 40pt round filter control this deliberately leaves
        // a readable 20pt inlet instead of collapsing it to a 1pt needle.
        let width = max(1, button.width - radius)
        return CGRect(
            x: button.midX - width / 2,
            y: button.maxY - 1,
            width: width,
            height: 1
        )
    }
}
