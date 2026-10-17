import SwiftUI
import UIKit

/// One input owner for the whole ParamTile, including the 44×30 AUTO region.
/// Android detectVerticalDragGestures consumes only the delta past touch slop;
/// that consumed drag cancels the corner toggle and the full-list tap.
struct RemoteParameterTouch {
    enum Event: Equatable { case begin, delta(CGFloat), end, tap(CGPoint) }
    private var origin: CGPoint?
    private var previous = CGPoint.zero
    private(set) var dragging = false
    private var tapAllowed = false
    mutating func down(_ point: CGPoint) {
        origin = point; previous = point; tapAllowed = true; dragging = false
    }
    mutating func handOff(to point: CGPoint) {
        guard let origin else { return }
        // Compose follows another pressed pointer when the active one lifts.
        // Retain accumulated slop, but never count the distance between fingers.
        self.origin = CGPoint(x: point.x - (previous.x - origin.x), y: point.y - (previous.y - origin.y))
        previous = point
    }
    mutating func move(_ point: CGPoint, bounds: CGRect, writable: Bool) -> [Event] {
        guard let origin else { return [] }
        let delta = point.y - previous.y
        previous = point
        if dragging { return [.delta(delta)] }
        if !bounds.contains(point) { tapAllowed = false }
        let accumulated = point.y - origin.y
        guard writable, abs(accumulated) >= 8 else { return [] }
        dragging = true; tapAllowed = false
        return [.begin, .delta(accumulated - (accumulated > 0 ? 8 : -8))]
    }
    mutating func up(_ point: CGPoint, bounds: CGRect) -> [Event] {
        defer { self = Self() }
        guard origin != nil else { return [] }
        if dragging { return [.end] }
        return tapAllowed && bounds.contains(point) ? [.tap(point)] : []
    }
    mutating func cancel() -> [Event] {
        defer { self = Self() }
        return dragging ? [.end] : []
    }
}

struct RemoteParameterInput: UIViewRepresentable {
    let configuration: RemoteParameterWheel.Configuration
    let autoBusy: Bool
    let identifier: String
    let label: String
    let value: String
    let onOpenList: () -> Void
    let onAutoToggle: (() -> Void)?
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> InputView { InputView() }
    func updateUIView(_ view: InputView, context: Context) { view.configure(self) }
    static func dismantleUIView(_ view: InputView, coordinator: ()) { view.recognizer.cancel(notify: false) }

    final class InputView: UIView {
        var configuration: RemoteParameterInput?
        let recognizer = VerticalGesture()
        private lazy var valueElement = ActionElement(accessibilityContainer: self)
        private lazy var autoElement = ActionElement(accessibilityContainer: self)
        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isMultipleTouchEnabled = true
            recognizer.input = self
            addGestureRecognizer(recognizer)
        }
        required init?(coder: NSCoder) { nil }
        func configure(_ next: RemoteParameterInput) {
            if next.configuration.gestureKey != configuration?.configuration.gestureKey {
                // The wheel's configure() owns key-change cancellation. Do not
                // publish a second state mutation from updateUIView.
                recognizer.cancel(notify: false)
            }
            configuration = next
            valueElement.accessibilityIdentifier = next.identifier
            valueElement.accessibilityLabel = next.label
            valueElement.accessibilityValue = next.value
            valueElement.accessibilityTraits = next.configuration.writable ? .button : .staticText
            valueElement.action = { [weak self] in
                guard let c = self?.configuration, c.configuration.writable else { return false }
                c.onOpenList(); return true
            }
            autoElement.accessibilityIdentifier = next.identifier + "-auto"
            autoElement.accessibilityLabel = AppLocalized.resource("auto_iso")
            autoElement.accessibilityValue = next.configuration.autoEnabled == true ? "1" : "0"
            autoElement.accessibilityTraits = next.autoBusy ? [.button, .notEnabled] : .button
            autoElement.action = { [weak self] in
                guard let c = self?.configuration, !c.autoBusy else { return false }
                c.onAutoToggle?(); return true
            }
            accessibilityElements = next.configuration.hasAutoControl ? [valueElement, autoElement] : [valueElement]
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            valueElement.accessibilityFrameInContainerSpace = bounds
            autoElement.accessibilityFrameInContainerSpace = CGRect(x: bounds.width - 44, y: 0, width: 44, height: 30)
        }
        func deliver(_ events: [RemoteParameterTouch.Event]) {
            guard let c = configuration else { return }
            for event in events {
                switch event {
                case .begin: c.onBegin()
                case .delta(let dy): c.onDrag(dy)
                case .end: c.onEnd()
                case .tap(let point):
                    if c.configuration.hasAutoControl,
                       RemoteParameterTileGeometry(width: bounds.width, height: bounds.height).isAutoTouch(point) {
                        if !c.autoBusy { c.onAutoToggle?() }
                    } else if c.configuration.writable { c.onOpenList() }
                }
            }
        }
    }
    private final class ActionElement: UIAccessibilityElement {
        var action: (() -> Bool)?
        override func accessibilityActivate() -> Bool { action?() ?? false }
    }
    final class VerticalGesture: UIGestureRecognizer {
        weak var input: InputView?
        private var touch: UITouch?
        private var contacts: Set<UITouch> = []
        private var tracking = RemoteParameterTouch()
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            contacts.formUnion(touches)
            guard touch == nil, let first = touches.first, let input else { return }
            touch = first; tracking.down(first.location(in: input))
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch, touches.contains(touch), let input else { return }
            let events = tracking.move(touch.location(in: input), bounds: input.bounds,
                                       writable: input.configuration?.configuration.writable == true)
            if tracking.dragging { state = state == .possible ? .began : .changed }
            input.deliver(events)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            contacts.subtract(touches)
            guard let touch, touches.contains(touch), let input else { return }
            if let replacement = contacts.first {
                self.touch = replacement
                tracking.handOff(to: replacement.location(in: input))
                return
            }
            let events = tracking.up(touch.location(in: input), bounds: input.bounds)
            self.touch = nil
            state = events.isEmpty && state == .possible ? .failed : .ended
            input.deliver(events)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancel(notify: true) }
        func cancel(notify: Bool) {
            let events = tracking.cancel()
            touch = nil
            contacts.removeAll()
            if notify { input?.deliver(events) }
            // Toggling isEnabled also cancels recognition in the parent scroll
            // arena; the next touch is a fresh gesture, never a stale AUTO tap.
            isEnabled = false; isEnabled = true
        }
        override func reset() {
            super.reset()
            touch = nil
            contacts.removeAll()
            input?.deliver(tracking.cancel())
        }
    }
}
