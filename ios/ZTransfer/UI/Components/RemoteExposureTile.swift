import SwiftUI
import UIKit

/// RemoteScreen.ParamTile: independent camera wheel, AUTO tap region, and
/// compact (<44dp) typography. Behavior/verification: iOS 1.93 ledger, N09.
struct RemoteExposureTile: View {
    let field: RemoteExposureField
    let descriptor: RemotePropertyDescriptor?
    let onOpenList: () -> Void
    let onStep: (Int) -> Void
    var autoEnabled: Bool? = nil
    var autoToggle: (() -> Void)? = nil
    var autoBusy = false
    var effectiveISO: UInt64? = nil
    var tileHeight: CGFloat = 54
    // Only the tile drawing subscribes to display frames, not the monitor.
    @State private var motion = RemoteParameterWheelDriver()
    private var configuration: RemoteParameterWheel.Configuration {
        .init(descriptor: descriptor, autoEnabled: autoEnabled,
              hasAutoControl: autoEnabled != nil && autoToggle != nil)
    }
    var body: some View {
        RemoteParameterDrawing(motion: motion, field: field, configuration: configuration,
            autoBusy: autoBusy, effectiveISO: effectiveISO)
            .frame(maxWidth: .infinity).frame(height: tileHeight)
            .overlay {
                RemoteParameterInput(configuration: configuration, autoBusy: autoBusy,
                    identifier: "remote-parameter-\(field)", label: field.label,
                    value: autoEnabled == true ? effectiveISO.map { RemoteExposureParameters.monitorFormat(.iso, raw: $0) } ?? "—"
                        : descriptor.map { RemoteExposureParameters.monitorFormat($0.property, raw: $0.current) } ?? "—",
                    onOpenList: onOpenList, onAutoToggle: autoToggle,
                    onBegin: { motion.begin() }, onDrag: { dy in
                        if let delta = motion.drag(dy) { onStep(delta) }
                    }, onEnd: { motion.end() })
            }
            .onAppear { motion.configure(configuration) }
            .onChange(of: configuration) { next in motion.configure(next) }
            .onDisappear { motion.stop() }
    }
}

@MainActor
private final class RemoteParameterWheelDriver: NSObject, ObservableObject {
    @Published private(set) var wheel = RemoteParameterWheel()
    private var link: CADisplayLink?
    func configure(_ configuration: RemoteParameterWheel.Configuration) {
        wheel.configure(configuration); schedule()
    }
    func begin() { wheel.beginDrag(); schedule() }
    func drag(_ dy: CGFloat) -> Int? { wheel.drag(by: Float(dy)) }
    func end() { wheel.endDrag(); schedule() }
    private func schedule() {
        if wheel.needsFrames, link == nil {
            let next = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link = next; next.add(to: .main, forMode: .common)
        }
    }
    @objc private func frame(_ link: CADisplayLink) {
        wheel.advance(Int64(link.timestamp * 1_000_000_000))
        if !wheel.needsFrames { stopClock() }
    }
    private func stopClock() { link?.invalidate(); link = nil }
    func stop() { wheel.endDrag(); stopClock() }
}

private struct RemoteParameterDrawing: View {
    @ObservedObject var motion: RemoteParameterWheelDriver
    let field: RemoteExposureField
    let configuration: RemoteParameterWheel.Configuration
    let autoBusy: Bool
    let effectiveISO: UInt64?
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }
    var body: some View {
        GeometryReader { proxy in
            let geometry = RemoteParameterTileGeometry(width: proxy.size.width, height: proxy.size.height)
            let shape = RoundedRectangle(cornerRadius: 14, style: .circular)
            ZStack {
                shape.fill(dark ? Color(white: 30 / 255).opacity(0.45) : .white.opacity(0.85))
                shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.60), .white.opacity(dark ? 0.04 : 0.10)],
                    startPoint: .top, endPoint: .bottom))
                if motion.wheel.dragging && configuration.writable {
                    shape.strokeBorder(ZTransferColors.accentBlue, lineWidth: 1.5)
                } else {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.4 : 0.95),
                        dark ? .white.opacity(0.1) : .black.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                Text(field.label).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ZTransferColors.secondaryText.opacity(configuration.valueWritable || configuration.hasAutoControl ? 0.85 : 0.4))
                    .padding(.leading, 10).padding(.top, geometry.labelTop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if configuration.hasAutoControl {
                    autoBadge(geometry).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                } else if configuration.descriptor != nil && !configuration.valueWritable && configuration.autoEnabled == nil {
                    RemoteEditorIcon(kind: .lock).fill(ZTransferColors.secondaryText.opacity(0.55))
                        .frame(width: 11, height: 11).padding(.trailing, 8).padding(.top, geometry.labelTop)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if motion.wheel.showsDragHint {
                    RemoteParameterDragHint().stroke(ZTransferColors.secondaryText.opacity(0.42),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        .frame(width: 6, height: 20).padding(.trailing, 8)
                        .padding(.bottom, configuration.hasAutoControl ? 5 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: configuration.hasAutoControl ? .bottomTrailing : .trailing)
                }
                values(geometry)
            }.clipShape(shape)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func valueText(_ text: String, _ geometry: RemoteParameterTileGeometry) -> some View {
        Text(text).font(.system(size: geometry.valueFontSize, weight: .semibold, design: .monospaced))
            .lineLimit(1).fixedSize().frame(height: geometry.valueLineHeight)
    }
    @ViewBuilder private func values(_ geometry: RemoteParameterTileGeometry) -> some View {
        if configuration.autoEnabled == true {
            valueText(effectiveISO.map { RemoteExposureParameters.monitorFormat(.iso, raw: $0) } ?? "—", geometry)
                .foregroundStyle(ZTransferColors.primaryText)
        } else if configuration.writable, let descriptor = configuration.descriptor {
            ForEach(motion.wheel.rows, id: \.index) { row in
                valueText(RemoteExposureParameters.monitorFormat(descriptor.property, raw: row.value), geometry)
                    .foregroundStyle(ZTransferColors.primaryText).opacity(Double(row.alpha))
                    .scaleEffect(CGFloat(row.scale)).offset(y: CGFloat(row.offset))
            }
        } else {
            valueText(configuration.descriptor.map { RemoteExposureParameters.monitorFormat($0.property, raw: $0.current) } ?? "—", geometry)
                .foregroundStyle(ZTransferColors.secondaryText.opacity(configuration.descriptor == nil ? Double(motion.wheel.loadingAlpha) : 0.5))
        }
    }
    private func autoBadge(_ geometry: RemoteParameterTileGeometry) -> some View {
        let on = configuration.autoEnabled == true
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 6, style: .circular)
        let background = on ? Color(red: 1, green: 193 / 255, blue: 7 / 255).opacity(0.90)
            : (dark ? Color(white: 45 / 255) : Color(red: 233 / 255, green: 233 / 255, blue: 238 / 255)).opacity(0.85)
        return Text("AUTO").font(.system(size: geometry.autoBadgeFontSize, weight: .medium))
            .foregroundStyle(on ? .black.opacity(0.75) : ZTransferColors.secondaryText)
            .frame(width: geometry.autoBadgeWidth, height: geometry.autoBadgeHeight)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(dark ? .white.opacity(0.15) : .black.opacity(0.10), lineWidth: 0.75))
            .opacity(autoBusy ? 0.5 : 1)
    }
}

private struct RemoteParameterDragHint: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.5, y: 3)); path.addLine(to: CGPoint(x: rect.midX, y: 0.5))
        path.addLine(to: CGPoint(x: rect.width - 0.5, y: 3))
        path.move(to: CGPoint(x: 0.5, y: rect.height - 3)); path.addLine(to: CGPoint(x: rect.midX, y: rect.height - 0.5))
        path.addLine(to: CGPoint(x: rect.width - 0.5, y: rect.height - 3))
        return path
    }
}

private extension RemoteExposureField {
    var label: String {
        switch self {
        case .exposureCompensation: return "EV"
        case .iso: return "ISO"
        case .aperture: return "f"
        case .shutter: return "S"
        }
    }
}
