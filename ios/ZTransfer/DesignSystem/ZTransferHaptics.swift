import CoreHaptics
import UIKit

/// Control-local logical ownership, one shared physical renderer. Tests can
/// observe events or inject a renderer without touching the phone's motor.
@MainActor
final class ZTransferHaptics {
    static let shared = ZTransferHaptics()
    private let defaults: UserDefaults
    private let output: ((HapticFeedbackEvent) -> Void)?
    private let renderer: (any HapticRendering)?
    private let owner = UUID()
    private var holding = false
    private static var confirmationDepth = 0

    init(defaults: UserDefaults = .standard, renderer: (any HapticRendering)? = nil,
         output: ((HapticFeedbackEvent) -> Void)? = nil) {
        self.defaults = defaults
        self.renderer = renderer
        self.output = output
    }

    /// Only the haptic preference's own switch uses the always-confirm exception.
    func play(_ feedback: HapticFeedback, isPreferenceToggle: Bool = false) {
        guard Self.confirmationDepth == 0 || feedback.isResult else { return }
        guard (isPreferenceToggle && feedback == .toggle) || HapticPreference.isEnabled(in: defaults) else { return }
        if observed(.feedback(feedback)) { return }
        physical.play(feedback)
    }

    func startProgressiveHold(durationMilliseconds: Int = ProgressiveHoldHapticPattern.durationMilliseconds) {
        cancelProgressiveHold()
        guard HapticPreference.isEnabled(in: defaults) else { return }
        holding = true
        if observed(.holdStarted) { return }
        let defaults = defaults
        physical.startHold(owner: owner, durationMilliseconds: durationMilliseconds,
                           isEnabled: { HapticPreference.isEnabled(in: defaults) })
    }

    /// Cancellation remains available after the preference was switched off.
    func cancelProgressiveHold() {
        guard holding else { return }
        holding = false
        if observed(.holdCancelled) { return }
        physical.cancelHold(owner: owner)
    }

    func completeProgressiveHold() {
        guard holding else { return }
        guard HapticPreference.isEnabled(in: defaults) else {
            cancelProgressiveHold()
            return
        }
        holding = false
        if observed(.holdCompleted) { return }
        physical.completeHold(owner: owner)
    }

    func completeLongPress(_ action: () -> Void) {
        completeProgressiveHold()
        Self.confirmationDepth += 1
        defer { Self.confirmationDepth -= 1 }
        action()
    }

    private var physical: any HapticRendering { renderer ?? NativeHapticRenderer.shared }

    private func observed(_ event: HapticFeedbackEvent) -> Bool {
        #if DEBUG
        if ButtonInteractionTrace.enabled {
            let name: String
            switch event {
            case let .feedback(feedback): name = String(describing: feedback)
            case .holdStarted: name = "holdStarted"
            case .holdCancelled: name = "holdCancelled"
            case .holdCompleted: name = "holdCompleted"
            }
            ButtonInteractionTrace.recordNow("haptic-" + name)
        }
        #endif
        if let output { output(event); return true }
        return false
    }
}

@MainActor
protocol HapticRendering: AnyObject {
    func play(_ feedback: HapticFeedback)
    func startHold(owner: UUID, durationMilliseconds: Int, isEnabled: @escaping () -> Bool)
    func cancelHold(owner: UUID)
    func completeHold(owner: UUID)
}

/// Bounded native players; nothing runs per frame. Background/preference/reset
/// cancels existing playback, and only a new user event can start it again.
@MainActor
final class NativeHapticRenderer: NSObject, HapticRendering {
    static let shared = NativeHapticRenderer()
    private lazy var selection = UISelectionFeedbackGenerator()
    private lazy var notification = UINotificationFeedbackGenerator()
    private var impacts: [HapticFeedback.Impact: UIImpactFeedbackGenerator] = [:]
    private var engine: CHHapticEngine?
    private var engineID: UUID?
    private var holdPlayer: CHHapticPatternPlayer?
    private var cuePlayer: CHHapticPatternPlayer?
    private(set) var holdOwner: UUID?
    private var holdEnabled: (() -> Bool)?
    private let supportsHaptics: Bool
    private let isActive: () -> Bool
    private let systemOutput: ((HapticFeedback) -> Void)?

    init(supportsHaptics: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics,
         isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         systemOutput: ((HapticFeedback) -> Void)? = nil) {
        self.supportsHaptics = supportsHaptics
        self.isActive = isActive
        self.systemOutput = systemOutput
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationInactive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferenceChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func play(_ feedback: HapticFeedback) {
        guard isActive() else { return }
        if let systemOutput { systemOutput(feedback); return }
        switch feedback.rendering {
        case .selection: selection.selectionChanged()
        case let .impact(style, intensity): impact(style).impactOccurred(intensity: CGFloat(intensity))
        case .failure:
            try? cuePlayer?.stop(atTime: CHHapticTimeImmediate)
            cuePlayer = nil
            notification.notificationOccurred(.error)
        case let .success(pulses):
            try? cuePlayer?.stop(atTime: CHHapticTimeImmediate)
            cuePlayer = nil
            do {
                cuePlayer = try start(pulses)
                if cuePlayer == nil { notification.notificationOccurred(.success) }
            } catch {
                stop()
                notification.notificationOccurred(.success)
            }
        }
    }

    func startHold(owner: UUID, durationMilliseconds: Int, isEnabled: @escaping () -> Bool) {
        stopHold()
        guard isActive(), isEnabled() else { return }
        holdOwner = owner
        holdEnabled = isEnabled
        do {
            holdPlayer = try start(ProgressiveHoldHapticPattern.pulses(durationMilliseconds: durationMilliseconds))
            if holdPlayer == nil { play(.focusStarted) }
        } catch {
            // No delayed retry: a late engine must never replay an old hold.
            discardEngine()
            play(.focusStarted)
        }
    }

    func cancelHold(owner: UUID) {
        guard holdOwner == owner else { return }
        stopHold()
    }

    func completeHold(owner: UUID) {
        guard holdOwner == owner else { return }
        let enabled = holdEnabled?() == true
        stopHold()
        if enabled { play(.holdConfirmed) }
    }

    func stop() {
        stopHold()
        discardEngine()
    }

    @objc nonisolated private func applicationInactive() {
        onMain { $0.stop() }
    }

    @objc nonisolated private func preferenceChanged() {
        // Defaults notifications can originate on a background writer. Read
        // the live value on the main actor before touching players/generators.
        onMain { renderer in
            if renderer.holdEnabled?() == false || !HapticPreference.isEnabled(in: .standard) {
                renderer.stop()
            }
        }
    }

    private nonisolated func onMain(_ action: @escaping @MainActor @Sendable (NativeHapticRenderer) -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { action(self) } }
        else { Task { @MainActor [weak self] in if let self { action(self) } } }
    }

    private func stopHold() {
        try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
        holdOwner = nil
        holdEnabled = nil
    }

    private func discardEngine() {
        try? cuePlayer?.stop(atTime: CHHapticTimeImmediate)
        cuePlayer = nil
        engineID = nil
        engine?.stop(completionHandler: nil)
        engine = nil
    }

    private func start(_ pulses: [HapticPulse]) throws -> CHHapticPatternPlayer? {
        guard supportsHaptics else { return nil }
        let activeEngine: CHHapticEngine
        if let engine { activeEngine = engine }
        else {
            activeEngine = try CHHapticEngine()
            activeEngine.playsHapticsOnly = true
            activeEngine.isAutoShutdownEnabled = true
            engine = activeEngine
        }
        // Also renew when restarting the same auto-shut-down engine: an idle
        // callback already queued for the previous run must not kill this one.
        let id = UUID()
        engineID = id
        activeEngine.resetHandler = { [weak self] in
            Task { @MainActor in self?.engineInterrupted(id) }
        }
        activeEngine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.engineInterrupted(id) }
        }
        try activeEngine.start()
        let events = pulses.map {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                .init(parameterID: .hapticIntensity, value: $0.intensity),
                .init(parameterID: .hapticSharpness, value: $0.sharpness),
            ], relativeTime: $0.time)
        }
        let player = try activeEngine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
        try player.start(atTime: CHHapticTimeImmediate)
        return player
    }

    private func engineInterrupted(_ id: UUID) {
        guard engineID == id else { return } // Ignore an old engine's late callback.
        stop()
    }

    private func impact(_ style: HapticFeedback.Impact) -> UIImpactFeedbackGenerator {
        if let existing = impacts[style] { return existing }
        let native: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case .light: native = .light
        case .medium: native = .medium
        case .soft: native = .soft
        case .rigid: native = .rigid
        }
        let generator = UIImpactFeedbackGenerator(style: native)
        impacts[style] = generator
        return generator
    }
}

/// One control owns its hold. Cancelling it cannot stop another control's player.
@MainActor
final class ZTransferLongPressFeedback {
    private enum Phase { case idle, holding, finished }
    private var phase = Phase.idle
    private let haptics: ZTransferHaptics

    init(haptics: ZTransferHaptics = ZTransferHaptics()) { self.haptics = haptics }

    func begin(durationMilliseconds: Int) {
        guard phase == .idle else { return }
        phase = .holding
        haptics.startProgressiveHold(durationMilliseconds: durationMilliseconds)
    }
    func cancel() {
        guard phase == .holding else { return }
        phase = .finished
        haptics.cancelProgressiveHold()
    }
    func trigger(_ action: () -> Void) {
        guard phase != .finished else { return }
        phase = .finished
        haptics.completeLongPress(action)
    }
    func end() {
        cancel()
        phase = .idle
    }
}
