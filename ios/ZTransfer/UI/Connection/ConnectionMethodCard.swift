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
    let success: Bool
    let selectionSceneProgress: CGFloat
    let successEffectProgress: CGFloat
    var onWirelessModeChanged: ((WirelessMode) -> Void)?
    var onConnect: (() -> Void)?
    var onResetSTAPairing: (() -> Void)?
    var onSTAHelpRequested: ((CGRect) -> Void)?
    var onSTAHotspotSettings: (() -> Void)?
    var onAPHelpRequested: ((CGRect) -> Void)?
    var onAPHotspotSettings: (() -> Void)?
    var staHelpViewed = false
    var apHelpViewed = false
    @State private var helpButtonFrame: CGRect = .zero

    private var accent: Color { mode == .usb ? ZTransferColors.accentOrange : ZTransferColors.accentBlue }
    private var isSTA: Bool { state.wirelessMode == .sta }
    private var steps: [String] {
        if mode == .usb { return [AppLocalized.resource("usb_step_power"), AppLocalized.resource("usb_step_cable")] }
        if isSTA { return [AppLocalized.resource("sta_step_phone_hotspot"), AppLocalized.resource("sta_step_connect_camera")] }
        return [AppLocalized.resource("step_camera_wifi"), AppLocalized.resource("step_phone_wifi")]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cardSurface
                // Android keeps the selected mode badge above the card while the
                // rounded card surface fades away. The flying badge and pulse
                // layer below are therefore deliberately outside this modifier.
                .modifier(ConnectionCelebrationModifier(progress: selectionSceneProgress))
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
                modeBadge
                Text(AppLocalized.resource(mode == .usb ? "USB" : "connection_wifi"))
                    .zTransferTypography(.titleMedium, weight: .bold)
                    .foregroundStyle(ZTransferColors.primaryText)
            }
            .frame(height: 42)
            Spacer().frame(height: mode == .usb ? 20 : 10)
            if mode == .wifi {
                modeTabs
                Spacer().frame(height: 12)
            }

            if mode == .wifi && isSTA {
                // Android reserves this slot. Failure replaces the steps inside
                // it, leaving both footer rows and the card outline stationary.
                ZStack(alignment: .topLeading) {
                    if case let .failed(message) = state.wifiPhase {
                        ConnectionFeedback(
                            title: AppLocalized.resource("sta_camera_not_found_short"),
                            message: message
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.timingCurve(0.0, 0.0, 0.2, 1.0, duration: 0.22).delay(0.05)),
                            removal: .opacity.animation(.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 0.13))
                        ))
                    } else {
                        instructions
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.timingCurve(0.0, 0.0, 0.2, 1.0, duration: 0.22).delay(0.05)),
                                removal: .opacity.animation(.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 0.13))
                            ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .animation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.22), value: state.wifiPhase)
            } else {
                instructions
                if let feedback = wifiFeedback {
                    ConnectionFeedback(title: feedback.title, message: feedback.message)
                        .padding(.top, 12)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.timingCurve(0.0, 0.0, 0.2, 1.0, duration: 0.22).delay(0.035)),
                            removal: .opacity.animation(.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 0.15))
                        ))
                }
                Spacer(minLength: 0)
            }
            if mode == .wifi { wirelessFooter }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(ZTransferGlassSurface(cornerRadius: ConnectionLayout.cardRadius,
                                           kind: .connection, tint: accent.opacity(0.018)))
        .overlay {
            // Android dims with a background wash, not by making text transparent.
            RoundedRectangle(cornerRadius: ConnectionLayout.cardRadius)
                .fill(ZTransferColors.background.opacity(dimmed ? 0.28 : 0))
                .allowsHitTesting(false)
        }
        .allowsHitTesting(!dimmed)
    }

    /// Android's selected badge flies from its card origin to the upper third
    /// of the screen while the card itself is fading. Keeping the calculation
    /// in a geometry overlay means the card layout never remeasures during the
    /// celebration, and the same target works for either side of the HStack.
    @ViewBuilder
    private var celebrationLayer: some View {
        GeometryReader { proxy in
            let scene = connectionCelebrationEase(selectionSceneProgress)
            if selected, scene > 0.0001 {
                let cardFrame = proxy.frame(in: .global)
                let start = CGPoint(x: 14 + 21, y: 16 + 21)
                let targetX = UIScreen.main.bounds.midX - cardFrame.minX
                let targetY = UIScreen.main.bounds.height / 3 - cardFrame.minY
                let travelX = targetX - start.x
                let travelY = targetY - start.y
                let arc = sin(scene * .pi) * 10
                let translation = CGSize(
                    width: travelX * scene,
                    height: travelY * scene - arc
                )

                if success {
                    ConnectionSuccessOverlay(progress: successEffectProgress)
                        .frame(width: 220, height: 220)
                        .position(x: start.x, y: start.y)
                        .offset(translation)
                }

                // Android places the free pulse behind the badge so the mode
                // glyph remains crisp while the rings expand past its edge.
                modeBadge
                    .scaleEffect(1 + scene * 1.12)
                    .position(x: start.x, y: start.y)
                    .offset(translation)
            }
        }
        .allowsHitTesting(false)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
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

    private var modeBadge: some View {
        let badgeAccent = success ? ZTransferColors.statusConnected : accent
        return Group {
            if mode == .usb { ClassicUSBIcon(tint: accent) }
            else { Image(systemName: ZTransferIcon.wifi).font(.system(size: 22, weight: .bold)).foregroundStyle(accent) }
        }
        .frame(width: 22, height: 22)
        .frame(width: 42, height: 42)
        .background(badgeAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(badgeAccent.opacity(0.35), lineWidth: 1))
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
    }

    @ViewBuilder private var wirelessFooter: some View {
        if isSTA {
            VStack(spacing: 8) {
                HStack {
                    Button { onSTAHelpRequested?(helpButtonFrame) } label: {
                        ZStack(alignment: .topTrailing) {
                            utilityIcon("lightbulb.fill", tint: ZTransferColors.accentOrange)
                            if !staHelpViewed {
                                Circle()
                                    .fill(ZTransferColors.statusError)
                                    .frame(width: 7, height: 7)
                                    .offset(x: -2, y: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalized.resource("tip_sta_title"))
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { helpButtonFrame = proxy.frame(in: .global) }
                    })
                    Spacer(minLength: 0)
                    Button { onResetSTAPairing?() } label: {
                      ZStack {
                        utilityIcon("link", tint: ZTransferColors.accentOrange)
                        Path { p in p.move(to: CGPoint(x: 9, y: 9)); p.addLine(to: CGPoint(x: 25, y: 25)) }
                            .stroke(ZTransferColors.accentOrange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                      }.frame(width: 34, height: 34)
                    }.buttonStyle(.plain)
                     .disabled(state.wifiPhase == .connected)
                     .accessibilityLabel(AppLocalized.resource("sta_reset_pairing"))
                    Spacer(minLength: 0)
                    Button { onSTAHotspotSettings?() } label: {
                        utilityIcon(ZTransferIcon.settings, tint: ZTransferColors.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.wifiPhase == .connected)
                    .accessibilityLabel(AppLocalized.resource("sta_hotspot_settings_short"))
                }
                Button(action: { onConnect?() }) {
                    Text(staButtonTitle)
                        .zTransferTypography(.labelLarge, weight: .semibold)
                        .foregroundStyle(ZTransferColors.primaryText)
                        .frame(maxWidth: .infinity).frame(height: 42)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
                .disabled(state.wifiPhase == .connected)
            }
        } else {
            HStack(spacing: 8) {
                Button { onAPHelpRequested?(helpButtonFrame) } label: {
                    ZStack(alignment: .topTrailing) {
                        utilityIcon("lightbulb.fill", tint: ZTransferColors.accentOrange, size: 36)
                        if !apHelpViewed {
                            Circle()
                                .fill(ZTransferColors.statusError)
                                .frame(width: 7, height: 7)
                                .offset(x: -2, y: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalized.resource("tip_title"))
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { helpButtonFrame = proxy.frame(in: .global) }
                })
                Button { onAPHotspotSettings?() } label: {
                    Text(AppLocalized.resource("open_wifi_settings"))
                        .zTransferTypography(.labelSmall, weight: .semibold)
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(ZTransferGlassSurface(cornerRadius: 12, kind: .button))
                }
                .buttonStyle(.plain)
                .disabled(dimmed)
            }
        }
    }

    // These existing utility entries still need their Android action flows.
    // Keep them as visual content until the corresponding task is implemented;
    // do not attach invented settings URLs or fake successful pairing actions.
    private func utilityIcon(_ name: String, tint: Color, size: CGFloat = 34) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(ZTransferGlassSurface(cornerRadius: size == 36 ? 12 : 11, kind: .button))
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
    private var wifiFeedback: (title: String, message: String)? {
        guard mode == .wifi, !isSTA else {
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
    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !active || scenePhase != .active)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(origin))
            let phase = (elapsed / 2.4 + offset).truncatingRemainder(dividingBy: 1)
            content.scaleEffect(1 + (active ? 0.04 * attention(phase) : 0))
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
