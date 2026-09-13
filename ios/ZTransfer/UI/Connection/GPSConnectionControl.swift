import SwiftUI

struct GPSConnectionControl: View {
    @ObservedObject var coordinator: GPSCoordinator
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                let pulse = coordinator.state.enabled ? 0.05 + 0.05 * CGFloat((sin(phase * 2 * .pi) + 1) / 2) : 0
                Button { withAnimation(ZTransferMotion.standard) { expanded.toggle() } } label: {
                    Text("GPS").zTransferTypography(.titleMedium, weight: .bold)
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
            if expanded {
                GPSInlinePanel(coordinator: coordinator)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
        case .off: return "开启GPS"
        case .starting, .searching: return "正在寻找"
        case .needsCamera: return "打开相机配对"
        case .connecting: return "正在连接"
        case .pairing: return "正在配对"
        case .cameraConfirm: return "相机请按 OK"
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready: return "长按关闭"
        case .apUnavailable: return "AP 模式不可用"
        case .error: return "重试"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("使相机拍照附带位置信息").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
            HStack(spacing: 8) {
                Text("手机").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                Text("开启蓝牙与定位服务").zTransferText(size: ZTransferMetrics.caption)
            }
            HStack(spacing: 8) {
                Text("相机").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                Text("开启蓝牙").zTransferText(size: ZTransferMetrics.caption)
                if coordinator.bluetooth.hasSavedPairing {
                    Text("已配对").zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                }
            }
            if !coordinator.bluetooth.hasSavedPairing {
                Text("首次: 连接至智能设备 → 配对 → 开始配对")
                    .zTransferText(size: ZTransferMetrics.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DetentWheel(label: "频率", options: GPSUpdateFrequency.allCases,
                        selected: coordinator.frequency, optionLabel: { $0.title },
                        onCommit: coordinator.setFrequency, rowHeight: 24,
                        enabled: !coordinator.state.enabled)
            Button(statusLabel) {
                if holdCompleted { holdCompleted = false; return }
                if !coordinator.state.enabled { coordinator.setEnabled(true) }
                else if coordinator.state.status == .error { coordinator.retry() }
                else if !requiresHoldToDisable && coordinator.state.status != .apUnavailable { coordinator.setEnabled(false) }
            }
            .font(.system(size: ZTransferMetrics.caption, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .onLongPressGesture(minimumDuration: 0.7) {
                if coordinator.state.enabled {
                    holdCompleted = true
                    coordinator.setEnabled(false)
                }
            }
            if coordinator.bluetooth.hasSavedPairing {
                Button("清除 GPS 配对", role: .destructive) { showingReset = true }
                    .font(.system(size: ZTransferMetrics.caption, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 1))
        .alert("清除 GPS 配对？", isPresented: $showingReset) {
            Button("取消", role: .cancel) {}
            Button("清除 GPS 配对", role: .destructive) { coordinator.bluetooth.clearPairing() }
        } message: {
            Text("将清除已保存的相机身份，下次使用时需要重新配对。")
        }
    }

    private var requiresHoldToDisable: Bool {
        switch coordinator.state.status {
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready: return coordinator.state.enabled
        default: return false
        }
    }
}
