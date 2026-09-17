import Foundation

/// Display-only monitor options copied from Android RemoteScreen preferences.
enum RemoteDisplayOptions {
    static let desqueezeValues: [Double] = [1, 1.33, 1.5, 1.8, 2]

    static func normalizedDesqueeze(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 1), 2)
    }

    static func nextDesqueeze(after value: Double) -> Double {
        let normalized = normalizedDesqueeze(value)
        let index = desqueezeValues.firstIndex { abs($0 - normalized) < 0.01 } ?? 0
        return desqueezeValues[(index + 1) % desqueezeValues.count]
    }

    static func label(for value: Double) -> String {
        abs(value - 1.33) < 0.01 ? "1.3" : String(format: "%.1f", value)
    }
}
