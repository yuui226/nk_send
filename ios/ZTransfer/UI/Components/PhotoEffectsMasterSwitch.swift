import SwiftUI
import UIKit

/// SettingsScreen.PhotoEffectsMasterSwitch: 180 ms default Compose tween for
/// position and both Oklab color vectors; interrupted motion starts at display.
struct PhotoEffectsSwitchMotion {
    private(set) var position: ZTransferScalarAnimation
    private(set) var track: ZTransferColorAnimation
    private(set) var thumb: ZTransferColorAnimation
    init(checked: Bool, accent: UInt32, foreground: UInt32, secondary: UInt32) {
        position = .init(value: checked ? 1 : 0)
        track = .init(checked ? accent : (foreground & 0x00FFFFFF) | 0x29000000, durationMilliseconds: 180)
        thumb = .init(checked ? 0xFFFFFFFF : secondary, durationMilliseconds: 180)
    }
    var isRunning: Bool { position.isRunning || track.isRunning || thumb.isRunning }
    mutating func update(checked: Bool, accent: UInt32, foreground: UInt32, secondary: UInt32) {
        position.retarget(checked ? 1 : 0, using: .tween(milliseconds: 180))
        track.retarget(checked ? accent : (foreground & 0x00FFFFFF) | 0x29000000)
        thumb.retarget(checked ? 0xFFFFFFFF : secondary)
    }
    mutating func advance(_ nanos: Int64) {
        position.advance(frameNanos: nanos); track.advance(nanos); thumb.advance(nanos)
    }
    func thumbCenterX(rightToLeft: Bool) -> CGFloat {
        10 + 16 * CGFloat(rightToLeft ? 1 - position.value : position.value)
    }
}

@MainActor
final class PhotoEffectsSwitchClock: NSObject, ObservableObject {
    @Published var motion: PhotoEffectsSwitchMotion?
    private var link: CADisplayLink?
    private var lastInput: (checked: Bool, palette: [UInt32])?
    func update(checked: Bool, palette: [UInt32]) {
        if motion == nil {
            motion = .init(checked: checked, accent: palette[0], foreground: palette[1], secondary: palette[2])
        } else if lastInput?.checked != checked || lastInput?.palette != palette {
            motion?.update(checked: checked, accent: palette[0], foreground: palette[1], secondary: palette[2])
        }
        lastInput = (checked, palette)
        // An unchanged target must still resume an interrupted onDisappear.
        guard motion?.isRunning == true, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { $0.frame($1) }
        link = next; next.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ sender: CADisplayLink) {
        motion?.advance(Int64(sender.timestamp * 1_000_000_000))
        if motion?.isRunning != true { stop() }
    }
    func stop() { link?.invalidate(); link = nil }
}

struct PhotoEffectsMasterSwitch: View {
    let checked: Bool
    let onCheckedChange: (Bool) -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var scheme
    @StateObject private var clock = PhotoEffectsSwitchClock()

    private var palette: [UInt32] {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        return [ZTransferColors.accentOrange, ZTransferColors.primaryText, ZTransferColors.secondaryText].map {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor($0).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return ZTransferAndroidColor.pack(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a))
        }
    }
    private func color(_ argb: UInt32) -> Color {
        Color(.sRGB, red: Double((argb >> 16) & 255) / 255,
              green: Double((argb >> 8) & 255) / 255, blue: Double(argb & 255) / 255,
              opacity: Double(argb >> 24) / 255)
    }
    var body: some View {
        let colors = palette
        let motion = clock.motion ?? .init(checked: checked, accent: colors[0], foreground: colors[1], secondary: colors[2])
        Button {
            ZTransferHaptics.shared.play(.toggle)
            onCheckedChange(!checked)
        } label: {
            Canvas { context, _ in
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 36, height: 20), cornerRadius: 10), with: .color(color(motion.track.value)))
                let center = motion.thumbCenterX(rightToLeft: layoutDirection == .rightToLeft)
                context.fill(Path(ellipseIn: CGRect(x: center - 7, y: 3, width: 14, height: 14)), with: .color(color(motion.thumb.value)))
            }
            .frame(width: 36, height: 20)
            .frame(width: 48, height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(AppLocalized.resource("photo_effects"), isOn: Binding(get: { checked }, set: {
                ZTransferHaptics.shared.play(.toggle); onCheckedChange($0)
            }))
            .accessibilityIdentifier("photo-effects-master-switch")
        }
        .onAppear { clock.update(checked: checked, palette: colors) }
        .onChange(of: checked) { clock.update(checked: $0, palette: palette) }
        .onChange(of: scheme) { _ in clock.update(checked: checked, palette: palette) }
        .onDisappear { clock.stop() }
    }
}
