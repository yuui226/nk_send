import SwiftUI
import UIKit

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
    var onWirelessModeChanged: ((WirelessMode) -> Void)?
    var onConnect: (() -> Void)?
    var onResetSTAPairing: (() -> Void)?
    var onSTAHelpRequested: (() -> Void)?
    var onSTAHotspotSettings: (() -> Void)?
    var onAPHelpRequested: (() -> Void)?
    var onAPHotspotSettings: (() -> Void)?
    var staHelpViewed = false
    var apHelpViewed = false
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.frostedGlass.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { mode == .usb ? ZTransferColors.accentOrange : ZTransferColors.accentBlue }
    private var isSTA: Bool { state.wirelessMode == .sta }
    private var buttonSkin: ZTransferButtonSkin { .init(storedValue: skinPreset) }
    private var materialForeground: Color {
        zTransferButtonForeground(skin: buttonSkin, scheme: colorScheme)
    }
    private var wifiSettingsTextColor: Color {
        buttonSkin == .wood ? materialForeground : ZTransferColors.accentBlue
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
        ZStack(alignment: .topLeading) {
            ConnectionCardSurfaceTimeline(start: celebrationStart) {
                cardSurface
            }
            celebrationLayer
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .modifier(ConnectionBreathingModifier(active: attentionActive,
                                               origin: attentionOrigin,
                                               offset: mode == .usb ? 0 : 0.5))
        .zIndex(selected ? 3 : 0)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.32), value: dimmed)
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
                instructions(for: nil)
                if let feedback = wifiFeedback(for: nil) {
                    ConnectionFeedback(title: feedback.title, message: feedback.message)
                        .padding(.top, 12)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.timingCurve(0.0, 0.0, 0.2, 1.0, duration: 0.22).delay(0.035)),
                            removal: .opacity.animation(.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 0.15))
                        ))
                }
                Spacer(minLength: 0)
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
        TimelineView(.animation(minimumInterval: 1.0 / 120.0,
                                paused: celebrationStart == nil)) { context in
            let values = ConnectionCelebrationValues(
                elapsedMilliseconds: connectionCelebrationElapsed(
                    start: celebrationStart, now: context.date
                )
            )
            GeometryReader { proxy in
                let scene = connectionCelebrationEase(values.hero)
                let cardFrame = proxy.frame(in: .global)
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
                    ConnectionSuccessOverlay(progress: values.success)
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
                activeColor: badgeAccent
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

    @ViewBuilder private func wirelessModeContent(_ wirelessMode: WirelessMode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if wirelessMode == .sta {
                // Android reserves this slot. Failure replaces the steps
                // inside it, leaving both footer rows and the outline fixed.
                ZStack(alignment: .topLeading) {
                    if case let .failed(message) = state.wifiPhase {
                        ConnectionFeedback(
                            title: AppLocalized.resource("sta_camera_not_found_short"),
                            message: message
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.timingCurve(0, 0, 0.2, 1, duration: 0.22).delay(0.05)),
                            removal: .opacity.animation(.timingCurve(0.4, 0, 1, 1, duration: 0.13))
                        ))
                    } else {
                        instructions(for: .sta)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.timingCurve(0, 0, 0.2, 1, duration: 0.22).delay(0.05)),
                                removal: .opacity.animation(.timingCurve(0.4, 0, 1, 1, duration: 0.13))
                            ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22),
                           value: state.wifiPhase)
            } else {
                instructions(for: .ap)
                if let feedback = wifiFeedback(for: .ap) {
                    ConnectionFeedback(title: feedback.title, message: feedback.message)
                        .padding(.top, 12)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.timingCurve(0, 0, 0.2, 1, duration: 0.22).delay(0.035)),
                            removal: .opacity.animation(.timingCurve(0.4, 0, 1, 1, duration: 0.15))
                        ))
                }
                Spacer(minLength: 0)
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
                    Spacer(minLength: 0)
                    Button { onSTAHotspotSettings?() } label: {
                        utilityIcon(ZTransferIcon.settings, tint: ZTransferColors.secondaryText)
                    }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 11))
                    .disabled(state.wifiPhase == .connected)
                    .accessibilityLabel(AppLocalized.resource("sta_hotspot_settings_short"))
                }
                Button(action: { onConnect?() }) {
                    Text(staButtonTitle)
                        .zTransferTypography(.labelLarge, weight: .semibold)
                        .foregroundStyle(materialForeground)
                        .frame(maxWidth: .infinity).frame(height: 42)
                }
                .buttonStyle(ZTransferGlassButtonStyle(
                    cornerRadius: 14,
                    liquidGlassBoundary: true
                ))
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
                Button { onAPHotspotSettings?() } label: {
                    Text(AppLocalized.resource("open_wifi_settings"))
                        .zTransferTypography(.labelSmall, weight: .semibold)
                        .foregroundStyle(wifiSettingsTextColor)
                        .frame(maxWidth: .infinity).frame(height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 12))
                .disabled(dimmed)
            }
        }
    }

    private func utilityIcon(_ name: String, tint: Color, size: CGFloat = 34) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint).frame(width: size, height: size)
    }

    private var staButtonTitle: String {
        switch state.wifiPhase {
        case .discovering: return AppLocalized.resource("sta_status_searching")
        case .pairing: return AppLocalized.resource("sta_status_pairing")
        case .connecting: return AppLocalized.resource("sta_status_connecting")
        case .connected: return AppLocalized.resource("sta_status_connected")
        case .idle, .unavailable, .reconnecting, .failed: return AppLocalized.resource("sta_connect_action")
        }
    }
    private func wifiFeedback(for wirelessMode: WirelessMode?) -> (title: String, message: String)? {
        guard mode == .wifi, wirelessMode != .sta else {
            if mode == .usb, case let .failed(message) = state.usbPhase {
                return (AppLocalized.resource("connection_failed_short"), message)
            }
            return nil
        }
        switch state.wifiPhase {
        case .reconnecting:
            return (AppLocalized.resource("wifi_connection_interrupted"), AppLocalized.resource("wifi_reconnecting"))
        case .failed:
            switch state.wifiFailureKind {
            case .notFound: return (AppLocalized.resource("wifi_camera_not_found"), AppLocalized.resource("wifi_connect_camera"))
            case .refused: return (AppLocalized.resource("wifi_camera_refused"), AppLocalized.resource("wifi_check_camera_connection"))
            case .failed, .none: return (AppLocalized.resource("wifi_camera_connection_failed"), AppLocalized.resource("wifi_restart_camera"))
            }
        default:
            return nil
        }
    }
}

/// Stores the complete static card subtree as content and refreshes only its
/// three exit properties. The former page-level timeline rebuilt both cards,
/// GPS and every control on each display tick.
private struct ConnectionCardSurfaceTimeline<Content: View>: View {
    let start: Date?
    @ViewBuilder let content: Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: start == nil)) { context in
            let elapsed = connectionCelebrationElapsed(start: start, now: context.date)
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

    var body: some View {
        Canvas { context, size in
            let p = min(1, max(0, progress))
            guard p > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
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
}

private struct ConnectionFeedback: View {
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).zTransferTypography(.labelSmall, weight: .bold)
                .foregroundStyle(ZTransferColors.statusError)
            Text(message).zTransferTypography(.labelSmall)
                .foregroundStyle(ZTransferColors.secondaryText).lineLimit(2)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZTransferColors.statusError.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Timeline updates only the transform of the captured content. It no longer
/// rebuilds the card's text/layout/controls on every frame. HomeScreen.kt uses
/// this same 2.4 s smootherstep wave, with Wi-Fi offset by half a cycle.
private struct ConnectionBreathingModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let active: Bool
    let origin: Date
    let offset: Double
    @State private var intensity: CGFloat = 0

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: intensity <= 0.001 || scenePhase != .active)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(origin))
            let phase = (elapsed / 2.4 + offset).truncatingRemainder(dividingBy: 1)
            content.scaleEffect(1 + 0.04 * attention(phase) * intensity)
        }
        .onAppear { intensity = active ? 1 : 0 }
        .onChange(of: active) { enabled in
            // Match Android's dedicated attentionIntensity tween. Keep the
            // timeline alive while the current breath settles instead of
            // snapping both connection cards back to scale 1 when GPS starts.
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.32)) {
                intensity = enabled ? 1 : 0
            }
        }
    }
    private func attention(_ phase: Double) -> Double {
        func smoother(_ value: Double) -> Double {
            let x = min(1, max(0, value))
            return x * x * x * (x * (x * 6 - 15) + 10)
        }
        if phase < 0.38 { return smoother(phase / 0.38) }
        if phase < 0.82 { return 1 - smoother((phase - 0.38) / 0.44) }
        return 0
    }
}
