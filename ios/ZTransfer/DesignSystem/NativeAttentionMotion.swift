import SwiftUI
import UIKit

/// Android's graphicsLayer attention effects, executed by Core Animation rather
/// than publishing a new SwiftUI layout graph on every display frame.
struct NativeAttentionConfiguration: Equatable {
    enum Kind: Equatable {
        case card(offset: Double)
        case opacityPulse(minimum: Double, maximum: Double, halfPeriod: Double)
        case scalePulse(minimum: Double, maximum: Double, halfPeriod: Double)
    }
    var kind: Kind
    var origin: Date
    var enabled: Bool
    var paused: Bool
    var frozenDate: Date? = nil

    func scale(at date: Date, intensity: Double = 1) -> Double {
        let elapsed = max(0, date.timeIntervalSince(origin))
        switch kind {
        case let .card(offset):
            return 1 + 0.04 * Self.cardWave(elapsed / 2.4 + offset) * intensity
        case .opacityPulse:
            return 1
        case let .scalePulse(minimum, maximum, halfPeriod):
            guard enabled else { return 1 }
            let phase = (elapsed / halfPeriod).truncatingRemainder(dividingBy: 2)
            let position = phase <= 1 ? phase : 2 - phase
            return Double(ZTransferAndroidMotion.tween(milliseconds: Int64(halfPeriod * 1000))
                .sample(at: Int64(position * halfPeriod * 1_000_000_000),
                        from: Float(minimum), to: Float(maximum), velocity: 0).value)
        }
    }
    func opacity(at date: Date) -> Double {
        guard enabled, case let .opacityPulse(minimum, maximum, halfPeriod) = kind else { return 1 }
        let phase = max(0, date.timeIntervalSince(origin)) / halfPeriod
        let position = phase.truncatingRemainder(dividingBy: 2)
        return minimum + (maximum - minimum) * (position <= 1 ? position : 2 - position)
    }
    static func cardWave(_ phase: Double) -> Double {
        let p = max(0, phase).truncatingRemainder(dividingBy: 1)
        func smoother(_ value: Double) -> Double {
            let x = min(1, max(0, value))
            return x * x * x * (x * (x * 6 - 15) + 10)
        }
        if p < 0.38 { return smoother(p / 0.38) }
        if p < 0.82 { return 1 - smoother((p - 0.38) / 0.44) }
        return 0
    }
}

struct NativeAttentionHost<Content: View>: UIViewRepresentable {
    let configuration: NativeAttentionConfiguration
    var onTipAnchorsChange: (([TipPopupTrigger: CGRect]) -> Void)? = nil
    var onWindowFrameChange: ((CGRect) -> Void)? = nil
    @ViewBuilder let content: Content

    func makeUIView(context: Context) -> NativeAttentionHostView { NativeAttentionHostView() }
    func updateUIView(_ view: NativeAttentionHostView, context: Context) {
        view.onTipAnchorsChange = onTipAnchorsChange
        view.onWindowFrameChange = onWindowFrameChange
        withTransaction(context.transaction) {
            view.host.rootView = AnyView(content.environment(\.self, context.environment)
                .modifier(NativeAttentionAnchorReporter(enabled: onTipAnchorsChange != nil) { [weak view] rects in
                    view?.report(rects)
                }))
        }
        view.configure(configuration)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeAttentionHostView,
                      context: Context) -> CGSize? {
        if let width = proposal.width, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        return uiView.host.sizeThatFits(in: CGSize(width: proposal.width ?? .greatestFiniteMagnitude,
                                                   height: proposal.height ?? .greatestFiniteMagnitude))
    }
    static func dismantleUIView(_ view: NativeAttentionHostView, coordinator: ()) {
        view.stop()
        view.onTipAnchorsChange = nil
        view.onWindowFrameChange = nil
        view.host.willMove(toParent: nil)
        view.host.removeFromParent()
    }
}

private struct NativeAttentionAnchorReporter: ViewModifier {
    let enabled: Bool
    let changed: ([TipPopupTrigger: CGRect]) -> Void
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TipPopupAnchorPreferenceKey.self) { anchors in
            if enabled {
                GeometryReader { proxy in
                    Color.clear.preference(key: NativeAttentionAnchorRects.self,
                                           value: anchors.mapValues { proxy[$0] })
                }.allowsHitTesting(false)
            }
        }.onPreferenceChange(NativeAttentionAnchorRects.self, perform: changed)
    }
}
private struct NativeAttentionAnchorRects: PreferenceKey {
    static var defaultValue: [TipPopupTrigger: CGRect] { [:] }
    static func reduce(value: inout [TipPopupTrigger: CGRect], nextValue: () -> [TipPopupTrigger: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
final class NativeAttentionHostView: UIView {
    // SwiftUI owns its hosting root layer; keep native transforms on a
    // separate transparent UIKit ancestor instead.
    let motionView = UIView()
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    var onTipAnchorsChange: (([TipPopupTrigger: CGRect]) -> Void)?
    var onWindowFrameChange: ((CGRect) -> Void)?
    private var lastWindowFrame: CGRect?
    private var lastRects: [TipPopupTrigger: CGRect] = [:]
    private var configuration: NativeAttentionConfiguration?
    private var intensityFrom = 0.0
    private var intensityTarget = 0.0
    private var intensityStart = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        motionView.backgroundColor = .clear
        motionView.isOpaque = false
        host.view.isOpaque = false
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        addSubview(motionView)
        motionView.addSubview(host.view)
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { stop(); return }
        contentScaleFactor = window.screen.scale
        motionView.contentScaleFactor = window.screen.scale
        host.view.contentScaleFactor = window.screen.scale
        if host.parent == nil {
            var candidate = next
            while let responder = candidate {
                if let parent = responder as? UIViewController {
                    parent.addChild(host); host.didMove(toParent: parent); break
                }
                candidate = responder.next
            }
        }
        if let configuration { install(configuration, now: Date()) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        motionView.bounds = CGRect(origin: .zero, size: bounds.size)
        motionView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        // A presentation transform must never feed back into layout dimensions.
        if host.view.bounds.size != bounds.size { host.view.bounds = CGRect(origin: .zero, size: bounds.size) }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if host.view.center != center { host.view.center = center }
        if window != nil, onWindowFrameChange != nil {
            let frame = convert(bounds, to: nil)
            if frame != lastWindowFrame {
                lastWindowFrame = frame
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lastWindowFrame == frame else { return }
                    self.onWindowFrameChange?(frame)
                }
            }
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        let transform = motionView.layer.presentation()?.affineTransform() ?? motionView.transform
        let center = host.view.center
        let local = CGPoint(x: point.x - center.x, y: point.y - center.y).applying(transform.inverted())
        return host.view.hitTest(CGPoint(x: local.x + host.view.bounds.midX,
                                        y: local.y + host.view.bounds.midY), with: event)
    }
    func report(_ rects: [TipPopupTrigger: CGRect]) {
        guard rects != lastRects else { return }
        lastRects = rects
        // Deliver outside the hosting layout; ignore a superseded measurement.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastRects == rects else { return }
            self.onTipAnchorsChange?(rects)
        }
    }
    func configure(_ next: NativeAttentionConfiguration) {
        guard configuration != next else { return }
        let now = Date()
        if configuration == nil {
            intensityFrom = next.enabled ? 1 : 0
            intensityTarget = intensityFrom
        } else if configuration?.enabled != next.enabled {
            intensityFrom = intensity(at: now)
            intensityTarget = next.enabled ? 1 : 0
            intensityStart = now
        }
        configuration = next
        install(next, now: now)
    }
    private func intensity(at date: Date) -> Double {
        let p = min(1, max(0, date.timeIntervalSince(intensityStart) / 0.32))
        // Same Android FastOutSlowIn curve as the bulb's outbound half-cycle.
        let eased = (TipAttentionValues(elapsed: p * 0.9).buttonScale - 1) / 0.09
        return intensityFrom + (intensityTarget - intensityFrom) * eased
    }
    func stop() { motionView.layer.removeAnimation(forKey: "attention.loop"); motionView.layer.removeAnimation(forKey: "attention.fade") }
    private func install(_ c: NativeAttentionConfiguration, now: Date) {
        stop()
        let layer = motionView.layer
        let date = c.frozenDate ?? now
        let scale = c.scale(at: date, intensity: intensity(at: date))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        layer.opacity = Float(c.opacity(at: date))
        CATransaction.commit()
        guard !c.paused, window != nil else { return }
        let time = layer.convertTime(CACurrentMediaTime(), from: nil)
        if case let .scalePulse(minimum, maximum, halfPeriod) = c.kind {
            guard c.enabled else { return }
            let loop = CABasicAnimation(keyPath: "transform.scale")
            loop.fromValue = minimum; loop.toValue = maximum
            loop.duration = halfPeriod; loop.autoreverses = true
            loop.repeatCount = .infinity
            loop.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            loop.beginTime = time - max(0, now.timeIntervalSince(c.origin))
                .truncatingRemainder(dividingBy: halfPeriod * 2)
            layer.add(loop, forKey: "attention.loop")
            return
        }
        if case let .opacityPulse(minimum, maximum, halfPeriod) = c.kind {
            guard c.enabled else { return }
            let loop = CABasicAnimation(keyPath: "opacity")
            loop.fromValue = minimum
            loop.toValue = maximum
            loop.duration = halfPeriod
            loop.autoreverses = true
            loop.repeatCount = .infinity
            loop.timingFunction = CAMediaTimingFunction(name: .linear)
            loop.beginTime = time - max(0, now.timeIntervalSince(c.origin))
                .truncatingRemainder(dividingBy: halfPeriod * 2)
            layer.add(loop, forKey: "attention.loop")
            return
        }
        let remaining = max(0, 0.32 - now.timeIntervalSince(intensityStart))
        if remaining > 0 {
            let fade = sampled(duration: remaining) { elapsed in
                let date = now.addingTimeInterval(elapsed)
                return c.scale(at: date, intensity: self.intensity(at: date))
            }
            fade.beginTime = time
            layer.add(fade, forKey: "attention.fade")
        }
        guard c.enabled else {
            if remaining > 0 {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            return
        }
        let start = now.addingTimeInterval(remaining)
        let loop = sampled(duration: 2.4) { c.scale(at: start.addingTimeInterval($0)) }
        loop.beginTime = time + remaining
        loop.repeatCount = .infinity
        layer.add(loop, forKey: "attention.loop")
    }
    private func sampled(duration: Double, value: (Double) -> Double) -> CAKeyframeAnimation {
        let count = max(1, Int(ceil(duration * 120)))
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = (0...count).map { value(duration * Double($0) / Double(count)) }
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }
}

/// Android SettingsScreen.rememberGpsEntryAmbientAlpha, including the static
/// expanded/error values. Only the fill layer changes; wheel content stays live.
struct NativeAmbientPulse: Equatable {
    var origin: Date
    var minimum: Double
    var maximum: Double
    var halfPeriod: Double
    var restingOpacity: Double
    var breathing: Bool
    var paused: Bool

    func opacity(at date: Date) -> Double {
        guard breathing else { return restingOpacity }
        let elapsed = max(0, date.timeIntervalSince(origin)) / halfPeriod * 0.9
        let eased = (TipAttentionValues(elapsed: elapsed).buttonScale - 1) / 0.09
        return minimum + (maximum - minimum) * eased
    }

    /// Shared by ambient fills and the monitor's loading glyph. The render
    /// server interpolates opacity; no display link or SwiftUI frame publishing.
    @MainActor
    func install(on layer: CALayer, key: String, visible: Bool) {
        layer.removeAnimation(forKey: key)
        let now = Date()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = Float(opacity(at: now))
        CATransaction.commit()
        guard breathing, !paused, visible else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = minimum; animation.toValue = maximum
        animation.duration = halfPeriod
        animation.autoreverses = true; animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            - max(0, now.timeIntervalSince(origin)).truncatingRemainder(dividingBy: halfPeriod * 2)
        layer.add(animation, forKey: key)
    }
}

struct NativeAmbientFill: UIViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat
    let pulse: NativeAmbientPulse
    func makeUIView(context: Context) -> NativeAmbientFillView { NativeAmbientFillView() }
    func updateUIView(_ view: NativeAmbientFillView, context: Context) {
        view.configure(color: UIColor(color), radius: cornerRadius, pulse: pulse)
    }
    static func dismantleUIView(_ view: NativeAmbientFillView, coordinator: ()) {
        view.layer.removeAnimation(forKey: "ambient.opacity")
    }
}

final class NativeAmbientFillView: UIView {
    private var pulse: NativeAmbientPulse?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    func configure(color: UIColor, radius: CGFloat, pulse: NativeAmbientPulse) {
        backgroundColor = color
        layer.cornerRadius = radius
        guard self.pulse != pulse else { return }
        self.pulse = pulse
        install()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); install() }
    private func install() {
        guard let pulse else { return }
        pulse.install(on: layer, key: "ambient.opacity", visible: window != nil)
    }
}
