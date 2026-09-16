import Foundation

enum HapticFeedbackEvent: Equatable {
    case tick, longPress, success, failure
    case holdStarted, holdCancelled, holdCompleted
}

/// Android Haptics.kt: ten pulses, then 63 ms of silence before the 800 ms
/// gesture completion. Durations describe segments, not pulse start times.
enum ProgressiveHoldHapticPattern {
    struct Pulse: Equatable {
        let startMilliseconds: Int
        let durationMilliseconds: Int
        let amplitude: Int
    }
    static let durationMilliseconds = 800
    static let pulses: [Pulse] = [
        .init(startMilliseconds: 0, durationMilliseconds: 8, amplitude: 24),
        .init(startMilliseconds: 120, durationMilliseconds: 8, amplitude: 28),
        .init(startMilliseconds: 230, durationMilliseconds: 9, amplitude: 34),
        .init(startMilliseconds: 330, durationMilliseconds: 9, amplitude: 42),
        .init(startMilliseconds: 420, durationMilliseconds: 10, amplitude: 52),
        .init(startMilliseconds: 500, durationMilliseconds: 10, amplitude: 64),
        .init(startMilliseconds: 570, durationMilliseconds: 11, amplitude: 78),
        .init(startMilliseconds: 630, durationMilliseconds: 11, amplitude: 96),
        .init(startMilliseconds: 680, durationMilliseconds: 12, amplitude: 118),
        .init(startMilliseconds: 725, durationMilliseconds: 12, amplitude: 142),
    ]
}

enum HapticPreference {
    static let key = "haptics_enabled"
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}
