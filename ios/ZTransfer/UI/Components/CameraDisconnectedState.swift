import SwiftUI
import UIKit

/// Uses the same system route/fallback already used by the connection page.
/// iOS may refuse a deep link; that does not change or fake camera state.
@MainActor
enum CameraWirelessSettings {
    static func open(_ mode: WirelessMode) {
        let route = mode == .sta ? "App-Prefs:root=INTERNET_TETHERING" : "App-Prefs:root=WIFI"
        guard let url = URL(string: route) else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened, let fallback = URL(string: UIApplication.openSettingsURLString) else { return }
            DispatchQueue.main.async { UIApplication.shared.open(fallback) }
        }
    }
}

/// Same bar geometry and disconnected strike as Android StaSignalIcon.
struct STASignalIcon: View {
    let connected: Bool
    var tint: Color = ZTransferColors.accentBlue

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 19
            let width = 3.2 * unit, gap = 1.65 * unit
            let bottom = size.height * 0.88
            let start = (size.width - width * 4 - gap * 3) / 2
            for (index, bar) in [5.0, 8, 11, 14].enumerated() {
                let height = bar * unit
                let rect = CGRect(x: start + CGFloat(index) * (width + gap),
                                  y: bottom - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.35 * unit),
                             with: .color(tint.opacity(connected ? 1 : 0.28)))
            }
            if !connected {
                var strike = Path()
                strike.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.12))
                strike.addLine(to: CGPoint(x: size.width * 0.87, y: size.height * 0.88))
                context.stroke(strike, with: .color(tint),
                               style: StrokeStyle(lineWidth: 2.15 * unit, lineCap: .round))
            }
        }
        .accessibilityLabel(AppLocalized.resource(connected ? "sta_signal_connected" : "sta_signal_disconnected_reconnect"))
    }
}

/// No loading indicator supersedes this state when an empty session disconnects.
/// Existing thumbnails remain mounted; this is only the empty-catalog fallback.
struct CameraDisconnectedState: View {
    let mode: CameraPresentationMode
    let onRetrySTA: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            icon.frame(width: 64, height: 64)
            Spacer().frame(height: 16)
            Text(AppLocalized.resource(mode.disconnectedTitle))
                .zTransferTypography(.titleMedium, weight: .medium)
                .foregroundStyle(ZTransferColors.primaryText)
            Spacer().frame(height: 6)
            Text(AppLocalized.resource(mode.disconnectedHint))
                .zTransferTypography(.bodySmall)
                .foregroundStyle(ZTransferColors.secondaryText)
                .multilineTextAlignment(.center)
            if let action = mode.disconnectedAction {
                Spacer().frame(height: 20)
                Button {
                    if mode == .sta { onRetrySTA() }
                    else { CameraWirelessSettings.open(.ap) }
                } label: {
                    HStack(spacing: 6) {
                        if mode == .ap { icon.frame(width: 20, height: 20) }
                        Text(AppLocalized.resource(action))
                            .zTransferTypography(.labelLarge, weight: .medium)
                            .foregroundStyle(ZTransferColors.primaryText)
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
                .accessibilityIdentifier("disconnected-camera-action")
            }
        }
        .accessibilityIdentifier("disconnected-camera-\(mode.rawValue)")
    }

    @ViewBuilder private var icon: some View {
        switch mode {
        case .usb: ClassicUSBIcon(tint: ZTransferColors.statusError)
        case .sta: STASignalIcon(connected: false, tint: ZTransferColors.statusError)
        case .ap:
            Image(systemName: "wifi.slash").resizable().scaledToFit()
                .foregroundStyle(ZTransferColors.statusError)
        }
    }
}

/// Android offline SignalPill: 1→1.09, 550ms FastOutSlowIn, reversing.
/// Remove the animation owner when online, so no idle frame work remains.
struct DisconnectedSignalBreath: ViewModifier {
    let connected: Bool
    func body(content: Content) -> some View {
        if connected { content }
        else { OfflineSignalBreath { content } }
    }
}

private struct OfflineSignalBreath<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var expanded = false
    var body: some View {
        content.scaleEffect(expanded ? 1.09 : 1)
            .onAppear {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.55)
                    .repeatForever(autoreverses: true)) { expanded = true }
            }
    }
}
