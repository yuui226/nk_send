import SwiftUI
import UIKit

enum ZTransferColors {
    static let background = adaptiveHex(light: (0xF2, 0xF2, 0xF7), dark: (0x12, 0x12, 0x12))
    static let primaryText = adaptiveHex(light: (0x1C, 0x1C, 0x1E), dark: (0xE0, 0xE0, 0xE0))
    static let secondaryText = adaptiveHex(light: (0x6E, 0x6E, 0x73), dark: (0xB0, 0xB0, 0xB0))
    static let statusError = adaptiveHex(light: (0xD3, 0x2F, 0x2F), dark: (0xF4, 0x43, 0x36))
    static let statusConnected = adaptiveHex(light: (0x2E, 0x7D, 0x32), dark: (0x4C, 0xAF, 0x50))
    static let statusWaiting = adaptiveHex(light: (0x8E, 0x8E, 0x93), dark: (0x75, 0x75, 0x75))
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

enum ZTransferButtonSkin: String {
    case frostedGlass = "FROSTED_GLASS"
    case liquidGlass = "LIQUID_GLASS"
    case titanium = "TITANIUM"
    case wood = "WOOD"
    case cameraControls = "CAMERA_CONTROLS"

    init(storedValue: String) {
        let restored = Self(rawValue: storedValue) ?? .frostedGlass
        if restored == .liquidGlass {
            if #available(iOS 26.0, *) {
                self = restored
            } else {
                self = .frostedGlass
            }
        } else {
            self = restored
        }
    }
}

struct ZTransferButtonAccentPalette {
    let inactive: Color
    let active: Color
    let material: Color
}

/// Android `materialButtonForegroundColor`: colors printed on a physical
/// material need their own contrast, while frosted glass keeps the semantic
/// foreground supplied by the caller.
func zTransferButtonForeground(
    skin: ZTransferButtonSkin,
    scheme: ColorScheme,
    fallback: Color = ZTransferColors.primaryText
) -> Color {
    let dark = scheme == .dark
    switch skin {
    case .frostedGlass, .liquidGlass: return fallback
    case .titanium: return dark ? Color(red: 0.894, green: 0.925, blue: 0.937)
                                  : Color(red: 0.204, green: 0.255, blue: 0.286)
    case .wood: return dark ? Color(red: 0.945, green: 0.839, blue: 0.655)
                             : Color(red: 0.278, green: 0.165, blue: 0.094)
    case .cameraControls: return Color(red: 0.835, green: 0.847, blue: 0.855)
    }
}

/// Default content treatment performed by Android after a physical material
/// has drawn its child row. Wood and frosted glass preserve the caller color;
/// titanium stamps a dark groove and camera controls use cool-grey ink.
func zTransferMaterialContentColor(
    skin: ZTransferButtonSkin,
    scheme: ColorScheme,
    fallback: Color,
    active: Bool = false,
    activeColor: Color = ZTransferColors.accentBlue
) -> Color {
    switch skin {
    case .frostedGlass, .liquidGlass, .wood:
        return fallback
    case .titanium:
        return scheme == .dark
            ? Color(red: 43.0 / 255, green: 55.0 / 255, blue: 62.0 / 255)
            : Color(red: 88.0 / 255, green: 101.0 / 255, blue: 108.0 / 255)
    case .cameraControls:
        let base = Color(red: 213.0 / 255, green: 216.0 / 255, blue: 218.0 / 255)
        return base.mix(with: activeColor, by: active ? 0.72 : 0, scheme: scheme)
    }
}

/// Android `filterButtonPalette`, also suitable for compact active tool
/// buttons that use the same material-aware engraved/printed foreground.
func zTransferButtonAccentPalette(
    skin: ZTransferButtonSkin,
    scheme: ColorScheme,
    inactive: Color = ZTransferColors.primaryText,
    active: Color = ZTransferColors.accentBlue
) -> ZTransferButtonAccentPalette {
    let dark = scheme == .dark
    switch skin {
    case .frostedGlass, .liquidGlass:
        return .init(inactive: inactive, active: active, material: active)
    case .titanium:
        return .init(
            inactive: dark ? Color(red: 0.894, green: 0.925, blue: 0.937)
                           : Color(red: 0.204, green: 0.255, blue: 0.286),
            active: dark ? Color(red: 0.941, green: 0.980, blue: 1)
                         : Color(red: 0.020, green: 0.227, blue: 0.329),
            material: dark ? Color(red: 0.271, green: 0.663, blue: 0.847)
                           : Color(red: 0.086, green: 0.490, blue: 0.655)
        )
    case .wood:
        return .init(
            inactive: dark ? Color(red: 0.945, green: 0.839, blue: 0.655)
                           : Color(red: 0.278, green: 0.165, blue: 0.094),
            active: dark ? Color(red: 0.847, green: 0.965, blue: 0.910)
                         : Color(red: 0.024, green: 0.176, blue: 0.133),
            material: dark ? Color(red: 0.263, green: 0.639, blue: 0.482)
                           : Color(red: 0.102, green: 0.463, blue: 0.345)
        )
    case .cameraControls:
        return .init(
            inactive: Color(red: 0.835, green: 0.847, blue: 0.855),
            active: Color(red: 1, green: 0.886, blue: 0.639),
            material: Color(red: 1, green: 0.624, blue: 0.102)
        )
    }
}

/// The iOS counterpart of Android `GlassButton`. Button themes intentionally
/// stop here: panels, tips and the queue's speed/count/Done capsule continue to
/// use the invariant glass tokens.
struct ZTransferGlassButtonStyle: ButtonStyle {
    var tint: Color?
    var cornerRadius: CGFloat
    var followsSkin: Bool
    var panel: Bool
    var active: Bool
    var activeColor: Color
    var activeOutline: Bool
    var materialContentColor: Color?
    var disabledAlpha: CGFloat
    var suppressFrostedShadowInLight: Bool

    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.frostedGlass.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    init(
        tint: Color? = nil,
        cornerRadius: CGFloat = 22,
        followsSkin: Bool = true,
        panel: Bool = false,
        active: Bool = false,
        activeColor: Color = ZTransferColors.accentBlue,
        activeOutline: Bool = false,
        materialContentColor: Color? = nil,
        disabledAlpha: CGFloat = 0.45,
        suppressFrostedShadowInLight: Bool = false
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.followsSkin = followsSkin
        self.panel = panel
        self.active = active
        self.activeColor = activeColor
        self.activeOutline = activeOutline
        self.materialContentColor = materialContentColor
        self.disabledAlpha = disabledAlpha
        self.suppressFrostedShadowInLight = suppressFrostedShadowInLight
    }

    private var skin: ZTransferButtonSkin {
        followsSkin ? .init(storedValue: skinPreset) : .frostedGlass
    }

    func makeBody(configuration: Configuration) -> some View {
        let physical = skin != .frostedGlass && skin != .liquidGlass && !panel
        let pressedScale: CGFloat = {
            guard configuration.isPressed && isEnabled else { return 1 }
            switch skin {
            case .liquidGlass: return 1
            case .cameraControls: return 0.982
            case .titanium: return 0.970
            default: return 0.965
            }
        }()
        let pressedOffset: CGFloat = configuration.isPressed && isEnabled && physical
            ? (skin == .cameraControls ? 2.1 : 1.6)
            : 0

        treatedLabel(configuration.label)
            .background {
                ZTransferButtonMaterialSurface(
                    skin: skin,
                    cornerRadius: cornerRadius,
                    panel: panel,
                    active: active,
                    activeColor: activeColor,
                    activeOutline: activeOutline,
                    pressed: configuration.isPressed && isEnabled,
                    suppressFrostedShadowInLight: suppressFrostedShadowInLight
                )
            }
            .scaleEffect(pressedScale)
            .offset(y: pressedOffset)
            .opacity(isEnabled ? 1 : disabledAlpha)
            .animation(configuration.isPressed
                       ? .easeOut(duration: 0.08)
                       : (skin == .cameraControls
                          ? .easeOut(duration: 0.14)
                          : .spring(response: 0.34, dampingFraction: 0.72)),
                       value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.18), value: active)
    }

    @ViewBuilder
    private func treatedLabel<Label: View>(_ label: Label) -> some View {
        switch skin {
        case .titanium:
            // Android's titanium modifier always turns the complete row into
            // a recessed stamp. Without an explicit inlay it uses the dark
            // groove face, not the material-aware high-contrast text color.
            let stamp = materialContentColor ?? zTransferMaterialContentColor(
                skin: skin, scheme: colorScheme, fallback: ZTransferColors.primaryText)
            label.hidden().overlay { stamp.mask(label) }
        case .cameraControls where !panel:
            // A camera keycap uses cool-grey printing by default. Active
            // controls blend that ink towards their status-light color.
            let print = materialContentColor ?? zTransferMaterialContentColor(
                skin: skin,
                scheme: colorScheme,
                fallback: ZTransferColors.primaryText,
                active: active,
                activeColor: activeColor
            )
            label.hidden().overlay { print.mask(label) }
        case .frostedGlass, .liquidGlass, .wood, .cameraControls:
            // Android does not recolor frosted/wood rows. Preserve each
            // caller's Text/Icon color; tint is only a fallback for controls
            // whose content intentionally inherits from the button.
            if let tint { label.foregroundStyle(tint) } else { label }
        }
    }
}

private extension Color {
    func mix(with other: Color, by amount: CGFloat, scheme: ColorScheme) -> Color {
        let t = min(max(amount, 0), 1)
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let first = UIColor(self).resolvedColor(with: traits)
        let second = UIColor(other).resolvedColor(with: traits)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return Color(red: r1 + (r2 - r1) * t,
                     green: g1 + (g2 - g1) * t,
                     blue: b1 + (b2 - b1) * t,
                     opacity: a1 + (a2 - a1) * t)
    }
}

/// Static material face shared by themed ButtonStyle and the queue's collapsed
/// icon state. Procedural marks are deterministic and clipped to the final
/// shape, so there is no rectangular texture seam during scaling.
struct ZTransferButtonMaterialSurface: View {
    let skin: ZTransferButtonSkin
    let cornerRadius: CGFloat
    var panel = false
    var active = false
    var activeColor: Color = ZTransferColors.accentBlue
    var activeOutline = false
    var pressed = false
    var suppressFrostedShadowInLight = false

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var textureStore = ZTransferMaterialTextureStore.shared
    private var dark: Bool { colorScheme == .dark }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
    private var shadowSuppressed: Bool {
        panel || (suppressFrostedShadowInLight && !dark &&
                  (skin == .frostedGlass || skin == .liquidGlass))
    }

    var body: some View {
        Group {
            if skin == .liquidGlass && !panel {
                if suppressFrostedShadowInLight && !dark {
                    // Native Liquid Glass draws its own drop shadow outside
                    // the requested shape. The Android Wi-Fi card is flat in
                    // light mode, so clip only these card-local controls at
                    // the material boundary while retaining native refraction
                    // and press behavior inside it.
                    nativeLiquidGlassMaterial.clipShape(shape)
                } else {
                    nativeLiquidGlassMaterial
                }
            } else {
                material
                    .clipShape(shape)
                    .overlay {
                        if activeOutline && active {
                            shape.strokeBorder(activeColor.opacity(0.58), lineWidth: 1.25)
                        }
                    }
                    .shadow(
                        color: shadowSuppressed ? .clear : .black.opacity(shadowOpacity),
                        radius: shadowSuppressed ? 0 : shadowRadius,
                        y: shadowSuppressed ? 0 : shadowY
                    )
            }
        }
        // Material is purely visual. Keeping it outside hit testing ensures
        // every skin (including native liquid glass) leaves the Button label
        // as the sole interaction owner.
        .allowsHitTesting(false)
        .task(id: "\(skin.rawValue)-\(dark)") {
            if skin == .wood { textureStore.loadWoodIfNeeded(dark: dark) }
        }
    }

    @ViewBuilder private var material: some View {
        if panel {
            // Android panel buttons stay embedded in the popup and use no
            // raised camera keycap. A restrained material tint remains.
            shape.fill(ZTransferColors.primaryText.opacity(0.05))
                .overlay(shape.fill(panelSheen))
        } else {
            switch skin {
            case .frostedGlass: frostedMaterial
            case .liquidGlass: frostedMaterial
            case .titanium: titaniumMaterial
            case .wood: woodMaterial
            case .cameraControls: cameraMaterial
            }
        }
    }

    private var frostedMaterial: some View {
        ZTransferGlassSurface(cornerRadius: cornerRadius, kind: .button,
                              tint: active ? activeColor.opacity(0.14) : .clear)
    }

    @ViewBuilder private var nativeLiquidGlassMaterial: some View {
        if #available(iOS 26.0, *) {
            let glass = Glass.regular
                .tint(active ? activeColor.opacity(0.22) : nil)
                .interactive()
            shape
                .fill(.clear)
                .glassEffect(glass, in: shape)
        } else {
            // Preferences can be restored before RootView has normalized
            // them. Keep the material itself safe on older systems as well.
            frostedMaterial
                .clipShape(shape)
        }
    }

    private var titaniumMaterial: some View {
        let base = dark
            ? Color(red: 0.408, green: 0.451, blue: 0.478).opacity(0.98)
            : Color(red: 0.733, green: 0.765, blue: 0.784).opacity(0.98)
        return shape.fill(base)
            .overlay(shape.fill(RadialGradient(
                colors: [.white.opacity(pressed ? 0.06 : 0.18),
                         .white.opacity(0.045), .clear,
                         Color(red: 0.19, green: 0.23, blue: 0.25).opacity(0.14)],
                center: UnitPoint(x: 0.40, y: 0.30), startRadius: 0, endRadius: 130
            )))
            .overlay(shape.fill(LinearGradient(
                stops: [.init(color: .white.opacity(pressed ? 0.05 : 0.16), location: 0),
                        .init(color: .clear, location: 0.50),
                        .init(color: .black.opacity(pressed ? 0.08 : 0.22), location: 1)],
                startPoint: .top, endPoint: .bottom
            )))
            .overlay(materialGrain(kind: .titanium))
            .overlay(shape.fill(active ? activeColor.opacity(0.12) : .clear))
    }

    private var woodMaterial: some View {
        let base = dark
            ? Color(red: 0.247, green: 0.157, blue: 0.094).opacity(0.86)
            : Color(red: 0.784, green: 0.584, blue: 0.329).opacity(0.96)
        let normalTop = dark
            ? Color(red: 216.0 / 255, green: 167.0 / 255, blue: 101.0 / 255).opacity(0.030)
            : Color(red: 242.0 / 255, green: 207.0 / 255, blue: 147.0 / 255).opacity(0.060)
        let normalBottom = dark
            ? Color(red: 216.0 / 255, green: 167.0 / 255, blue: 101.0 / 255).opacity(0.010)
            : Color(red: 242.0 / 255, green: 207.0 / 255, blue: 147.0 / 255).opacity(0.015)
        return shape.fill(base)
            // Android order: opaque wood base -> stable 256 px natural tile
            // -> active/highlight wash -> sculpted hard-wood volume.
            .overlay(shape.fill(ImagePaint(
                image: textureStore.woodImage(dark: dark).map(Image.init(uiImage:)) ?? Image(systemName: "square.fill"),
                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                scale: 1
            )).opacity(textureStore.woodImage(dark: dark) == nil ? 0 : 1))
            .overlay(shape.fill(LinearGradient(
                colors: active
                    ? [activeColor.opacity(0.30), activeColor.opacity(0.12)]
                    : [normalTop, normalBottom],
                startPoint: .top,
                endPoint: .bottom
            )))
            .overlay(woodSculptedFinish)
    }

    private var woodSculptedFinish: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let volume: CGFloat = pressed ? 0.36 : 1
            let warm = dark
                ? Color(red: 247.0 / 255, green: 214.0 / 255, blue: 155.0 / 255)
                : Color(red: 1, green: 224.0 / 255, blue: 169.0 / 255)
            let shadow = dark
                ? Color(red: 20.0 / 255, green: 10.0 / 255, blue: 4.0 / 255)
                : Color(red: 92.0 / 255, green: 48.0 / 255, blue: 19.0 / 255)
            let radius = max(size.width * 0.53, size.height * 1.98)

            shape.fill(RadialGradient(
                stops: [
                    .init(color: warm.opacity((dark ? 0.115 : 0.130) * volume), location: 0),
                    .init(color: warm.opacity((dark ? 0.068 : 0.080) * volume), location: 0.35),
                    .init(color: warm.opacity(0.025 * volume), location: 0.61),
                    .init(color: shadow.opacity(0.045 * volume), location: 0.81),
                    .init(color: shadow.opacity((dark ? 0.135 : 0.100) * volume), location: 1)
                ],
                center: UnitPoint(x: 0.39, y: 0.30),
                startRadius: 0,
                endRadius: radius
            ))
            .overlay(shape.fill(LinearGradient(
                stops: [
                    .init(color: warm.opacity((dark ? 0.105 : 0.140) * volume), location: 0),
                    .init(color: warm.opacity((dark ? 0.040 : 0.055) * volume), location: 0.20),
                    .init(color: .clear, location: 0.46),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )))
            .overlay(shape.fill(LinearGradient(
                stops: [
                    .init(color: warm.opacity(0.025 * volume), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.72),
                    .init(color: shadow.opacity((dark ? 0.135 : 0.095) * volume), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )))
            .overlay(shape.fill(LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.58),
                    .init(color: shadow.opacity(0.055 * volume), location: 0.78),
                    .init(color: shadow.opacity((dark ? 0.31 : 0.21) * volume), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )))
            .overlay(shape.fill(RadialGradient(
                colors: [shadow.opacity(pressed ? 0.045 : 0), .clear],
                center: UnitPoint(x: 0.5, y: 0.52),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.72
            )))
        }
    }

    private var cameraMaterial: some View {
        let base = dark ? Color(red: 0.082, green: 0.090, blue: 0.098)
                        : Color(red: 0.106, green: 0.114, blue: 0.125)
        let cool = dark ? Color(red: 0.824, green: 0.843, blue: 0.855)
                        : Color(red: 0.745, green: 0.769, blue: 0.780)
        return shape.fill(base.opacity(0.995))
            .overlay(shape.fill(RadialGradient(
                colors: [cool.opacity(pressed ? 0.025 : 0.075), .clear,
                         .black.opacity(0.11)],
                center: UnitPoint(x: 0.42, y: 0.28), startRadius: 0, endRadius: 100
            )))
            .overlay(shape.fill(LinearGradient(
                stops: [.init(color: cool.opacity(pressed ? 0.05 : 0.16), location: 0),
                        .init(color: .clear, location: 0.34),
                        .init(color: .black.opacity(0.34), location: 1)],
                startPoint: .top, endPoint: .bottom
            )))
            .overlay(materialGrain(kind: .cameraControls))
            .overlay(shape.strokeBorder(LinearGradient(
                colors: [.black.opacity(0.20), .black.opacity(0.68)],
                startPoint: .top, endPoint: .bottom), lineWidth: 3.2))
            .overlay(shape.strokeBorder(LinearGradient(
                colors: [cool.opacity(dark ? 0.22 : 0.16), .black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom), lineWidth: 1.05))
            .overlay(shape.fill(active ? activeColor.opacity(0.14) : .clear))
    }

    private var panelSheen: LinearGradient {
        LinearGradient(colors: [.white.opacity(dark ? 0.025 : 0.10), .clear],
                       startPoint: .top, endPoint: .bottom)
    }

    private enum GrainKind { case titanium, cameraControls }

    private func materialGrain(kind: GrainKind) -> some View {
        Canvas(rendersAsynchronously: true) { context, size in
            switch kind {
            case .titanium:
                for index in 0..<28 {
                    let x = size.width * CGFloat(index) / 28
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x + 0.35, y: size.height))
                    context.stroke(line, with: .color(.white.opacity(index.isMultiple(of: 3) ? 0.026 : 0.012)), lineWidth: 0.45)
                }
            case .cameraControls:
                for index in 0..<36 {
                    let x = size.width * CGFloat((index * 37) % 101) / 101
                    let y = size.height * CGFloat((index * 61 + 17) % 103) / 103
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.7, height: 0.7)),
                                 with: .color(.white.opacity(0.035)))
                }
            }
        }
    }

    private var shadowOpacity: CGFloat {
        switch skin {
        case .frostedGlass, .liquidGlass: return 0.10
        case .titanium: return 0.22
        case .wood: return 0.24
        case .cameraControls: return 0.30
        }
    }
    private var shadowRadius: CGFloat {
        switch skin {
        case .frostedGlass, .liquidGlass: return 3
        case .titanium: return 4
        case .wood: return 4.5
        case .cameraControls: return 5
        }
    }
    private var shadowY: CGFloat {
        switch skin {
        case .frostedGlass, .liquidGlass: return 2
        case .titanium: return 3
        case .wood: return 3.5
        case .cameraControls: return 4
        }
    }
}

/// Android generates its 256 px material tiles away from the UI thread and
/// temporarily shows the solid material base. Keep that loading behavior on
/// iOS so switching to wood cannot stall popup interaction or scrolling.
@MainActor
private final class ZTransferMaterialTextureStore: ObservableObject {
    static let shared = ZTransferMaterialTextureStore()

    @Published private var darkWood: UIImage?
    @Published private var lightWood: UIImage?
    private var loadingDarkWood = false
    private var loadingLightWood = false

    func woodImage(dark: Bool) -> UIImage? { dark ? darkWood : lightWood }

    func loadWoodIfNeeded(dark: Bool) {
        if dark {
            guard darkWood == nil, !loadingDarkWood else { return }
            loadingDarkWood = true
        } else {
            guard lightWood == nil, !loadingLightWood else { return }
            loadingLightWood = true
        }
        let displayScale = UITraitCollection.current.displayScale
        Task {
            let rendered = await Task.detached(priority: .utility) {
                ZTransferWoodTexture.RenderedImage(
                    image: ZTransferWoodTexture.render(dark: dark, scale: displayScale)
                )
            }.value.image
            if dark {
                darkWood = rendered
                loadingDarkWood = false
            } else {
                lightWood = rendered
                loadingLightWood = false
            }
        }
    }
}

/// Pixel-for-pixel port of Android SkinTexture.kt's wood tile equations:
/// asymmetric growth rings, two-scale domain warp, longitudinal fibres,
/// vessels and a softly warped knot. The same 256 px tile size, color pairs
/// and alpha ranges are used before the sculpted-light layers are applied.
private enum ZTransferWoodTexture {
    struct RenderedImage: @unchecked Sendable { let image: UIImage }
    private static let tile = 256
    private static let tau = Float.pi * 2

    static func render(dark: Bool, scale: CGFloat) -> UIImage {
        let skinOrdinal = Int32(2) // Android SkinPreset.WOOD ordinal.
        let materialSeed = Int32(bitPattern: 0x5F3759DF)
            ^ (skinOrdinal &* Int32(bitPattern: 0x045D9F3B))
        let seed = mixSeed(materialSeed) // stable variant zero
        let maxAlpha: Float = dark ? 0.30 : 0.21
        let lightRGB = dark ? 0xE0B16E : 0xF6D59A
        let darkRGB = dark ? 0x160B05 : 0x5C3013
        let phase = cellHash(seed, 11, seed &+ 31)
        let ringCount = 4 + Int(cellHash(seed, 29, seed &+ 71) * 3)
        let fiberCount = 24 + Int(cellHash(seed, 31, seed &+ 83) * 8)
        let fineCount = 14 + Int(cellHash(seed, 37, seed &+ 97) * 6)
        let bendStrength = 0.060 + 0.025 * cellHash(seed, 41, seed &+ 109)
        let knotEnabled = cellHash(seed, 43, seed &+ 127) > 0.58
        let knotX = 0.18 + 0.64 * cellHash(seed, 17, seed &+ 43)
        let knotY = 0.18 + 0.64 * cellHash(seed, 23, seed &+ 59)
        var bytes = [UInt8](repeating: 0, count: tile * tile * 4)

        for y in 0..<tile {
            let v = Float(y) / Float(tile)
            for x in 0..<tile {
                let u = Float(x) / Float(tile)
                let low = periodicNoise(u, v, 2, 2, seed &+ 101)
                let mid = periodicNoise(u, v, 5, 4, seed &+ 211)
                let bend = bendStrength * low + 0.028 * mid
                    + 0.018 * sinf(tau * (u + phase)) * cosf(tau * v)

                let knotDX = torusDelta(u, knotX)
                let knotDY = torusDelta(v, knotY)
                let knotDistance = sqrtf(
                    (knotDX / 0.17) * (knotDX / 0.17)
                        + (knotDY / 0.25) * (knotDY / 0.25)
                )
                let knotMask = knotEnabled ? expf(-2.7 * knotDistance * knotDistance) : 0
                let knotWarp = knotMask * 0.48
                    * sinf(tau * (u - knotX + periodicNoise(u, v, 3, 3, seed &+ 307)))
                let knotCore = knotEnabled ? expf(-10 * knotDistance * knotDistance) : 0
                let knotRing = knotMask * sinf(tau * (3.4 * knotDistance + 0.15 * mid))

                let ringCoordinate = Float(ringCount) * (v + bend)
                    + 0.20 * sinf(tau * (u + phase)) + knotWarp
                let ringCycle = fract(ringCoordinate)
                let lateWoodCenter = 0.79 + 0.045 * mid
                let lateWoodDistance = (ringCycle - lateWoodCenter) / 0.075
                let lateWood = expf(-lateWoodDistance * lateWoodDistance)
                let shoulderDistance = (ringCycle - lateWoodCenter + 0.105) / 0.14
                let lateWoodShoulder = expf(-shoulderDistance * shoulderDistance)
                let earlyWood = cosf(tau * ringCycle)

                let fiberWarp = periodicNoise(u, v, 9, 7, seed &+ 401)
                let fiber = sinf(tau * (Float(fiberCount) * v + 0.55 * fiberWarp + bend * 4))
                let fineCoordinate = Float(fineCount) * (v + 0.55 * bend) + 0.38 * fiberWarp
                let fineCycle = fract(fineCoordinate)
                let fineDistance = (fineCycle - 0.82) / 0.07
                let fineLine = expf(-fineDistance * fineDistance)
                let fibreNoise = periodicNoise(u, v, 7, 3, seed &+ 503)
                let fiberMask = 0.55 + 0.45 * min(max(fibreNoise, -0.8), 0.8)
                let macroTone = periodicNoise(u, v, 3, 2, seed &+ 601)

                let vesselGridX = u * 12
                let vesselGridY = v * 26
                let vesselCellX = Int32(floorf(vesselGridX))
                let vesselCellY = Int32(floorf(vesselGridY))
                let vesselLocalX = fract(vesselGridX)
                let vesselLocalY = fract(vesselGridY)
                let vesselHash = cellHash(vesselCellX, vesselCellY, seed &+ 719)
                let vesselCenterX = 0.18 + 0.64 * cellHash(vesselCellX, vesselCellY, seed &+ 761)
                let vesselCenterY = 0.20 + 0.60 * cellHash(vesselCellX, vesselCellY, seed &+ 809)
                let vesselDX = (vesselLocalX - vesselCenterX) / 0.34
                let vesselDY = (vesselLocalY - vesselCenterY) / 0.09
                let vessel = vesselHash > 0.72
                    ? expf(-3.2 * (vesselDX * vesselDX + vesselDY * vesselDY))
                        * smoothStep(0.72, 0.96, vesselHash)
                    : 0

                let texture = 0.16 * macroTone + 0.14 * earlyWood
                    - 0.72 * lateWood - 0.12 * lateWoodShoulder
                    - 0.12 * fineLine * fiberMask + 0.045 * fiber
                    - 0.18 * vessel - 0.24 * knotCore + 0.08 * knotRing
                writeSigned(texture, maxAlpha: maxAlpha, lightRGB: lightRGB,
                            darkRGB: darkRGB, into: &bytes, at: (y * tile + x) * 4)
            }
        }

        let data = Data(bytes) as CFData
        let provider = CGDataProvider(data: data)!
        let info = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let image = CGImage(
            width: tile,
            height: tile,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: tile * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: image, scale: max(1, scale), orientation: .up)
    }

    private static func writeSigned(
        _ value: Float,
        maxAlpha: Float,
        lightRGB: Int,
        darkRGB: Int,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        let clamped = min(max(value, -1), 1)
        let alpha = abs(clamped) * maxAlpha
        let rgb = clamped >= 0 ? lightRGB : darkRGB
        bytes[offset] = UInt8(Float((rgb >> 16) & 0xFF) * alpha + 0.5)
        bytes[offset + 1] = UInt8(Float((rgb >> 8) & 0xFF) * alpha + 0.5)
        bytes[offset + 2] = UInt8(Float(rgb & 0xFF) * alpha + 0.5)
        bytes[offset + 3] = UInt8(alpha * 255 + 0.5)
    }

    private static func mixSeed(_ value: Int32) -> Int32 {
        var x = value
        x = (x ^ (x >> 16)) &* Int32(bitPattern: 0x7FEB352D)
        x = (x ^ (x >> 15)) &* Int32(bitPattern: 0x846CA68B)
        return x ^ (x >> 16)
    }

    private static func cellHash(_ i: Int32, _ j: Int32, _ seed: Int32) -> Float {
        var h = i &* 374_761_393 &+ j &* 668_265_263 &+ seed &* 974_711
        h ^= h >> 13
        h = h &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0x7FFF_FFFF) / Float(Int32.max)
    }

    private static func smoothCurve(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }

    private static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return smoothCurve(x)
    }

    private static func fract(_ value: Float) -> Float { value - floorf(value) }

    private static func periodicNoise(
        _ u: Float,
        _ v: Float,
        _ cellsX: Int32,
        _ cellsY: Int32,
        _ seed: Int32
    ) -> Float {
        let gx = u * Float(cellsX)
        let gy = v * Float(cellsY)
        let x0 = Int32(floorf(gx))
        let y0 = Int32(floorf(gy))
        let tx = smoothCurve(gx - floorf(gx))
        let ty = smoothCurve(gy - floorf(gy))
        func sample(_ x: Int32, _ y: Int32) -> Float {
            let wx = ((x % cellsX) + cellsX) % cellsX
            let wy = ((y % cellsY) + cellsY) % cellsY
            return cellHash(wx, wy, seed) * 2 - 1
        }
        let a = sample(x0, y0)
        let b = sample(x0 &+ 1, y0)
        let c = sample(x0, y0 &+ 1)
        let d = sample(x0 &+ 1, y0 &+ 1)
        let top = a + (b - a) * tx
        let bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    private static func torusDelta(_ a: Float, _ b: Float) -> Float {
        let direct = abs(a - b)
        return min(direct, 1 - direct)
    }
}
