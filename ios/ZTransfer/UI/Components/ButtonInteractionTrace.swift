#if DEBUG
import SwiftUI
import UIKit

/// Explicit UI-test instrumentation. Never enabled in a normal App launch;
/// no persisted data, screenshot polling or per-frame SwiftUI updates.
@MainActor
enum ButtonInteractionTrace {
    struct Event: Codable {
        let event: String
        let milliseconds: Int64
        var id: Int32 = 0
        var scale: Float = 1
        var light: Float = 0
        var active: Float = 0
        var pressed: Bool = false
        var scroll: Bool = false
    }
    static var enabled = false
    private static var events: [Event] = []
    static func record(_ event: Event) {
        guard enabled else { return }
        if events.count == 2048 { events.removeFirst(1024) }
        events.append(event)
    }
    static func reset() { events.removeAll(keepingCapacity: true) }
    static func snapshot() -> String {
        guard let data = try? JSONEncoder().encode(events) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Passive, test-only observation of UIKit's actual touch timestamps. It never
/// recognizes, prevents a recognizer, delays a touch or sends a button action.
struct ButtonInteractionTouchTrace: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {}
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        private var recognizer: TouchRecorder?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let recorder = TouchRecorder()
            window.addGestureRecognizer(recorder)
            recognizer = recorder
        }
        func detach() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }
    }

    final class TouchRecorder: UIGestureRecognizer {
        private var touches: Set<ObjectIdentifier> = []
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches {
                self.touches.insert(ObjectIdentifier(touch))
                ButtonInteractionTrace.record(.init(event: "touch-down", milliseconds: Int64(touch.timestamp * 1000)))
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches {
                self.touches.remove(ObjectIdentifier(touch))
                ButtonInteractionTrace.record(.init(event: "touch-up", milliseconds: Int64(touch.timestamp * 1000)))
            }
            if self.touches.isEmpty { state = .failed }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches {
                self.touches.remove(ObjectIdentifier(touch))
                ButtonInteractionTrace.record(.init(event: "touch-cancel", milliseconds: Int64(touch.timestamp * 1000)))
            }
            if self.touches.isEmpty { state = .failed }
        }
        override func reset() { super.reset(); touches.removeAll() }
    }
}
#endif
