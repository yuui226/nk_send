import SwiftUI

struct RootView: View {
    @StateObject private var connectionModel = ConnectionViewModel()
    @StateObject private var effectsStore = PhotoEffectsStore()
    @StateObject private var gpsCoordinator = GPSCoordinator()
    @StateObject private var directoryStore = DirectoryAccessStore()
    @State private var transferQueue = TransferQueue()
    @AppStorage("themeMode") private var themeMode = "自动"
    var body: some View {
        Group {
            if let session = connectionModel.cameraSession {
                PhotoListView(session: session, queue: transferQueue, directory: directoryStore) {
                    Task { await connectionModel.disconnectCamera() }
                }
            } else {
                ConnectionPage(model: connectionModel, effectsStore: effectsStore, gpsCoordinator: gpsCoordinator, directory: directoryStore)
            }
        }
        .preferredColorScheme(themeMode == "深色" ? .dark : themeMode == "浅色" ? .light : nil)
        .task {
            connectionModel.startUSBDiscovery()
            connectionModel.startWiFiDiscovery()
        }
        .onDisappear {
            connectionModel.stopUSBDiscovery()
            connectionModel.stopWiFiDiscovery()
        }
    }
}

private struct ConnectionPage: View {
    @ObservedObject var model: ConnectionViewModel
    let effectsStore: PhotoEffectsStore
    let gpsCoordinator: GPSCoordinator
    let directory: DirectoryAccessStore
    @State private var showSettings = false
    @State private var showWorkspace = false
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ZTransferColors.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer().frame(height: max(112, proxy.size.height * 0.12))
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 10) {
                            ConnectionMethodCard(mode: .usb, phase: model.state.usbPhase,
                                                 dimmed: gpsCoordinator.state.enabled,
                                                 onConnect: { Task { await model.connectSelectedUSB() } })
                            GpsButton(coordinator: gpsCoordinator)
                        }
                            ConnectionMethodCard(mode: .wifi, phase: model.state.usbPhase,
                                             wifiPhase: model.state.wifiPhase,
                                             dimmed: gpsCoordinator.state.enabled,
                                             wirelessMode: model.state.wirelessMode,
                                             onWirelessModeChanged: { model.select(wirelessMode: $0) },
                                             onConnect: { Task { await model.connectSelectedWiFi() } })
                    }
                    .padding(.horizontal, proxy.size.width < 380 ? 14 : 20)
                    Spacer(minLength: 0)
                    WorkspaceButton { showWorkspace = true }.padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button { showSettings = true } label: {
                    DoubleZMark().fill(ZTransferColors.primaryText).frame(width: 38, height: 22)
                        .frame(height: 36).padding(.horizontal, 14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.7), lineWidth: 1))
                }.buttonStyle(.plain).padding(.leading, 12).padding(.top, 8)
            }
        }
            .sheet(isPresented: $showSettings) { SettingsView(showPhotoEffectsEntry: false, effectsStore: effectsStore, directory: directory) }
            .sheet(isPresented: $showWorkspace) { LocalPhotoEffectsView() }
    }
}

private struct ConnectionMethodCard: View {
    let mode: CameraConnectionMode
    let phase: USBConnectionPhase
    var wifiPhase: WiFiConnectionPhase = .idle
    var dimmed = false
    var wirelessMode: WirelessMode = .sta
    var onWirelessModeChanged: ((WirelessMode) -> Void)?
    var onConnect: (() -> Void)?
    private var accent: Color { mode == .usb ? ZTransferColors.accentOrange : ZTransferColors.accentBlue }
    private var title: String { mode == .usb ? "USB" : "Wi-Fi" }
    private var steps: [String] { mode == .usb ? ["相机电源开启", "使用 USB 数据线连接相机与手机"] : (wirelessMode == .sta ? ["相机连接到手机发起的热点", "点击 连接相机"] : ["相机开启「与智能设备建立 Wi-Fi 连接」", "手机 Wi-Fi 连接到相机的热点"]) }
    var body: some View {
        TimelineView(.animation) { context in
            let period = 2.4
            let rawPhase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let phase = (rawPhase + (mode == .usb ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
            let smooth: CGFloat = {
                let x = max(0, min(1, phase))
                func smoother(_ value: Double) -> Double {
                    let value = max(0, min(1, value))
                    return value * value * value * (value * (value * 6 - 15) + 10)
                }
                if x < 0.38 { return CGFloat(smoother(x / 0.38)) }
                if x < 0.82 { return CGFloat(1 - smoother((x - 0.38) / 0.44)) }
                return 0
            }()
            let breath = 1 + smooth * 0.04
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 42, height: 42)
                    Text(title).zTransferText(size: ZTransferMetrics.title, weight: .bold)
                }
                if mode == .wifi {
                    HStack(spacing: 0) {
                        ForEach(WirelessMode.allCases, id: \.self) { item in
                            Button(item == .sta ? "STA" : "AP") { onWirelessModeChanged?(item) }
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(item == wirelessMode ? accent : ZTransferColors.secondaryText)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(item == wirelessMode ? accent.opacity(0.14) : .clear, in: Capsule())
                        }
                    }.padding(3).background(Color.black.opacity(0.045), in: Capsule())
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.system(size: 15, weight: .bold)).foregroundStyle(accent).frame(width: 34, height: 34).background(accent.opacity(0.12), in: Circle())
                        Text(step).zTransferText(size: 16, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if mode == .wifi {
                    Spacer(minLength: 2)
                    HStack(spacing: 10) { Image(systemName: "lightbulb.fill"); Image(systemName: "link.badge.plus"); Image(systemName: ZTransferIcon.settings) }.font(.system(size: 20, weight: .semibold)).foregroundStyle(accent).frame(maxWidth: .infinity).padding(.top, 4)
                    Button("连接相机", action: { onConnect?() })
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ZTransferColors.primaryText)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        // Wi‑Fi has no iOS transport yet. Keep Android's button in
                        // the same position, but never present a dead enabled action.
                        .disabled(onConnect == nil)
                        .opacity(onConnect == nil ? 0.45 : 1)
                }
                if mode == .usb, let usbStatus { Text(usbStatus).zTransferText(size: ZTransferMetrics.caption, weight: .semibold).foregroundStyle(accent) }
                if mode == .wifi, let status = wifiStatus { Text(status).zTransferText(size: ZTransferMetrics.caption, weight: .semibold).foregroundStyle(accent) }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: mode == .usb ? 236 : 296)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: ZTransferMetrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ZTransferMetrics.cardRadius).stroke(accent.opacity(0.12), lineWidth: 1)
                Group {
                    if mode == .usb {
                        ClassicUSBIcon(tint: accent)
                    } else {
                        Image(systemName: ZTransferIcon.wifi).font(.system(size: 24, weight: .semibold)).foregroundStyle(accent)
                    }
                }
                .frame(width: 42, height: 42)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(accent.opacity(0.35), lineWidth: 1.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 14).padding(.top, 16)
            }
            .scaleEffect(breath)
            .opacity(dimmed ? 0.52 : 1)
            .allowsHitTesting(!dimmed)
        }
    }

    private var usbStatus: String? {
        switch phase {
        case .unavailable, .waitingForCamera: return nil
        case .connecting: return "正在连接"
        case .connected: return "连接成功"
        case let .failed(message): return message
        }
    }

    private var wifiStatus: String? {
        switch wifiPhase {
        case .unavailable, .idle: return nil
        case .discovering: return "正在搜索"
        case .connecting: return "正在连接"
        case .connected: return "连接成功"
        case .failed(let message): return message
        }
    }
}

private struct GpsButton: View {
    @ObservedObject var coordinator: GPSCoordinator
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                let pulse = coordinator.state.enabled ? 0.05 + 0.05 * CGFloat((sin(phase * 2 * .pi) + 1) / 2) : 0
                Button { withAnimation(ZTransferMotion.standard) { expanded.toggle() } } label: {
                    Text("GPS").zTransferText(size: 20, weight: .bold)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background((coordinator.state.enabled ? ZTransferColors.accentBlue : ZTransferColors.background).opacity(coordinator.state.enabled ? 0.12 + pulse : 0.55), in: Capsule())
                        .overlay(Capsule().stroke((coordinator.state.enabled ? ZTransferColors.accentBlue : Color.white).opacity(0.55), lineWidth: 1))
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

private struct WorkspaceButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { HStack(spacing: 9) { Image(systemName: ZTransferIcon.workspace).foregroundStyle(ZTransferColors.accentBlue); Text("滤镜·边框·水印").zTransferText(size: 18, weight: .semibold); Image(systemName: "chevron.down").foregroundStyle(ZTransferColors.secondaryText) }.padding(.horizontal, 24).frame(maxWidth: 500).frame(height: 44).background(.thinMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.65), lineWidth: 1)) }.buttonStyle(.plain)
    }
}
