import SwiftUI

/// Shared frosted surface tokens from Color.kt / ConnectionCardMaterial.kt.
/// The connection page contains a flat background, so its glass can be drawn
/// with static composited fills without a live system blur per breathing card.
struct ZTransferGlassSurface: View {
    enum Kind { case connection, button }
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let kind: Kind
    var tint: Color = .clear

    private var dark: Bool { colorScheme == .dark }
    private var base: Color {
        switch kind {
        case .connection: return dark ? Color(white: 30 / 255).opacity(0.45) : .white.opacity(0.85)
        case .button: return dark ? Color(red: 137 / 255, green: 153 / 255, blue: 164 / 255).opacity(0.20) : .white.opacity(0.62)
        }
    }
    private var sheen: [Color] {
        switch kind {
        case .connection: return [.white.opacity(dark ? 0.16 : 0.60), .white.opacity(dark ? 0.04 : 0.10)]
        case .button: return [.white.opacity(dark ? 0.025 : 0.12), .clear]
        }
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(base)
            .overlay(shape.fill(LinearGradient(colors: sheen, startPoint: .top, endPoint: .bottom)))
            .overlay(shape.fill(tint))
            .overlay {
                if kind == .connection {
                    // Android draws a centered 1.8 dp rim and clips the outside
                    // half at the card shape (0.9 dp remains on the inside).
                    shape.stroke(LinearGradient(
                        colors: [.white.opacity(dark ? 0.192 : 0.78),
                                 dark ? .white.opacity(0.018) : .black.opacity(0.17)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 1.8)
                } else {
                    shape.strokeBorder(LinearGradient(
                        colors: [.white.opacity(dark ? 0.12 : 0.55), .black.opacity(dark ? 0.18 : 0.08)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .clipShape(shape)
    }
}
