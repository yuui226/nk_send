import SwiftUI
import UIKit

/// A non-hit-testing viewport marker. The recognizer observes its window but
/// accepts only touches beginning in this page, leaving single-finger paging alone.
struct PreviewPinchObserver: UIViewRepresentable {
    let enabled: Bool
    let onActive: (Bool) -> Void
    let onChange: (CGFloat, CGPoint, CGSize) -> Void

    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) {
        view.onActive = onActive
        view.onChange = onChange
        if !enabled { view.recognizer.clearTracking() }
        view.recognizer.isEnabled = enabled
    }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.detach() }

    final class Marker: UIView, UIGestureRecognizerDelegate {
        var onActive: ((Bool) -> Void)?
        var onChange: ((CGFloat, CGPoint, CGSize) -> Void)?
        lazy var recognizer: TouchTransform = {
            let value = TouchTransform()
            value.marker = self
            value.delegate = self
            value.cancelsTouchesInView = true
            return value
        }()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(recognizer)
        }
        func detach() {
            recognizer.clearTracking()
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard window != nil, !isHidden, bounds.width > 0, bounds.height > 0 else { return false }
            return bounds.contains(touch.location(in: self))
        }
    }

    final class TouchTransform: UIGestureRecognizer {
        weak var marker: Marker?
        private var points: [UITouch: CGPoint] = [:]
        private var active = false
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let marker else { state = .failed; return }
            for touch in touches { points[touch] = touch.location(in: marker) }
            if points.count >= 2, !active {
                active = true
                marker.onActive?(true)
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let marker, active, !points.isEmpty else { return }
            let previous = Array(points.values)
            let current = points.keys.map { $0.location(in: marker) }
            let delta = previewTouchTransform(previous: previous, current: current)
            for touch in Array(points.keys) { points[touch] = touch.location(in: marker) }
            guard delta.factor != 1 || delta.pan != .zero else { return }
            state = state == .possible ? .began : .changed
            marker.onChange?(delta.factor, delta.centroid, delta.pan)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches { points.removeValue(forKey: touch) }
            if points.isEmpty { state = state == .possible ? .failed : .ended }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = state == .possible ? .failed : .cancelled
        }
        override func reset() {
            super.reset()
            clearTracking()
        }
        func clearTracking() {
            points.removeAll()
            let wasActive = active
            active = false
            if wasActive { marker?.onActive?(false) }
        }
    }
}

/// Compose calculateZoom/calculatePan use the mean radius and centroid of the
/// pointers present in both samples, not a fixed first-two-finger distance.
func previewTouchTransform(previous: [CGPoint], current: [CGPoint]) ->
    (factor: CGFloat, centroid: CGPoint, pan: CGSize) {
    guard !previous.isEmpty, previous.count == current.count else { return (1, .zero, .zero) }
    func center(_ points: [CGPoint]) -> CGPoint {
        CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
    }
    func radius(_ points: [CGPoint], _ center: CGPoint) -> CGFloat {
        points.reduce(0) { $0 + hypot($1.x - center.x, $1.y - center.y) } / CGFloat(points.count)
    }
    let old = center(previous), new = center(current)
    let oldRadius = radius(previous, old), newRadius = radius(current, new)
    let factor = oldRadius > 0 && newRadius > 0 ? newRadius / oldRadius : 1
    return (factor, new, CGSize(width: new.x - old.x, height: new.y - old.y))
}
