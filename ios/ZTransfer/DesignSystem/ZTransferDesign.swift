import SwiftUI

enum ZTransferMetrics {
    static let pageHorizontal: CGFloat = 24
    static let cardSpacing: CGFloat = 16
    static let cardRadius: CGFloat = 28
    static let controlRadius: CGFloat = 16
    static let touchTarget: CGFloat = 44
    // Match the Android Material typography tokens (titleLarge/bodyLarge/bodyMedium).
    // Individual screens may choose the corresponding weight, but never invent a
    // second global font scale for the same semantic role.
    static let title: CGFloat = 20
    static let body: CGFloat = 16
    static let caption: CGFloat = 14
}

enum ZTransferMotion {
    static let standard = Animation.easeInOut(duration: 0.24)
    static let emphasized = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let popup = Animation.spring(response: 0.34, dampingFraction: 0.9)

    /// Android ButtonStateTextMotion: incoming 220 ms, outgoing 190 ms,
    /// independent fade timing and FastOutSlowIn cubic control points.
    static func buttonStateTransition(forward: Bool) -> AnyTransition {
        let direction: CGFloat = forward ? 1 : -1
        return .asymmetric(
            insertion: .offset(y: 20 * direction)
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22))
                .combined(with: .opacity.animation(.linear(duration: 0.15).delay(0.035))),
            removal: .offset(y: -20 * direction)
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.19))
                .combined(with: .opacity.animation(.linear(duration: 0.12))))
    }
}

enum ZTransferIcon {
    static let settings = "gearshape.fill"
    static let usb = "cable.connector"
    static let wifi = "wifi"
    static let gps = "location.fill"
    static let workspace = "photo.on.rectangle.angled"
}

struct ZTransferTextStyle: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        // Android uses the platform sans face; using iOS's default system design
        // keeps glyph metrics and wrapping closer than the rounded face.
        content.font(.system(size: size, weight: weight, design: .default))
            .foregroundStyle(ZTransferColors.primaryText)
    }
}

extension View {
    func zTransferText(size: CGFloat = ZTransferMetrics.body, weight: Font.Weight = .regular) -> some View {
        modifier(ZTransferTextStyle(size: size, weight: weight))
    }
}
