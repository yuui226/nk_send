import Foundation

/// RecControlBar.kt uses Transition for content visibility and animate*AsState
/// for width/pause. Only interrupted Transition tweens switch to the default
/// critical spring; the width and pause channels keep their specified curves.
struct RemoteRecorderTransitionValue {
    private(set) var animation: ZTransferScalarAnimation
    private var delayed: (target: Float, spec: ZTransferAndroidMotion, delay: Int64)?
    private var firstFrame: Int64?
    init(_ value: Float) { animation = .init(value: value) }
    var value: Float { animation.value }
    var isRunning: Bool { animation.isRunning || delayed != nil }
    mutating func set(_ target: Float, spec: ZTransferAndroidMotion, delay: Int64 = 0,
                      interruptionThreshold: Float = 0.01) {
        let interrupted = isRunning
        delayed = nil; firstFrame = nil
        let actual: ZTransferAndroidMotion
        if interrupted, case .tween = spec {
            actual = .criticallyDampedSpring(stiffness: 1500, threshold: interruptionThreshold)
        } else { actual = spec }
        if !interrupted && delay > 0 {
            delayed = (target, actual, delay * 1_000_000)
        } else { animation.retarget(target, using: actual) }
    }
    mutating func advance(_ now: Int64) {
        if let delayed {
            if firstFrame == nil { firstFrame = now }
            let start = firstFrame! + delayed.delay
            guard now >= start else { return }
            animation.retarget(delayed.target, using: delayed.spec)
            animation.advance(frameNanos: start)
            self.delayed = nil; firstFrame = nil
        }
        animation.advance(frameNanos: now)
    }
}

struct RemoteRecorderVisibility {
    enum Kind { case icon, savedLabel, timer, lockedHint }
    let kind: Kind
    private(set) var visible: Bool
    private(set) var retained: Bool
    private(set) var alpha: RemoteRecorderTransitionValue
    private(set) var scale: RemoteRecorderTransitionValue
    private(set) var slide: RemoteRecorderTransitionValue
    // The timer's 12sp line plus 3dp padding on either side. Slide operates in
    // integer physical pixels, as Compose slideIn/OutVertically(IntOffset).
    private let timerPixels: Float
    init(_ kind: Kind, visible: Bool = false, density: Float = 1) {
        self.kind = kind; self.visible = visible; retained = visible
        timerPixels = floor(18 * density + 0.5)
        alpha = .init(visible ? 1 : 0)
        scale = .init(visible ? 1 : Self.entryScale(kind))
        slide = .init(visible ? 0 : floor(timerPixels / 3))
    }
    private static func entryScale(_ kind: Kind) -> Float {
        switch kind { case .icon: 0.52; case .savedLabel, .timer: 0.82; case .lockedHint: 0.86 }
    }
    var isRunning: Bool { alpha.isRunning || scale.isRunning || (kind == .timer && slide.isRunning) }
    mutating func setVisible(_ next: Bool) {
        guard next != visible else { return }
        visible = next
        if next && !retained {
            alpha = .init(0); scale = .init(Self.entryScale(kind)); slide = .init(floor(timerPixels / 3))
        }
        retained = true
        let enterAlpha: Int64, exitAlpha: Int64, exitScale: Float, scaleDuration: Int64
        switch kind {
        case .icon: (enterAlpha, exitAlpha, exitScale, scaleDuration) = (150, 90, 0.72, 110)
        case .savedLabel: (enterAlpha, exitAlpha, exitScale, scaleDuration) = (200, 120, 0.90, 120)
        case .timer: (enterAlpha, exitAlpha, exitScale, scaleDuration) = (140, 120, 0.90, 130)
        case .lockedHint: (enterAlpha, exitAlpha, exitScale, scaleDuration) = (160, 140, 0.92, 140)
        }
        alpha.set(next ? 1 : 0, spec: .tween(milliseconds: next ? enterAlpha : exitAlpha),
                  delay: next && kind == .savedLabel ? 60 : 0)
        scale.set(next ? 1 : exitScale, spec: next
            ? (kind == .lockedHint ? .tween(milliseconds: 180) : .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
            : .tween(milliseconds: scaleDuration))
        if kind == .timer {
            slide.set(next ? 0 : floor(timerPixels / 4), spec: next
                ? .underdampedSpring(stiffness: 400, dampingRatio: 0.5)
                : .tween(milliseconds: 130), interruptionThreshold: 1)
        }
    }
    mutating func advance(_ now: Int64) {
        alpha.advance(now); scale.advance(now)
        if kind == .timer { slide.advance(now) }
        if !visible && !isRunning { retained = false }
    }
}

struct RemoteRecorderMotion {
    struct Configuration: Equatable {
        var phase: RemoteLocalRecordingPhase
        var compactSaved: Bool
        var recording: Bool { phase == .recording || phase == .paused }
        var saved: Bool { phase == .saved }
        var width: Float { saved ? (compactSaved ? 36 : 88) : (recording || phase == .finalizing ? 70 : 36) }
    }
    private(set) var configuration: Configuration
    private(set) var layoutWidth: ZTransferScalarAnimation
    private(set) var surfaceWidth: ZTransferScalarAnimation
    private(set) var pauseAlpha: ZTransferScalarAnimation
    private(set) var icons: [Bool: RemoteRecorderVisibility]
    private(set) var savedLabel: RemoteRecorderVisibility
    private(set) var timer: RemoteRecorderVisibility
    private(set) var lockedHint = RemoteRecorderVisibility(.lockedHint)
    init(_ configuration: Configuration, density: Float) {
        self.configuration = configuration
        layoutWidth = .init(value: configuration.width); surfaceWidth = .init(value: configuration.width)
        pauseAlpha = .init(value: configuration.recording ? 1 : 0)
        icons = [configuration.saved: .init(.icon, visible: true)]
        savedLabel = .init(.savedLabel, visible: configuration.saved && !configuration.compactSaved)
        timer = .init(.timer, visible: configuration.recording, density: density)
    }
    mutating func configure(_ next: Configuration) {
        let old = configuration
        configuration = next
        layoutWidth.retarget(next.width, using: .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
        surfaceWidth.retarget(next.width, using: .underdampedSpring(stiffness: 400, dampingRatio: 0.5))
        pauseAlpha.retarget(next.recording ? 1 : 0, using: .tween(milliseconds: 150))
        if old.saved != next.saved {
            if icons[next.saved] == nil { icons[next.saved] = .init(.icon) }
            for key in icons.keys { icons[key]?.setVisible(key == next.saved) }
        }
        savedLabel.setVisible(next.saved && !next.compactSaved)
        timer.setVisible(next.recording)
    }
    mutating func showLockedHint(_ visible: Bool) { lockedHint.setVisible(visible) }
    var needsFrames: Bool {
        layoutWidth.isRunning || surfaceWidth.isRunning || pauseAlpha.isRunning ||
        icons.values.contains { $0.isRunning } || savedLabel.isRunning || timer.isRunning || lockedHint.isRunning
    }
    mutating func advance(_ now: Int64) {
        layoutWidth.advance(frameNanos: now); surfaceWidth.advance(frameNanos: now)
        pauseAlpha.advance(frameNanos: now)
        for key in icons.keys { icons[key]?.advance(now) }
        icons = icons.filter { $0.value.retained }
        savedLabel.advance(now); timer.advance(now); lockedHint.advance(now)
    }
}
