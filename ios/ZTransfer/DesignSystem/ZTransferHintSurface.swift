import SwiftUI

/// Android GlassHintSurface (2026-10-22): rounded heavy fill and border with
/// zero elevation. The host owns visibility, placement and animation; a shadow
/// here would be clipped by its fade/slide layer into a flashing rectangle.
struct ZTransferHintSurface: View {
    var cornerRadius: CGFloat = 22
    var fill: Color? = nil
    var border: Color? = nil
    var borderWidth: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        shape.fill(fill ?? (colorScheme == .dark
            ? Color(white: 30 / 255).opacity(0.92) : .white.opacity(0.95)))
            .overlay(shape.strokeBorder(border ?? (colorScheme == .dark
                ? .white.opacity(0.15) : .black.opacity(0.10)), lineWidth: borderWidth))
            .allowsHitTesting(false)
    }
}
