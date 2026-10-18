import SwiftUI

/// Fireworks.kt: each tap launches an independent 400 ms rise + 1,600 ms burst.
/// No timers or drawing exist when the active set is empty.
@MainActor
final class PremiumFireworks: ObservableObject {
    struct Launch: Identifiable {
        let id: Int
        let drawing: PremiumFireworkDrawing
    }
    @Published private(set) var active: [Launch] = []
    private var sequence = 0
    func launch() {
        sequence += 1
        active.append(Launch(id: sequence, drawing: PremiumFireworkDrawing(seed: sequence)))
    }
    func finish(_ id: Int) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        active.remove(at: index)
    }
}

struct PremiumFireworksOverlay: View {
    @ObservedObject var state: PremiumFireworks
    var onExploded: () -> Void = { ZTransferHaptics.shared.tick() }
    var body: some View {
        ZStack {
            ForEach(state.active) { launch in
                PremiumFirework(drawing: launch.drawing, onExploded: onExploded) { state.finish(launch.id) }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct PremiumFirework: View {
    private let drawing: PremiumFireworkDrawing
    let onExploded: () -> Void
    let onFinished: () -> Void
    @State private var start = Date()

    init(drawing: PremiumFireworkDrawing, onExploded: @escaping () -> Void,
         onFinished: @escaping () -> Void) {
        self.drawing = drawing
        self.onExploded = onExploded
        self.onFinished = onFinished
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                drawing.draw(context: context, size: size, elapsed: timeline.date.timeIntervalSince(start))
            }
        }
        .task {
            start = Date()
            do {
                try await Task.sleep(for: .milliseconds(400))
                onExploded()
                try await Task.sleep(for: .milliseconds(1600))
                onFinished()
            } catch {}
        }
    }
}

/// Android FireworkSpec remembers each launch's random parameters. Keep that
/// work outside TimelineView so frames only evaluate motion/fading and draw.
/// Fixed-time reference frames verify the existing rendering is unchanged.
struct PremiumFireworkDrawing {
    private struct Spark {
        let cosine: Double
        let sine: Double
        let speed: Double
        let life: Double
        let weight: Double
        let shade: Double
        let tint: Color
    }

    private struct Stardust {
        let cosine: Double
        let sine: Double
        let speed: Double
        let phase: Double
    }

    private struct TailSample {
        let time: Double
        let expansion: Double
        let fade: Double
        let width: Double

        init(segment: Int, progress: Double) {
            time = max(0, progress - 0.035 * Double(segment))
            expansion = 1 - pow(1 - time, 4)
            fade = 1 - (Double(segment) - 0.5) / 3
            width = (0.8 + 0.7 * (1 - progress)) * (0.35 + 0.65 * fade)
        }
    }

    private let x: Double
    private let y: Double
    private let sway: Double
    private let rgb: (Double, Double, Double)
    private let base: Color
    private let dustTint: Color
    private let sparks: [Spark]
    private let stardust: [Stardust]

    init(seed: Int) {
        func random(_ index: Int) -> Double {
            var value = (UInt32(truncatingIfNeeded: seed) &* 374761393) ^ (UInt32(index) &* 668265263)
            value = (value ^ (value >> 13)) &* 1274126177
            return Double((value ^ (value >> 16)) & 0x7fffffff) / 2147483647
        }
        let palette: [(Double, Double, Double)] = [
            (232, 196, 104), (229, 143, 168), (111, 191, 199),
            (157, 143, 219), (127, 183, 227), (134, 198, 154)
        ]
        let rgb = palette[seed % palette.count]
        self.rgb = rgb
        x = 0.18 + random(1) * 0.64
        y = 0.16 + random(2) * 0.30
        sway = (random(3) - 0.5) * 2 * 8
        base = Self.tint(rgb)
        dustTint = Self.tint(rgb, 0.55)
        sparks = (0..<36).map { k in
            let angle = Double(k) * (2 * .pi / 36) + (random(k * 2 + 11) - 0.5) * (2 * .pi / 36)
            let shade = random(k * 3 + 14) * 0.35
            return Spark(cosine: cos(angle), sine: sin(angle),
                         speed: 0.55 + random(k * 2 + 10) * 0.45,
                         life: 0.7 + random(k * 3 + 12) * 0.3,
                         weight: 0.75 + random(k * 3 + 13) * 0.5,
                         shade: shade, tint: Self.tint(rgb, shade))
        }
        stardust = (0..<18).map { k in
            let phase = random(k * 5 + 41) * 2 * .pi
            let angle = Double(k) * (2 * .pi / 18) + phase
            return Stardust(cosine: cos(angle), sine: sin(angle),
                            speed: 0.35 + random(k * 5 + 40) * 0.4, phase: phase)
        }
    }

    private static func tint(_ rgb: (Double, Double, Double), _ white: Double = 0) -> Color {
        Color(red: rgb.0 / 255 + (1 - rgb.0 / 255) * white,
              green: rgb.1 / 255 + (1 - rgb.1 / 255) * white,
              blue: rgb.2 / 255 + (1 - rgb.2 / 255) * white)
    }

    func draw(context: GraphicsContext, size: CGSize, elapsed: Double) {
        func circle(_ center: CGPoint, _ radius: Double, _ color: Color) {
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2)), with: .color(color))
        }
        func line(_ from: CGPoint, _ to: CGPoint, _ width: Double, _ color: Color) {
            var path = Path(); path.move(to: from); path.addLine(to: to)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        let cx = x * size.width
        let cy = y * size.height
        if elapsed < 0.4 {
            let progress = max(0, elapsed / 0.4)
            let ease = 1 - pow(1 - progress, 2)
            func rise(_ value: Double) -> CGPoint {
                let eased = 1 - pow(1 - value, 2)
                return CGPoint(x: cx + sin(eased * .pi) * sway,
                               y: size.height + (cy - size.height) * eased)
            }
            let head = rise(progress)
            let span = 0.05 + 0.22 * (1 - ease)
            var previous = head
            for i in 1...6 {
                let point = rise(max(0, progress - span * Double(i) / 6))
                let fade = 1 - (Double(i) - 0.5) / 6
                line(previous, point, 2 * (0.35 + 0.65 * fade), base.opacity(0.5 * fade))
                previous = point
            }
            circle(head, 4, base.opacity(0.25))
            circle(head, 2.2, .white.opacity(0.95))
            return
        }
        let e = min(1, (elapsed - 0.4) / 1.6)
        let expand = 1 - pow(1 - e, 4)
        let radius = min(size.width, size.height) * 0.22
        let gravity = radius * 0.6
        if e < 0.18 {
            let flash = e / 0.18
            let flashRadius = radius * (0.2 + 0.5 * flash)
            let center = CGPoint(x: cx, y: cy)
            context.fill(Path(ellipseIn: CGRect(x: cx - flashRadius, y: cy - flashRadius,
                                               width: flashRadius * 2, height: flashRadius * 2)),
                         with: .radialGradient(Gradient(colors: [.white.opacity((1 - flash) * 0.5),
                                                                base.opacity((1 - flash) * 0.18), .clear]),
                                               center: center, startRadius: 0, endRadius: flashRadius))
        }
        // All 36 sparks sample the same three earlier times. Evaluate the
        // fourth-power expansion and stroke widths three times per frame,
        // rather than repeating them for every particle. Keep operation order
        // in each position/alpha expression to preserve the reference pixels.
        let tails = (1...3).map { TailSample(segment: $0, progress: e) }
        for (k, spark) in sparks.enumerated() {
            let pe = min(1, e / spark.life)
            guard pe < 1 else { continue }
            let ca = spark.cosine, sa = spark.sine
            let speed = spark.speed
            let fall = gravity * spark.weight
            let point = CGPoint(x: cx + ca * radius * speed * expand,
                                y: cy + sa * radius * speed * expand + fall * e * e)
            let flicker = 1 - (0.45 * pe) * (0.5 + 0.5 * sin(e * 24 + Double(k) * 1.7))
            let alpha = min(1, max(0, (1 - pe * pe) * flicker))
            var tail = point
            for sample in tails {
                let es = sample.time
                let r = radius * speed * sample.expansion
                let next = CGPoint(x: cx + ca * r, y: cy + sa * r + fall * es * es)
                line(tail, next, sample.width,
                     spark.tint.opacity(alpha * 0.4 * sample.fade))
                tail = next
            }
            circle(point, 3, spark.tint.opacity(alpha * 0.18))
            circle(point, 1.3, Self.tint(rgb, 1 - min(1, pe * 1.4) * (1 - spark.shade)).opacity(alpha))
        }
        for (k, dust) in stardust.enumerated() {
            let r = radius * dust.speed * expand
            let point = CGPoint(x: cx + dust.cosine * r,
                                y: cy + dust.sine * r + gravity * 0.45 * e * e + radius * 0.2 * e)
            let alpha = min(1, max(0, (1 - e) * max(0, sin(e * 32 + Double(k) * 2.3 + dust.phase))))
            if alpha > 0.02 { circle(point, 0.9, dustTint.opacity(alpha * 0.9)) }
        }
    }
}
