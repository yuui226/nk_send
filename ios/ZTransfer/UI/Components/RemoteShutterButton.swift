import SwiftUI
import UIKit

/// Android ShutterButton's independent animate*AsState channels. Keep focus
/// tied to the accepted model state, not simply to the 300ms timer firing.
struct RemoteShutterMotion {
    private(set) var press = ZTransferScalarAnimation(value: 1)
    private(set) var focus = ZTransferScalarAnimation(value: 1)
    private(set) var size: ZTransferScalarAnimation
    private(set) var corner: ZTransferScalarAnimation
    private(set) var timerAccent = ZTransferScalarAnimation(value: 0)
    private(set) var countdownWidth: ZTransferScalarAnimation?
    init(diameter: Float = 76, focusing: Bool = false, recording: Bool = false, timerVisible: Bool = false) {
        size = .init(value: diameter * (recording ? Float(28) / 76 : Float(60) / 76))
        corner = .init(value: diameter * (recording ? Float(7) / 76 : Float(30) / 76))
        focus.reset(to: focusing ? 0.8 : 1)
        press.reset(to: focusing ? 0.95 : 1)
        timerAccent.reset(to: timerVisible ? 1 : 0)
    }
    mutating func configure(held: Bool, focusing: Bool, recording: Bool, diameter: Float,
                            timerEnabled: Bool = false, movie: Bool = false, seconds: Int = 0) {
        let down = held || focusing
        press.retarget(down ? 0.95 : 1, using: down ? .tween(milliseconds: 100)
            : .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
        focus.retarget(focusing ? 0.8 : 1, using: .tween(milliseconds: 120))
        size.retarget(diameter * (recording ? Float(28) / 76 : Float(60) / 76), using: .tween(milliseconds: 160))
        corner.retarget(diameter * (recording ? Float(7) / 76 : Float(30) / 76), using: .tween(milliseconds: 160))
        if movie {
            timerAccent.reset(to: 0)
            countdownWidth = nil
        } else {
            timerAccent.retarget(timerEnabled ? 1 : 0, using: .tween(milliseconds: 160))
        }
        if seconds > 0 {
            let font = UIFont.monospacedDigitSystemFont(ofSize: CGFloat(diameter) * 0.40, weight: .semibold)
            let width = Float((String(seconds) as NSString).size(withAttributes: [.font: font]).width)
            if countdownWidth == nil { countdownWidth = .init(value: width) }
            else { countdownWidth?.retarget(width, using: .bouncy) }
        }
    }
    var needsFrames: Bool {
        press.isRunning || focus.isRunning || size.isRunning || corner.isRunning ||
        timerAccent.isRunning || countdownWidth?.isRunning == true
    }
    mutating func advance(_ now: Int64) {
        press.advance(frameNanos: now); focus.advance(frameNanos: now)
        size.advance(frameNanos: now); corner.advance(frameNanos: now)
        timerAccent.advance(frameNanos: now); countdownWidth?.advance(frameNanos: now)
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
        var delayedPhoto = false
        var cancelsTimer = false
        var remainingSeconds = 0
        var movie = false
    }
    struct Display: Equatable {
        let press: Float
        let focus: Float
        let size: Float
        let corner: Float
        let timerAccent: Float
        let countdownWidth: Float?
        init(_ motion: RemoteShutterMotion) {
            press = motion.press.value; focus = motion.focus.value
            size = motion.size.value; corner = motion.corner.value
            timerAccent = motion.timerAccent.value; countdownWidth = motion.countdownWidth?.value
        }
    }
    private(set) var motion: RemoteShutterMotion
    @Published private(set) var display: Display
    private var active = true
    var clockRunning: Bool { link != nil }
    private(set) var gesture = RemoteShutterGesture()
    private(set) var configuration: Configuration
    private let haptics: ZTransferHaptics
    var onQuickTap: () -> Void = {}
    var onFocus: () -> Void = {}
    var onRelease: (Bool) -> Void = { _ in }
    var onCancelTimer: () -> Void = {}
    private var timer: Task<Void, Never>?
    private var link: CADisplayLink?
    init(configuration: Configuration, haptics: ZTransferHaptics = ZTransferHaptics()) {
        self.configuration = configuration; self.haptics = haptics
        let initial = RemoteShutterMotion(diameter: Float(configuration.diameter), focusing: configuration.focusing,
                                         recording: configuration.recording, timerVisible: configuration.cancelsTimer && !configuration.movie)
        motion = initial
        display = Display(initial)
    }
    func configure(_ next: Configuration) {
        if !next.enabled || next.capturing || next.cancelsTimer != configuration.cancelsTimer ||
            next.delayedPhoto != configuration.delayedPhoto || next.movie != configuration.movie { end(inside: false) }
        configuration = next
        updateMotion()
    }
    func down() {
        guard active else { return }
        let actions = gesture.down(at: ProcessInfo.processInfo.systemUptime,
                                   enabled: configuration.enabled && !configuration.capturing)
        guard !actions.isEmpty else { return }
        deliver(actions); updateMotion()
        timer?.cancel()
        guard !configuration.delayedPhoto, !configuration.cancelsTimer else { return }
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
            case .beginHold:
                if !configuration.delayedPhoto && !configuration.cancelsTimer {
                    haptics.startProgressiveHold(durationMilliseconds: 300)
                }
            case .focus:
                haptics.completeLongPress(onFocus)
            case .cancelHold: haptics.cancelProgressiveHold()
            case .release(let fire): onRelease(fire)
            case .quickTap: if configuration.cancelsTimer { onCancelTimer() } else { onQuickTap() }
            }
        }
    }
    private func updateMotion() {
        motion.configure(held: gesture.held && !configuration.cancelsTimer, focusing: configuration.focusing,
                         recording: configuration.recording, diameter: Float(configuration.diameter),
                         timerEnabled: configuration.cancelsTimer, movie: configuration.movie, seconds: configuration.remainingSeconds)
        publish()
        if active, motion.needsFrames, link == nil {
            let next = CADisplayLink(target: ClockTarget(self), selector: #selector(ClockTarget.frame(_:)))
            link = next; next.add(to: .main, forMode: .common)
        }
    }
    func advance(_ now: Int64) {
        guard active else { return }
        motion.advance(now)
        publish()
        if !motion.needsFrames { stopClock() }
    }
    private func publish() {
        let next = Display(motion)
        if display != next { display = next }
    }
    func activate() { active = true; updateMotion() }
    private func stopClock() { link?.invalidate(); link = nil }
    func stop() { active = false; end(inside: false); stopClock() }
    @MainActor
    private final class ClockTarget: NSObject {
        weak var owner: RemoteShutterController?
        init(_ owner: RemoteShutterController) { self.owner = owner }
        @objc func frame(_ sender: CADisplayLink) {
            guard let owner else { sender.invalidate(); return }
            owner.advance(Int64(sender.timestamp * 1_000_000_000))
        }
    }
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
    let delaySeconds: Int
    let timerActive: Bool
    let remainingSeconds: Int
    let timerFocusing: Bool
    let onCancel: () -> Void
    @State private var controller: RemoteShutterController
    init(capture: RemoteCapturePhase, movieMode: Bool, enabled: Bool, focusing: Bool,
         onQuickTap: @escaping () -> Void, onFocusStart: @escaping () -> Void,
         onRelease: @escaping (Bool) -> Void, diameter: CGFloat = 76,
         delaySeconds: Int = 0, timerActive: Bool = false, remainingSeconds: Int = 0,
         timerFocusing: Bool = false, onCancel: @escaping () -> Void = {}) {
        self.capture = capture; self.movieMode = movieMode; self.enabled = enabled
        self.focusing = focusing; self.onQuickTap = onQuickTap
        self.onFocusStart = onFocusStart; self.onRelease = onRelease; self.diameter = diameter
        self.delaySeconds = delaySeconds; self.timerActive = timerActive
        self.remainingSeconds = remainingSeconds; self.timerFocusing = timerFocusing; self.onCancel = onCancel
        let cancel = !movieMode && (remainingSeconds > 0 || timerFocusing)
        _controller = State(initialValue: RemoteShutterController(configuration:
            .init(enabled: enabled, capturing: capture == .capturing || timerActive && !cancel, focusing: focusing,
                  recording: capture == .recording, diameter: diameter, delayedPhoto: !movieMode && delaySeconds > 0,
                  cancelsTimer: cancel, remainingSeconds: movieMode ? 0 : remainingSeconds, movie: movieMode)))
    }
    @Environment(\.scenePhase) private var scenePhase
    private var configuration: RemoteShutterController.Configuration {
        let cancel = !movieMode && (remainingSeconds > 0 || timerFocusing)
        return .init(enabled: enabled, capturing: capture == .capturing || timerActive && !cancel, focusing: focusing,
              recording: capture == .recording, diameter: diameter, delayedPhoto: !movieMode && delaySeconds > 0,
              cancelsTimer: cancel, remainingSeconds: movieMode ? 0 : remainingSeconds, movie: movieMode)
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
        controller.activate()
        controller.onQuickTap = onQuickTap; controller.onFocus = onFocusStart; controller.onRelease = onRelease
        controller.onCancelTimer = onCancel
        controller.configure(configuration)
    }
}

private struct RemoteShutterDrawing: View {
    @ObservedObject var controller: RemoteShutterController
    let configuration: RemoteShutterController.Configuration
    let movie: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var lastSeconds = 1
    @State private var lastCounting = true
    private static let fadeIn = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.12)
    private static let fadeOut = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.10)
    var body: some View {
        let motion = controller.display
        let accent = movie ? 0 : CGFloat(motion.timerAccent)
        let ring = ZTransferColors.primaryText.opacity(0.9).mix(with: ZTransferColors.accentBlue, by: accent, scheme: scheme)
        let fill = (movie ? ZTransferColors.statusError : Color.white)
            .mix(with: ZTransferColors.accentBlue.opacity(0.12), by: accent, scheme: scheme)
        ZStack {
            Circle().strokeBorder(!configuration.enabled ? ZTransferColors.primaryText.opacity(0.3)
                : (configuration.focusing ? ZTransferColors.accentBlue : ring), lineWidth: 3)
            if configuration.capturing {
                RemoteCameraToolLoading(diameter: configuration.diameter * 52 / 76,
                    strokeWidth: 3, color: ZTransferColors.primaryText)
            } else {
                RoundedRectangle(cornerRadius: CGFloat(motion.corner), style: .circular)
                    .fill(fill.opacity(configuration.enabled ? 1 : 0.3))
                    .frame(width: CGFloat(motion.size), height: CGFloat(motion.size))
                    .scaleEffect(CGFloat(motion.focus))
            }
            if !movie && configuration.cancelsTimer {
                timerFace(width: motion.countdownWidth.map(CGFloat.init))
                    .transition(.asymmetric(insertion: .opacity.animation(Self.fadeIn), removal: .opacity.animation(Self.fadeOut)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .overlay { RemoteShutterInput(controller: controller, enabled: configuration.enabled && !configuration.capturing) }
            .scaleEffect(CGFloat(motion.press))
            .animation(movie ? nil : Self.fadeIn, value: configuration.cancelsTimer)
            .onAppear {
                if configuration.remainingSeconds > 0 { lastSeconds = configuration.remainingSeconds }
                lastCounting = configuration.remainingSeconds > 0
            }
            .onChange(of: configuration.remainingSeconds) { seconds in
                guard seconds > 0 else { return }
                lastSeconds = seconds
                // Android's polite live region: announce whole seconds only,
                // never interrupt speech or wake work for visual animation frames.
                guard UIAccessibility.isVoiceOverRunning else { return }
                let attributes: [NSAttributedString.Key: Any]
                if #available(iOS 17, *) {
                    attributes = [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low.rawValue]
                } else {
                    attributes = [.accessibilitySpeechQueueAnnouncement: true]
                }
                UIAccessibility.post(notification: .announcement,
                    argument: NSAttributedString(string: String(seconds), attributes: attributes))
            }
            .onChange(of: configuration.cancelsTimer) { if $0 { lastCounting = configuration.remainingSeconds > 0 } }
            .onChange(of: configuration.remainingSeconds > 0) { if configuration.cancelsTimer { lastCounting = $0 } }
    }

    private func timerFace(width: CGFloat?) -> some View {
        let counting = configuration.cancelsTimer ? configuration.remainingSeconds > 0 : lastCounting
        return ZStack {
            if counting {
                let seconds = configuration.remainingSeconds > 0 ? configuration.remainingSeconds : lastSeconds
                QueueAnimatedValue(text: String(seconds), value: Int64(seconds),
                    style: .init(size: configuration.diameter * 0.40, lineHeight: configuration.diameter * 0.48),
                    weight: .semibold, color: ZTransferColors.accentBlue)
                    .frame(width: width, alignment: .center)
                    .transition(.opacity)
            } else {
                RemoteCameraToolLoading(diameter: configuration.diameter * 52 / 76, strokeWidth: 3,
                                        color: ZTransferColors.accentBlue)
                Image(systemName: "xmark").font(.system(size: configuration.diameter * 0.24, weight: .medium))
                    .foregroundStyle(ZTransferColors.accentBlue)
            }
        }.animation(Self.fadeIn, value: counting)
    }
}

private struct RemoteShutterInput: UIViewRepresentable {
    let controller: RemoteShutterController
    let enabled: Bool
    func makeUIView(context: Context) -> Input { Input() }
    func updateUIView(_ view: Input, context: Context) {
        view.controller = controller
        view.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        view.accessibilityValue = controller.configuration.remainingSeconds > 0 ? String(controller.configuration.remainingSeconds) : nil
        view.accessibilityLabel = AppLocalized.resource(controller.configuration.cancelsTimer ? "cancel" : "cd_remote_entry")
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
            if controller.configuration.cancelsTimer { controller.onCancelTimer() }
            else { controller.onQuickTap() }
            return true
        }
    }
}
