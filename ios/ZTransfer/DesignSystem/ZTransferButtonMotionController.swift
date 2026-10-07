import SwiftUI
import UIKit

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
                    await Task.yield()
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
        releasedByClick = nativePressed
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

/// Reads the real hierarchy; no gesture recognizer or scroll delegate is replaced.
struct ZTransferButtonScrollContext: UIViewRepresentable {
    let changed: (Bool) -> Void
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.changed = changed
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.changed = changed
        view.report()
    }
    final class Probe: UIView {
        var changed: ((Bool) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); report() }
        func report() {
            var parent = superview
            while let view = parent {
                if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                    changed?(true)
                    return
                }
                parent = view.superview
            }
            changed?(false)
        }
    }
}
