import Foundation

/// Frame-driven scalar state following Compose Animatable/animateFloatAsState.
/// Starts on the first display frame; an interrupted animation continues from
/// the last displayed value and velocity, using that frame as its new origin.
struct ZTransferScalarAnimation {
    private(set) var value: Float
    private(set) var velocity: Float = 0
    private(set) var target: Float
    private(set) var isRunning = false
    private var initialValue: Float
    private var initialVelocity: Float = 0
    private var spec = ZTransferAndroidMotion.tween(milliseconds: 0)
    private var durationNanos: Int64 = 0
    private var startNanos: Int64?
    private var lastFrameNanos: Int64?

    init(value: Float) {
        self.value = value
        target = value
        initialValue = value
    }

    mutating func retarget(_ target: Float, using spec: ZTransferAndroidMotion,
                          fromDisplayedValue: Float? = nil, force: Bool = false) {
        // animateValueAsState does not restart on a spec-only recomposition.
        // A vector animation retargets every component, even unchanged ones;
        // force preserves that common timeline and its rounded displayed start.
        guard target != self.target || force else { return }
        // IntSize converters publish rounded pixels. Their next animation
        // starts at that displayed integer while retaining frame time/velocity.
        if let fromDisplayedValue { value = fromDisplayedValue }
        initialValue = value
        initialVelocity = velocity
        self.target = target
        self.spec = spec
        durationNanos = spec.durationNanos(from: value, to: target, velocity: velocity)
        startNanos = lastFrameNanos
        isRunning = true
        if let startNanos {
            // Animatable executes a zero-play-time frame immediately when
            // interrupting, including an already-within-threshold spring.
            advance(frameNanos: startNanos)
        }
    }

    mutating func advance(frameNanos: Int64) {
        guard isRunning else { return }
        if startNanos == nil { startNanos = frameNanos }
        let elapsed = max(frameNanos - startNanos!, 0)
        let result = spec.animationSample(at: elapsed, from: initialValue, to: target, velocity: initialVelocity)
        value = result.value
        velocity = result.velocity
        lastFrameNanos = frameNanos
        if elapsed >= durationNanos {
            // Animatable.endAnimation clears the velocity even for tweens
            // (TargetBasedAnimation itself reports its finite difference).
            velocity = 0
            lastFrameNanos = nil
            startNanos = nil
            isRunning = false
        }
    }

    mutating func reset(to value: Float) {
        self = Self(value: value)
    }
}
