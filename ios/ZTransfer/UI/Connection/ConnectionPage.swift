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
    @State private var showSettings = false
    @State private var showSTAReset = false
    @State private var showSTATips = false
    @State private var tipsWirelessMode: WirelessMode = .sta
    @State private var tipsAnchor: CGRect = .zero
    @AppStorage("sta_connection_help_viewed") private var staHelpViewed = false
    @AppStorage("ap_connection_help_viewed") private var apHelpViewed = false
    @State private var attentionOrigin = Date()
    @State private var settingsAnchor: CGRect = .zero

    var body: some View {
        TimelineView(.animation(paused: celebrationStart == nil)) { context in
            let elapsed = celebrationStart.map {
                max(0, context.date.timeIntervalSince($0) * 1_000)
            } ?? 0
            pageBody(celebration: ConnectionCelebrationValues(elapsedMilliseconds: elapsed))
        }
    }

    @ViewBuilder
    private func pageBody(celebration: ConnectionCelebrationValues) -> some View {
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
                            success: celebration.success > 0 && model.cameraSession?.isUSB == true,
                            selectionSceneProgress: celebration.hero,
                            successEffectProgress: celebration.success)
                        GPSConnectionControl(coordinator: gpsCoordinator)
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
                        success: celebration.success > 0 && model.cameraSession != nil && model.cameraSession?.isUSB == false,
                        selectionSceneProgress: celebration.hero,
                        successEffectProgress: celebration.success,
                        onWirelessModeChanged: model.select(wirelessMode:),
                        onConnect: { Task { await model.connectSelectedWiFi() } },
                        onResetSTAPairing: { Task { await model.refreshSTAProfiles(); showSTAReset = true } },
                        onSTAHelpRequested: { anchor in
                            tipsAnchor = anchor
                            tipsWirelessMode = .sta
                            staHelpViewed = true
                            showSTATips = true
                        },
                        onSTAHotspotSettings: {
                            model.cancelWiFiConnection()
                            openWirelessSettings(.sta)
                        },
                        onAPHelpRequested: { anchor in
                            tipsAnchor = anchor
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
                    }
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, layout.cardsTop)

                    Button { showSettings = true } label: {
                        DoubleZMark(tint: ZTransferColors.primaryText)
                            .frame(width: 20 * DoubleZMark.aspectRatio, height: 20)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                    }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                    .padding(.leading, 12)
                    .padding(.top, 6)
                    .background {
                        GeometryReader { anchor in
                            Color.clear.preference(key: SettingsAnchorPreferenceKey.self,
                                                   value: anchor.frame(in: .global))
                        }
                    }

                }
                .overlay(alignment: .bottom) {
                    ConnectionWorkspaceButton(
                        enabled: !gpsCoordinator.state.enabled,
                        action: onOpenWorkspace,
                    )
                        .padding(.bottom, 18)
                }
                .onPreferenceChange(SettingsAnchorPreferenceKey.self) { settingsAnchor = $0 }
            }

            // Keep the scrim outside the safe-area-constrained page overlay.
            // This lets it dim the complete application surface while the
            // page's measured card positions remain unchanged.
            if showSTAReset {
                STAResetPairingOverlay(count: model.pairedCameraCount, models: model.pairedCameraModels,
                    onConfirm: { showSTAReset = false; Task { await model.resetSTAPairing() } },
                    onDismiss: { showSTAReset = false })
                    .ignoresSafeArea()
            }
            if showSettings {
                SettingsPopupOverlay(
                    isPresented: $showSettings,
                    showPhotoEffectsEntry: false,
                    effectsStore: effectsStore,
                    directory: directory,
                    anchor: settingsAnchor,
                    effectPreviewSource: nil,
                    effectPreviewExif: nil,
                    onEffectPreviewRequested: {}
                )
                .ignoresSafeArea()
            }
            if showSTATips {
                STATipsOverlay(isPresented: $showSTATips, wirelessMode: tipsWirelessMode, anchor: tipsAnchor)
                    .ignoresSafeArea()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: gpsCoordinator.state.enabled) { enabled in
            if !enabled { attentionOrigin = Date() }
        }
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

/// Timing copied from HomeScreen.kt.  The first 500 ms is the selected-card
/// hero flight; the following 760 ms is the success effect before navigation.
struct ConnectionCelebrationValues: Equatable {
    let hero: CGFloat
    let success: CGFloat

    init(elapsedMilliseconds: Double) {
        let heroDuration = 620.0
        let successDelay = 500.0
        let successDuration = 760.0
        let heroLinear = min(1, max(0, elapsedMilliseconds / heroDuration))
        let successLinear = min(1, max(0, (elapsedMilliseconds - successDelay) / successDuration))
        hero = CGFloat(Self.smoother(heroLinear))
        // Android's FastOutSlowInEasing is cubic-bezier(0.4, 0, 0.2, 1).
        success = CGFloat(Self.fastOutSlowIn(successLinear))
    }

    private static func smoother(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
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

private struct SettingsAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
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
