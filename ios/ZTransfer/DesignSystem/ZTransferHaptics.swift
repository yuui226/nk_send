import CoreHaptics
import UIKit

/// Android Haptics.kt semantics, with a single live preference gate. The
/// optional output observes events in regression tests without using motors.
@MainActor
final class ZTransferHaptics {
    static let shared = ZTransferHaptics()
    private let defaults: UserDefaults
    private let output: ((HapticFeedbackEvent) -> Void)?
    private var engine: CHHapticEngine?
    private var holdPlayer: CHHapticPatternPlayer?
    private var holding = false

    init(defaults: UserDefaults = .standard, output: ((HapticFeedbackEvent) -> Void)? = nil) {
        self.defaults = defaults
        self.output = output
    }

    /// Only the haptic preference's own wheel uses Android's always-confirm exception.
    func tick(isPreferenceToggle: Bool = false) {
        guard isPreferenceToggle || HapticPreference.isEnabled(in: defaults) else { return }
        emit(.tick)
    }

    func longPress() { sendIfEnabled(.longPress) }
    func success() { sendIfEnabled(.success) }
    func failure() { sendIfEnabled(.failure) }

    func startProgressiveHold() {
        cancelProgressiveHold()
        guard HapticPreference.isEnabled(in: defaults) else { return }
        holding = true
        emit(.holdStarted)
    }

    /// Cancellation remains available after the preference was switched off.
    func cancelProgressiveHold() {
        guard holding else { return }
        holding = false
        emit(.holdCancelled)
    }

    func completeProgressiveHold() {
        guard holding else { return }
        guard HapticPreference.isEnabled(in: defaults) else {
            cancelProgressiveHold()
            return
        }
        holding = false
        emit(.holdCompleted)
    }

    private func sendIfEnabled(_ event: HapticFeedbackEvent) {
        guard HapticPreference.isEnabled(in: defaults) else { return }
        emit(event)
    }

    private func emit(_ event: HapticFeedbackEvent) {
        if let output { output(event); return }
        switch event {
        case .tick: UISelectionFeedbackGenerator().selectionChanged()
        case .longPress: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .holdStarted: startHoldPattern()
        case .holdCancelled: stopHoldPattern()
        case .holdCompleted:
            stopHoldPattern()
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    private func stopHoldPattern() {
        try? holdPlayer?.stop(atTime: CHHapticTimeImmediate)
        holdPlayer = nil
    }

    private func startHoldPattern() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let activeEngine: CHHapticEngine
            if let engine {
                activeEngine = engine
            } else {
                activeEngine = try CHHapticEngine()
                activeEngine.playsHapticsOnly = true
                activeEngine.isAutoShutdownEnabled = true
                activeEngine.resetHandler = { [weak self] in
                    Task { @MainActor in
                        // Never replay an interrupted gesture after a reset.
                        self?.engine = nil
                        self?.holdPlayer = nil
                        self?.holding = false
                    }
                }
                activeEngine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.holdPlayer = nil }
                }
                engine = activeEngine
            }
            // An existing engine may have auto-shut down or been interrupted.
            try activeEngine.start()
            let events = ProgressiveHoldHapticPattern.pulses.map { pulse in
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(pulse.amplitude) / 255),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ], relativeTime: Double(pulse.startMilliseconds) / 1_000,
                   duration: Double(pulse.durationMilliseconds) / 1_000)
            }
            let player = try activeEngine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            holdPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            stopHoldPattern()
            engine = nil
        }
    }
}
