import SwiftUI
import UIKit

private struct RemoteToolTintKey: EnvironmentKey {
    static let defaultValue = ZTransferColors.secondaryText
}
extension EnvironmentValues {
    var remoteToolTint: Color {
        get { self[RemoteToolTintKey.self] }
        set { self[RemoteToolTintKey.self] = newValue }
    }
}

/// Android RemoteScreen.RemoteToolMark: one immutable mark for the toolbar,
/// manager and rotated Dock. Camera MODE's live value/spinner remains separate.
struct RemoteToolMark: View {
    let tool: RemoteTool
    var histogramRGB = false
    var waveformRGB = false
    var falseColor = false
    var grid: RemoteGridMode = .off
    var desqueeze: Double = 1
    var locked = false
    @Environment(\.remoteToolTint) private var tint

    @ViewBuilder var body: some View {
        switch tool {
        case .pictureControl: RemotePictureControlGlyph()
        case .hd: text("HD", 13)
        case .fps: text("FPS", 10.5)
        case .lut: text("LUT", 10)
        case .meter: text("±EV", 10)
        case .computerControl: text("PC", 11)
        case .whiteBalance: text("WB", 11)
        case .focusMode: text("MODE", 9)
        case .audio: material(.volumeUp)
        case .focusArea: material(.focusArea)
        case .lock: material(locked ? .lock : .lockOpen)
        case .desqueeze:
            if desqueeze > 1.001 { text(RemoteDisplayOptions.label(for: desqueeze), 12) }
            else { material(.aspectRatio) }
        case .focusFrame:
            text("AF", 8).frame(width: 20, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint, lineWidth: 1.4))
        case .grid: RemoteFramingGridMark(grid: grid).foregroundStyle(tint).frame(width: 19, height: 19)
        case .histogram, .waveform, .exposure, .level, .rotate:
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(width: tool == .rotate ? 20 : 19, height: tool == .rotate ? 20 : 19)
        }
    }
    private func text(_ value: String, _ size: CGFloat) -> some View {
        Text(value).font(.system(size: size, weight: .bold)).foregroundStyle(tint).lineLimit(1).fixedSize()
    }
    private func material(_ kind: RemoteEditorIcon.Kind) -> some View {
        RemoteEditorIcon(kind: kind).fill(tint).frame(width: 19, height: 19)
    }
    static let rgb = [Color(red: 255/255, green: 98/255, blue: 104/255),
                      Color(red: 99/255, green: 232/255, blue: 154/255),
                      Color(red: 101/255, green: 155/255, blue: 255/255)]
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        switch tool {
        case .histogram:
            let barWidth = (w - 7) / 5, base = h - 2
            for (i, height) in [0.38, 0.62, 0.85, 0.55, 0.28].enumerated() {
                var path = Path()
                let x = 2.5 + CGFloat(i) * (barWidth + 1.5)
                path.move(to: CGPoint(x: x, y: base))
                path.addLine(to: CGPoint(x: x, y: base - base * height))
                context.stroke(path, with: .color(histogramRGB ? Self.rgb[min(i * 3 / 5, 2)] : tint),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        case .waveform:
            var path = Path()
            for (i, fraction) in [0.7, 0.3, 0.6, 0.15, 0.8, 0.4, 0.65].enumerated() {
                let point = CGPoint(x: w * CGFloat(i) / 6, y: h * fraction)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            for i in 0..<(waveformRGB ? 3 : 1) {
                var band = context
                if waveformRGB { band.clip(to: Path(CGRect(x: w * CGFloat(i) / 3, y: 0, width: w / 3, height: h))) }
                band.stroke(path, with: .color(waveformRGB ? Self.rgb[i] : tint),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
        case .exposure:
            if falseColor {
                let colors = [Color(red: 40/255, green: 116/255, blue: 215/255),
                              Color(red: 90/255, green: 190/255, blue: 135/255),
                              Color(red: 241/255, green: 77/255, blue: 77/255)]
                for i in 0..<3 {
                    let rect = CGRect(x: w * CGFloat(i) / 3, y: h * (0.35 - CGFloat(i) * 0.1),
                                      width: w * 0.23, height: h * (0.4 + CGFloat(i) * 0.1))
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(colors[i]))
                }
            } else {
                for i in 0..<5 {
                    let x = w * (CGFloat(i) + 1) / 6, d = h * 0.24
                    var path = Path(); path.move(to: CGPoint(x: x - d, y: h/2 - d))
                    path.addLine(to: CGPoint(x: x + d, y: h/2 + d))
                    context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        case .rotate:
            // ic_monitor_rotate.xml viewport 24: large 270° SVG arc and both arrow wings.
            context.scaleBy(x: w/24, y: h/24)
            var path = Path()
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 8,
                        startAngle: .degrees(45), endAngle: .degrees(315), clockwise: false)
            path.addLine(to: CGPoint(x: 20, y: 8.686))
            path.move(to: CGPoint(x: 20, y: 3.886)); path.addLine(to: CGPoint(x: 20, y: 8.686))
            path.addLine(to: CGPoint(x: 15.2, y: 8.686))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        case .level: drawLevel(in: &context, size: size)
        default: break
        }
    }

    private func drawLevel(in context: inout GraphicsContext, size: CGSize) {
        let left = size.width * 0.08, right = size.width * 0.92
        let top = size.height * 0.24, bottom = size.height * 0.78
        let corner = min(size.width, size.height) * 0.09
        let vialLeft = size.width * 0.34, vialRight = size.width * 0.66
        let vialBottom = size.height * 0.49
        var path = Path()
        path.move(to: CGPoint(x: left + corner, y: top)); path.addLine(to: CGPoint(x: vialLeft, y: top))
        path.addCurve(to: CGPoint(x: vialRight, y: top), control1: CGPoint(x: vialLeft, y: vialBottom),
                      control2: CGPoint(x: vialRight, y: vialBottom))
        path.addLine(to: CGPoint(x: right - corner, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + corner), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - corner))
        path.addQuadCurve(to: CGPoint(x: right - corner, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + corner, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - corner), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top + corner))
        path.addQuadCurve(to: CGPoint(x: left + corner, y: top), control: CGPoint(x: left, y: top)); path.closeSubpath()
        for x in [0.27, 0.73] {
            path.move(to: CGPoint(x: size.width * x, y: top)); path.addLine(to: CGPoint(x: size.width * x, y: bottom))
        }
        context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
    }
}

/// TopIconToggle's palette applies equally to Canvas and physical-material ink.
/// Native liquid glass uses the app's already-approved iOS glass palette.
enum RemoteToolPalette {
    static func mark(skin: ZTransferButtonSkin, dark: Bool, active: Bool, fixed: Bool) -> UInt32 {
        if active {
            switch skin {
            case .titanium, .wood: return dark ? 0xFF80D8FF : 0xFF005B83
            case .cameraControls: return 0xFF80D8FF
            case .frostedGlass, .liquidGlass: return dark ? 0xFF4FC3F7 : 0xFF0277BD
            }
        }
        if fixed && skin != .wood { return dark || skin == .cameraControls ? 0xFFBDD1DD : 0xFF3F6075 }
        switch skin {
        case .titanium: return dark ? 0xFFE4ECEF : 0xFF344149
        case .wood: return dark ? 0xFFF1D6A7 : 0xFF472A18
        case .cameraControls: return 0xFFD5D8DA
        case .frostedGlass, .liquidGlass: return dark ? 0xFFB0B0B0 : 0xFF6E6E73
        }
    }
    static func color(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255,
              blue: Double(value & 255)/255, opacity: Double(value >> 24)/255)
    }
}

@MainActor final class RemoteToolTintMotion: ObservableObject {
    @Published private(set) var value: UInt32
    private var animation: ZTransferColorAnimation
    private var link: CADisplayLink?
    var clockRunning: Bool { link != nil }
    init(_ color: UInt32) { value = color; animation = .init(color, durationMilliseconds: 180) }
    func update(_ color: UInt32) {
        animation.retarget(color)
        guard animation.isRunning, link == nil else { return }
        link = ZTransferDisplayLink.make(owner: self) { $0.advance(Int64($1.timestamp * 1_000_000_000)) }
        link?.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) {
        animation.advance(nanos)
        if value != animation.value { value = animation.value }
        if !animation.isRunning { stop() }
    }
    func stop() { link?.invalidate(); link = nil }
}

struct RemoteMonitorToolButton<Label: View>: View {
    let active: Bool
    let enabled: Bool
    let fixed: Bool
    let preserveContentColors: Bool
    let accessibilityLabel: String
    @ViewBuilder let label: () -> Label
    let action: () -> Void
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let skin = ZTransferButtonSkin(storedValue: skinPreset)
        let target = RemoteToolPalette.mark(skin: skin, dark: scheme == .dark, active: active, fixed: fixed)
        RemoteToolTintScope(target: target) { tint in
            Button(action: action) {
                label().foregroundStyle(tint).environment(\.remoteToolTint, tint)
                    .frame(minWidth: 20, minHeight: 20).frame(width: 36, height: 36)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 18, active: active,
                activeColor: ZTransferColors.accentBlue, activeOutline: true, materialContentColor: tint,
                preserveContentColors: preserveContentColors))
            .disabled(!enabled).accessibilityLabel(accessibilityLabel)
        }
    }
}
private struct RemoteToolTintScope<Content: View>: View {
    let target: UInt32
    @ViewBuilder let content: (Color) -> Content
    @StateObject private var motion: RemoteToolTintMotion
    init(target: UInt32, @ViewBuilder content: @escaping (Color) -> Content) {
        self.target = target; self.content = content
        _motion = StateObject(wrappedValue: RemoteToolTintMotion(target))
    }
    var body: some View {
        content(RemoteToolPalette.color(motion.value))
            .onAppear { motion.update(target) }.onChange(of: target) { motion.update($0) }
            .onDisappear { motion.stop() }
    }
}
