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
    @State private var presentation = RemoteParameterPresentationCache()
    var body: some View {
        let configuration = presentation.configuration(descriptor: descriptor, autoEnabled: autoEnabled,
            hasAutoControl: autoEnabled != nil && autoToggle != nil)
        let value = autoEnabled == true
            ? effectiveISO.map { presentation.label(.iso, value: $0) } ?? "—"
            : descriptor.map { presentation.label($0.property, value: $0.current) } ?? "—"
        RemoteParameterDrawing(motion: motion, field: field, configuration: configuration,
            autoBusy: autoBusy, value: value, presentation: presentation)
            .frame(maxWidth: .infinity).frame(height: tileHeight)
            .overlay {
                RemoteParameterInput(configuration: configuration, autoBusy: autoBusy,
                    identifier: "remote-parameter-\(field)", label: field.label,
                    value: value,
                    onOpenList: onOpenList, onAutoToggle: autoToggle,
                    onBegin: { motion.begin() }, onDrag: { dy in
                        if let delta = motion.drag(dy) { onStep(delta) }
                    }, onEnd: { motion.end() })
            }
            .onAppear { motion.configure(configuration); motion.setActive(true) }
            .onChange(of: configuration) { next in motion.configure(next) }
            .onDisappear { motion.setActive(false) }
    }
}

/// Android remember(param) and keyed value rows: one anchor lookup per input
/// change, bounded formatting cache across display frames. No observable state.
@MainActor
final class RemoteParameterPresentationCache {
    private var cachedConfiguration: RemoteParameterWheel.Configuration?
    private var property: RemoteProperty?
    private var labels: [UInt64: String] = [:]
    private let format: (RemoteProperty, UInt64) -> String
    init(format: @escaping (RemoteProperty, UInt64) -> String = RemoteExposureParameters.monitorFormat) {
        self.format = format
    }
    func configuration(descriptor: RemotePropertyDescriptor?, autoEnabled: Bool?, hasAutoControl: Bool)
        -> RemoteParameterWheel.Configuration {
        if let cachedConfiguration, cachedConfiguration.descriptor == descriptor,
           cachedConfiguration.autoEnabled == autoEnabled, cachedConfiguration.hasAutoControl == hasAutoControl {
            return cachedConfiguration
        }
        let next = RemoteParameterWheel.Configuration(descriptor: descriptor,
            autoEnabled: autoEnabled, hasAutoControl: hasAutoControl)
        cachedConfiguration = next
        return next
    }
    func label(_ property: RemoteProperty, value: UInt64) -> String {
        if property != self.property { labels.removeAll(keepingCapacity: true); self.property = property }
        if let label = labels[value] { return label }
        // At most five wheel rows are visible; retain a small neighborhood,
        // never the entire camera domain or every AUTO ISO reading over time.
        if labels.count >= 64 { labels.removeAll(keepingCapacity: true) }
        let label = format(property, value)
        labels[value] = label
        return label
    }
}

@MainActor
final class RemoteParameterWheelDriver: NSObject, ObservableObject {
    struct Display: Equatable {
        let dragging: Bool
        let rows: [RemoteParameterWheel.Row]
        let loadingAlpha: Float
        let showsDragHint: Bool
        init(_ wheel: RemoteParameterWheel) {
            dragging = wheel.dragging
            rows = wheel.configuration.writable ? wheel.rows : []
            loadingAlpha = wheel.configuration.descriptor == nil && wheel.configuration.autoEnabled != true
                ? wheel.loadingAlpha : 1
            showsDragHint = wheel.showsDragHint
        }
    }
    private(set) var wheel = RemoteParameterWheel()
    @Published private(set) var display = Display(RemoteParameterWheel())
    private var active = false
    private var link: CADisplayLink?
    var clockRunning: Bool { link != nil }
    private var needsFrames: Bool {
        wheel.position.isRunning || wheel.neighbors.isRunning ||
            (wheel.configuration.descriptor == nil && wheel.configuration.autoEnabled != true)
    }
    func configure(_ configuration: RemoteParameterWheel.Configuration) {
        guard configuration != wheel.configuration else { return }
        wheel.configure(configuration); publish(); schedule()
    }
    func begin() { wheel.beginDrag(); publish(); schedule() }
    func drag(_ dy: CGFloat) -> Int? {
        let delta = wheel.drag(by: Float(dy))
        publish(); schedule()
        return delta
    }
    func end() { wheel.endDrag(); publish(); schedule() }
    func setActive(_ active: Bool) {
        self.active = active
        if !active { wheel.endDrag(); publish() }
        schedule()
    }
    private func publish() {
        let next = Display(wheel)
        if display != next { display = next }
    }
    private func schedule() {
        guard active && needsFrames else { stopClock(); return }
        if link == nil {
            let next = CADisplayLink(target: ClockTarget(self), selector: #selector(ClockTarget.frame(_:)))
            link = next; next.add(to: .main, forMode: .common)
        }
    }
    func advance(_ nanos: Int64) {
        wheel.advance(nanos); publish(); schedule()
    }
    @MainActor private final class ClockTarget: NSObject {
        weak var owner: RemoteParameterWheelDriver?
        init(_ owner: RemoteParameterWheelDriver) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(Int64(link.timestamp * 1_000_000_000))
        }
    }
    private func stopClock() { link?.invalidate(); link = nil }
}

private struct RemoteParameterDrawing: View {
    @ObservedObject var motion: RemoteParameterWheelDriver
    let field: RemoteExposureField
    let configuration: RemoteParameterWheel.Configuration
    let autoBusy: Bool
    let value: String
    let presentation: RemoteParameterPresentationCache
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
                if motion.display.dragging && configuration.writable {
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
                if motion.display.showsDragHint {
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
            valueText(value, geometry)
                .foregroundStyle(ZTransferColors.primaryText)
        } else if configuration.writable, let descriptor = configuration.descriptor {
            ForEach(motion.display.rows, id: \.index) { row in
                valueText(presentation.label(descriptor.property, value: row.value), geometry)
                    .foregroundStyle(ZTransferColors.primaryText).opacity(Double(row.alpha))
                    .scaleEffect(CGFloat(row.scale)).offset(y: CGFloat(row.offset))
            }
        } else {
            valueText(value, geometry)
                .foregroundStyle(ZTransferColors.secondaryText.opacity(configuration.descriptor == nil ? Double(motion.display.loadingAlpha) : 0.5))
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
