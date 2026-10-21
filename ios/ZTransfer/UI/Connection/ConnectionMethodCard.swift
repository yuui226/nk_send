import SwiftUI
import UIKit

/// Android HomeScreen.StaConnectButtonState. Error detail changes keep the same
/// idle action instead of restarting its transition; cancellation rolls back.
enum STAConnectButtonState: Int {
    case idle, searching, pairing, connecting, connected

    init(_ phase: WiFiConnectionPhase) {
        switch phase {
        case .discovering: self = .searching
        case .pairing: self = .pairing
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .idle, .unavailable, .reconnecting, .failed: self = .idle
        }
    }

    var title: String {
        switch self {
        case .idle: AppLocalized.resource("sta_connect_action")
        case .searching: AppLocalized.resource("sta_status_searching")
        case .pairing: AppLocalized.resource("sta_status_pairing")
        case .connecting: AppLocalized.resource("sta_status_connecting")
        case .connected: AppLocalized.resource("sta_status_connected")
        }
    }
}

/// Android HomeScreen.kt's Wi-Fi feedback has priority over the steps inside
/// one reserved slot. AP probing is .connecting in ConnectionViewModel;
/// STA search/pair/connect changes only its action label, never this feedback.
enum ConnectionCardWirelessFeedback: Hashable {
    case probing, notFound, refused, failed, reconnecting, staFailure(String)

    static let probingDelay: Duration = .milliseconds(350)

    static func isAPProbing(_ state: ConnectionState) -> Bool {
        state.wirelessMode == .ap && state.usbPhase != .connected && state.wifiPhase == .connecting
    }

    static func resolve(_ state: ConnectionState, mode: WirelessMode,
                        showAPProbing: Bool) -> Self? {
        guard state.wirelessMode == mode else { return nil }
        if mode == .sta {
            if case let .failed(message) = state.wifiPhase { return .staFailure(message) }
            return nil
        }
        // USB owns the connection once verified; a late network callback must
        // not flash AP feedback while the Wi-Fi card is leaving the scene.
        guard state.usbPhase != .connected else { return nil }
        switch state.wifiPhase {
        case .connecting: return showAPProbing ? .probing : nil
        case .reconnecting: return .reconnecting
        case .failed:
            switch state.wifiFailureKind {
            case .notFound: return .notFound
            case .refused: return .refused
            case .failed, .none: return .failed
            }
        default: return nil
        }
    }

    var title: String {
        let key = switch self {
        case .probing: "wifi_identifying_camera"
        case .notFound: "wifi_camera_not_found"
        case .refused: "wifi_camera_refused"
        case .failed: "wifi_camera_connection_failed"
        case .reconnecting: "wifi_connection_interrupted"
        case .staFailure: "sta_camera_not_found_short"
        }
        return AppLocalized.resource(key)
    }

    var message: String? {
        switch self {
        case .probing: nil
        case .notFound: AppLocalized.resource("wifi_connect_camera")
        case .refused: AppLocalized.resource("wifi_check_camera_connection")
        case .failed: AppLocalized.resource("wifi_restart_camera")
        case .reconnecting: AppLocalized.resource("wifi_reconnecting")
        case let .staFailure(message): message
        }
    }

    var accent: Color {
        switch self {
        case .probing: ZTransferColors.accentBlue
        case .staFailure: ZTransferColors.statusError
        default: ZTransferColors.accentOrange
        }
    }

    var busy: Bool { self == .probing || self == .reconnecting }
}

struct ConnectionMethodCard: View {
    let mode: CameraConnectionMode
    let state: ConnectionState
    let height: CGFloat
    let dimmed: Bool
    /// Android supplies one page-level attention flag to both cards. It stays
    /// active until a real connection is selected, including connecting and
    /// failed states.
    let attentionActive: Bool
    let attentionOrigin: Date
    /// Android's HomeScreen supplies the selected card and the shared
    /// celebration clock.  Keeping these values at the card boundary lets
    /// the surrounding page remain static while only the hero layers redraw.
    let selected: Bool
    let celebrationStart: Date?
    var previewPremiumCelebration = false
    var onWirelessModeChanged: ((WirelessMode) -> Void)?
    var onConnect: (() -> Void)?
    var onResetSTAPairing: (() -> Void)?
    var onSTAHelpRequested: (() -> Void)?
    var onAPHelpRequested: (() -> Void)?
    var staHelpViewed = false
    var apHelpViewed = false
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var tipRects: [TipPopupTrigger: CGRect] = [:]
    @State private var cardWindowFrame = CGRect.zero
    @State private var showAPProbing = false

    private var accent: Color { mode == .usb ? ZTransferColors.accentOrange : ZTransferColors.accentBlue }
    private var isSTA: Bool { state.wirelessMode == .sta }
    private var isAPProbing: Bool {
        mode == .wifi && scenePhase == .active && ConnectionCardWirelessFeedback.isAPProbing(state)
    }
    private var buttonSkin: ZTransferButtonSkin { .init(storedValue: skinPreset) }
    private var materialForeground: Color {
        zTransferButtonForeground(skin: buttonSkin, scheme: colorScheme)
    }
    private var staResetIconColor: Color {
        buttonSkin == .wood ? ZTransferColors.primaryText : ZTransferColors.accentOrange
    }
    private func steps(for wirelessMode: WirelessMode? = nil) -> [String] {
        if mode == .usb {
            return [
                AppLocalized.resource("usb_step_mode"),
                AppLocalized.resource("usb_step_power"),
                AppLocalized.resource("usb_step_cable"),
            ]
        }
        if wirelessMode == .sta {
            return [AppLocalized.resource("sta_step_phone_hotspot"),
                    AppLocalized.resource("sta_step_connect_camera")]
        }
        return [AppLocalized.resource("step_camera_wifi"), AppLocalized.resource("step_phone_wifi")]
    }

    var body: some View {
        NativeAttentionHost(configuration: .init(kind: .card(offset: mode == .usb ? 0 : 0.5),
            origin: attentionOrigin, enabled: attentionActive, paused: scenePhase != .active),
            onTipAnchorsChange: { if tipRects != $0 { tipRects = $0 } },
            onWindowFrameChange: { if cardWindowFrame != $0 { cardWindowFrame = $0 } }) {
        ZStack(alignment: .topLeading) {
            ConnectionCardSurfaceTimeline(start: celebrationStart) {
                cardSurface
            }
            celebrationLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        // Android keeps popup anchors outside graphicsLayer's breathing scale.
        // Publish measured local bounds through this static hosting boundary.
        .anchorPreference(key: TipPopupAnchorPreferenceKey.self, value: .rect(tipRects[.sta] ?? .zero)) {
            tipRects[.sta] == nil ? [:] : [.sta: $0]
        }
        .transformAnchorPreference(key: TipPopupAnchorPreferenceKey.self, value: .rect(tipRects[.ap] ?? .zero)) {
            if tipRects[.ap] != nil { $0[.ap] = $1 }
        }
        .zIndex(selected ? 3 : 0)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.32), value: dimmed)
        .task(id: isAPProbing) {
            showAPProbing = false
            guard isAPProbing else { return }
            do { try await Task.sleep(for: ConnectionCardWirelessFeedback.probingDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            showAPProbing = true
        }
    }

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Match Android: the unique mode badge is rendered by the
                // independent layer below. Keeping only this 42pt placeholder
                // prevents a stationary copy from remaining in the card when
                // the original badge takes off.
                Color.clear
                    .frame(width: 42, height: 42)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Text(AppLocalized.resource(mode == .usb ? "USB" : "connection_wifi"))
                    .zTransferTypography(.titleMedium, weight: .bold)
                    .foregroundStyle(ZTransferColors.primaryText)
            }
            .frame(height: 42)
            Spacer().frame(height: mode == .usb ? 20 : 10)
            if mode == .wifi {
                modeTabs
                Spacer().frame(height: 12)
                // Keep both final layouts mounted in one fixed content slot.
                // Only their opacity changes, so STA/AP never flash through a
                // transient empty frame and the card outline/tabs do not move.
                ZStack(alignment: .topLeading) {
                    wirelessModeContent(.ap)
                        .opacity(isSTA ? 0 : 1)
                        .allowsHitTesting(!isSTA)
                        .accessibilityHidden(isSTA)
                    wirelessModeContent(.sta)
                        .opacity(isSTA ? 1 : 0)
                        .allowsHitTesting(isSTA)
                        .accessibilityHidden(!isSTA)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22),
                           value: state.wirelessMode)
            } else {
                if let feedback = usbFeedback {
                    // On narrow phones the instructions and a full readiness
                    // explanation do not fit together. Keep the actionable
                    // error intact instead of truncating it or growing the card.
                    ViewThatFits(in: .vertical) {
                        VStack(alignment: .leading, spacing: 12) {
                            instructions(for: nil)
                            ConnectionFeedback(title: feedback.title, message: feedback.message, lineLimit: nil)
                        }.fixedSize(horizontal: false, vertical: true)
                        ConnectionFeedback(title: feedback.title, message: feedback.message, lineLimit: nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.timingCurve(0.0, 0.0, 0.2, 1.0, duration: 0.22).delay(0.035)),
                            removal: .opacity.animation(.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 0.15))
                        ))
                } else {
                    instructions(for: nil)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(connectionCardBackground)
        .overlay {
            // Android dims with a background wash, not by making text transparent.
            RoundedRectangle(cornerRadius: ConnectionLayout.cardRadius)
                .fill(ZTransferColors.background.opacity(dimmed ? 0.28 : 0))
                .allowsHitTesting(false)
        }
        .allowsHitTesting(!dimmed)
    }

    /// This is the only mode badge instance. It rests over the card header in
    /// the idle state, then the very same view flies to the upper third while
    /// the surface underneath fades. The unselected card's badge fades with
    /// its card, matching Android's external 42dp flying container.
    private var celebrationLayer: some View {
        ConnectionAnimationTimeline(start: celebrationStart, duration: 1.38) { elapsed in
            let values = ConnectionCelebrationValues(
                elapsedMilliseconds: elapsed
            )
            GeometryReader { _ in
                let scene = connectionCelebrationEase(values.hero)
                // The card now owns a hosting boundary. Its local SwiftUI
                // global space is not the screen used by the hero destination.
                let cardFrame = cardWindowFrame
                let start = CGPoint(x: 14 + 21, y: 16 + 21)
                let targetX = UIScreen.main.bounds.midX - cardFrame.minX
                let targetY = UIScreen.main.bounds.height / 3 - cardFrame.minY
                let travelX = targetX - start.x
                let travelY = targetY - start.y
                let heroScene = selected ? scene : 0
                let arc = sin(heroScene * .pi) * 10
                let translation = CGSize(
                    width: travelX * heroScene,
                    height: travelY * heroScene - arc
                )
                let success = values.success > 0 && selected

                if success {
                    ConnectionSuccessOverlay(progress: values.success,
                                             previewPremium: previewPremiumCelebration)
                        .frame(width: 220, height: 220)
                        .position(x: start.x, y: start.y)
                        .offset(translation)
                }

                // Android places the free pulse behind the badge so the mode
                // glyph remains crisp while the rings expand past its edge.
                modeBadge(success: success)
                    .scaleEffect(1 + heroScene * 1.12)
                    .opacity(selected ? 1 : 1 - scene)
                    .position(x: start.x, y: start.y)
                    .offset(translation)
            }
        }
        .allowsHitTesting(false)
    }

    private func instructions(for wirelessMode: WirelessMode?) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(steps(for: wirelessMode).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .zTransferTypography(.labelSmall, weight: .bold)
                        .foregroundStyle(accent)
                        .frame(width: 21, height: 21)
                        .background(accent.opacity(0.14), in: Circle())
                    Text(step)
                        .zTransferTypography(.bodySmall, weight: .medium)
                        .foregroundStyle(ZTransferColors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func modeBadge(success: Bool) -> some View {
        let badgeAccent = success ? ZTransferColors.statusConnected : accent
        return Group {
            if mode == .usb { ClassicUSBIcon(tint: accent) }
            else { Image(systemName: ZTransferIcon.wifi).font(.system(size: 22, weight: .bold)).foregroundStyle(accent) }
        }
        .frame(width: 22, height: 22)
        .frame(width: 42, height: 42)
        .background {
            ZTransferButtonMaterialSurface(
                skin: .init(storedValue: skinPreset),
                cornerRadius: 13,
                active: success,
                activeColor: badgeAccent,
                textureSeed: ZTransferTextureKey.stableSeed(mode == .usb ? "connection-badge-usb" : "connection-badge-wifi")
            )
            .overlay(RoundedRectangle(cornerRadius: 13)
                .fill(badgeAccent.opacity(0.08)))
        }
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(badgeAccent.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder private var connectionCardBackground: some View {
        let skin = ZTransferButtonSkin(storedValue: skinPreset)
        let dark = colorScheme == .dark
        if skin == .frostedGlass || skin == .liquidGlass {
            ZTransferGlassSurface(cornerRadius: ConnectionLayout.cardRadius,
                                  kind: .connection, tint: accent.opacity(0.018))
        } else {
            let base: Color = switch skin {
            case .titanium: dark ? Color(red: 0.137, green: 0.157, blue: 0.173)
                                     : Color(red: 0.949, green: 0.957, blue: 0.961)
            case .wood: dark ? Color(red: 0.149, green: 0.118, blue: 0.094)
                                : Color(red: 1, green: 0.976, blue: 0.941)
            case .cameraControls: dark ? Color(red: 0.098, green: 0.106, blue: 0.114)
                                          : Color(red: 0.949, green: 0.953, blue: 0.953)
            case .frostedGlass, .liquidGlass: .clear
            }
            let edgeTop: Color = switch skin {
            case .titanium: dark ? .white.opacity(0.36) : Color(red: 0.678, green: 0.725, blue: 0.749).opacity(0.48)
            case .wood: dark ? Color(red: 0.91, green: 0.745, blue: 0.482).opacity(0.38)
                             : Color(red: 0.784, green: 0.561, blue: 0.263).opacity(0.42)
            case .cameraControls: dark ? Color(red: 0.816, green: 0.835, blue: 0.843).opacity(0.32)
                                       : Color(red: 0.384, green: 0.420, blue: 0.439).opacity(0.36)
            case .frostedGlass, .liquidGlass: .clear
            }
            RoundedRectangle(cornerRadius: ConnectionLayout.cardRadius, style: .continuous)
                .fill(base)
                .overlay(RoundedRectangle(cornerRadius: ConnectionLayout.cardRadius)
                    .fill(accent.opacity(0.018)))
                .overlay(RoundedRectangle(cornerRadius: ConnectionLayout.cardRadius)
                    .fill(LinearGradient(colors: [edgeTop.opacity(0.20), .clear, .black.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: ConnectionLayout.cardRadius)
                    .strokeBorder(LinearGradient(colors: [edgeTop, .black.opacity(dark ? 0.52 : 0.30)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.9))
                .shadow(color: .black.opacity(0.20), radius: skin == .cameraControls ? 5.5 : 5, y: 3)
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 2) {
            ForEach(WirelessMode.allCases, id: \.self) { item in
                Button { onWirelessModeChanged?(item) } label: {
                    Text(item == .sta ? "STA" : "AP")
                        .zTransferTypography(.labelSmall, weight: item == state.wirelessMode ? .bold : .medium)
                        .foregroundStyle(item == state.wirelessMode ? accent : ZTransferColors.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(item == state.wirelessMode ? accent.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(ZTransferColors.primaryText.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18),
                   value: state.wirelessMode)
    }

    private func wirelessModeContent(_ wirelessMode: WirelessMode) -> some View {
        let feedback = ConnectionCardWirelessFeedback.resolve(
            state, mode: wirelessMode, showAPProbing: showAPProbing)
        return VStack(alignment: .leading, spacing: 0) {
            // Android's weight(1f) slot must consume only the space left by the
            // header/tabs/footer. A flexible frame alone still propagates the
            // long English text's minimum height and can push those controls.
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Group {
                        if let feedback {
                            ConnectionFeedback(title: feedback.title, message: feedback.message,
                                lineLimit: 3, titleLineLimit: 2, verticalPadding: 5,
                                textSpacing: 0, accent: feedback.accent, busy: feedback.busy)
                        } else {
                            instructions(for: wirelessMode)
                        }
                    }
                    .id(feedback)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.timingCurve(0, 0, 0.2, 1, duration: 0.22).delay(0.05)),
                        removal: .opacity.animation(.timingCurve(0.4, 0, 1, 1, duration: 0.13))
                    ))
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22), value: feedback)
            }
            wirelessFooter(for: wirelessMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func wirelessFooter(for wirelessMode: WirelessMode) -> some View {
        if wirelessMode == .sta {
            VStack(spacing: 8) {
                HStack {
                    TipLightbulbButton(
                        attention: !staHelpViewed, size: 34,
                        accessibilityLabel: AppLocalized.resource("tip_sta_title")
                    ) {
                        onSTAHelpRequested?()
                    }
                    .tipPopupAnchor(.sta)
                    Spacer(minLength: 0)
                    Button { onResetSTAPairing?() } label: {
                      ZStack {
                        utilityIcon("link", tint: staResetIconColor)
                        Path { p in p.move(to: CGPoint(x: 9, y: 9)); p.addLine(to: CGPoint(x: 25, y: 25)) }
                            .stroke(staResetIconColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                      }.frame(width: 34, height: 34)
                    }.buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 11))
                     .disabled(state.wifiPhase == .connected)
                     .accessibilityLabel(AppLocalized.resource("sta_reset_pairing"))
                }
                Button(action: { onConnect?() }) {
                    ButtonStateLabel(text: staButtonState.title, rank: staButtonState.rawValue,
                                     color: materialForeground, active: isSTA && !dimmed)
                        .frame(height: ZTransferTypography.labelLarge.lineHeight)
                        .frame(maxWidth: .infinity).frame(height: 42)
                }
                .buttonStyle(ZTransferGlassButtonStyle(
                    cornerRadius: 14,
                    liquidGlassBoundary: true,
                    // Android keeps CONNECTED at full opacity while disabling
                    // repeat taps; don't dim the whole label mid-transition.
                    disabledAlpha: 1
                ))
                .accessibilityLabel(staButtonState.title)
                .accessibilityIdentifier("sta-connect-control")
                .disabled(state.wifiPhase == .connected)
            }
        } else {
            HStack(spacing: 8) {
                TipLightbulbButton(
                    attention: !apHelpViewed, size: 36,
                    accessibilityLabel: AppLocalized.resource("tip_title")
                ) {
                    onAPHelpRequested?()
                }
                .tipPopupAnchor(.ap)
                Spacer(minLength: 0)
            }
        }
    }

    private func utilityIcon(_ name: String, tint: Color, size: CGFloat = 34) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint).frame(width: size, height: size)
    }

    private var staButtonState: STAConnectButtonState { .init(state.wifiPhase) }
    private var usbFeedback: (title: String, message: String)? {
        guard mode == .usb, case let .failed(message) = state.usbPhase else { return nil }
        return (AppLocalized.resource("connection_failed_short"), message)
    }

}

/// Stores the complete static card subtree as content and refreshes only its
/// three exit properties. The former page-level timeline rebuilt both cards,
/// GPS and every control on each display tick.
private struct ConnectionCardSurfaceTimeline<Content: View>: View {
    let start: Date?
    @ViewBuilder let content: Content

    var body: some View {
        ConnectionAnimationTimeline(start: start, duration: 0.62) { elapsed in
            let hero = CGFloat(min(1, max(0, elapsed / 620)))
            content.modifier(ConnectionCelebrationModifier(progress: hero))
        }
    }
}

func connectionCelebrationElapsed(start: Date?, now: Date) -> Double {
    start.map { max(0, now.timeIntervalSince($0) * 1_000) } ?? 0
}

/// Mirrors HomeScreen.kt's selected-card exit treatment. Both cards fade and
/// drift down together; the selected mode badge is rendered by
/// `celebrationLayer` so it can remain visible above the fading surface.
private struct ConnectionCelebrationModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        let scene = connectionCelebrationEase(progress)
        content
            .scaleEffect(1 - scene * 0.045)
            .offset(y: scene * 8)
            .opacity(1 - scene)
    }
}

/// HomeScreen.kt applies a smootherstep to the shared linear hero clock at the
/// card boundary. Keeping the same curve here avoids a platform-specific
/// double easing and preserves the Android start/end velocities.
func connectionCelebrationEase(_ value: CGFloat) -> CGFloat {
    let x = min(1, max(0, value))
    return x * x * (3 - 2 * x)
}

/// The free Android success branch emits two green rings from the flying mode
/// badge. Canvas keeps the pulse independent from SwiftUI layout and matches
/// the Android radii, stagger, fade-in and stroke widths in points.
private struct ConnectionSuccessOverlay: View {
    let progress: CGFloat
    // Capture once per mounted success effect; a refund must not restart it.
    @State private var goldBurst: Bool

    init(progress: CGFloat, previewPremium: Bool) {
        self.progress = progress
        _goldBurst = State(initialValue: previewPremium || PremiumAccess.shared.isPro)
    }

    var body: some View {
        ConnectionSuccessArtwork(progress: progress, goldBurst: goldBurst)
            .zIndex(goldBurst ? 1 : -1)
    }
}

/// HomeScreen.kt 73b81a56: all premium light layers settle to transparency.
/// Keep Float operations for the same smoothstep tail as Android.
func premiumConnectionEffectFade(_ progress: CGFloat) -> CGFloat {
    let tail = min(1, max(0, (Float(progress) - 0.62) / 0.38))
    return CGFloat(1 - tail * tail * (3 - 2 * tail))
}

/// Drawing-only leaf shared by the real celebration and pixel regressions.
/// Entitlement capture, the single flying badge and the finite clock stay in
/// their existing owners; this layer does not create a timer or another badge.
struct ConnectionSuccessArtwork: View {
    let progress: CGFloat
    let goldBurst: Bool

    var body: some View {
        Canvas { context, size in
            let p = min(1, max(0, progress))
            guard p > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            if goldBurst {
                guard p < 1 else { return }
                drawPremium(context: &context, size: size, progress: p)
                return
            }
            let startRadius: CGFloat = 42
            let endRadius: CGFloat = 102

            for index in 0..<2 {
                let ringProgress = min(1, max(0, (p - CGFloat(index) * 0.14) / 0.82))
                let visibility: CGFloat
                if ringProgress <= 0 || ringProgress >= 1 {
                    visibility = 0
                } else {
                    let appear = min(1, max(0, ringProgress / 0.10))
                    visibility = appear * (1 - ringProgress)
                }
                guard visibility > 0 else { continue }

                let radius = startRadius + (endRadius - startRadius) * ringProgress
                let strength: CGFloat = index == 0 ? 1 : 0.84
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                var ring = Path()
                ring.addEllipse(in: rect)
                context.stroke(
                    ring,
                    with: .color(ZTransferColors.statusConnected.opacity(
                        0.12 * visibility * strength
                    )),
                    lineWidth: 5.2 - 2.2 * ringProgress
                )
                context.stroke(
                    ring,
                    with: .color(ZTransferColors.statusConnected.opacity(
                        0.68 * visibility * strength
                    )),
                    lineWidth: 1.9 - 0.8 * ringProgress
                )
            }
        }
    }

    /// HomeScreen.kt drawPremiumSuccessEffect + the original confirmation
    /// rings, particles and core. Preserves the confirmed iOS 620 + 760 ms
    /// clock (docs/技术调研/iOS-连接成功动画性能优化.md).
    private func drawPremium(context: inout GraphicsContext, size: CGSize, progress p: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dimension = min(size.width, size.height)
        let gold = Color(red: 1, green: 214 / 255.0, blue: 107 / 255.0)
        let warm = Color(red: 240 / 255.0, green: 169 / 255.0, blue: 59 / 255.0)
        let green = ZTransferColors.statusConnected
        let fade = premiumConnectionEffectFade(p)
        let visibility = min(1, p / 0.16) * fade
        let halo = max(0, sin(min(p, 0.72) / 0.72 * .pi))
        func circle(_ at: CGPoint, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
        }
        func glow(_ radius: CGFloat, color: Color, alpha: Double) {
            context.fill(circle(center, radius), with: .radialGradient(
                Gradient(colors: [color.opacity(alpha), .clear]),
                center: center, startRadius: 0, endRadius: radius))
        }
        glow(dimension * (0.16 + p * 0.16), color: gold, alpha: 0.12 * halo * fade)
        glow(dimension * (0.24 + p * 0.12), color: warm, alpha: 0.07 * halo * fade)
        let orbit = dimension * (0.22 + p * 0.10)
        for index in 0..<3 {
            let angle = CGFloat(index * 120 + 8) - 32 + p * 118
            var arc = Path()
            arc.addArc(center: center, radius: orbit, startAngle: .degrees(angle),
                       endAngle: .degrees(angle + 54), clockwise: false)
            context.stroke(arc, with: .color((index == 1 ? gold : warm).opacity((index == 1 ? 0.92 : 0.72) * visibility)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        for index in 0..<6 {
            let phase = min(1, max(0, (p - CGFloat(index) * 0.025) / 0.78))
            let angle = CGFloat(index) * .pi / 3 + phase * 0.28
            let distance = dimension * (0.19 + phase * 0.25)
            let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let sparkleFade = min(1, phase * 5) * (1 - phase)
            let long = CGFloat(index.isMultiple(of: 2) ? 7 : 5) * (0.7 + sparkleFade * 0.6)
            var star = Path()
            star.move(to: CGPoint(x: point.x, y: point.y - long))
            star.addLine(to: CGPoint(x: point.x, y: point.y + long))
            star.move(to: CGPoint(x: point.x - long * 0.42, y: point.y))
            star.addLine(to: CGPoint(x: point.x + long * 0.42, y: point.y))
            context.stroke(star, with: .color((index.isMultiple(of: 2) ? gold : .white).opacity(sparkleFade * 0.95 * fade)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        let reveal = min(1, p * 5)
        for index in 0..<2 {
            let phase = min(1, max(0, (p - CGFloat(index) * 0.14) / 0.72))
            let scale = 0.72 + phase * 1.72
            context.stroke(circle(center, (41 - 0.75) * scale),
                           with: .color(green.opacity((1 - phase) * 0.62 * reveal * fade)), lineWidth: 1.5 * scale)
        }
        for index in 0..<10 {
            let angle = CGFloat(index * 36 + (index.isMultiple(of: 2) ? 7 : -5)) * .pi / 180
            let distance = CGFloat(48 + (index % 3) * 11) * p
            let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let color = index.isMultiple(of: 2) ? Color(red: 1, green: 224 / 255.0, blue: 130 / 255.0) : warm
            context.fill(circle(point, index.isMultiple(of: 3) ? 3 : 2), with: .color(color.opacity(reveal * (1 - p) * fade)))
        }
        let coreScale = 0.82 + p * 0.28
        let coreAlpha = (1 - p) * fade
        glow(39 * coreScale, color: green, alpha: 0.08 * coreAlpha * reveal)
        context.stroke(circle(center, (39 - 0.75) * coreScale),
                       with: .color(green.opacity(0.70 * coreAlpha * reveal)), lineWidth: 1.5 * coreScale)
    }
}

private struct ConnectionFeedback: View {
    let title: String
    let message: String?
    var lineLimit: Int? = 2
    var titleLineLimit: Int? = nil
    var verticalPadding: CGFloat = 7
    var textSpacing: CGFloat = 3
    var accent: Color = ZTransferColors.statusError
    var busy = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        HStack(spacing: 7) {
            if busy {
                // Reuse the Android Material3 head/tail motion and lifecycle.
                if scenePhase == .active {
                    RemoteCameraToolLoading(diameter: 14, strokeWidth: 1.5, color: accent)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            VStack(alignment: .leading, spacing: textSpacing) {
                Text(title).zTransferTypography(.labelSmall, weight: .bold)
                    .foregroundStyle(accent).lineLimit(titleLineLimit)
                if let message {
                    Text(message).zTransferTypography(.labelSmall)
                        .foregroundStyle(ZTransferColors.secondaryText).lineLimit(lineLimit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9).padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
