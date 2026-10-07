import Foundation

/// Display-only monitor options copied from Android RemoteScreen preferences.
enum RemoteDisplayOptions {
    static let desqueezeValues: [Double] = [1, 1.33, 1.5, 1.8, 2]

    static func normalizedDesqueeze(_ value: Double) -> Double {
        // RemoteToolPreferences rejects an invalid stored multiplier rather
        // than clamping it to a different active lens correction.
        guard value.isFinite, (1...2).contains(value) else { return 1 }
        return value
    }

    static func nextDesqueeze(after value: Double) -> Double {
        let normalized = normalizedDesqueeze(value)
        // RemoteScreen advances from the nearest preset, including values
        // restored from an older/custom preference. Equal distances keep the
        // first preset, matching Kotlin minByOrNull.
        var index = 0
        for candidate in desqueezeValues.indices.dropFirst() {
            if abs(desqueezeValues[candidate] - normalized) < abs(desqueezeValues[index] - normalized) {
                index = candidate
            }
        }
        return desqueezeValues[(index + 1) % desqueezeValues.count]
    }

    static func label(for value: Double) -> String {
        abs(value - 1.33) < 0.01 ? "1.3" : String(format: "%.1f", value)
    }
}
