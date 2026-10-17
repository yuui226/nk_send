import SwiftUI
import UIKit

/// Android ShutterButton's independent animate*AsState channels. Keep focus
/// tied to the accepted model state, not simply to the 300ms timer firing.
struct RemoteShutterMotion {
    private(set) var press = ZTransferScalarAnimation(value: 1)
    private(set) var focus = ZTransferScalarAnimation(value: 1)
    private(set) var size: ZTransferScalarAnimation
    private(set) var corner: ZTransferScalarAnimation
    init(diameter: Float = 76, focusing: Bool = false, recording: Bool = false) {
        size = .init(value: diameter * (recording ? Float(28) / 76 : Float(60) / 76))
        corner = .init(value: diameter * (recording ? Float(7) / 76 : Float(30) / 76))
        focus.reset(to: focusing ? 0.8 : 1)
        press.reset(to: focusing ? 0.95 : 1)
    }
    mutating func configure(held: Bool, focusing: Bool, recording: Bool, diameter: Float) {
        let down = held || focusing
        press.retarget(down ? 0.95 : 1, using: down ? .tween(milliseconds: 100)
            : .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
        focus.retarget(focusing ? 0.8 : 1, using: .tween(milliseconds: 120))
        size.retarget(diameter * (recording ? Float(28) / 76 : Float(60) / 76), using: .tween(milliseconds: 160))
        corner.retarget(diameter * (recording ? Float(7) / 76 : Float(30) / 76), using: .tween(milliseconds: 160))
    }
    var needsFrames: Bool { press.isRunning || focus.isRunning || size.isRunning || corner.isRunning }
    mutating func advance(_ now: Int64) {
        press.advance(frameNanos: now); focus.advance(frameNanos: now)
        size.advance(frameNanos: now); corner.advance(frameNanos: now)
    }
}

struct RemoteShutterGesture {
    enum Action: Equatable { case beginHold, focus, cancelHold, release(Bool), quickTap }
    private(set) var held = false
    private(set) var fired = false
    private var deadline: TimeInterval = 0
    mutating func down(at now: TimeInterval, enabled: Bool) -> [Action] {
        guard enabled, !held else { return [] }
        held = true; fired = false; deadline = now + 0.3
        return [.beginHold]
    }
    mutating func advance(_ now: TimeInterval) -> [Action] {
        guard held, !fired, now >= deadline else { return [] }
        fired = true
        return [.focus]
    }
    mutating func end(inside: Bool) -> [Action] {
        guard held else { return [] }
        held = false
        let action: Action? = fired ? .release(inside) : (inside ? .quickTap : nil)
        fired = false
        return [.cancelHold] + (action.map { [$0] } ?? [])
    }
}

@MainActor
final class RemoteShutterController: NSObject, ObservableObject {
    struct Configuration: Equatable {
        var enabled: Bool
        var capturing: Bool
        var focusing: Bool
        var recording: Bool
        var diameter: CGFloat
    }
    @Published private(set) var motion: RemoteShutterMotion
    private(set) var gesture = RemoteShutterGesture()
    private(set) var configuration: Configuration
    private let haptics: ZTransferHaptics
    var onQuickTap: () -> Void = {}
    var onFocus: () -> Void = {}
    var onRelease: (Bool) -> Void = { _ in }
    private var timer: Task<Void, Never>?
    private var link: CADisplayLink?
    init(configuration: Configuration, haptics: ZTransferHaptics = .shared) {
        self.configuration = configuration; self.haptics = haptics
        motion = .init(diameter: Float(configuration.diameter), focusing: configuration.focusing, recording: configuration.recording)
    }
    func configure(_ next: Configuration) {
        configuration = next
        if !next.enabled || next.capturing { end(inside: false) }
        updateMotion()
    }
    func down() {
        let actions = gesture.down(at: ProcessInfo.processInfo.systemUptime,
                                   enabled: configuration.enabled && !configuration.capturing)
        guard !actions.isEmpty else { return }
        deliver(actions); updateMotion()
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            deliver(gesture.advance(ProcessInfo.processInfo.systemUptime))
            timer = nil
        }
    }
    func end(inside: Bool) {
        timer?.cancel(); timer = nil
        deliver(gesture.end(inside: inside)); updateMotion()
    }
    private func deliver(_ actions: [RemoteShutterGesture.Action]) {
        for action in actions {
            switch action {
            case .beginHold: haptics.startProgressiveHold(durationMilliseconds: 300)
            case .focus:
                haptics.completeLongPress(onFocus)
            case .cancelHold: haptics.cancelProgressiveHold()
            case .release(let fire): onRelease(fire)
            case .quickTap: onQuickTap()
            }
        }
    }
    private func updateMotion() {
        motion.configure(held: gesture.held, focusing: configuration.focusing,
                         recording: configuration.recording, diameter: Float(configuration.diameter))
        if motion.needsFrames, link == nil {
            let next = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link = next; next.add(to: .main, forMode: .common)
        }
    }
    @objc private func frame(_ sender: CADisplayLink) {
        motion.advance(Int64(sender.timestamp * 1_000_000_000))
        if !motion.needsFrames { stopClock() }
    }
    private func stopClock() { link?.invalidate(); link = nil }
    func stop() { end(inside: false); stopClock() }
}

struct RemoteShutterButton: View {
    let capture: RemoteCapturePhase
    let movieMode: Bool
    let enabled: Bool
    let focusing: Bool
    let onQuickTap: () -> Void
    let onFocusStart: () -> Void
    let onRelease: (Bool) -> Void
    let diameter: CGFloat
    @StateObject private var controller: RemoteShutterController
    init(capture: RemoteCapturePhase, movieMode: Bool, enabled: Bool, focusing: Bool,
         onQuickTap: @escaping () -> Void, onFocusStart: @escaping () -> Void,
         onRelease: @escaping (Bool) -> Void, diameter: CGFloat = 76) {
        self.capture = capture; self.movieMode = movieMode; self.enabled = enabled
        self.focusing = focusing; self.onQuickTap = onQuickTap
        self.onFocusStart = onFocusStart; self.onRelease = onRelease; self.diameter = diameter
        _controller = StateObject(wrappedValue: RemoteShutterController(configuration:
            .init(enabled: enabled, capturing: capture == .capturing, focusing: focusing,
                  recording: capture == .recording, diameter: diameter)))
    }
    @Environment(\.scenePhase) private var scenePhase
    private var configuration: RemoteShutterController.Configuration {
        .init(enabled: enabled, capturing: capture == .capturing, focusing: focusing,
              recording: capture == .recording, diameter: diameter)
    }
    var body: some View {
        RemoteShutterDrawing(controller: controller, configuration: configuration, movie: movieMode)
            .frame(width: diameter, height: diameter)
            .onAppear { update() }
            .onChange(of: configuration) { next in controller.configure(next) }
            .onChange(of: scenePhase) { if $0 != .active { controller.end(inside: false) } }
            .onDisappear { controller.stop() }
    }
    private func update() {
        controller.onQuickTap = onQuickTap; controller.onFocus = onFocusStart; controller.onRelease = onRelease
        controller.configure(configuration)
    }
}

private struct RemoteShutterDrawing: View {
    @ObservedObject var controller: RemoteShutterController
    let configuration: RemoteShutterController.Configuration
    let movie: Bool
    var body: some View {
        let motion = controller.motion
        ZStack {
            Circle().strokeBorder(!configuration.enabled ? ZTransferColors.primaryText.opacity(0.3)
                : (configuration.focusing ? ZTransferColors.accentBlue : ZTransferColors.primaryText.opacity(0.9)), lineWidth: 3)
            if configuration.capturing {
                RemoteCameraToolLoading(diameter: configuration.diameter * 52 / 76,
                    strokeWidth: 3, color: ZTransferColors.primaryText)
            } else {
                RoundedRectangle(cornerRadius: CGFloat(motion.corner.value), style: .circular)
                    .fill((movie ? ZTransferColors.statusError : .white).opacity(configuration.enabled ? 1 : 0.3))
                    .frame(width: CGFloat(motion.size.value), height: CGFloat(motion.size.value))
                    .scaleEffect(CGFloat(motion.focus.value))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .overlay { RemoteShutterInput(controller: controller, enabled: configuration.enabled && !configuration.capturing) }
            .scaleEffect(CGFloat(motion.press.value))
    }
}

private struct RemoteShutterInput: UIViewRepresentable {
    let controller: RemoteShutterController
    let enabled: Bool
    func makeUIView(context: Context) -> Input { Input() }
    func updateUIView(_ view: Input, context: Context) {
        view.controller = controller
        view.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }
    final class Input: UIView {
        weak var controller: RemoteShutterController?
        private var contacts: Set<UITouch> = []
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            isAccessibilityElement = true
            accessibilityIdentifier = "remote-shutter"
            accessibilityLabel = AppLocalized.resource("cd_remote_entry")
        }
        required init?(coder: NSCoder) { nil }
        private func contains(_ point: CGPoint) -> Bool {
            point.x >= 0 && point.x <= bounds.width && point.y >= 0 && point.y <= bounds.height
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let first = contacts.isEmpty
            contacts.formUnion(touches)
            if first { controller?.down() }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if touches.contains(where: { !contains($0.location(in: self)) }) { controller?.end(inside: false) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            contacts.subtract(touches)
            if contacts.isEmpty { controller?.end(inside: touches.allSatisfy { contains($0.location(in: self)) }) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            contacts.removeAll(); controller?.end(inside: false)
        }
        override func accessibilityActivate() -> Bool {
            guard let controller, controller.configuration.enabled, !controller.configuration.capturing else { return false }
            controller.onQuickTap(); return true
        }
    }
}
