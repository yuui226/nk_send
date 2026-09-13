import SwiftUI

struct ConnectionMethodCard: View {
    let mode: CameraConnectionMode
    let state: ConnectionState
    let height: CGFloat
    let dimmed: Bool
    let attentionOrigin: Date
    var onWirelessModeChanged: ((WirelessMode) -> Void)?
    var onConnect: (() -> Void)?

    private var accent: Color { mode == .usb ? ZTransferColors.accentOrange : ZTransferColors.accentBlue }
    private var isSTA: Bool { state.wirelessMode == .sta }
    private var attentionActive: Bool {
        guard !dimmed else { return false }
        switch state.usbPhase {
        case .connecting, .connected, .failed: return false
        case .unavailable, .waitingForCamera: return state.wifiPhase != .connected
        }
    }
    private var steps: [String] {
        if mode == .usb { return ["相机电源开启", "使用 USB 数据线连接相机与手机"] }
        if isSTA { return ["相机连接到手机发起的热点", "点击 连接相机"] }
        return ["相机开启「与智能设备建立 Wi-Fi 连接」", "手机 Wi-Fi 连接到相机的热点"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                modeBadge
                Text(mode == .usb ? "USB" : "Wi-Fi")
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
                Group {
                    if case let .failed(message) = state.wifiPhase {
                        ConnectionFeedback(title: "未找到相机", message: message)
                    } else {
                        instructions
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            } else {
                instructions
                if let failure {
                    ConnectionFeedback(title: "连接失败", message: failure)
                        .padding(.top, 12)
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
        .modifier(ConnectionBreathingModifier(active: attentionActive,
                                               origin: attentionOrigin,
                                               offset: mode == .usb ? 0 : 0.5))
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.32), value: dimmed)
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
        Group {
            if mode == .usb { ClassicUSBIcon(tint: accent) }
            else { Image(systemName: ZTransferIcon.wifi).font(.system(size: 22, weight: .bold)).foregroundStyle(accent) }
        }
        .frame(width: 22, height: 22)
        .frame(width: 42, height: 42)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(accent.opacity(0.35), lineWidth: 1))
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
                    utilityIcon("lightbulb.fill", tint: ZTransferColors.accentOrange)
                    Spacer(minLength: 0)
                    ZStack {
                        utilityIcon("link", tint: ZTransferColors.accentOrange)
                        Path { p in p.move(to: CGPoint(x: 9, y: 9)); p.addLine(to: CGPoint(x: 25, y: 25)) }
                            .stroke(ZTransferColors.accentOrange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }.frame(width: 34, height: 34)
                    Spacer(minLength: 0)
                    utilityIcon(ZTransferIcon.settings, tint: ZTransferColors.secondaryText)
                }
                Button(action: { onConnect?() }) {
                    Text(staButtonTitle)
                        .zTransferTypography(.labelLarge, weight: .semibold)
                        .foregroundStyle(ZTransferColors.primaryText)
                        .frame(maxWidth: .infinity).frame(height: 42)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
            }
        } else {
            HStack(spacing: 8) {
                utilityIcon("lightbulb.fill", tint: ZTransferColors.accentOrange, size: 36)
                Text("Wi-Fi 设置")
                    .zTransferTypography(.labelSmall, weight: .semibold)
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(ZTransferGlassSurface(cornerRadius: 12, kind: .button))
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
        case .discovering: return "正在寻找"
        case .connecting: return "正在连接"
        case .connected: return "连接成功"
        case .idle, .unavailable, .failed: return "连接相机"
        }
    }
    private var failure: String? {
        if mode == .usb, case let .failed(message) = state.usbPhase { return message }
        if mode == .wifi, case let .failed(message) = state.wifiPhase { return message }
        return nil
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
