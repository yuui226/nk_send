import SwiftUI
import UIKit

/// RemoteToolBar Crossfade(tween(160)): no entry animation; interrupted mode
/// changes retain their current opacity and dispose old content only at rest.
struct RemoteToolModeTransition {
    let durationMilliseconds: Int64
    private(set) var target: Bool
    private(set) var modes: [Bool]
    private var opacity: [Bool: ZTransferScalarAnimation]

    init(movie: Bool, durationMilliseconds: Int64 = 160) {
        self.durationMilliseconds = durationMilliseconds
        target = movie
        modes = [movie]
        opacity = [movie: ZTransferScalarAnimation(value: 1)]
    }

    var isRunning: Bool { opacity.values.contains { $0.isRunning } }
    func alpha(_ movie: Bool) -> Float { opacity[movie]?.value ?? 0 }

    mutating func setTarget(_ movie: Bool) {
        guard movie != target else { return }
        target = movie
        if opacity[movie] == nil {
            modes.append(movie)
            opacity[movie] = ZTransferScalarAnimation(value: 0)
        }
        for mode in modes {
            // Transition.kt substitutes its default critical spring when a
            // tween is interrupted, retaining the last displayed velocity.
            let spec: ZTransferAndroidMotion = opacity[mode]?.isRunning == true
                ? .criticallyDampedSpring(stiffness: 1500) : .tween(milliseconds: durationMilliseconds)
            opacity[mode]?.retarget(mode == movie ? 1 : 0, using: spec)
        }
    }

    mutating func advance(frameNanos: Int64) {
        for mode in modes { opacity[mode]?.advance(frameNanos: frameNanos) }
        if !isRunning {
            modes = [target]
            opacity = [target: ZTransferScalarAnimation(value: 1)]
        }
    }
}

@MainActor
final class RemoteToolModeClock: NSObject, ObservableObject {
    private(set) var transition: RemoteToolModeTransition
    @Published private(set) var modes: [Bool]
    let photoOpacity = AndroidAnimatedOpacity()
    let movieOpacity = AndroidAnimatedOpacity()
    private var displayLink: CADisplayLink?
    var clockRunning: Bool { displayLink != nil }

    init(movie: Bool, durationMilliseconds: Int64 = 160) {
        transition = RemoteToolModeTransition(movie: movie, durationMilliseconds: durationMilliseconds)
        modes = [movie]
        super.init()
        publish()
    }
    func opacity(_ movie: Bool) -> AndroidAnimatedOpacity { movie ? movieOpacity : photoOpacity }
    func setTarget(_ movie: Bool) {
        transition.setTarget(movie)
        publish()
        guard transition.isRunning, displayLink == nil else { return }
        let link = CADisplayLink(target: ClockTarget(self), selector: #selector(ClockTarget.frame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) {
        transition.advance(frameNanos: nanos)
        publish()
        if !transition.isRunning { invalidate() }
    }
    private func publish() {
        if modes != transition.modes { modes = transition.modes }
        photoOpacity.update(transition.alpha(false))
        movieOpacity.update(transition.alpha(true))
    }
    @MainActor private final class ClockTarget: NSObject {
        weak var owner: RemoteToolModeClock?
        init(_ owner: RemoteToolModeClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(Int64(link.timestamp * 1_000_000_000))
        }
    }
    func invalidate() { displayLink?.invalidate(); displayLink = nil }
    func reset(movie: Bool) {
        invalidate()
        transition = RemoteToolModeTransition(movie: movie, durationMilliseconds: transition.durationMilliseconds)
        publish()
    }
}

@MainActor
final class AndroidAnimatedOpacity: ObservableObject {
    @Published private(set) var value: Float = 0
    func update(_ value: Float) { if self.value != value { self.value = value } }
}
struct AndroidOpacity: ViewModifier {
    @ObservedObject var opacity: AndroidAnimatedOpacity
    func body(content: Content) -> some View { content.opacity(Double(opacity.value)) }
}

/// Compose Crossfade for two modes, shared by the 160ms monitor toolbar and
/// 180ms preview histogram. Retains interrupted layers without ticking parents.
struct AndroidBooleanCrossfade<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: (Bool) -> Content
    @StateObject private var clock: RemoteToolModeClock

    init(selected: Bool, durationMilliseconds: Int64 = 160,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.selected = selected
        self.content = content
        _clock = StateObject(wrappedValue: RemoteToolModeClock(movie: selected,
                                                            durationMilliseconds: durationMilliseconds))
    }

    var body: some View {
        ZStack(alignment: .center) {
            ForEach(clock.modes, id: \.self) { mode in
                content(mode)
                    .modifier(AndroidOpacity(opacity: clock.opacity(mode)))
                    .allowsHitTesting(mode == selected)
                    .accessibilityHidden(mode != selected)
                    // Keep an input surface above an outgoing layer. Merely
                    // disabling hit testing lets touches reach the next mode.
                    // Place it outside opacity: UIKit otherwise ignores a
                    // nearly transparent view before the transition disposes it.
                    .overlay {
                        if mode != selected {
                            RemoteToolInputShield()
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .onChange(of: selected) { clock.setTarget($0) }
        .onAppear { clock.setTarget(selected) }
        .onDisappear { clock.reset(movie: selected) }
    }
}

/// A transparent control owns touches in an outgoing toolbar's bounds without
/// invoking either toolbar. Its lifetime follows the same retained mode layer.
struct RemoteToolInputShield: UIViewRepresentable {
    func makeUIView(context: Context) -> RemoteToolInputShieldView {
        let view = RemoteToolInputShieldView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: RemoteToolInputShieldView, context: Context) {}
}

final class RemoteToolInputShieldView: UIControl {}

/// MainActivity FilesQueueWorkspace and Files↔Remote share Motion.kt's short
/// travel and delayed fade. This owner publishes page membership only at the
/// edges; frame-frequency values are observed exclusively by compositing leaves.
struct WorkspacePageMotion {
    private(set) var presented = false
    private(set) var travel = ZTransferScalarAnimation(value: 0)
    private(set) var sourceAlpha = ZTransferScalarAnimation(value: 1)
    private(set) var destinationAlpha = ZTransferScalarAnimation(value: 0)
    private(set) var headerAlpha = ZTransferScalarAnimation(value: 0)
    var running: Bool {
        travel.isRunning || sourceAlpha.isRunning || destinationAlpha.isRunning || headerAlpha.isRunning
    }

    mutating func setPresented(_ value: Bool) {
        guard presented != value else { return }
        presented = value
        Self.retarget(&travel, to: value ? 1 : 0, spec: .tween(milliseconds: 300))
        Self.retarget(&sourceAlpha, to: value ? 0 : 1, spec: value
            ? .tween(milliseconds: 140) : .tween(milliseconds: 200, delayMilliseconds: 100))
        Self.retarget(&destinationAlpha, to: value ? 1 : 0, spec: value
            ? .tween(milliseconds: 200, delayMilliseconds: 100) : .tween(milliseconds: 140))
        Self.retarget(&headerAlpha, to: value ? 1 : 0, spec: value
            ? .tween(milliseconds: 200, delayMilliseconds: 100) : .tween(milliseconds: 80))
    }

    private static func retarget(_ channel: inout ZTransferScalarAnimation, to value: Float,
                                 spec: ZTransferAndroidMotion) {
        // Compose Transition uses its critical spring on interruption. Retain
        // current values/velocities instead of restarting a delayed tween.
        channel.retarget(value, using: channel.isRunning ? .criticallyDampedSpring(stiffness: 1500) : spec)
    }

    mutating func advance(_ nanos: Int64) {
        travel.advance(frameNanos: nanos)
        sourceAlpha.advance(frameNanos: nanos)
        destinationAlpha.advance(frameNanos: nanos)
        headerAlpha.advance(frameNanos: nanos)
    }

    mutating func settle(presented value: Bool) {
        presented = value
        travel.reset(to: value ? 1 : 0)
        sourceAlpha.reset(to: value ? 0 : 1)
        destinationAlpha.reset(to: value ? 1 : 0)
        headerAlpha.reset(to: value ? 1 : 0)
    }
}

@MainActor
final class WorkspacePageClock: ObservableObject {
    enum DestinationSide: CGFloat { case left = -1, right = 1 }
    struct Sample: Equatable {
        var travel: CGFloat = 0
        var alpha: Double = 1
    }
    final class Frame: ObservableObject {
        @Published private(set) var sample = Sample()
        var travel: CGFloat { sample.travel }
        var alpha: Double { sample.alpha }
        func update(_ travel: CGFloat, _ alpha: Double) {
            let next = Sample(travel: travel, alpha: min(1, max(0, alpha)))
            if sample != next { sample = next }
        }
    }
    @Published private(set) var pages: Set<Bool> = [false]
    @Published private(set) var transitioning = false
    let source = Frame()
    let destination = Frame()
    let header = Frame()
    private(set) var motion = WorkspacePageMotion()
    private let side: DestinationSide
    private let keepsSource: Bool
    private var mounted = false
    private var active = true
    private var link: CADisplayLink?
    var running: Bool { link != nil }
    var retained: Bool { pages.contains(true) }

    init(side: DestinationSide, keepsSource: Bool = false) {
        self.side = side
        self.keepsSource = keepsSource
        publishFrames()
    }

    func mount(presented: Bool) {
        if !mounted {
            mounted = true
            // SceneStorage can restore directly into queue: no one-frame flash
            // of the files page and no replay of a navigation the user did not do.
            settle(presented: presented)
        } else { setPresented(presented) }
    }

    func setPresented(_ value: Bool) {
        #if DEBUG
        if motion.presented != value {
            ButtonInteractionTrace.recordNow("workspace-\(side == .right ? "queue" : "monitor")-\(value ? "enter" : "exit")")
        }
        #endif
        motion.setPresented(value)
        guard active else { settle(presented: value); return }
        guard motion.running else { return }
        if pages != [false, true] { pages = [false, true] }
        if !transitioning { transitioning = true }
        guard link == nil else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func advance(_ nanos: Int64) {
        #if DEBUG
        if transitioning && ButtonInteractionTrace.enabled {
            ButtonInteractionTrace.recordNow("workspace-\(side == .right ? "queue" : "monitor")-frame")
        }
        #endif
        motion.advance(nanos)
        publishFrames()
        if !motion.running { finish() }
    }

    func setActive(_ value: Bool) {
        active = value
        // Offscreen transitions have no visible frames to preserve. Settle
        // once, release the exiting monitor and never replay stale timestamps.
        if !value { settle(presented: motion.presented) }
    }

    func settle(presented: Bool) {
        motion.settle(presented: presented)
        publishFrames()
        finish()
    }

    private func publishFrames() {
        let distance = side.rawValue * 24
        source.update(-CGFloat(motion.travel.value) * distance, Double(motion.sourceAlpha.value))
        destination.update((1 - CGFloat(motion.travel.value)) * distance, Double(motion.destinationAlpha.value))
        header.update(0, Double(motion.headerAlpha.value))
    }

    private func finish() {
        stop()
        if transitioning {
            #if DEBUG
            ButtonInteractionTrace.recordNow("workspace-\(side == .right ? "queue" : "monitor")-settled")
            #endif
            transitioning = false
        }
        let settled: Set<Bool> = keepsSource && motion.presented ? [false, true] : [motion.presented]
        if pages != settled { pages = settled }
    }

    func stop() { link?.invalidate(); link = nil }

    @MainActor private final class Target: NSObject {
        weak var owner: WorkspacePageClock?
        init(_ owner: WorkspacePageClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(Int64(link.timestamp * 1_000_000_000))
        }
    }
}

/// Fixed-size, single compositing group at alpha=1 as well as during a fade.
/// Do not put frame observation in the list/monitor body or animate layout size.
struct WorkspacePageEffect: ViewModifier {
    @ObservedObject var frame: WorkspacePageClock.Frame
    func body(content: Content) -> some View {
        content.compositingGroup().opacity(frame.alpha).offset(x: frame.travel)
    }
}

/// A retained page must not leak descendant buttons through an outer overlay's
/// accessibility configuration. Ignoring its children while inactive keeps the
/// tree boundary explicit without dimming controls during their exit fade.
struct WorkspacePageInput: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        content
            .allowsHitTesting(enabled)
            .accessibilityElement(children: enabled ? .contain : .ignore)
            .accessibilityHidden(!enabled)
    }
}

struct WorkspacePageLifecycle: ViewModifier {
    let clock: WorkspacePageClock
    let presented: Bool
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .onAppear {
                clock.mount(presented: presented)
                clock.setActive(scenePhase != .background)
            }
            .onChange(of: presented) { clock.setPresented($0) }
            .onChange(of: scenePhase) { clock.setActive($0 != .background) }
            .onDisappear { clock.settle(presented: presented) }
    }
}

private struct WorkspaceMonitorPresentation<Monitor: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    @ViewBuilder let monitor: () -> Monitor
    @StateObject private var clock = WorkspacePageClock(side: .left, keepsSource: true)
    func body(content: Content) -> some View {
        ZStack {
            content.modifier(WorkspacePageEffect(frame: clock.source))
                .modifier(WorkspacePageInput(enabled: !isPresented && !clock.transitioning))
            if clock.retained {
                monitor().modifier(WorkspacePageEffect(frame: clock.destination))
                    .modifier(WorkspacePageInput(enabled: isPresented))
                    .transition(.identity)
                    .zIndex(1)
            }
        }
        .background(ZTransferColors.background.ignoresSafeArea())
        .modifier(WorkspacePageLifecycle(clock: clock, presented: isPresented))
        .onChange(of: clock.retained) { if !$0 { onDismiss() } }
    }
}

extension View {
    func workspaceMonitor<Monitor: View>(isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping () -> Monitor) -> some View {
        modifier(WorkspaceMonitorPresentation(isPresented: isPresented, onDismiss: onDismiss, monitor: content))
    }
}
