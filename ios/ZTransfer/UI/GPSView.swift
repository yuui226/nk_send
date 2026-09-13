import SwiftUI

/// GPS page mirrors Android's stateful control: one enable switch, one update
/// frequency wheel and status details. BLE and location lifecycles are owned by
/// GPSCoordinator, so leaving the page does not silently reset an active session.
struct GPSView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator: GPSCoordinator
    @State private var showingReset = false

    init(coordinator: GPSCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    SettingsCardProxy {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(coordinator.state.enabled ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(AppLocalized.resource("gps_auto_write")).zTransferText(size: ZTransferMetrics.body, weight: .semibold)
                                Text(statusText).zTransferText(size: ZTransferMetrics.caption)
                            }
                            Spacer()
                            Button(AppLocalized.resource(coordinator.state.enabled ? "gps_hold_to_disable" : "gps_enable")) {
                                coordinator.setEnabled(!coordinator.state.enabled)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if coordinator.state.enabled {
                        SettingsCardProxy {
                            DetentWheel(label: AppLocalized.resource("gps_update_frequency_label"),
                                        options: GPSUpdateFrequency.allCases,
                                        selected: coordinator.frequency,
                                        optionLabel: { $0.title },
                                        onCommit: coordinator.setFrequency,
                                        rowHeight: 30)
                            if let name = coordinator.state.cameraName {
                                detailRow(AppLocalized.resource("gps_camera_label"), name)
                            }
                            if let latitude = coordinator.state.latitude, let longitude = coordinator.state.longitude {
                                detailRow(AppLocalized.text("位置"), String(format: "%.5f, %.5f", latitude, longitude))
                            }
                            if let altitude = coordinator.state.altitudeMeters {
                                detailRow(
                                    AppLocalized.resource("gps_altitude_value")
                                        .replacingOccurrences(of: "%1$d", with: "\(Int(altitude.rounded()))"),
                                    "",
                                )
                            }
                            if coordinator.state.status == .error {
                                Button(AppLocalized.resource("gps_retry")) { coordinator.retry() }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            if coordinator.bluetooth.hasSavedPairing {
                                Button(AppLocalized.resource("gps_clear_pairing"), role: .destructive) { showingReset = true }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.horizontal, ZTransferMetrics.pageHorizontal)
                .padding(.vertical, 14)
            }
            .background(ZTransferColors.background.ignoresSafeArea())
            .navigationTitle(AppLocalized.resource("gps_auto_write"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") } } }
            .alert(AppLocalized.resource("gps_clear_pairing_title"), isPresented: $showingReset) {
                Button(AppLocalized.resource("cancel"), role: .cancel) {}
                Button(AppLocalized.resource("gps_clear_pairing"), role: .destructive) { coordinator.bluetooth.clearPairing() }
            } message: {
                Text(AppLocalized.resource("gps_clear_pairing_message"))
            }
        }
    }

    private var statusText: String {
        if let message = coordinator.state.message, coordinator.state.status == .error { return message }
        switch coordinator.state.status {
        case .off: return AppLocalized.resource("gps_enable")
        case .starting, .searching: return AppLocalized.resource("gps_searching")
        case .needsCamera: return coordinator.state.message ?? AppLocalized.resource("gps_need_camera")
        case .connecting: return coordinator.state.message ?? AppLocalized.resource("gps_connecting")
        case .pairing: return AppLocalized.resource("gps_pairing")
        case .cameraConfirm: return AppLocalized.resource("gps_camera_confirm")
        case .pairingSuccess, .connected: return AppLocalized.resource("gps_paired_device_status")
        case .writing, .waitingFix, .ready: return AppLocalized.resource("gps_detail_description")
        case .apUnavailable: return AppLocalized.resource("gps_ap_unavailable")
        case .error: return coordinator.state.message ?? AppLocalized.resource("gps_retry")
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).zTransferText(size: ZTransferMetrics.caption); Spacer(); Text(value).zTransferText(size: ZTransferMetrics.caption, weight: .semibold) }
    }
}

private struct SettingsCardProxy<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 1))
    }
}
