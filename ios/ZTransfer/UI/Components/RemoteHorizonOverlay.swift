import SwiftUI
import UIKit

@MainActor
private final class RemoteHorizonClock: NSObject, ObservableObject {
    @Published var state: RemoteHorizonAnimation
    private var link: CADisplayLink?
    init(roll: Float, pitch: Float?) { state = .init(roll: roll, pitch: pitch) }
    func update(roll: Float, pitch: Float?) {
        state.update(roll: roll, pitch: pitch)
        guard state.isRunning, link == nil else { return }
        let next = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ sender: CADisplayLink) {
        state.advance(Int64(sender.timestamp * 1_000_000_000))
        if !state.isRunning { stop() }
    }
    func stop() { link?.invalidate(); link = nil }
}

struct RemoteHorizonOverlay: View {
    let roll: Float
    let pitch: Float?
    @StateObject private var clock: RemoteHorizonClock
    init(roll: Float, pitch: Float?) {
        self.roll = roll; self.pitch = pitch
        _clock = StateObject(wrappedValue: RemoteHorizonClock(roll: roll, pitch: pitch))
    }
    var body: some View {
        RemoteHorizonDrawing(state: clock.state)
            .overlay {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--remote-level-ui-test") {
                    Text(verbatim: "dual=\(clock.state.hasPitch);angle=\(clock.state.angle.value)")
                        .font(.system(size: 1)).allowsHitTesting(false)
                        .accessibilityIdentifier("remote-horizon-state")
                }
                #endif
            }
            .onAppear { clock.update(roll: roll, pitch: pitch) }
            .onChange(of: roll) { clock.update(roll: $0, pitch: pitch) }
            .onChange(of: pitch) { clock.update(roll: roll, pitch: $0) }
            .onDisappear { clock.stop() }
    }
}

/// ViewfinderLevelOverlay: only short fixed ticks; pitch is a rotating chord.
struct RemoteHorizonDrawing: View {
    let state: RemoteHorizonAnimation
    private func color(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255,
              opacity: Double(value >> 24) / 255)
    }
    var body: some View {
        Canvas { context, size in
            let radius = min(Float(size.width) * 0.19, Float(size.height) * 0.28)
            guard radius >= 18 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = CGFloat(radius)
            let outline = color(0x3D000000)
            func circle(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            func line(_ start: CGPoint, _ end: CGPoint) -> Path {
                var path = Path(); path.move(to: start); path.addLine(to: end); return path
            }
            context.stroke(circle(r), with: .color(color(0x1F000000)), lineWidth: 1.5)
            context.stroke(circle(r), with: .color(color(state.reference.value)), lineWidth: 0.75)
            for side in [CGFloat(-1), 1] {
                context.stroke(line(CGPoint(x: center.x + side * (r - 4), y: center.y),
                                    CGPoint(x: center.x + side * r, y: center.y)),
                               with: .color(color(state.reference.value)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                context.stroke(line(CGPoint(x: center.x, y: center.y + side * (r - 4)),
                                    CGPoint(x: center.x, y: center.y + side * r)),
                               with: .color(color(state.reference.value)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            var rotated = context
            rotated.translateBy(x: center.x, y: center.y)
            rotated.rotate(by: .degrees(Double(state.angle.value)))
            rotated.translateBy(x: -center.x, y: -center.y)
            let inner = max(0, radius - 2)
            if state.hasPitch {
                let y = state.pitchOffset.value * inner * 0.75
                let half = sqrt(max(0, inner * inner - y * y))
                let chord = line(CGPoint(x: center.x - CGFloat(half), y: center.y + CGFloat(y)),
                                 CGPoint(x: center.x + CGFloat(half), y: center.y + CGFloat(y)))
                rotated.stroke(chord, with: .color(outline), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                rotated.stroke(chord, with: .color(color(state.pitchTint.value)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            let diameter = line(CGPoint(x: center.x - CGFloat(inner), y: center.y),
                                CGPoint(x: center.x + CGFloat(inner), y: center.y))
            rotated.stroke(diameter, with: .color(outline), style: StrokeStyle(lineWidth: CGFloat(state.stroke.value + 1), lineCap: .round))
            rotated.stroke(diameter, with: .color(color(state.tint.value)), style: StrokeStyle(lineWidth: CGFloat(state.stroke.value), lineCap: .round))
            context.fill(circle(3), with: .color(outline))
            let marker = state.hasPitch ? (state.pitchAligned ? RemoteHorizonAnimation.green : RemoteHorizonAnimation.amber) : state.tint.value
            context.fill(circle(state.aligned ? 2.2 : 1.5), with: .color(color(marker)))
        }
    }
}
