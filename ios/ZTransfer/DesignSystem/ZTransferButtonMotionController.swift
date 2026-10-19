import SwiftUI
import UIKit

/// A display link retains its target, including while the app is suspended.
/// Keep the visual owner weak without changing the caller's clock, run-loop,
/// phase or stop/resume policy (performance ledger P33). The callback must use
/// its owner argument rather than capture the owner.
@MainActor
enum ZTransferDisplayLink {
    static func make<Owner: AnyObject>(owner: Owner,
                                      frame: @escaping (Owner, CADisplayLink) -> Void) -> CADisplayLink {
        let target = Target(owner: owner) { owner, link in
            if let owner = owner as? Owner { frame(owner, link) }
        }
        return CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
    }

    private final class Target: NSObject {
        weak var owner: AnyObject?
        let frame: (AnyObject, CADisplayLink) -> Void
        init(owner: AnyObject, frame: @escaping (AnyObject, CADisplayLink) -> Void) {
            self.owner = owner
            self.frame = frame
        }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            frame(owner, link)
        }
    }
}

/// Owns only visual feedback. The native Button still owns recognition, focus,
/// accessibility and immediate action delivery. A successful activation repairs
/// a Press/Release that SwiftUI may have coalesced into one isPressed value.
@MainActor
final class ZTransferButtonMotionController: ObservableObject {
    @Published private(set) var frame: ZTransferButtonMotion.Frame
    private(set) var motion: ZTransferButtonMotion
    private var nextID: UInt64 = 0
    private var inputID: UInt64?
    private var emittedPress = false
    private var enabled: Bool
    private var active: Bool
    private var nativePressed = false
    private var releasedByClick = false
    var inScrollableContainer = false
    var observesPhysicalPress = false
    private var delayTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var scheduledHoldDeadline: Int64?
    private var cancellationTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private let clock: () -> Int64
    private let automaticallySchedule: Bool
    #if DEBUG
    var traceID: Int32 = 0
    #endif

    init(skin: ZTransferButtonSkin, panel: Bool, active: Bool, enabled: Bool,
         automaticallySchedule: Bool = true,
         clock: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) }) {
        motion = ZTransferButtonMotion(skin: skin, panel: panel, active: active, enabled: enabled)
        frame = motion.frame
        self.active = active
        self.enabled = enabled
        self.clock = clock
        self.automaticallySchedule = automaticallySchedule
    }

    func configure(skin: ZTransferButtonSkin, panel: Bool, active: Bool, enabled: Bool) {
        self.active = active
        if self.enabled != enabled {
            clearInput()
            self.enabled = enabled
        }
        motion.configure(skin: skin, panel: panel, active: active, enabled: enabled)
        publishAndSchedule()
    }

    func nativePressChanged(_ pressed: Bool) {
        trace(pressed ? "native-down" : "native-up")
        guard !observesPhysicalPress else { return }
        pressChanged(pressed)
    }

    func physicalPressChanged(_ pressed: Bool) {
        // A real new touch distinguishes it from an isPressed callback that
        // arrived after the previous touch's already-delivered Button action.
        if pressed { releasedByClick = false }
        guard observesPhysicalPress else { return }
        pressChanged(pressed)
    }

    private func pressChanged(_ pressed: Bool) {
        guard enabled, nativePressed != pressed else { return }
        nativePressed = pressed
        if pressed {
            // A click may precede the coalesced isPressed callback. Its visual
            // release is already scheduled and must not become a held press.
            guard !releasedByClick else { return }
            cancellationTask?.cancel()
            nextID &+= 1
            inputID = nextID
            emittedPress = false
            if inScrollableContainer {
                if automaticallySchedule {
                    let id = nextID
                    delayTask = Task { [weak self] in
                        // Foundation TapIndicationDelay -> Android
                        // ViewConfiguration.TAP_TIMEOUT (100ms).
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard !Task.isCancelled else { return }
                        self?.emitDelayedPress(id: id)
                    }
                }
            } else {
                emitDelayedPress(id: nextID)
            }
        } else {
            if releasedByClick {
                releasedByClick = false
                return
            }
            // Native action and isPressed updates have no public ordering
            // guarantee. Give that same event a chance to deliver its action
            // before classifying a false edge as cancellation.
            if automaticallySchedule {
                cancellationTask?.cancel()
                cancellationTask = Task { [weak self] in
                    // Task.yield may resume immediately on the same actor,
                    // before UIKit finishes dispatching this release's action.
                    // Cross a main-queue turn instead of adding a time delay.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    guard !Task.isCancelled else { return }
                    self?.resolveUnsuccessfulRelease()
                }
            }
        }
    }

    func emitDelayedPress(id: UInt64? = nil) {
        guard enabled, let current = inputID, id == nil || id == current, !emittedPress else { return }
        emittedPress = true
        motion.press(current, at: clock())
        trace("press-emitted")
        publishAndSchedule()
    }

    /// Called immediately before configuration.trigger(). No waiting, dispatch
    /// or animation completion is inserted in the business action's path.
    func successfulActivation() {
        guard enabled else { return }
        trace("action")
        cancellationTask?.cancel()
        cancellationTask = nil
        delayTask?.cancel()
        delayTask = nil
        if inputID == nil {
            nextID &+= 1
            inputID = nextID
            emittedPress = false
        }
        let id = inputID!
        if !emittedPress {
            motion.press(id, at: clock())
            trace("press-emitted")
        }
        motion.release(id, at: clock())
        trace("release-emitted")
        inputID = nil
        emittedPress = false
        releasedByClick = true
        publishAndSchedule()
    }

    func resolveUnsuccessfulRelease() {
        guard !nativePressed else { return }
        delayTask?.cancel()
        delayTask = nil
        if let id = inputID, emittedPress {
            motion.cancel(id)
            trace("cancel-emitted")
        }
        inputID = nil
        emittedPress = false
        publishAndSchedule()
    }

    func advanceFrame(nanos: Int64) {
        motion.advanceFrame(nanos: nanos)
        publishAndSchedule()
    }

    func advanceHold() {
        motion.advanceHold(to: clock())
        trace("hold-ended")
        publishAndSchedule()
    }

    func stop() {
        clearInput()
        motion.reset(active: active)
        displayLink?.invalidate()
        displayLink = nil
        publishFrame()
    }

    private func clearInput() {
        delayTask?.cancel()
        holdTask?.cancel()
        cancellationTask?.cancel()
        delayTask = nil
        holdTask = nil
        scheduledHoldDeadline = nil
        cancellationTask = nil
        inputID = nil
        emittedPress = false
        nativePressed = false
        releasedByClick = false
    }

    private func publishAndSchedule() {
        publishFrame()
        guard automaticallySchedule else { return }
        if motion.needsFrames {
            if displayLink == nil {
                let target = DisplayLinkTarget(owner: self)
                let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.frame(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
        let deadline = motion.press.releaseDeadline
        guard deadline != scheduledHoldDeadline else { return }
        holdTask?.cancel()
        holdTask = nil
        scheduledHoldDeadline = deadline
        if let deadline {
            let milliseconds = max(deadline - clock(), 0)
            holdTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.advanceHold()
            }
        }
    }

    private func publishFrame() {
        guard frame != motion.frame else { return }
        // Values already come from the Android equations. Do not let an outer
        // SwiftUI transaction interpolate these frame values a second time.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { frame = motion.frame }
        trace("frame")
    }

    private func trace(_ event: String) {
        #if DEBUG
        ButtonInteractionTrace.record(.init(event: event, milliseconds: clock(), id: traceID,
            scale: motion.frame.scale, light: motion.frame.light, active: motion.frame.active,
            pressed: motion.press.visualPressed, scroll: inScrollableContainer))
        #endif
    }

    // CADisplayLink retains its target. Keep the reverse edge weak so a removed
    // SwiftUI button cannot retain a frame clock forever.
    @MainActor private final class DisplayLinkTarget: NSObject {
        weak var owner: ZTransferButtonMotionController?
        init(owner: ZTransferButtonMotionController) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advanceFrame(nanos: Int64(link.timestamp * 1_000_000_000))
        }
    }
}

/// Reads scroll ancestry and observes raw touches for visual/hold feedback.
/// A shared, non-recognizing window observer avoids stacking UIKit's scroll
/// delivery delay with Android's 100ms indication delay. Native Button remains
/// the sole owner of activation; no scroll delegate or recognizer is replaced.
struct ZTransferButtonScrollContext: UIViewRepresentable {
    let motion: ZTransferButtonMotionController
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.motion = motion
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.motion = motion
        view.report()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }
    final class Probe: UIView {
        weak var motion: ZTransferButtonMotionController?
        var onPressChanged: ((Bool) -> Void)?
        var maximumMovement: CGFloat = 8
        weak var scroll: UIScrollView?
        weak var observer: PressObserver?
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); report() }
        func report() {
            var parent = superview
            var container: UIScrollView?
            while let view = parent {
                if let candidate = view as? UIScrollView, candidate.isScrollEnabled {
                    container = candidate
                    break
                }
                parent = view.superview
            }
            motion?.inScrollableContainer = container != nil
            guard let window else { detach(); return }
            scroll = container
            if observer?.view !== window {
                detach()
                scroll = container
                let shared = window.gestureRecognizers?.compactMap { $0 as? PressObserver }.first ?? PressObserver()
                if shared.view == nil { window.addGestureRecognizer(shared) }
                shared.probes.add(self)
                observer = shared
            }
            motion?.observesPhysicalPress = container != nil
        }
        func detach() {
            observer?.remove(self)
            observer = nil; scroll = nil
            motion?.observesPhysicalPress = false
        }
        func pressChanged(_ pressed: Bool) {
            motion?.physicalPressChanged(pressed)
            onPressChanged?(pressed)
        }
        func accepts(_ touch: UITouch) -> Bool {
            guard let window, bounds.width > 0, bounds.height > 0,
                  bounds.contains(touch.location(in: self)) else { return false }
            // A popup can overlap a button without hiding its backing view.
            // Only touches actually delivered inside its scroll subtree count.
            if let scroll {
                guard scroll.isScrollEnabled, touch.view?.isDescendant(of: scroll) == true else { return false }
            }
            var candidate: UIView? = self
            while let view = candidate, view !== window {
                if view.isHidden || view.alpha <= 0.01 { return false }
                candidate = view.superview
            }
            return true
        }
    }

    final class PressObserver: UIGestureRecognizer {
        let probes = NSHashTable<Probe>.weakObjects()
        private var held = NSHashTable<Probe>.weakObjects()
        private var contact: UITouch?
        private var origin = CGPoint.zero
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false; delaysTouchesEnded = false
        }
        convenience init() { self.init(target: nil, action: nil) }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard contact == nil, touches.count == 1, let touch = touches.first else { cancel(); return }
            contact = touch; origin = touch.location(in: view)
            for probe in probes.allObjects where probe.accepts(touch) {
                held.add(probe)
                probe.pressChanged(true)
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let contact else { return }
            let point = contact.location(in: view)
            let distance = hypot(point.x - origin.x, point.y - origin.y)
            for probe in held.allObjects where distance > probe.maximumMovement {
                probe.pressChanged(false)
                held.remove(probe)
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if let contact, touches.contains(contact) { cancel() }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancel() }
        override func reset() { super.reset(); cancelHeld(); contact = nil }
        func remove(_ probe: Probe) {
            if held.contains(probe) { probe.pressChanged(false); held.remove(probe) }
            probes.remove(probe)
            if probes.allObjects.isEmpty { view?.removeGestureRecognizer(self) }
        }
        private func cancelHeld() {
            for probe in held.allObjects { probe.pressChanged(false) }
            held.removeAllObjects()
        }
        private func cancel() {
            cancelHeld(); contact = nil; state = .failed
        }
    }
}

/// Shares the existing non-recognizing window observer. No recognizer is
/// attached to the photo's exclusive tap/hold gesture, so feedback cannot
/// change its timing or consume a tap/scroll. Only reverse-transfer cells use it.
struct ZTransferHoldTouchObservation: UIViewRepresentable {
    let haptics: ZTransferHaptics
    let durationMilliseconds: Int
    let maximumMovement: CGFloat
    func makeUIView(context: Context) -> ZTransferButtonScrollContext.Probe {
        let view = ZTransferButtonScrollContext.Probe()
        view.isUserInteractionEnabled = false
        configure(view)
        return view
    }
    func updateUIView(_ view: ZTransferButtonScrollContext.Probe, context: Context) {
        configure(view)
        view.report()
    }
    static func dismantleUIView(_ view: ZTransferButtonScrollContext.Probe, coordinator: ()) { view.detach() }
    private func configure(_ view: ZTransferButtonScrollContext.Probe) {
        view.maximumMovement = maximumMovement
        view.onPressChanged = { pressed in
            if pressed { haptics.startProgressiveHold(durationMilliseconds: durationMilliseconds) }
            else { haptics.cancelProgressiveHold() }
        }
    }
}
