import SwiftUI
import UIKit

enum ZTransferColors {
    static let background = adaptive(light: (0.95, 0.95, 0.98), dark: (0.09, 0.09, 0.11))
    static let primaryText = adaptive(light: (0.08, 0.08, 0.10), dark: (0.96, 0.96, 0.98))
    static let secondaryText = adaptive(light: (0.36, 0.37, 0.40), dark: (0.68, 0.69, 0.73))
    // Android light Material tokens (Color.kt), kept in one source for every page.
    static let accentBlue = adaptiveHex(light: (0x02, 0x77, 0xBD), dark: (0x4F, 0xC3, 0xF7))
    static let accentOrange = adaptiveHex(light: (0xEF, 0x6C, 0x00), dark: (0xFF, 0xB7, 0x4D))
    static let accentYellow = adaptiveHex(light: (0xB7, 0x79, 0x00), dark: (0xFF, 0xD5, 0x4F))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    private static func adaptiveHex(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
    }
}

struct ZTransferGlassButtonStyle: ButtonStyle {
    var tint: Color = ZTransferColors.primaryText

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.62), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
