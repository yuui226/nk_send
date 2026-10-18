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

/// MainActivity Files↔Remote: Remote is to the LEFT, 24dp travel/300ms;
/// incoming alpha 200ms after 100ms, outgoing alpha 140ms (Motion.kt).
/// Keep the source and the monitor owner alive until the exit has settled.
struct WorkspaceMonitorMotion {
    private(set) var presented = false
    private(set) var travel = ZTransferScalarAnimation(value: 0)
    private(set) var filesAlpha = ZTransferScalarAnimation(value: 1)
    private(set) var monitorAlpha = ZTransferScalarAnimation(value: 0)
    var running: Bool { travel.isRunning || filesAlpha.isRunning || monitorAlpha.isRunning }

    mutating func setPresented(_ value: Bool) {
        guard presented != value else { return }
        presented = value
        travel.retarget(value ? 1 : 0, using: travel.isRunning
            ? .criticallyDampedSpring(stiffness: 1500) : .tween(milliseconds: 300))
        filesAlpha.retarget(value ? 0 : 1, using: filesAlpha.isRunning
            ? .criticallyDampedSpring(stiffness: 1500) : value
            ? .tween(milliseconds: 140) : .tween(milliseconds: 200, delayMilliseconds: 100))
        monitorAlpha.retarget(value ? 1 : 0, using: monitorAlpha.isRunning
            ? .criticallyDampedSpring(stiffness: 1500) : value
            ? .tween(milliseconds: 200, delayMilliseconds: 100) : .tween(milliseconds: 140))
    }
    mutating func advance(_ nanos: Int64) {
        travel.advance(frameNanos: nanos)
        filesAlpha.advance(frameNanos: nanos)
        monitorAlpha.advance(frameNanos: nanos)
    }
}

@MainActor
final class WorkspaceMonitorClock: ObservableObject {
    final class Frame: ObservableObject {
        @Published var travel: CGFloat = 0
        @Published var alpha: Double = 1
        func update(_ travel: CGFloat, _ alpha: Double) {
            if self.travel != travel { self.travel = travel }
            if self.alpha != alpha { self.alpha = alpha }
        }
    }
    @Published private(set) var retained = false
    let files = Frame()
    let monitor = Frame()
    private(set) var motion = WorkspaceMonitorMotion()
    private var link: CADisplayLink?
    var running: Bool { link != nil }
    init() { monitor.update(-24, 0) }
    func setPresented(_ value: Bool) {
        motion.setPresented(value)
        if value { retained = true }
        guard motion.running, link == nil else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) {
        motion.advance(nanos)
        files.update(CGFloat(motion.travel.value) * 24, Double(motion.filesAlpha.value))
        monitor.update((CGFloat(motion.travel.value) - 1) * 24, Double(motion.monitorAlpha.value))
        if !motion.running {
            stop()
            if !motion.presented { retained = false }
        }
    }
    func stop() { link?.invalidate(); link = nil }
    @MainActor private final class Target: NSObject {
        weak var owner: WorkspaceMonitorClock?
        init(_ owner: WorkspaceMonitorClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(Int64(link.timestamp * 1_000_000_000))
        }
    }
}

private struct WorkspaceMonitorPage: ViewModifier {
    @ObservedObject var frame: WorkspaceMonitorClock.Frame
    func body(content: Content) -> some View {
        content.compositingGroup().opacity(frame.alpha).offset(x: frame.travel)
    }
}

private struct WorkspaceMonitorPresentation<Monitor: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    @ViewBuilder let monitor: () -> Monitor
    @StateObject private var clock = WorkspaceMonitorClock()
    func body(content: Content) -> some View {
        ZStack {
            content.modifier(WorkspaceMonitorPage(frame: clock.files))
                .allowsHitTesting(!isPresented && !clock.running)
                .accessibilityHidden(isPresented)
            if clock.retained {
                monitor().modifier(WorkspaceMonitorPage(frame: clock.monitor))
                    .allowsHitTesting(isPresented)
                    .accessibilityHidden(!isPresented)
                    .transition(.identity)
                    .zIndex(1)
            }
        }
        .background(ZTransferColors.background.ignoresSafeArea())
        .onAppear { clock.setPresented(isPresented) }
        .onChange(of: isPresented) { clock.setPresented($0) }
        .onChange(of: clock.retained) { if !$0 { onDismiss() } }
        .onDisappear { clock.stop() }
    }
}

extension View {
    func workspaceMonitor<Monitor: View>(isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping () -> Monitor) -> some View {
        modifier(WorkspaceMonitorPresentation(isPresented: isPresented, onDismiss: onDismiss, monitor: content))
    }
}
