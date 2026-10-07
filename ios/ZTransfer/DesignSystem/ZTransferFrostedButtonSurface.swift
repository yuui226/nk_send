import SwiftUI

/// Final Android GlassButton.frostedPebbleOptics. This material has no external
/// elevation or directional sheen, even when a caller supplies shadowElevation.
struct ZTransferFrostedButtonSurface: View, Animatable {
    let cornerRadius: CGFloat
    let dark: Bool
    let panel: Bool
    let showSheen: Bool
    let opacityBoost: Double
    let activeColor: Color
    let active: Bool
    let pressed: Bool
    var pressProgress: CGFloat? = nil
    var activeProgress: CGFloat? = nil

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pressProgress ?? (pressed ? 1 : 0), activeProgress ?? (active ? 1 : 0)) }
        set { pressProgress = newValue.first; activeProgress = newValue.second }
    }

    static func baseAlpha(dark: Bool, boost: Double) -> Double {
        let base = dark ? 0.20 : 0.62
        return base + (1 - base) * min(1, max(0, boost))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        let strength = panel ? 0.66 : 1.0
        let definition = showSheen ? 1.0 : 0.72
        let press = Double(min(max(pressProgress ?? (pressed ? 1 : 0), 0), 1))
        let active = Double(min(max(activeProgress ?? (self.active ? 1 : 0), 0), 1))
        let volume = 1 - 0.48 * press
        let base = panel ? ZTransferColors.primaryText.opacity(0.05)
            : (dark ? Color(red: 137 / 255, green: 153 / 255, blue: 164 / 255) : .white)
                .opacity(Self.baseAlpha(dark: dark, boost: opacityBoost))
        shape.fill(base)
            .overlay(shape.fill((dark ? Color(red: 214 / 255, green: 226 / 255, blue: 232 / 255) : .white)
                .opacity((dark ? 0.050 : 0.105) * strength)))
            .overlay(shape.fill(activeColor.opacity(0.14 * active)))
            .overlay(shape.fill((dark ? Color.black : Color(red: 64 / 255, green: 81 / 255, blue: 92 / 255))
                .opacity(0.045 * strength * press)))
            .overlay {
                GeometryReader { proxy in
                    let paths = FrostedGrainCache.paths(size: proxy.size)
                    Canvas { context, _ in
                        context.fill(paths.light, with: .color(.white.opacity((dark ? 0.040 : 0.075) * strength * definition)))
                        let ink = dark ? Color(red: 7 / 255, green: 16 / 255, blue: 22 / 255)
                            : Color(red: 106 / 255, green: 123 / 255, blue: 133 / 255)
                        context.fill(paths.dark, with: .color(ink.opacity((dark ? 0.045 : 0.038) * strength * definition)))
                    }
                }
            }
            // Android draws centered strokes then clips the outer halves.
            .overlay(shape.stroke((dark ? Color(red: 2 / 255, green: 8 / 255, blue: 12 / 255)
                : Color(red: 97 / 255, green: 113 / 255, blue: 123 / 255))
                .opacity((dark ? 0.24 : 0.13) * strength * volume), lineWidth: 3.2))
            .overlay(shape.stroke(.white.opacity((dark ? 0.24 : 0.66) * strength * volume * definition), lineWidth: 1))
            .clipShape(shape)
    }
}

/// Paths are stable for a given layout and reused during press/active animation.
/// Bounded storage also avoids retaining every intermediate animated width.
@MainActor
private enum FrostedGrainCache {
    struct Paths { let light: Path; let dark: Path }
    private struct SizeKey: Hashable { let width: CGFloat; let height: CGFloat }
    private static var cache: [SizeKey: Paths] = [:]
    static func paths(size: CGSize) -> Paths {
        let key = SizeKey(width: size.width, height: size.height)
        if let cached = cache[key] { return cached }
        let step = 5.5
        let columns = max(1, Int(ceil(max(1, size.width) / step)))
        let rows = max(1, Int(ceil(max(1, size.height) / step)))
        var light = Path(), dark = Path()
        for row in 0..<rows {
            for column in 0..<columns {
                var hash = UInt32(truncatingIfNeeded: column) &* 0x1F123BB5
                hash = hash &+ UInt32(truncatingIfNeeded: row) &* 0x05491333
                hash = hash &+ UInt32(truncatingIfNeeded: columns) &* 0x0127A5D9
                hash = hash &+ UInt32(truncatingIfNeeded: rows) &* 0x001B8735
                hash = (hash ^ (hash >> 16)) &* 0x45D9F3B
                hash ^= hash >> 16
                let x = (Double(column) + 0.18 + 0.64 * Double(hash & 0xFF) / 255) * step
                let y = (Double(row) + 0.18 + 0.64 * Double((hash >> 8) & 0xFF) / 255) * step
                let radius = 0.24 + 0.24 * Double((hash >> 16) & 0x7F) / 127
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                if hash & 0x01000000 == 0 { light.addEllipse(in: rect) }
                else { dark.addEllipse(in: rect) }
            }
        }
        let result = Paths(light: light, dark: dark)
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }
}
