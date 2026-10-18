import SwiftUI
import UIKit

/// RemoteToolBar Crossfade(tween(160)): no entry animation; interrupted mode
/// changes retain their current opacity and dispose old content only at rest.
struct RemoteToolModeTransition {
    private(set) var target: Bool
    private(set) var modes: [Bool]
    private var opacity: [Bool: ZTransferScalarAnimation]

    init(movie: Bool) {
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
                ? .criticallyDampedSpring(stiffness: 1500) : .tween(milliseconds: 160)
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
    let photoOpacity = RemoteToolModeOpacity()
    let movieOpacity = RemoteToolModeOpacity()
    private var displayLink: CADisplayLink?
    var clockRunning: Bool { displayLink != nil }

    init(movie: Bool) {
        transition = RemoteToolModeTransition(movie: movie)
        modes = [movie]
        super.init()
        publish()
    }
    func opacity(_ movie: Bool) -> RemoteToolModeOpacity { movie ? movieOpacity : photoOpacity }
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
        transition = RemoteToolModeTransition(movie: movie)
        publish()
    }
}

@MainActor
final class RemoteToolModeOpacity: ObservableObject {
    @Published private(set) var value: Float = 0
    func update(_ value: Float) { if self.value != value { self.value = value } }
}
private struct RemoteToolModeFade: ViewModifier {
    @ObservedObject var opacity: RemoteToolModeOpacity
    func body(content: Content) -> some View { content.opacity(Double(opacity.value)) }
}

struct RemoteToolModeCrossfade<Content: View>: View {
    let movie: Bool
    @ViewBuilder let content: (Bool) -> Content
    @StateObject private var clock: RemoteToolModeClock

    init(movie: Bool, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.movie = movie
        self.content = content
        _clock = StateObject(wrappedValue: RemoteToolModeClock(movie: movie))
    }

    var body: some View {
        ZStack(alignment: .center) {
            ForEach(clock.modes, id: \.self) { mode in
                content(mode)
                    .modifier(RemoteToolModeFade(opacity: clock.opacity(mode)))
                    .allowsHitTesting(mode == movie)
                    // Keep an input surface above an outgoing layer. Merely
                    // disabling hit testing lets touches reach the next mode.
                    // Place it outside opacity: UIKit otherwise ignores a
                    // nearly transparent view before the transition disposes it.
                    .overlay {
                        if mode != movie {
                            RemoteToolInputShield()
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .onChange(of: movie) { clock.setTarget($0) }
        .onAppear { clock.setTarget(movie) }
        .onDisappear { clock.reset(movie: movie) }
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
