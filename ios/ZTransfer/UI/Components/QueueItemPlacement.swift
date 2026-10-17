import SwiftUI
import UIKit

/// Motion.itemPlacement and LazyLayoutItemAnimation.animatePlacementDelta.
/// The spring animates an integer-pixel delta, independent of scroll position.
struct QueueItemPlacementMotion {
    private static let spring = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 500, threshold: 1)
    private var position: CGPoint?
    private var density: CGFloat = 1
    private var frame: Int64?
    private var startFrame: Int64?
    private var duration: Int64 = 0
    private var x = PlacementAxis()
    private var y = PlacementAxis()
    private(set) var isRunning = false
    var offset: CGSize {
        CGSize(width: CGFloat(x.delta) / density, height: CGFloat(y.delta) / density)
    }

    mutating func place(at point: CGPoint, scale: CGFloat) {
        guard point.x.isFinite, point.y.isFinite, scale.isFinite, scale > 0 else { return }
        let pixels = CGPoint(x: floor(point.x * scale + 0.5), y: floor(point.y * scale + 0.5))
        guard let previous = position, density == scale else {
            reset()
            position = pixels
            density = scale
            return
        }
        position = pixels
        let dx = Float(pixels.x - previous.x)
        let dy = Float(pixels.y - previous.y)
        guard dx != 0 || dy != 0 else { return }
        // IntOffset is one vector animation: both components keep sampling
        // until the maximum duration, including the shorter axis's velocity.
        x.move(by: dx, running: isRunning)
        y.move(by: dy, running: isRunning)
        duration = max(x.duration, y.duration, 0)
        startFrame = frame
        isRunning = true
        if let frame { advance(frame) }
    }

    mutating func advance(_ nanos: Int64) {
        guard isRunning else { return }
        if startFrame == nil { startFrame = nanos }
        let elapsed = max(nanos - startFrame!, 0)
        if elapsed >= duration {
            x.finish(); y.finish()
            isRunning = false
            frame = nil
            startFrame = nil
        } else {
            x.advance(elapsed); y.advance(elapsed)
            frame = nanos
        }
    }

    mutating func reset() { self = Self() }

    private struct PlacementAxis {
        private var value: Float = 0
        private var velocity: Float = 0
        private var target: Float = 0
        private var initialValue: Float = 0
        private var initialVelocity: Float = 0
        var delta: Float { floor(value + 0.5) - target }
        var duration: Int64 {
            QueueItemPlacementMotion.spring.durationNanos(from: initialValue, to: target,
                                                         velocity: initialVelocity)
        }
        mutating func move(by change: Float, running: Bool) {
                let totalDelta = delta - change
            if !running { value = totalDelta; velocity = 0 }
            initialValue = floor(value + 0.5)
            initialVelocity = velocity
            target = initialValue - totalDelta
            value = initialValue
        }
        mutating func advance(_ elapsed: Int64) {
            let sample = QueueItemPlacementMotion.spring.sample(at: elapsed, from: initialValue,
                                                                to: target, velocity: initialVelocity)
            value = sample.value
            velocity = sample.velocity
        }
        mutating func finish() { value = target; velocity = 0 }
    }
}

@MainActor
private final class QueueItemPlacementClock: ObservableObject {
    @Published private(set) var motion = QueueItemPlacementMotion()
    private var link: CADisplayLink?
    @MainActor
    private final class Target: NSObject {
        weak var owner: QueueItemPlacementClock?
        init(_ owner: QueueItemPlacementClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.motion.advance(Int64(link.timestamp * 1_000_000_000))
            if !owner.motion.isRunning { owner.stop() }
        }
    }
    func place(at point: CGPoint, scale: CGFloat) {
        motion.place(at: point, scale: scale)
        guard motion.isRunning, link == nil else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    func reset() { stop(); motion.reset() }
}

private struct QueueItemPlacementKey: PreferenceKey {
    static let defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        if let next = nextValue() { value = next }
    }
}

struct QueueItemPlacement: ViewModifier {
    static let coordinateSpace = "transfer-queue-content-placement"
    @Environment(\.displayScale) private var displayScale
    @StateObject private var clock = QueueItemPlacementClock()
    @State private var origin: CGPoint?
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .offset(clock.motion.offset)
            // Outside the visual offset: observe the unanimated layout target.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: QueueItemPlacementKey.self,
                        value: proxy.frame(in: .named(Self.coordinateSpace)).origin)
                }
            }
            .onPreferenceChange(QueueItemPlacementKey.self) { point in
                guard let point else { return }
                origin = point
                if visible { clock.place(at: point, scale: displayScale) }
            }
            .onChange(of: displayScale) { scale in
                if visible, let origin { clock.place(at: origin, scale: scale) }
            }
            .onAppear {
                visible = true
                if let origin { clock.place(at: origin, scale: displayScale) }
            }
            .onDisappear { visible = false; clock.reset() }
    }
}
