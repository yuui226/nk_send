import Foundation

/// Android owns when feedback happens; the user approved a native iPhone
/// vocabulary on 2026-10-19. See docs/待做/iOS-20261019-触感场景与震感设计.md.
enum HapticFeedback: CaseIterable, Hashable {
    case selection, toggle, navigation, preview, favorite, action, enqueue
    case focusStarted, focusLocked, shutter, contentReady
    case connectionReady, transferComplete, failure, celebration, holdConfirmed

    enum Impact: Hashable { case light, medium, soft, rigid }
    enum Rendering: Equatable {
        case selection
        case impact(Impact, Float)
        case success([HapticPulse])
        case failure
    }

    var rendering: Rendering {
        switch self {
        case .selection: return .selection
        case .toggle: return .impact(.rigid, 0.45)
        case .navigation: return .impact(.soft, 0.45)
        case .preview: return .impact(.soft, 0.70)
        case .favorite: return .impact(.soft, 0.85)
        case .action: return .impact(.light, 0.65)
        case .enqueue: return .impact(.medium, 0.75)
        case .focusStarted: return .impact(.light, 0.35)
        case .focusLocked: return .impact(.rigid, 0.65)
        case .shutter: return .impact(.rigid, 1)
        case .contentReady: return .impact(.light, 0.45)
        case .connectionReady: return .success([
            .init(time: 0, intensity: 0.35, sharpness: 0.40),
            .init(time: 0.1, intensity: 0.75, sharpness: 0.65),
        ])
        case .transferComplete: return .success([
            .init(time: 0, intensity: 0.25, sharpness: 0.30),
            .init(time: 0.07, intensity: 0.45, sharpness: 0.50),
            .init(time: 0.16, intensity: 0.80, sharpness: 0.65),
        ])
        case .failure: return .failure
        case .celebration: return .impact(.soft, 0.80)
        case .holdConfirmed: return .impact(.rigid, 0.85)
        }
    }

    /// Android completeLongPress suppresses synchronous tick/longPress, but
    /// not success/failure. Asynchronous AF results are outside that scope.
    var isResult: Bool {
        switch self {
        case .connectionReady, .transferComplete, .failure: return true
        default: return false
        }
    }
}

struct HapticPulse: Equatable {
    let time: TimeInterval
    let intensity: Float
    let sharpness: Float
}

enum HapticFeedbackEvent: Equatable {
    case feedback(HapticFeedback)
    case holdStarted, holdCancelled, holdCompleted
}

/// Finite, increasingly close transients, never a polling timer or a sustained
/// buzz. Gesture deadlines remain owned by their existing input handlers.
enum ProgressiveHoldHapticPattern {
    static let durationMilliseconds = 800
    static func pulses(durationMilliseconds requested: Int) -> [HapticPulse] {
        let duration = Double(max(1, requested)) / 1_000
        let count = min(8, max(2, max(1, requested) / 90 + 1))
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            return HapticPulse(
                time: duration * 0.86 * (1 - pow(1 - progress, 1.3)),
                intensity: Float(0.12 + 0.34 * pow(progress, 1.4)),
                sharpness: Float(0.25 + 0.45 * progress))
        }
    }
}

enum HapticPreference {
    static let key = "haptics_enabled"
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}
