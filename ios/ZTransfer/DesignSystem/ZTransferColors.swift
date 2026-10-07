import SwiftUI
import UIKit

enum ZTransferColors {
    static let surface = adaptiveHex(light: (0xFF, 0xFF, 0xFF), dark: (0x1E, 0x1E, 0x1E))
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

/// The iOS counterpart of Android `GlassButton`. The separately selected
/// Liquid Glass skin keeps the user-approved native iOS material.
/// `panel` remains the snapshot-stable embedded variant used inside Genie
/// popup animation content.
struct ZTransferGlassButtonStyle: PrimitiveButtonStyle {
    var tint: Color?
    var cornerRadius: CGFloat
    var followsSkin: Bool
    var panel: Bool
    var active: Bool
    var activeColor: Color
    var activeOutline: Bool
    var liquidGlassBoundary: Bool
    var materialContentColor: Color?
    var disabledAlpha: CGFloat
    var prominentPressFeedback: Bool
    var showSheen: Bool
    var frostedOpacityBoost: Double
    var shadowElevation: CGFloat?
    var textureSeed: Int32

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
        liquidGlassBoundary: Bool = false,
        materialContentColor: Color? = nil,
        disabledAlpha: CGFloat = 0.45,
        prominentPressFeedback: Bool = false,
        showSheen: Bool = true,
        frostedOpacityBoost: Double = 0,
        shadowElevation: CGFloat? = nil,
        textureSeed: Int32? = nil,
        sourceFile: StaticString = #fileID,
        sourceLine: UInt = #line
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.followsSkin = followsSkin
        self.panel = panel
        self.active = active
        self.activeColor = activeColor
        self.activeOutline = activeOutline
        self.liquidGlassBoundary = liquidGlassBoundary
        self.materialContentColor = materialContentColor
        self.disabledAlpha = disabledAlpha
        self.prominentPressFeedback = prominentPressFeedback
        self.showSheen = showSheen
        self.frostedOpacityBoost = frostedOpacityBoost
        self.shadowElevation = shadowElevation
        self.textureSeed = textureSeed ?? ZTransferTextureKey.stableSeed("\(sourceFile):\(sourceLine)")
    }

    private var skin: ZTransferButtonSkin {
        followsSkin ? .init(storedValue: skinPreset) : .frostedGlass
    }

    func makeBody(configuration: Configuration) -> some View {
        ZTransferAnimatedGlassButton(style: self, configuration: configuration,
            skin: skin, enabled: isEnabled)
    }

    fileprivate func materialBody<Label: View>(_ label: Label, skin: ZTransferButtonSkin,
                                               frame: ZTransferButtonMotion.Frame,
                                               nativePressed: Bool) -> some View {
        let nativeGlass = skin == .liquidGlass
        let physical = !nativeGlass && skin != .frostedGlass && !panel
        let resolvedDisabledAlpha = min(max(disabledAlpha, 0), 1)
        let needsDisabledLayer = !isEnabled && resolvedDisabledAlpha < 0.999
        let transformed = frame.scale != 1 || needsDisabledLayer
        let scale: CGFloat = nativeGlass
            ? (nativePressed && isEnabled && prominentPressFeedback ? 0.94 : 1)
            : CGFloat(frame.scale)
        // Android omits the entire graphics layer once scale has returned to 1.
        let translation: CGFloat = physical && transformed
            ? (skin == .cameraControls ? 2.1 : 1.6) * CGFloat(frame.light) : 0
        return treatedLabel(label, skin: skin, press: CGFloat(frame.light), active: CGFloat(frame.active))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius,
                style: nativeGlass ? .continuous : .circular))
            .background {
                ZTransferButtonMaterialSurface(
                    skin: skin, cornerRadius: cornerRadius, panel: panel,
                    active: active, activeColor: activeColor, activeOutline: activeOutline,
                    liquidGlassBoundary: liquidGlassBoundary,
                    pressed: nativePressed && isEnabled,
                    showSheen: showSheen, frostedOpacityBoost: frostedOpacityBoost,
                    shadowElevation: shadowElevation, textureSeed: textureSeed,
                    pressProgress: CGFloat(frame.light), activeProgress: CGFloat(frame.active)
                )
            }
            .scaleEffect(scale)
            .offset(y: translation)
            .brightness(nativeGlass && nativePressed && prominentPressFeedback ? -0.035 : 0)
            .opacity(!isEnabled && (nativeGlass || transformed) ? resolvedDisabledAlpha : 1)
            .animation(nativeGlass
                ? (nativePressed ? .easeOut(duration: 0.08) : .spring(response: 0.34, dampingFraction: 0.72))
                : nil, value: nativePressed)
    }

    @ViewBuilder
    private func treatedLabel<Label: View>(_ label: Label, skin: ZTransferButtonSkin,
                                           press: CGFloat, active: CGFloat) -> some View {
        switch skin {
        case .titanium:
            label.modifier(ZTransferTitaniumStamp(dark: colorScheme == .dark,
                inlay: materialContentColor, pressProgress: press))
        case .cameraControls where !panel:
            label.modifier(ZTransferCameraPrint(scheme: colorScheme, inlay: materialContentColor,
                activeColor: activeColor, progress: active))
        case .frostedGlass, .liquidGlass, .wood, .cameraControls:
            if let tint { label.foregroundStyle(tint) } else { label }
        }
    }
}

private struct ZTransferAnimatedGlassButton: View {
    let style: ZTransferGlassButtonStyle
    let configuration: PrimitiveButtonStyleConfiguration
    let skin: ZTransferButtonSkin
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var motion: ZTransferButtonMotionController

    init(style: ZTransferGlassButtonStyle, configuration: PrimitiveButtonStyleConfiguration,
         skin: ZTransferButtonSkin, enabled: Bool) {
        self.style = style
        self.configuration = configuration
        self.skin = skin
        self.enabled = enabled
        _motion = StateObject(wrappedValue: ZTransferButtonMotionController(
            skin: skin, panel: style.panel, active: style.active, enabled: enabled))
    }

    var body: some View {
        Button(role: configuration.role) {
            motion.successfulActivation()
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(FeedbackStyle(style: style, skin: skin, motion: motion))
        // Android's semantics onClick bypasses PressInteraction. Preserve that
        // distinction while keeping native Button focus/keyboard/action handling.
        .accessibilityAction {
            if enabled { configuration.trigger() }
        }
        .background { ZTransferButtonScrollContext { motion.inScrollableContainer = $0 } }
        .onAppear(perform: configure)
        .onChange(of: enabled) { _ in configure() }
        .onChange(of: skin) { _ in configure() }
        .onChange(of: style.panel) { _ in configure() }
        .onChange(of: style.active) { _ in configure() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { motion.stop() } else { configure() }
        }
        .onDisappear { motion.stop() }
    }

    private func configure() {
        #if DEBUG
        motion.traceID = style.textureSeed
        #endif
        motion.configure(skin: skin, panel: style.panel, active: style.active, enabled: enabled)
    }

    private struct FeedbackStyle: ButtonStyle {
        let style: ZTransferGlassButtonStyle
        let skin: ZTransferButtonSkin
        @ObservedObject var motion: ZTransferButtonMotionController
        func makeBody(configuration: Configuration) -> some View {
            style.materialBody(configuration.label, skin: skin, frame: motion.frame,
                               nativePressed: configuration.isPressed)
                .onChange(of: configuration.isPressed) { motion.nativePressChanged($0) }
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
        let start = ZTransferAndroidColor.pack(red: Float(r1), green: Float(g1), blue: Float(b1), alpha: Float(a1))
        let end = ZTransferAndroidColor.pack(red: Float(r2), green: Float(g2), blue: Float(b2), alpha: Float(a2))
        let result = ZTransferAndroidColor.lerp(start: start, end: end, fraction: Float(t))
        return Color(.sRGB, red: Double((result >> 16) & 255) / 255,
                     green: Double((result >> 8) & 255) / 255,
                     blue: Double(result & 255) / 255, opacity: Double(result >> 24) / 255)
    }
}

/// Static material face shared by themed ButtonStyle and the queue's collapsed
/// icon state. Procedural marks are deterministic and clipped to the final
/// shape, so there is no rectangular texture seam during scaling.
struct ZTransferButtonMaterialSurface: View, Animatable {
    let skin: ZTransferButtonSkin
    let cornerRadius: CGFloat
    var panel = false
    var active = false
    var activeColor: Color = ZTransferColors.accentBlue
    var activeOutline = false
    var liquidGlassBoundary = false
    var pressed = false
    var showSheen = true
    var frostedOpacityBoost: Double = 0
    var shadowElevation: CGFloat?
    var textureSeed: Int32 = 0
    var pressProgress: CGFloat? = nil
    var activeProgress: CGFloat? = nil

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pressProgress ?? (pressed ? 1 : 0), activeProgress ?? (active && !panel ? 1 : 0)) }
        set { pressProgress = newValue.first; activeProgress = newValue.second }
    }
    private var pressAmount: CGFloat { min(max(pressProgress ?? (pressed ? 1 : 0), 0), 1) }
    private var activeAmount: CGFloat { panel ? 0 : min(max(activeProgress ?? (active ? 1 : 0), 0), 1) }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var textureStore = ZTransferMaterialTextureStore.shared
    private var dark: Bool { colorScheme == .dark }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: skin == .liquidGlass ? .continuous : .circular)
    }
    private var shadowSuppressed: Bool {
        (panel && shadowElevation == nil) || skin == .frostedGlass
    }

    var body: some View {
        Group {
            if skin == .liquidGlass && !panel {
                nativeLiquidGlassMaterial
            } else {
                material
                    .clipShape(shape)
                    .overlay {
                        if activeOutline && activeAmount > 0.001 {
                            shape.strokeBorder(activeColor.opacity(0.58 * activeAmount), lineWidth: 1.25)
                        }
                    }
                    .shadow(
                        color: shadowSuppressed ? .clear : .black.opacity(shadowOpacity),
                        radius: shadowSuppressed ? 0 : shadowRadius * elevationScale,
                        y: shadowSuppressed ? 0 : shadowY * elevationScale
                    )
                    // Surface owns the interpolated scalars. Child finishes
                    // must draw this frame, not start a second animation.
                    .transaction { $0.animation = nil }
            }
        }
        .overlay {
            if skin == .liquidGlass && liquidGlassBoundary {
                shape.strokeBorder(
                    ZTransferColors.primaryText.opacity(dark ? 0.18 : 0.10),
                    lineWidth: 0.75
                )
            }
        }
        // Material is purely visual. Keeping it outside hit testing ensures
        // every skin (including native liquid glass) leaves the Button label
        // as the sole interaction owner.
        .allowsHitTesting(false)
        .task(id: textureKey) {
            if let key = textureKey { await textureStore.load(key) }
        }
    }

    private var textureKey: ZTransferTextureKey? {
        ZTransferTextureKey(skin: skin, dark: dark, seed: textureSeed, panel: panel)
    }

    @ViewBuilder private var materialTexture: some View {
        if let key = textureKey, let image = textureStore.image(for: key) {
            shape.fill(ImagePaint(image: Image(decorative: image, scale: max(displayScale, 1)),
                                  scale: 1))
        }
    }

    @ViewBuilder private var material: some View {
        if skin == .frostedGlass {
            frostedMaterial
        } else if skin == .liquidGlass {
            if panel {
                shape.fill(ZTransferColors.primaryText.opacity(0.05))
                    .overlay(shape.fill(panelSheen))
            } else { frostedMaterial }
        } else {
            shape.fill(panel ? ZTransferColors.primaryText.opacity(0.05) : physicalBase)
                .overlay(materialTexture)
                .overlay(shape.fill(physicalHighlight))
                .overlay {
                    ZTransferPhysicalMaterialFinish(skin: skin, cornerRadius: cornerRadius,
                        dark: dark, panel: panel, activeColor: activeColor,
                        pressProgress: pressAmount, activeProgress: activeAmount)
                }
        }
    }

    private func rgb(_ hex: UInt32, alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: alpha)
    }

    private var physicalBase: Color {
        switch skin {
        case .titanium: return rgb(dark ? 0x68737A : 0xBBC3C8, alpha: 0.98)
        case .wood: return rgb(dark ? 0x3F2818 : 0xC89554, alpha: dark ? 0.86 : 0.96)
        case .cameraControls: return rgb(dark ? 0x151719 : 0x1B1D20, alpha: 0.995)
        case .frostedGlass, .liquidGlass: return .clear
        }
    }

    private var frostedMaterial: some View {
        ZTransferFrostedButtonSurface(cornerRadius: cornerRadius, dark: dark, panel: panel,
                                     showSheen: showSheen, opacityBoost: frostedOpacityBoost,
                                     activeColor: activeColor, active: active && !panel, pressed: pressed,
                                     pressProgress: pressAmount, activeProgress: activeAmount)
    }

    @ViewBuilder private var nativeLiquidGlassMaterial: some View {
        if #available(iOS 26.0, *) {
            let glass = Glass.regular
                .tint(active ? activeColor.opacity(0.22) : nil)
                .interactive()
            ZStack {
                // Never derive the replacement shadow from `glassEffect`:
                // its backdrop-sampling layer has rectangular bounds, which
                // makes neighbouring controls merge into a grey block. This
                // layer uses an explicit rounded shadowPath instead.
                ZTransferRoundedPathShadow(
                    cornerRadius: cornerRadius,
                    opacity: dark ? 0.14 : 0.055,
                    radius: dark ? 2.5 : 1.5,
                    y: dark ? 1.25 : 0.75
                )
                shape
                    .fill(.clear)
                    .glassEffect(glass, in: shape)
                    .clipShape(shape)
            }
        } else {
            // Preferences can be restored before RootView has normalized
            // them. Keep the material itself safe on older systems as well.
            frostedMaterial
                .clipShape(shape)
        }
    }

    private var physicalHighlight: LinearGradient {
        let top: Color
        let bottom: Color
        if !showSheen {
            top = .clear; bottom = .clear
        } else if panel {
            switch skin {
            case .titanium: top = rgb(dark ? 0xEAF1F4 : 0xFAFCFD).opacity(dark ? 0.070 : 0.120)
            case .wood: top = rgb(dark ? 0xD8A765 : 0xF2CF93).opacity(dark ? 0.025 : 0.045)
            case .cameraControls: top = rgb(0xB9C0C4).opacity(dark ? 0.035 : 0.040)
            case .frostedGlass, .liquidGlass: top = .clear
            }
            bottom = .clear
        } else {
            switch skin {
            case .titanium:
                top = rgb(dark ? 0xEAF1F4 : 0xFAFCFD).opacity(dark ? 0.080 : 0.150)
                bottom = rgb(dark ? 0x303A41 : 0x68737B).opacity(0.035)
            case .wood:
                top = rgb(dark ? 0xD8A765 : 0xF2CF93).opacity(dark ? 0.030 : 0.060)
                bottom = rgb(dark ? 0xD8A765 : 0xF2CF93).opacity(dark ? 0.010 : 0.015)
            case .cameraControls:
                top = rgb(0xB9C0C4).opacity(dark ? 0.040 : 0.050)
                bottom = .black.opacity(dark ? 0.18 : 0.20)
            case .frostedGlass, .liquidGlass:
                top = .clear; bottom = .clear
            }
        }
        return LinearGradient(colors: [
            top.mix(with: activeColor.opacity(0.30), by: activeAmount, scheme: colorScheme),
            bottom.mix(with: activeColor.opacity(0.12), by: activeAmount, scheme: colorScheme)
        ], startPoint: .top, endPoint: .bottom)
    }

    private var elevationScale: CGFloat {
        guard skin != .liquidGlass else { return 1 }
        let reference = ZTransferButtonElevation.base(skin: skin, active: false, panel: false)
        return ZTransferButtonElevation.value(skin: skin, activeProgress: activeAmount, panel: panel,
            override: shadowElevation, pressProgress: pressAmount) / max(reference, 1)
    }

    private var panelSheen: LinearGradient {
        LinearGradient(colors: [.white.opacity(showSheen ? (dark ? 0.025 : 0.10) : 0), .clear],
                       startPoint: .top, endPoint: .bottom)
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

/// A path-backed shadow for Liquid Glass buttons. `glassEffect` owns a larger
/// rectangular backdrop layer, so applying SwiftUI's `.shadow` to that view
/// leaks the compositor bounds as a grey rectangle when controls are grouped.
private struct ZTransferRoundedPathShadow: UIViewRepresentable {
    let cornerRadius: CGFloat
    let opacity: CGFloat
    let radius: CGFloat
    let y: CGFloat

    func makeUIView(context: Context) -> ZTransferRoundedShadowView {
        ZTransferRoundedShadowView()
    }

    func updateUIView(_ view: ZTransferRoundedShadowView, context: Context) {
        view.configure(cornerRadius: cornerRadius, opacity: opacity, radius: radius, y: y)
    }
}

private final class ZTransferRoundedShadowView: UIView {
    private var configuredCornerRadius: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = UIColor.white.withAlphaComponent(0.001)
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func configure(cornerRadius: CGFloat, opacity: CGFloat, radius: CGFloat, y: CGFloat) {
        configuredCornerRadius = cornerRadius
        layer.shadowOpacity = Float(opacity)
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: 0, height: y)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: configuredCornerRadius
        ).cgPath
    }
}

/// Animate the scalar before computing the ink. Animating two endpoint Colors
/// would make SwiftUI choose its own interpolation space between those colors.
struct ZTransferCameraPrint: ViewModifier, Animatable {
    let scheme: ColorScheme
    let inlay: Color?
    let activeColor: Color
    var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    var resolvedInk: Color {
        inlay ?? Color(.sRGB, red: 213.0 / 255, green: 216.0 / 255, blue: 218.0 / 255)
            .mix(with: activeColor, by: 0.72 * min(max(progress, 0), 1), scheme: scheme)
    }
    func body(content: Content) -> some View {
        content.hidden().overlay { resolvedInk.mask(content).opacity(0.96) }
            .transaction { $0.animation = nil }
    }
}
