import SwiftUI
import UIKit

enum ZTransferColors {
    static let background = adaptiveHex(light: (0xF2, 0xF2, 0xF7), dark: (0x12, 0x12, 0x12))
    static let primaryText = adaptiveHex(light: (0x1C, 0x1C, 0x1E), dark: (0xE0, 0xE0, 0xE0))
    static let secondaryText = adaptiveHex(light: (0x6E, 0x6E, 0x73), dark: (0xB0, 0xB0, 0xB0))
    static let statusError = adaptiveHex(light: (0xD3, 0x2F, 0x2F), dark: (0xF4, 0x43, 0x36))
    // Android light Material tokens (Color.kt), kept in one source for every page.
    static let accentBlue = adaptiveHex(light: (0x02, 0x77, 0xBD), dark: (0x4F, 0xC3, 0xF7))
    static let accentOrange = adaptiveHex(light: (0xEF, 0x6C, 0x00), dark: (0xFF, 0xB7, 0x4D))
    static let accentYellow = adaptiveHex(light: (0xB7, 0x79, 0x00), dark: (0xFF, 0xD5, 0x4F))
    static let accentPurple = adaptiveHex(light: (0x7B, 0x1F, 0xA2), dark: (0xCE, 0x93, 0xD8))

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
    var cornerRadius: CGFloat = 22
    @AppStorage("skinPreset") private var skinPreset = "毛玻璃"

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background(buttonSurface)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    @ViewBuilder private var buttonSurface: some View {
        switch skinPreset {
        case "木纹":
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.92, green: 0.78, blue: 0.60), Color(red: 0.72, green: 0.52, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.brown.opacity(0.34), lineWidth: 1))
        case "相机按键":
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.68)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.black.opacity(0.28), lineWidth: 1))
        case "钛合金":
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.48), Color(white: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.30), lineWidth: 1))
        default:
            ZTransferGlassSurface(cornerRadius: cornerRadius, kind: .button)
        }
    }
}
