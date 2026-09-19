import SwiftUI
import UIKit

/// HomeScreen.kt: measurements use the space inside the system bars. The GPS
/// detail is an overflow layer so expanding it never moves either card or the
/// bottom workbench entry.
struct ConnectionPage: View {
    @ObservedObject var model: ConnectionViewModel
    let effectsStore: PhotoEffectsStore
    @ObservedObject var gpsCoordinator: GPSCoordinator
    let directory: DirectoryAccessStore
    let celebrationStart: Date?
    let onOpenWorkspace: () -> Void
    @Binding var gpsPanelPresented: Bool
    @State private var showSettings = false
    @State private var showSTAReset = false
    @State private var showGPSReset = false
    @State private var showSTATips = false
    @State private var tipsWirelessMode: WirelessMode = .sta
    @AppStorage("sta_connection_help_viewed") private var staHelpViewed = false
    @AppStorage("ap_connection_help_viewed") private var apHelpViewed = false
    @State private var attentionOrigin = Date()
    @State private var connectionHint: PhotoEffectsHint?

    var body: some View {
        pageBody()
    }

    @ViewBuilder
    private func pageBody() -> some View {
        ZStack {
            GeometryReader { proxy in
                let layout = ConnectionLayout(size: proxy.size)
                ZStack(alignment: .topLeading) {
                    ZTransferColors.background.ignoresSafeArea()
                    HStack(alignment: .top, spacing: ConnectionLayout.cardSpacing) {
                    VStack(alignment: .leading, spacing: ConnectionLayout.gpsSpacing) {
                        ConnectionMethodCard(
                            mode: .usb, state: model.state,
                            height: layout.usbHeight,
                            dimmed: gpsCoordinator.state.enabled,
                            attentionActive: model.cameraSession == nil && !gpsCoordinator.state.enabled,
                            attentionOrigin: attentionOrigin,
                            selected: model.cameraSession?.isUSB == true,
                            celebrationStart: celebrationStart)
                            .modifier(GPSBlockedConnectionCard(
                                blocked: gpsCoordinator.state.enabled,
                                onBlockedTap: showGPSConnectionBlockedHint
                            ))
                        ConnectionSceneFadeTimeline(start: celebrationStart) {
                            GPSConnectionControl(
                                coordinator: gpsCoordinator,
                                expanded: $gpsPanelPresented,
                                showingResetPairing: $showGPSReset,
                                availableHeight: max(1, proxy.size.height - layout.gpsTop)
                            )
                        }
                    }
                    .frame(width: layout.cardWidth)
                    .zIndex(1)
                    ConnectionMethodCard(
                        mode: .wifi, state: model.state,
                        height: layout.wifiHeight,
                        dimmed: gpsCoordinator.state.enabled,
                        attentionActive: model.cameraSession == nil && !gpsCoordinator.state.enabled,
                        attentionOrigin: attentionOrigin,
                        selected: model.cameraSession != nil && model.cameraSession?.isUSB == false,
                        celebrationStart: celebrationStart,
                        onWirelessModeChanged: model.select(wirelessMode:),
                        onConnect: { Task { await model.connectSelectedWiFi() } },
                        onResetSTAPairing: { Task { await model.refreshSTAProfiles(); showSTAReset = true } },
                        onSTAHelpRequested: {
                            tipsWirelessMode = .sta
                            staHelpViewed = true
                            showSTATips = true
                        },
                        onSTAHotspotSettings: {
                            model.cancelWiFiConnection()
                            openWirelessSettings(.sta)
                        },
                        onAPHelpRequested: {
                            tipsWirelessMode = .ap
                            apHelpViewed = true
                            showSTATips = true
                        },
                        onAPHotspotSettings: {
                            model.cancelWiFiConnection()
                            openWirelessSettings(.ap)
                        },
                        staHelpViewed: staHelpViewed,
                        apHelpViewed: apHelpViewed)
                        .frame(width: layout.cardWidth)
                        .modifier(GPSBlockedConnectionCard(
                            blocked: gpsCoordinator.state.enabled,
                            onBlockedTap: showGPSConnectionBlockedHint
                        ))
                    }
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, layout.cardsTop)

                    ConnectionSceneFadeTimeline(start: celebrationStart) {
                        HStack(spacing: 8) {
                            Button {
                                ZTransferHaptics.shared.tick()
                                showSettings = true
                            } label: {
                                DoubleZMark(tint: ZTransferColors.primaryText)
                                    .frame(width: 20 * DoubleZMark.aspectRatio, height: 20)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                            }
                            .buttonStyle(ZTransferGlassButtonStyle(
                                cornerRadius: 22,
                                materialContentColor: ZTransferColors.accentYellow,
                                prominentPressFeedback: true
                            ))
                            .geniePopupAnchor(.settings)
                            .accessibilityIdentifier("popup-trigger-settings")
                            #if DEBUG
                            Button { model.connectDebugSimulator() } label: {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 40, height: 36)
                            }
                            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                            .accessibilityIdentifier("debug-photo-library")
                            #endif
                        }
                        .padding(.leading, 12)
                        .padding(.top, 6)
                    }
                }
                .overlay(alignment: .bottom) {
                    ConnectionSceneFadeTimeline(start: celebrationStart) {
                        ConnectionWorkspaceButton(
                            enabled: !gpsCoordinator.state.enabled,
                            action: onOpenWorkspace,
                        )
                        .padding(.bottom, 18)
                    }
                }
            }

            // Keep the scrim outside the safe-area-constrained page overlay.
            // This lets it dim the complete application surface while the
            // page's measured card positions remain unchanged.
            if showSTAReset {
                ConnectionSceneFadeTimeline(start: celebrationStart) {
                    STAResetPairingOverlay(count: model.pairedCameraCount, models: model.pairedCameraModels,
                        onConfirm: { showSTAReset = false; Task { await model.resetSTAPairing() } },
                        onDismiss: { showSTAReset = false })
                    .ignoresSafeArea()
                }
            }
            if showGPSReset {
                ConnectionSceneFadeTimeline(start: celebrationStart) {
                    GPSResetPairingOverlay(
                        onConfirm: {
                            showGPSReset = false
                            gpsCoordinator.clearPairing()
                        },
                        onDismiss: { showGPSReset = false }
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .overlayPreferenceValue(TipPopupAnchorPreferenceKey.self) { anchors in
            TipPopupLayer(isPresented: showSTATips) {
                if let anchor = anchors[tipsWirelessMode == .sta ? .sta : .ap] {
                    ConnectionSceneFadeTimeline(start: celebrationStart) {
                        STATipsOverlay(isPresented: $showSTATips, wirelessMode: tipsWirelessMode, anchor: anchor)
                            .ignoresSafeArea()
                    }
                }
            }
        }
        .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
            if let anchor = anchors[.settings] {
                ConnectionSceneFadeTimeline(start: celebrationStart) {
                    SettingsPopupOverlay(
                        isPresented: $showSettings,
                        showPhotoEffectsEntry: false,
                        effectsStore: effectsStore,
                        directory: directory,
                        anchor: anchor,
                        effectPreviewSource: nil,
                        effectPreviewExif: nil,
                        onEffectPreviewRequested: {}
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .photoEffectsHint($connectionHint, duration: 1.8)
        .onChange(of: gpsCoordinator.state.enabled) { enabled in
            if !enabled { attentionOrigin = Date() }
        }
        // HomeScreen resets the STA guide after a failed discovery so the
        // next attempt can surface the same one-shot entry point again. Keep
        // the persisted unread flag in sync with that boundary; AP and GPS
        // guides remain permanently quiet once acknowledged.
        .onChange(of: model.state.wifiPhase) { phase in
            guard model.state.wirelessMode == .sta else { return }
            switch phase {
            case .failed:
                if staHelpViewed { staHelpViewed = false }
            case .connected:
                if !staHelpViewed { staHelpViewed = true }
            default:
                break
            }
        }
        .task(id: celebrationStart) {
            guard let celebrationStart else { return }
            // HomeScreen fires CONFIRM after the 620ms connection hero delay.
            let remaining = max(0, 0.62 - Date().timeIntervalSince(celebrationStart))
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, model.cameraSession != nil else { return }
            ZTransferHaptics.shared.success()
        }
        .onChange(of: model.state.hapticOutcome(connectedViaUSB: model.cameraSession?.isUSB)) { outcome in
            if outcome.isFailure { ZTransferHaptics.shared.failure() }
        }
    }

    private func showGPSConnectionBlockedHint() {
        connectionHint = PhotoEffectsHint(resource: "gps_close_before_connect")
    }

    /// Android opens the phone's hotspot settings for STA and Wi‑Fi settings
    /// for AP. iOS has no public deep-link API for either page, so try the
    /// corresponding system route and fall back to the app settings page if
    /// the installed iOS version rejects that route.
    private func openWirelessSettings(_ mode: WirelessMode) {
        let route = mode == .sta ? "App-Prefs:root=INTERNET_TETHERING" : "App-Prefs:root=WIFI"
        guard let url = URL(string: route) else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened, let fallback = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(fallback)
        }
    }
}

private struct GPSBlockedConnectionCard: ViewModifier {
    let blocked: Bool
    let onBlockedTap: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if blocked {
                RoundedRectangle(cornerRadius: ConnectionLayout.cardRadius, style: .continuous)
                    .fill(Color.clear)
                    .contentShape(RoundedRectangle(
                        cornerRadius: ConnectionLayout.cardRadius,
                        style: .continuous
                    ))
                    .onTapGesture(perform: onBlockedTap)
            }
        }
    }
}

/// Keeps each non-card branch mounted as a static subtree while updating only
/// its Android-matched scene opacity from the shared absolute celebration
/// clock. Independent display callbacks cannot drift because no local clock or
/// accumulated progress is used.
private struct ConnectionSceneFadeTimeline<Content: View>: View {
    let start: Date?
    @ViewBuilder let content: Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: start == nil)) { context in
            let elapsed = connectionCelebrationElapsed(start: start, now: context.date)
            let hero = CGFloat(min(1, max(0, elapsed / 620)))
            content.opacity(1 - connectionCelebrationEase(hero))
        }
    }
}

/// The selected-card hero runs first; once the icon is at its destination the
/// success effect plays behind it. The final 220 ms is owned by RootView's
/// cross-fade into the photo list.
struct ConnectionCelebrationValues: Equatable {
    let hero: CGFloat
    let success: CGFloat

    init(elapsedMilliseconds: Double) {
        let heroDuration = 620.0
        let successDelay = 620.0
        let successDuration = 760.0
        let heroLinear = min(1, max(0, elapsedMilliseconds / heroDuration))
        let successLinear = min(1, max(0, (elapsedMilliseconds - successDelay) / successDuration))
        // HomeScreen.kt exposes the hero clock linearly and applies its
        // smootherstep once inside ConnectionMethodCard. Keep the raw clock
        // here so the iOS card uses the same single easing stage.
        hero = CGFloat(heroLinear)
        // Android's FastOutSlowInEasing is cubic-bezier(0.4, 0, 0.2, 1).
        success = CGFloat(Self.fastOutSlowIn(successLinear))
    }

    private static func fastOutSlowIn(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        // Solve the cubic's x component for t, then evaluate its y component.
        // Binary search is stable at the endpoints and avoids UIKit timing
        // abstractions that use a different curve on older iOS versions.
        func component(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if component(mid, 0.4, 0.2) < x { low = mid } else { high = mid }
        }
        return component((low + high) / 2, 0.0, 1.0)
    }
}

struct ConnectionLayout {
    static let cardSpacing: CGFloat = 12
    static let gpsSpacing: CGFloat = 10
    static let gpsHeight: CGFloat = 50
    static let cardRadius: CGFloat = 24
    let horizontalPadding: CGFloat
    let cardWidth: CGFloat
    let cardsTop: CGFloat
    // 296 dp in the Android reference maps to 310 pt on the iPhone 14
    // screenshot scale; this keeps the measured physical card height equal.
    let wifiHeight: CGFloat = 310
    var usbHeight: CGFloat { wifiHeight - Self.gpsSpacing - Self.gpsHeight }
    var gpsTop: CGFloat { cardsTop + usbHeight + Self.gpsSpacing }

    init(size: CGSize) {
        horizontalPadding = size.width < 360 ? 14 : 20
        cardWidth = max(0, (size.width - horizontalPadding * 2 - Self.cardSpacing) / 2)
        // HomeScreen.kt: 56 top toolbar, measured 310 pt iOS card, 44 + 18 bottom entry.
        let spacerRoom = max(0, size.height - 56 - wifiHeight - 62)
        let proportionalSpacer = spacerRoom * (0.28 / 1.28)
        cardsTop = 56 + proportionalSpacer * 0.94
    }
}

private struct ConnectionWorkspaceButton: View {
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: ZTransferIcon.workspace)
                    .font(.system(size: 18)).frame(width: 18, height: 18)
                    .foregroundStyle(ZTransferColors.accentBlue)
                Spacer().frame(width: 8)
                Text(AppLocalized.resource("photo_effects"))
                    .zTransferTypography(.labelLarge, weight: .semibold)
                    .foregroundStyle(ZTransferColors.primaryText)
                Spacer().frame(width: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium)).frame(width: 18, height: 18)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .fixedSize(horizontal: true, vertical: false)
    }
}
