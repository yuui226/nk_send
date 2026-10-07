import Foundation

/// RemoteViewfinderFeatures.kt: preserve physical roll direction, including
/// portrait and inverted orientations, rather than folding it into ±45 degrees.
enum RemoteHorizon {
    static func aligned(_ roll: Float, wasAligned: Bool) -> Bool {
        guard roll.isFinite else { return false }
        let remainder = abs(roll.truncatingRemainder(dividingBy: 90))
        let deviation = min(remainder, 90 - remainder)
        return deviation <= (wasAligned ? 1.2 : 0.7)
    }

    static func displayRoll(_ roll: Float, previous: Float? = nil) -> Float {
        let previous = previous ?? roll
        return previous + ((roll - previous + 180).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) - 180
    }

    static func validPitch(_ pitch: Float?) -> Float? {
        guard let pitch, pitch.isFinite, abs(pitch) <= 90 else { return nil }
        return pitch
    }

    static func pitchAligned(_ pitch: Float?, wasAligned: Bool) -> Bool {
        guard let pitch = validPitch(pitch) else { return false }
        return abs(pitch) <= (wasAligned ? 1.2 : 0.7)
    }

    static func pitchOffset(_ pitch: Float?) -> Float {
        min(30, max(-30, validPitch(pitch) ?? 0)) / 30
    }
}
