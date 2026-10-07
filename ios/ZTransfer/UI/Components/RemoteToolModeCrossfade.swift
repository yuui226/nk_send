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
private final class RemoteToolModeClock: NSObject, ObservableObject {
    @Published private(set) var transition: RemoteToolModeTransition
    private var displayLink: CADisplayLink?

    init(movie: Bool) { transition = RemoteToolModeTransition(movie: movie) }

    func setTarget(_ movie: Bool) {
        transition.setTarget(movie)
        guard transition.isRunning, displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        transition.advance(frameNanos: Int64(link.timestamp * 1_000_000_000))
        if !transition.isRunning { invalidate() }
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func reset(movie: Bool) {
        invalidate()
        transition = RemoteToolModeTransition(movie: movie)
    }
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
            ForEach(clock.transition.modes, id: \.self) { mode in
                content(mode)
                    .opacity(Double(clock.transition.alpha(mode)))
                    .allowsHitTesting(mode == movie)
            }
        }
        .onChange(of: movie) { clock.setTarget($0) }
        .onAppear { clock.setTarget(movie) }
        .onDisappear { clock.reset(movie: movie) }
    }
}
