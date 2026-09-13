import SwiftUI

/// HomeScreen.kt: measurements use the space inside the system bars. The GPS
/// detail is an overflow layer so expanding it never moves either card or the
/// bottom workbench entry.
struct ConnectionPage: View {
    @ObservedObject var model: ConnectionViewModel
    let effectsStore: PhotoEffectsStore
    @ObservedObject var gpsCoordinator: GPSCoordinator
    let directory: DirectoryAccessStore
    let onOpenWorkspace: () -> Void
    @State private var showSettings = false
    @State private var attentionOrigin = Date()
    @State private var settingsAnchor: CGRect = .zero

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let layout = ConnectionLayout(size: proxy.size)
                ZStack(alignment: .topLeading) {
                    ZTransferColors.background.ignoresSafeArea()
                    HStack(alignment: .top, spacing: ConnectionLayout.cardSpacing) {
                    VStack(spacing: ConnectionLayout.gpsSpacing) {
                        ConnectionMethodCard(
                            mode: .usb, state: model.state,
                            height: layout.usbHeight,
                            dimmed: gpsCoordinator.state.enabled,
                            attentionOrigin: attentionOrigin)
                        GPSConnectionControl(coordinator: gpsCoordinator)
                    }
                    .frame(width: layout.cardWidth)
                    .zIndex(1)
                    ConnectionMethodCard(
                        mode: .wifi, state: model.state,
                        height: layout.wifiHeight,
                        dimmed: gpsCoordinator.state.enabled,
                        attentionOrigin: attentionOrigin,
                        onWirelessModeChanged: model.select(wirelessMode:),
                        onConnect: { Task { await model.connectSelectedWiFi() } })
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
            if showSettings {
                SettingsPopupOverlay(
                    isPresented: $showSettings,
                    showPhotoEffectsEntry: false,
                    effectsStore: effectsStore,
                    directory: directory,
                    anchor: settingsAnchor
                )
                .ignoresSafeArea()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: gpsCoordinator.state.enabled) { enabled in
            if !enabled { attentionOrigin = Date() }
        }
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
                Text("滤镜·边框·水印")
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
