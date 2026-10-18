import SwiftUI
import UIKit

/// Axis intent is decided before recognition so vertical scrolling can win.
/// Movement is in fixed window coordinates, unaffected by the card's offset.
struct QueueCardSwipeTouch {
    enum Event: Equatable { case begin, delta(Float), reject }
    private var origin: CGPoint?
    private var previous = CGPoint.zero
    private(set) var dragging = false

    mutating func down(_ point: CGPoint) { origin = point; previous = point; dragging = false }
    mutating func handOff(to point: CGPoint) {
        guard let origin else { return }
        self.origin = CGPoint(x: point.x - (previous.x - origin.x),
                              y: point.y - (previous.y - origin.y))
        previous = point
    }
    mutating func move(_ point: CGPoint) -> [Event] {
        guard let origin else { return [] }
        let dx = point.x - previous.x
        previous = point
        if dragging { return [.delta(Float(dx))] }
        let x = point.x - origin.x, y = point.y - origin.y
        if abs(y) > 8 && abs(y) > abs(x) { self = Self(); return [.reject] }
        guard abs(x) > 8 else { return [] }
        dragging = true
        return [.begin, .delta(Float(x - (x < 0 ? -8 : 8)))]
    }
    mutating func reset() { self = Self() }
}

struct QueueCardSwipeModifier: ViewModifier {
    let enabled: Bool
    let removing: Bool
    let onRemove: () -> Void
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(QueueCardSwipeInput(enabled: enabled, removing: removing,
                                            onOffset: { offset = $0 }, onRemove: onRemove))
            .offset(x: offset)
            .accessibilityActions {
                if enabled {
                    Button(AppLocalized.resource("cd_remove_from_queue"), action: onRemove)
                }
            }
    }
}

/// A non-hit-testing marker, like PreviewPinchObserver. The recognizer belongs
/// to the nearest scroll view, accepts only this visible card, and fails early
/// for vertical intent. Buttons keep their touch until a horizontal drag wins.
struct QueueCardSwipeInput: UIViewRepresentable {
    let enabled: Bool
    let removing: Bool
    let onOffset: (CGFloat) -> Void
    let onRemove: () -> Void

    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) { view.configure(self) }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.detach() }

    final class Marker: UIView, UIGestureRecognizerDelegate {
        private var configuration: QueueCardSwipeInput?
        private var motion = QueueCardSwipeState(enabled: false)
        private var link: CADisplayLink?
        private weak var scroll: UIScrollView?
        lazy var recognizer: HorizontalGesture = {
            let value = HorizontalGesture()
            value.marker = self
            value.delegate = self
            value.cancelsTouchesInView = true
            value.delaysTouchesBegan = false
            return value
        }()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }

        func configure(_ next: QueueCardSwipeInput) {
            configuration = next
            motion.configure(enabled: next.enabled, removing: next.removing)
            recognizer.isEnabled = next.enabled
            updateClock()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard window != nil else { return }
            var parent = superview
            while let candidate = parent {
                if let scroll = candidate as? UIScrollView {
                    self.scroll = scroll
                    scroll.addGestureRecognizer(recognizer)
                    scroll.panGestureRecognizer.require(toFail: recognizer)
                    break
                }
                parent = candidate.superview
            }
            updateClock()
        }
        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            // Removing a recognizer can synchronously cancel a drag and start
            // restoration. Invalidate after that callback to avoid a live link
            // retaining a card which has left the lazy stack.
            link?.invalidate(); link = nil
            scroll = nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard configuration?.enabled == true, let scroll, window != nil,
                  bounds.contains(touch.location(in: self)),
                  scroll.bounds.contains(touch.location(in: scroll)) else { return false }
            return true
        }
        func deliver(_ events: [QueueCardSwipeTouch.Event]) {
            for event in events {
                switch event {
                case .begin: motion.beginDrag()
                case .delta(let amount): motion.drag(by: amount, width: Float(bounds.width))
                case .reject: break
                }
            }
            configuration?.onOffset(CGFloat(motion.offset))
            updateClock()
        }
        func endDrag(cancelled: Bool) {
            if cancelled { motion.cancelDrag() }
            else { motion.endDrag(width: Float(bounds.width), exitMargin: 48) }
            updateClock()
        }
        private func updateClock() {
            if !motion.isAnimating || window == nil { link?.invalidate(); link = nil; return }
            guard link == nil else { return }
            let next = ZTransferDisplayLink.make(owner: self) { $0.frame($1) }
            next.add(to: .main, forMode: .common)
            link = next
        }
        @objc private func frame(_ sender: CADisplayLink) {
            let remove = motion.advance(Int64(sender.timestamp * 1_000_000_000))
            configuration?.onOffset(CGFloat(motion.offset))
            updateClock()
            if remove, configuration?.enabled == true { configuration?.onRemove() }
        }
    }

    final class HorizontalGesture: UIGestureRecognizer {
        weak var marker: Marker?
        private var touch: UITouch?
        private var contacts: Set<UITouch> = []
        private var tracking = QueueCardSwipeTouch()
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            contacts.formUnion(touches)
            guard touch == nil, let first = touches.first else { return }
            touch = first
            tracking.down(first.location(in: view?.window))
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch, touches.contains(touch) else { return }
            let events = tracking.move(touch.location(in: view?.window))
            if events.contains(.reject) { state = .failed; return }
            if tracking.dragging { state = state == .possible ? .began : .changed }
            marker?.deliver(events)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            contacts.subtract(touches)
            guard let touch, touches.contains(touch) else { return }
            if let replacement = contacts.first {
                self.touch = replacement
                tracking.handOff(to: replacement.location(in: view?.window))
                return
            }
            let dragging = tracking.dragging
            tracking.reset()
            self.touch = nil
            if dragging { marker?.endDrag(cancelled: false) }
            state = dragging ? .ended : .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            let dragging = tracking.dragging
            tracking.reset()
            if dragging { marker?.endDrag(cancelled: true) }
            state = state == .possible ? .failed : .cancelled
        }
        override func reset() {
            super.reset()
            let dragging = tracking.dragging
            tracking.reset(); touch = nil; contacts.removeAll()
            if dragging { marker?.endDrag(cancelled: true) }
        }
    }
}
