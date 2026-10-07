import SwiftUI
import UIKit

// Transform calculations ported from AndroidX Compose Foundation 1.7.6
// (Copyright The Android Open Source Project, Apache-2.0; see Resources/licenses).
/// Compose 1.7.6 TransformGestureDetector: centroid/radius use pointers present
/// in both samples. Rotation participates in slop even though the monitor ignores it.
struct RemoteViewfinderTransformGesture {
    private var accumulatedZoom: Float = 1
    private var accumulatedRotation: Float = 0
    private var accumulatedPan = SIMD2<Float>.zero
    private(set) var active = false

    struct Change {
        let centroid: CGPoint
        let pan: CGSize
        let zoom: Float
    }

    mutating func sample(previous: [CGPoint], current: [CGPoint], slop: Float = 8) -> Change? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }
        let old = previous.map { SIMD2(Float($0.x), Float($0.y)) }
        let new = current.map { SIMD2(Float($0.x), Float($0.y)) }
        func length(_ p: SIMD2<Float>) -> Float { sqrt(p.x * p.x + p.y * p.y) }
        let oldCenter = old.reduce(.zero, +) / Float(old.count)
        let newCenter = new.reduce(.zero, +) / Float(new.count)
        let oldRadius = old.reduce(Float(0)) { $0 + length($1 - oldCenter) } / Float(old.count)
        let newRadius = new.reduce(Float(0)) { $0 + length($1 - newCenter) } / Float(new.count)
        let zoom: Float = oldRadius == 0 || newRadius == 0 ? 1 : newRadius / oldRadius
        let pan = newCenter - oldCenter
        var rotation: Float = 0, weights: Float = 0
        if old.count > 1 {
            func angle(_ p: SIMD2<Float>) -> Float { p == .zero ? 0 : -atan2(p.x, p.y) * 180 / .pi }
            for (a, b) in zip(old, new) {
                let before = a - oldCenter, after = b - newCenter
                var difference = angle(after) - angle(before)
                if difference > 180 { difference -= 360 }
                if difference < -180 { difference += 360 }
                let weight = length(after + before) / 2
                rotation += difference * weight
                weights += weight
            }
            rotation = weights == 0 ? 0 : rotation / weights
        }
        if !active {
            accumulatedZoom *= zoom
            accumulatedRotation += rotation
            accumulatedPan += pan
            active = abs(1 - accumulatedZoom) * oldRadius > slop
                || abs(accumulatedRotation * .pi * oldRadius / 180) > slop
                || length(accumulatedPan) > slop
        }
        guard active, zoom != 1 || pan != .zero || rotation != 0 else { return nil }
        return Change(centroid: CGPoint(x: CGFloat(oldCenter.x), y: CGFloat(oldCenter.y)),
                      pan: CGSize(width: CGFloat(pan.x), height: CGFloat(pan.y)), zoom: zoom)
    }
}

/// Local touch surface: it is transformed with the monitor's layout rotation,
/// but never with its image zoom. Menus above it retain normal hit testing.
struct RemoteViewfinderInputIdentity: Equatable {
    let aspect: CGFloat
    let imageSize: CGSize
    let trackingSize: CGSize
    let focusSize: CGSize

    init(aspect: CGFloat, imageSize: CGSize, metadata: RemoteLiveViewMetadata? = nil) {
        self.aspect = aspect
        self.imageSize = imageSize
        trackingSize = CGSize(width: metadata?.trackingCoordinateWidth ?? Int(imageSize.width),
                              height: metadata?.trackingCoordinateHeight ?? Int(imageSize.height))
        focusSize = CGSize(width: metadata?.focusCoordinateWidth ?? Int(imageSize.width),
                           height: metadata?.focusCoordinateHeight ?? Int(imageSize.height))
    }
}

struct RemoteViewfinderInput: UIViewRepresentable {
    let identity: RemoteViewfinderInputIdentity
    let onTransform: (RemoteViewfinderTransformGesture.Change) -> Void
    let acceptsTap: (CGPoint) -> Bool
    let onTap: (CGPoint) -> Void
    let onDoubleTap: () -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.updateIdentity(identity)
        view.onTransform = onTransform; view.acceptsTap = acceptsTap
        view.onTap = onTap; view.onDoubleTap = onDoubleTap
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.clear() }

    final class Surface: UIView {
        var onTransform: ((RemoteViewfinderTransformGesture.Change) -> Void)?
        var acceptsTap: ((CGPoint) -> Bool)?
        var onTap: ((CGPoint) -> Void)?
        var onDoubleTap: (() -> Void)?
        private var identity: RemoteViewfinderInputIdentity?
        private var points: [UITouch: CGPoint] = [:]
        private var transformGesture = RemoteViewfinderTransformGesture()
        private var tapCancelled = false
        private var secondTap = false
        private var ignoredEarlyTap = false
        private var firstTap: (point: CGPoint, timestamp: TimeInterval)?
        private var tapWork: DispatchWorkItem?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityIdentifier = "remote-viewfinder-input"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { clear() } }

        func updateIdentity(_ next: RemoteViewfinderInputIdentity) {
            defer { identity = next }
            guard let previous = identity, previous != next else { return }
            // Android restarts the outer transform detector only for an aspect
            // change; the image child's tap detector has all coordinate keys.
            if previous.aspect != next.aspect { clear() }
            firstTap = nil
            tapWork?.cancel(); tapWork = nil
            tapCancelled = true
            secondTap = false
            ignoredEarlyTap = true
        }

        private func trace(_ event: String) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--remote-camera-tools-ui-test") {
                accessibilityValue = String(((accessibilityValue ?? "") + " | " + event).suffix(1600))
            }
            #endif
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            trace("down t=\(touches.first?.timestamp ?? 0) pending=\(firstTap?.timestamp ?? 0)")
            if points.isEmpty {
                transformGesture = RemoteViewfinderTransformGesture()
                tapCancelled = false
                secondTap = false
                ignoredEarlyTap = false
                if let down = touches.first, acceptsTap?(down.location(in: self)) == false {
                    // The clipped image child receives no down in the letterbox;
                    // its double-tap detector must not start there. The outer
                    // transform surface still handles panning and pinching.
                    tapCancelled = true
                    ignoredEarlyTap = true
                } else if let first = firstTap, let down = touches.first {
                    let elapsed = down.timestamp - first.timestamp
                    if elapsed >= 0.04 && elapsed <= 0.3 {
                        secondTap = true
                        tapWork?.cancel(); tapWork = nil
                    } else if elapsed < 0.04 {
                        // awaitSecondDown ignores down events before the minimum.
                        ignoredEarlyTap = true
                    } else { deliverFirstTap() }
                }
            }
            updateExistingTouches()
            for touch in touches { points[touch] = touch.location(in: self) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            updateExistingTouches()
        }

        private func updateExistingTouches() {
            // On down/up events sample only the surviving pointers, before adding
            // new touches or after removing lifted ones, just like Compose.
            let keys = Array(points.keys)
            let previous = keys.compactMap { points[$0] }
            let current = keys.map { $0.location(in: self) }
            let change = transformGesture.sample(previous: previous, current: current)
            for (touch, point) in zip(keys, current) { points[touch] = point }
            if transformGesture.active || current.contains(where: { !bounds.contains($0) }) { cancelTap() }
            if let change { onTransform?(change) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let last = touches.max { $0.timestamp < $1.timestamp }
            for touch in touches { points.removeValue(forKey: touch) }
            updateExistingTouches()
            guard points.isEmpty, let last else { return }
            let point = last.location(in: self)
            trace("up t=\(last.timestamp) cancel=\(tapCancelled) early=\(ignoredEarlyTap) second=\(secondTap)")
            guard !tapCancelled, !ignoredEarlyTap, bounds.contains(point) else { return }
            finishTap(at: point, timestamp: last.timestamp)
        }

        func finishTap(at point: CGPoint, timestamp: TimeInterval) {
            guard !tapCancelled, !ignoredEarlyTap else { return }
            if secondTap {
                firstTap = nil; tapWork?.cancel(); tapWork = nil
                onDoubleTap?()
            } else {
                firstTap = (point, timestamp)
                let work = DispatchWorkItem { [weak self] in self?.deliverFirstTap() }
                tapWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            trace("cancel")
            cancelTap(); points.removeAll()
        }
        private func cancelTap() {
            tapCancelled = true
            if secondTap { secondTap = false; deliverFirstTap() }
        }
        private func deliverFirstTap() {
            let point = firstTap?.point
            firstTap = nil; tapWork?.cancel(); tapWork = nil
            if let point { onTap?(point) }
        }
        func clear() {
            trace("clear")
            points.removeAll(); firstTap = nil
            tapWork?.cancel(); tapWork = nil
            transformGesture = RemoteViewfinderTransformGesture()
        }
    }
}
