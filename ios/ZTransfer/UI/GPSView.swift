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
                                Text("GPS").zTransferText(size: ZTransferMetrics.body, weight: .semibold)
                                Text(statusText).zTransferText(size: ZTransferMetrics.caption)
                            }
                            Spacer()
                            Button(coordinator.state.enabled ? "关闭" : "开启") {
                                coordinator.setEnabled(!coordinator.state.enabled)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if coordinator.state.enabled {
                        SettingsCardProxy {
                            DetentWheel(label: "更新频率",
                                        options: GPSUpdateFrequency.allCases,
                                        selected: coordinator.frequency,
                                        optionLabel: { $0.title },
                                        onCommit: coordinator.setFrequency,
                                        rowHeight: 30)
                            if let name = coordinator.state.cameraName {
                                detailRow("相机", name)
                            }
                            if let latitude = coordinator.state.latitude, let longitude = coordinator.state.longitude {
                                detailRow("位置", String(format: "%.5f, %.5f", latitude, longitude))
                            }
                            if let altitude = coordinator.state.altitudeMeters {
                                detailRow("海拔", String(format: "%.0f m", altitude))
                            }
                            if let accuracy = coordinator.state.accuracyMeters {
                                detailRow("精度", String(format: "%.0f m", accuracy))
                            }
                            if let sent = coordinator.state.lastSentAt {
                                detailRow("上次更新", sent.formatted(date: .omitted, time: .standard))
                            }
                            if coordinator.state.status == .error {
                                Button("重试") { coordinator.retry() }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            if coordinator.bluetooth.hasSavedPairing {
                                Button("清除 GPS 配对", role: .destructive) { showingReset = true }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.horizontal, ZTransferMetrics.pageHorizontal)
                .padding(.vertical, 14)
            }
            .background(ZTransferColors.background.ignoresSafeArea())
            .navigationTitle("GPS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") } } }
            .alert("清除 GPS 配对？", isPresented: $showingReset) {
                Button("取消", role: .cancel) {}
                Button("清除 GPS 配对", role: .destructive) { coordinator.bluetooth.clearPairing() }
            } message: {
                Text("将清除已保存的相机身份，下次使用时需要重新配对。")
            }
        }
    }

    private var statusText: String {
        if let message = coordinator.state.message, coordinator.state.status == .error { return message }
        switch coordinator.state.status {
        case .off: return "GPS 已关闭"
        case .starting, .searching: return "正在寻找相机"
        case .needsCamera: return coordinator.state.message ?? "请打开相机蓝牙"
        case .connecting: return coordinator.state.message ?? "正在连接相机"
        case .pairing, .cameraConfirm: return "正在连接相机"
        case .pairingSuccess, .connected: return "已连接，等待位置更新"
        case .writing: return "已连接，正在写入位置"
        case .waitingFix: return "已连接，等待定位"
        case .ready: return "已连接，自动写入位置"
        case .apUnavailable: return "AP 模式不可用"
        case .error: return coordinator.state.message ?? "GPS 连接失败"
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
