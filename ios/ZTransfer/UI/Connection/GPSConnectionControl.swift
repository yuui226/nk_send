import SwiftUI

struct GPSConnectionControl: View {
    @ObservedObject var coordinator: GPSCoordinator
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                let pulse = coordinator.state.enabled ? 0.05 + 0.05 * CGFloat((sin(phase * 2 * .pi) + 1) / 2) : 0
                Button { withAnimation(ZTransferMotion.standard) { expanded.toggle() } } label: {
                    Text(AppLocalized.resource("gps_auto_write")).zTransferTypography(.titleMedium, weight: .bold)
                        .foregroundStyle(ZTransferColors.primaryText)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background((coordinator.state.enabled ? ZTransferColors.accentBlue : ZTransferColors.background).opacity(coordinator.state.enabled ? 0.12 + pulse : 0.55), in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke((coordinator.state.enabled ? ZTransferColors.accentBlue : Color.white).opacity(0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.8).onEnded { _ in
                        UIPasteboard.general.string = gpsDiagnosticsSnapshot(coordinator)
                    }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            if expanded {
                GPSInlinePanel(coordinator: coordinator)
                    // HomeScreen.kt uses GPS_DETAIL_PANEL_WIDTH = 250.dp and
                    // deliberately places it in an overflow layer. Overlay
                    // keeps the two connection cards at their measured width.
                    .frame(width: 250)
                    .padding(.top, 60)
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.965, anchor: .topLeading))
                                .combined(with: .move(edge: .top)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.975, anchor: .topLeading))
                                .combined(with: .move(edge: .top)),
                        )
                    )
            }
        }
        // Android GpsDetailOverflowLayer uses 260ms enter/220ms exit motion;
        // keep the panel mounted in the overlay so the neighbouring card is
        // never remeasured during either direction.
        .animation(.easeInOut(duration: expanded ? 0.26 : 0.22), value: expanded)
    }
}

@MainActor
private func gpsDiagnosticsSnapshot(_ coordinator: GPSCoordinator) -> String {
    let state = coordinator.state
    let latitude = state.latitude.map { String($0) } ?? "-"
    let longitude = state.longitude.map { String($0) } ?? "-"
    let altitude = state.altitudeMeters.map { String($0) } ?? "-"
    let accuracy = state.accuracyMeters.map { String($0) } ?? "-"
    return [
        "status=\(state.status.rawValue)",
        "enabled=\(state.enabled)",
        "camera=\(state.cameraName ?? "-")",
        "latitude=\(latitude)",
        "longitude=\(longitude)",
        "altitude=\(altitude)",
        "accuracy=\(accuracy)",
        "message=\(state.message ?? "-")",
    ].joined(separator: "\n")
}

private struct GPSInlinePanel: View {
    @ObservedObject var coordinator: GPSCoordinator
    @State private var showingReset = false
    @State private var holdCompleted = false

    private var statusLabel: String {
        switch coordinator.state.status {
        case .off: return AppLocalized.resource("gps_enable")
        case .starting, .searching: return AppLocalized.resource("gps_searching")
        case .needsCamera: return AppLocalized.resource("gps_need_camera")
        case .connecting: return AppLocalized.resource("gps_connecting")
        case .pairing: return AppLocalized.resource("gps_pairing")
        case .cameraConfirm: return AppLocalized.resource("gps_camera_confirm")
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready: return AppLocalized.resource("gps_hold_to_disable")
        case .apUnavailable: return AppLocalized.resource("gps_ap_unavailable")
        case .error: return AppLocalized.resource("gps_retry")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                gpsPreparationRow(icon: "iphone", title: AppLocalized.resource("gps_phone_label"), detail: AppLocalized.resource("gps_phone_ready"))
                gpsPreparationRow(icon: "camera.fill", title: AppLocalized.resource("gps_camera_label"), detail: AppLocalized.resource("gps_camera_ready"), status: coordinator.bluetooth.hasSavedPairing ? AppLocalized.resource("gps_paired_badge") : nil)
            }
            if !coordinator.bluetooth.hasSavedPairing {
                HStack(spacing: 6) {
                    Text(AppLocalized.resource("gps_first_pairing_label"))
                        .zTransferText(size: 12, weight: .bold)
                        .foregroundStyle(ZTransferColors.accentBlue)
                    Text(AppLocalized.resource("gps_first_pairing_path"))
                        .zTransferText(size: 11)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ZTransferColors.accentBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ZTransferColors.accentBlue.opacity(0.22)))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                GeometryReader { geometry in
                    // Android uses weights 0.82 / 0.86 / 1.18 with two 8dp
                    // gaps. Keep those proportions instead of fixing the
                    // leading control to 44pt, which made the panel diverge
                    // on narrow phones.
                    let unit = max(0, geometry.size.width - 16) / 2.86
                    let leadingWidth = unit * 0.82
                    let frequencyWidth = unit * 0.86
                    let actionWidth = unit * 1.18
                    HStack(spacing: 8) {
                        leadingControl(width: leadingWidth, now: context.date)
                            .frame(width: leadingWidth)
                        frequencyControl(width: frequencyWidth, now: context.date)
                            .frame(width: frequencyWidth)
                        statusControl(width: actionWidth)
                            .frame(width: actionWidth)
                    }
                }
            }
            .frame(height: 42)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 1))
        .alert(AppLocalized.resource("gps_clear_pairing_title"), isPresented: $showingReset) {
            Button(AppLocalized.resource("cancel"), role: .cancel) {}
            Button(AppLocalized.resource("gps_clear_pairing"), role: .destructive) { coordinator.clearPairing() }
        } message: {
            Text(AppLocalized.resource("gps_clear_pairing_message"))
        }
    }

    @ViewBuilder
    private func gpsPreparationRow(icon: String, title: String, detail: String, status: String? = nil) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ZTransferColors.accentBlue)
                .frame(width: 30, height: 30)
                .background(ZTransferColors.accentBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).zTransferText(size: 12, weight: .bold).foregroundStyle(ZTransferColors.secondaryText)
                    if let status { Text(status).zTransferText(size: 10, weight: .medium).foregroundStyle(ZTransferColors.accentBlue) }
                }
                Text(detail).zTransferText(size: 14, weight: .medium)
            }
            Spacer(minLength: 0)
        }
    }

    private var requiresHoldToDisable: Bool {
        switch coordinator.state.status {
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready: return coordinator.state.enabled
        default: return false
        }
    }

    @ViewBuilder
    private func leadingControl(width: CGFloat, now: Date) -> some View {
        if !coordinator.state.enabled {
            Button { showingReset = true } label: {
                Image(systemName: "link.slash")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 42)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
            .disabled(!coordinator.bluetooth.hasSavedPairing)
            .opacity(coordinator.bluetooth.hasSavedPairing ? 1 : 0.42)
        } else if requiresHoldToDisable {
            let value = coordinator.state.lastSentAt.map { date in
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                return formatter.string(from: date)
            } ?? "--:--:--"
            DetentWheel(label: "", options: [value], selected: value,
                        optionLabel: { $0 }, onCommit: { _ in }, rowHeight: 16,
                        wheelHeight: 42, readOnly: true, cornerRadius: 14,
                        optionFontSize: 13, accentColor: ZTransferColors.accentBlue,
                        emphasized: coordinator.state.lastSentAt != nil,
                        showEmphasisBorder: false)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func frequencyControl(width: CGFloat, now: Date) -> some View {
        if requiresHoldToDisable {
            let remaining = coordinator.state.lastSentAt.map {
                max(0, Int(ceil(Double(coordinator.frequency.rawValue) - now.timeIntervalSince($0))))
            }
            let text = remaining.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "--:--"
            DetentWheel(label: "", options: [text], selected: text,
                        optionLabel: { $0 }, onCommit: { _ in }, rowHeight: 16,
                        wheelHeight: 42, readOnly: true, cornerRadius: 14,
                        optionFontSize: 13, accentColor: ZTransferColors.statusConnected,
                        emphasized: true, showEmphasisBorder: false)
        } else {
            DetentWheel(label: AppLocalized.resource("gps_update_frequency_label"),
                        options: GPSUpdateFrequency.allCases, selected: coordinator.frequency,
                        optionLabel: { $0.title }, onCommit: coordinator.setFrequency,
                        rowHeight: 16, wheelHeight: 42, enabled: !coordinator.state.enabled,
                        cornerRadius: 14, optionFontSize: 13,
                        accentColor: ZTransferColors.accentBlue)
        }
    }

    private func statusControl(width: CGFloat) -> some View {
        Button(statusLabel) {
            if holdCompleted { holdCompleted = false; return }
            if !coordinator.state.enabled { coordinator.setEnabled(true) }
            else if coordinator.state.status == .error { coordinator.retry() }
            else if !requiresHoldToDisable && coordinator.state.status != .apUnavailable { coordinator.setEnabled(false) }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(ZTransferColors.primaryText)
        .frame(maxWidth: .infinity).frame(height: 42)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ZTransferColors.secondaryText.opacity(0.15)))
        .onLongPressGesture(minimumDuration: 0.7) {
            if coordinator.state.enabled {
                holdCompleted = true
                coordinator.setEnabled(false)
            }
        }
    }
}
