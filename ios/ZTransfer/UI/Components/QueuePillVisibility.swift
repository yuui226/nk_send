import SwiftUI
import UIKit

/// Compose IntSize spring: both axes share the longer duration, and expose
/// integer pixels. Do not snap one axis early while the other is still moving.
struct QueuePillSizeSpring {
    private(set) var value: SIMD2<Float>
    private(set) var velocity = SIMD2<Float>.zero
    private(set) var target: SIMD2<Float>
    private(set) var isRunning = false
    private var initial: SIMD2<Float>
    private var initialVelocity = SIMD2<Float>.zero
    private var spec = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 400, threshold: 1)
    private var start: Int64?
    private var duration: Int64 = 0
    var pixels: SIMD2<Float> { .init(floor(value.x + 0.5), floor(value.y + 0.5)) }

    init(_ value: SIMD2<Float>) { self.value = value; initial = value; target = value }

    mutating func retarget(_ target: SIMD2<Float>, spec: ZTransferAndroidMotion,
                          force: Bool, origin: Int64?) {
        guard force || target != self.target else { return }
        initial = pixels; value = initial; initialVelocity = velocity
        self.target = target; self.spec = spec; start = origin
        duration = max(spec.durationNanos(from: initial.x, to: target.x, velocity: velocity.x),
                       spec.durationNanos(from: initial.y, to: target.y, velocity: velocity.y))
        isRunning = true
        if let origin { advance(origin) }
    }

    mutating func advance(_ nanos: Int64) {
        guard isRunning else { return }
        if start == nil { start = nanos }
        let elapsed = max(0, nanos - start!)
        if elapsed >= duration {
            value = target; velocity = .zero; isRunning = false; start = nil
        } else {
            let x = spec.sample(at: elapsed, from: initial.x, to: target.x, velocity: initialVelocity.x)
            let y = spec.sample(at: elapsed, from: initial.y, to: target.y, velocity: initialVelocity.y)
            value = .init(x.value, y.value); velocity = .init(x.velocity, y.velocity)
        }
    }
}

/// TransferPillVisibility / EnterExitTransition.kt (Compose 1.7.6).
/// Only PreEnter -> Visible has a delay/bounce; reversing PostExit uses the
/// default 400 spring. Content remains live, including nullable content clearing.
struct QueuePillVisibilityMotion {
    /// TransferRetryButton shares the retained horizontal layout, but uses
    /// Compose's default fade/IntSize springs without pill delay/slide/scale.
    enum Style { case pill, retry }
    private enum Phase { case preEnter, visible, postExit }
    private(set) var visible: Bool
    private(set) var retained: Bool
    private(set) var alpha: ZTransferScalarAnimation
    private(set) var scale: ZTransferScalarAnimation
    private(set) var slide: ZTransferScalarAnimation
    private(set) var size = QueuePillSizeSpring(.zero)
    private var fullSize: SIMD2<Float>?
    private var phase: Phase
    private var pendingEntry = false
    private var lastFrame: Int64?
    private var density: CGFloat = 1
    private let delay: Int64
    let style: Style
    private var sizeSpec = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 400, threshold: 1)
    var isRunning: Bool { alpha.isRunning || scale.isRunning || slide.isRunning || size.isRunning }
    var displayedSize: CGSize? {
        guard fullSize != nil || pendingEntry else { return nil }
        return CGSize(width: max(0, CGFloat(size.pixels.x) / density),
                      height: max(0, CGFloat(size.pixels.y) / density))
    }
    var offset: CGFloat { CGFloat(floor(slide.value + 0.5)) / density }

    init(visible: Bool, delay: Int64, style: Style = .pill) {
        self.visible = visible; retained = visible; self.delay = delay; self.style = style
        phase = visible ? .visible : .preEnter
        alpha = .init(value: visible ? 1 : 0, retainsEndVelocity: true)
        scale = .init(value: visible || style == .retry ? 1 : 0.78, retainsEndVelocity: true)
        slide = .init(value: 0, retainsEndVelocity: true)
    }

    mutating func setVisible(_ next: Bool) {
        guard next != visible else { return }
        visible = next
        if next && !retained {
            retained = true; pendingEntry = true; phase = .preEnter
            alpha.reset(to: 0); scale.reset(to: style == .retry ? 1 : 0.78); slide.reset(to: 0)
            size = .init(.zero)
            if let fullSize { beginEntry(fullSize) }
        } else if retained {
            pendingEntry = false
            transition(to: next ? .visible : .postExit)
        }
    }

    mutating func measure(_ measured: CGSize, density: CGFloat) {
        guard measured.width.isFinite, measured.height.isFinite,
              measured.width >= 0, measured.height >= 0, density.isFinite, density > 0 else { return }
        self.density = density
        let pixels = SIMD2<Float>(Float(floor(measured.width * density + 0.5)),
                                  Float(floor(measured.height * density + 0.5)))
        guard fullSize != pixels else { return }
        fullSize = pixels
        if pendingEntry { beginEntry(pixels) }
        else if phase == .visible && !isRunning { size = .init(pixels) }
        else if retained { retargetSize(force: false, origin: isRunning ? lastFrame : nil) }
    }

    private mutating func beginEntry(_ pixels: SIMD2<Float>) {
        pendingEntry = false
        size = .init(.init(0, pixels.y))
        // Android's lambda returns eight physical pixels, not eight dp.
        slide.reset(to: style == .retry ? 0 : -min(pixels.x, 8))
        transition(to: .visible)
    }

    private mutating func transition(to target: Phase) {
        let entering = phase == .preEnter && target == .visible
        let exiting = phase == .visible && target == .postExit
        let origin = isRunning ? lastFrame : nil
        if !isRunning { lastFrame = nil }
        if style == .retry {
            alpha.retarget(target == .visible ? 1 : 0,
                using: .criticallyDampedSpring(stiffness: 400), force: true, atFrameNanos: origin)
            sizeSpec = .criticallyDampedSpring(stiffness: 400, threshold: 1)
            phase = target
            retargetSize(force: true, origin: origin)
            return
        }
        let alphaSpec: ZTransferAndroidMotion = entering
            ? .tween(milliseconds: 200, delayMilliseconds: delay)
            : exiting ? .tween(milliseconds: 100) : .criticallyDampedSpring(stiffness: 400)
        let scaleSpec: ZTransferAndroidMotion = entering
            ? .tween(milliseconds: 200, delayMilliseconds: delay) : .criticallyDampedSpring(stiffness: 400)
        Self.retarget(&alpha, target: target == .visible ? 1 : 0, spec: alphaSpec, origin: origin)
        Self.retarget(&scale, target: 1, spec: scaleSpec, origin: origin)
        let slideSpec: ZTransferAndroidMotion = entering
            ? .underdampedSpring(stiffness: 360, dampingRatio: 0.62)
            : .criticallyDampedSpring(stiffness: 400, threshold: 1)
        let displayedSlide = floor(slide.value + 0.5)
        slide.retarget(0, using: slideSpec, fromDisplayedValue: displayedSlide, force: true, atFrameNanos: origin)
        // Explicit spring() / Motion.bouncy() have a null visibilityThreshold,
        // hence FloatSpringSpec's .01 per axis, even with an IntSize converter.
        // Only the default exit/reverse spec explicitly supplies IntSize(1, 1).
        sizeSpec = entering
            ? .bouncy
            : .criticallyDampedSpring(stiffness: 400, threshold: 1)
        phase = target
        retargetSize(force: true, origin: origin)
    }

    private static func retarget(_ value: inout ZTransferScalarAnimation, target: Float,
                                 spec: ZTransferAndroidMotion, origin: Int64?) {
        let actual: ZTransferAndroidMotion
        if value.isRunning, case .tween = spec { actual = .criticallyDampedSpring(stiffness: 1500) }
        else { actual = spec }
        value.retarget(target, using: actual, force: true, atFrameNanos: origin)
    }

    private mutating func retargetSize(force: Bool, origin: Int64?) {
        guard let fullSize else { return }
        let target = phase == .visible ? fullSize : SIMD2<Float>(0, fullSize.y)
        size.retarget(target, spec: sizeSpec, force: force, origin: origin)
    }

    mutating func advance(_ nanos: Int64) {
        lastFrame = nanos
        alpha.advance(frameNanos: nanos); scale.advance(frameNanos: nanos)
        slide.advance(frameNanos: nanos); size.advance(nanos)
        if !isRunning { lastFrame = nil }
        if !visible && !isRunning && !pendingEntry {
            retained = false; fullSize = nil; lastFrame = nil
        }
    }
}

@MainActor
private final class QueuePillVisibilityClock: NSObject, ObservableObject {
    @Published private(set) var motion: QueuePillVisibilityMotion
    private let delay: Int64
    private let style: QueuePillVisibilityMotion.Style
    // nil distinguishes first composition (possibly hidden) from a detached
    // lazy row. A hidden Group need not receive onAppear until content enters.
    private var active: Bool?
    private var link: CADisplayLink?
    init(visible: Bool, delay: Int64, style: QueuePillVisibilityMotion.Style) {
        self.delay = delay; self.style = style
        motion = .init(visible: visible, delay: delay, style: style)
    }
    func activate(_ visible: Bool) { active = true; update(visible); schedule() }
    func update(_ visible: Bool) {
        #if DEBUG
        let before = motion
        #endif
        if active != false { motion.setVisible(visible); schedule() }
        else { motion = .init(visible: visible, delay: delay, style: style) }
        #if DEBUG
        QueuePillVisibilityProbe.shared.transition(from: before, to: motion, delay: delay, owner: ObjectIdentifier(self))
        #endif
    }
    func measure(_ size: CGSize, density: CGFloat) { motion.measure(size, density: density); schedule() }
    func unmount(_ visible: Bool) {
        active = false; stop(); motion = .init(visible: visible, delay: delay, style: style)
    }
    private func schedule() {
        guard active == true, motion.isRunning, link == nil else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    private func frame(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000))
        #if DEBUG
        QueuePillVisibilityProbe.shared.record(motion, delay: delay, owner: ObjectIdentifier(self))
        #endif
        if !motion.isRunning { stop() }
    }
    private func stop() { link?.invalidate(); link = nil }
    @MainActor private final class FrameTarget: NSObject {
        weak var owner: QueuePillVisibilityClock?
        init(_ owner: QueuePillVisibilityClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(link)
        }
    }
}

#if DEBUG
/// Records actual display callbacks only in the dedicated presentation fixture.
/// Publish each observed phase once, rather than making its host observe frames.
@MainActor
final class QueuePillVisibilityProbe: ObservableObject {
    static let shared = QueuePillVisibilityProbe()
    private let enabled = ProcessInfo.processInfo.arguments.contains("--queue-pill-visibility-test")
    private let reversal = ProcessInfo.processInfo.arguments.contains("--queue-pill-reversal-test")
    private var entered = Set<Int64>()
    private var exited = Set<Int64>()
    private var reversed = Set<Int64>()
    private var resumed = Set<Int64>()
    private var owners: [Int64: ObjectIdentifier] = [:]
    private var stable = true
    private var continuous = true
    @Published private(set) var summary = "entered=;exited="
    @Published private(set) var reverseRequested = false
    @Published private(set) var reversalSummary = "reversed=;resumed=;continuous=true;stable=true"
    func record(_ motion: QueuePillVisibilityMotion, delay: Int64, owner: ObjectIdentifier) {
        guard enabled, motion.alpha.value > 0, motion.alpha.value < 1 else { return }
        observeOwner(owner, delay: delay)
        let inserted = motion.visible ? entered.insert(delay).inserted : exited.insert(delay).inserted
        if inserted {
            summary = "entered=\(keys(entered));exited=\(keys(exited))"
        }
        if reversal, motion.visible, reversed.contains(delay), resumed.insert(delay).inserted { publishReversal() }
        if reversal, exited.count == 3, !reverseRequested { reverseRequested = true }
    }
    func transition(from before: QueuePillVisibilityMotion, to after: QueuePillVisibilityMotion,
                    delay: Int64, owner: ObjectIdentifier) {
        guard enabled, reversal, reverseRequested, !before.visible, after.visible else { return }
        observeOwner(owner, delay: delay)
        reversed.insert(delay)
        continuous = continuous && before.retained && before.alpha.value > 0 && before.alpha.value < 1
            && abs(after.alpha.value - before.alpha.value) < 0.000001
            && abs(after.alpha.velocity - before.alpha.velocity) < 0.00001
            && after.scale.value == before.scale.value && after.size.pixels == before.size.pixels
        publishReversal()
    }
    private func observeOwner(_ owner: ObjectIdentifier, delay: Int64) {
        if let previous = owners[delay] { stable = stable && previous == owner }
        else { owners[delay] = owner }
    }
    private func keys(_ values: Set<Int64>) -> String { values.sorted().map(String.init).joined(separator: ",") }
    private func publishReversal() {
        reversalSummary = "reversed=\(keys(reversed));resumed=\(keys(resumed));continuous=\(continuous);stable=\(stable)"
    }
}
#endif

private struct QueuePillVisibilityLayout: Layout {
    let displayed: CGSize?
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let full = child.sizeThatFits(proposal)
        guard let displayed, proposal.width != 0, proposal.width != .infinity else { return full }
        return CGSize(width: min(displayed.width, proposal.width ?? displayed.width),
                      height: min(displayed.height, proposal.height ?? displayed.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(child.sizeThatFits(proposal)))
    }
}

struct QueuePillVisibility<Content: View>: View {
    let visible: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.displayScale) private var density
    @StateObject private var clock: QueuePillVisibilityClock
    init(visible: Bool, delay: Int64, style: QueuePillVisibilityMotion.Style = .pill,
         @ViewBuilder content: @escaping () -> Content) {
        self.visible = visible; self.content = content
        _clock = StateObject(wrappedValue: QueuePillVisibilityClock(visible: visible, delay: delay, style: style))
    }
    var body: some View {
        Group {
            if visible || clock.motion.retained {
                QueuePillVisibilityLayout(displayed: clock.motion.displayedSize) {
                    ZStack(alignment: .topLeading) { content() }
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { clock.measure(geometry.size, density: density) }
                                    .onChange(of: geometry.size) { clock.measure($0, density: density) }
                                    .onChange(of: density) { clock.measure(geometry.size, density: $0) }
                            }
                        }
                        .scaleEffect(CGFloat(clock.motion.scale.value), anchor: .leading)
                        .offset(x: clock.motion.offset)
                        .opacity(Double(clock.motion.alpha.value))
                }
                .modifier(QueueVisibilityClip(enabled: clock.motion.style == .retry))
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
            }
        }
        .transaction { $0.animation = nil }
        .onAppear { clock.activate(visible) }
        .onChange(of: visible) { clock.update($0) }
        .onDisappear { clock.unmount(visible) }
    }
}

private struct QueueVisibilityClip: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.clipped() } else { content }
    }
}
