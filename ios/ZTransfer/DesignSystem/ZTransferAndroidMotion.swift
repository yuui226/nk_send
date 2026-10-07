// Adapted from AndroidX Compose 1.7.6 FloatAnimationSpec.kt, SpringSimulation.kt,
// SpringEstimation.kt, Easing.kt and Bezier.kt, Copyright 2019–2024 The Android
// Open Source Project. Licensed under Apache-2.0; see Resources/licenses.
import Foundation

/// Compose scalar equations shared by button feedback and monitor transitions.
/// Spring cases explicitly distinguish underdamped motion from the critical
/// spring used when Transition interrupts a tween; overdamping is unsupported.
enum ZTransferAndroidMotion: Equatable {
    case tween(milliseconds: Int64)
    case criticallyDampedSpring(stiffness: Float, threshold: Float = 0.01)
    case underdampedSpring(stiffness: Float, dampingRatio: Float, threshold: Float = 0.01)

    struct Sample: Equatable {
        var value: Float
        var velocity: Float
    }

    func durationNanos(from start: Float, to target: Float, velocity: Float) -> Int64 {
        switch self {
        case let .criticallyDampedSpring(stiffness, threshold):
            let position = Double((start - target) / threshold)
            let velocity = Double(velocity / threshold)
            if position == 0 && velocity == 0 { return 0 }
            let r = -sqrt(Double(stiffness))
            let c1 = abs(position)
            let c2 = (position < 0 ? -velocity : velocity) - r * c1
            let t1 = log(abs(1 / c1)) / r
            let guess = log(abs(1 / c2))
            var t2 = guess
            for _ in 0...5 { t2 = guess - log(abs(t2 / r)) }
            t2 /= r
            var time = !t1.isFinite ? t2 : (!t2.isFinite ? t1 : max(t1, t2))
            let inflection = -(r * c1 + c2) / (r * c2)
            let x = (c1 + c2 * inflection) * exp(r * inflection)
            let delta: Double
            if inflection.isNaN || inflection <= 0 {
                delta = -1
            } else if -x < 1 {
                if c2 < 0 && c1 > 0 { time = 0 }
                delta = -1
            } else {
                time = -(2 / r) - c1 / c2
                delta = 1
            }
            for _ in 0..<100 {
                let previous = time
                time -= ((c1 + c2 * time) * exp(r * time) + delta)
                    / ((c2 * (r * time + 1) + c1 * r) * exp(r * time))
                if !(abs(previous - time) > 0.001) { break }
            }
            // Kotlin Double.toLong maps NaN to zero.
            return time.isFinite ? Int64(time * 1000) * 1_000_000 : 0
        case .tween(let milliseconds):
            precondition(milliseconds >= 0)
            return milliseconds * 1_000_000
        case let .underdampedSpring(stiffness, ratio, threshold):
            precondition(stiffness > 0 && ratio > 0 && ratio < 1 && threshold > 0)
            // Division/subtraction take place in Float before conversion,
            // matching FloatSpringSpec's visibility-threshold normalization.
            let position = Double((start - target) / threshold)
            let speed = Double(velocity / threshold)
            if position == 0 && speed == 0 { return 0 }
            let damping = 2 * Double(ratio) * sqrt(Double(stiffness))
            let rootReal = -damping * 0.5
            let rootImaginary = sqrt(abs(damping * damping - 4 * Double(stiffness))) * 0.5
            let c1 = abs(position)
            let c2 = ((position < 0 ? -speed : speed) - rootReal * c1) / rootImaginary
            let envelope = sqrt(c1 * c1 + c2 * c2)
            // Compose can return a negative estimate when already inside the
            // threshold. TargetBasedAnimation immediately finishes that case.
            return Int64(log(1 / envelope) / rootReal * 1000) * 1_000_000
        }
    }

    /// Raw FloatAnimationSpec sampling, including values beyond its estimated
    /// end. The animation owner, not this equation, applies endpoint snapping.
    func sample(at nanos: Int64, from start: Float, to target: Float, velocity: Float) -> Sample {
        switch self {
        case let .criticallyDampedSpring(stiffness, _):
            let frequency = sqrt(Double(stiffness))
            let time = Double(nanos / 1_000_000) / 1000
            let displacement = Double(start - target)
            let coefficient = Double(velocity) + frequency * displacement
            let decay = exp(-frequency * time)
            let position = (displacement + coefficient * time) * decay
            return Sample(value: Float(position + Double(target)),
                          velocity: Float(-frequency * position + coefficient * decay))
        case .tween(let milliseconds):
            let duration = durationNanos(from: start, to: target, velocity: velocity)
            let time = min(max(nanos, 0), duration)
            func value(_ nanos: Int64) -> Float {
                let fraction = milliseconds == 0 ? 1 : Float(min(max(nanos, 0), duration)) / Float(duration)
                let eased = Self.fastOutSlowIn(fraction)
                return (1 - eased) * start + eased * target
            }
            let current = value(time)
            let speed = time == 0 ? velocity : (current - value(time - 1_000_000)) * 1000
            return Sample(value: current, velocity: speed)
        case let .underdampedSpring(stiffness, ratio, threshold):
            precondition(stiffness > 0 && ratio > 0 && ratio < 1 && threshold > 0)
            let naturalFrequency = sqrt(Double(stiffness))
            let damping = Double(ratio)
            let frequency = naturalFrequency * sqrt(1 - damping * damping)
            let displacement = Double(start - target)
            // Compose 1.7.6 truncates to whole milliseconds for springs.
            let time = Double(nanos / 1_000_000) / 1000
            let sineCoefficient = (1 / frequency) * (damping * naturalFrequency * displacement + Double(velocity))
            let decay = exp(-damping * naturalFrequency * time)
            let sine = sin(frequency * time)
            let cosine = cos(frequency * time)
            let position = decay * (displacement * cosine + sineCoefficient * sine)
            let speed = position * (-naturalFrequency) * damping
                + decay * (-frequency * displacement * sine + frequency * sineCoefficient * cosine)
            return Sample(value: Float(position + Double(target)), velocity: Float(speed))
        }
    }

    /// TargetBasedAnimation's final-value/velocity behavior, which differs from
    /// querying the spring equation beyond its visibility threshold.
    func animationSample(at nanos: Int64, from start: Float, to target: Float, velocity: Float) -> Sample {
        let duration = durationNanos(from: start, to: target, velocity: velocity)
        guard nanos < duration else {
            switch self {
            case .underdampedSpring, .criticallyDampedSpring: return Sample(value: target, velocity: 0)
            case .tween: return Sample(value: target,
                velocity: sample(at: duration, from: start, to: target, velocity: velocity).velocity)
            }
        }
        return sample(at: nanos, from: start, to: target, velocity: velocity)
    }

    /// Compose's analytical cubic solver rather than a platform timing curve.
    /// Preserve Float/Double boundaries, including Float p1-p0 and p1-p2.
    static func fastOutSlowIn(_ fraction: Float) -> Float {
        guard fraction > 0 && fraction < 1 else { return fraction }
        let t = cubicRoot(-fraction, 0.4 - fraction, 0.2 - fraction, 1 - fraction)
        let a: Float = 1 / 3 - 1
        let value = 3 * ((a * t + 1) * t) * t
        return min(max(value, 0), 1)
    }

    private static func validRoot(_ value: Float) -> Float {
        let epsilon: Float = 8.3446500e-7
        if value < 0 { return value >= -epsilon ? 0 : .nan }
        if value > 1 { return value <= 1 + epsilon ? 1 : .nan }
        return value
    }

    private static func cubicRoot(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        var a = 3 * (Double(p0) - 2 * Double(p1) + Double(p2))
        var b = 3 * Double(p1 - p0)
        var c = Double(p0)
        let d = Double(-p0) + 3 * Double(p1 - p2) + Double(p3)
        if abs(d) < 1e-7 {
            if abs(a) < 1e-7 {
                return abs(b) < 1e-7 ? .nan : validRoot(Float(-c / b))
            }
            let q = sqrt(b * b - 4 * a * c)
            let first = validRoot(Float((q - b) / (2 * a)))
            return first.isNaN ? validRoot(Float((-b - q) / (2 * a))) : first
        }
        a /= d
        b /= d
        c /= d
        let o3 = (3 * b - a * a) / 9
        let q2 = (2 * a * a * a - 9 * a * b + 27 * c) / 54
        let discriminant = q2 * q2 + o3 * o3 * o3
        let a3 = a / 3
        if discriminant < 0 {
            let r = sqrt(-(o3 * o3 * o3))
            let phi = acos(min(max(-q2 / r, -1), 1))
            let t1 = 2 * ZTransferAndroidMath.fastCbrt(Float(r))
            for shift in [0.0, 2 * Double.pi, 4 * Double.pi] {
                let root = validRoot(Float(Double(t1) * cos((phi + shift) / 3) - a3))
                if !root.isNaN { return root }
            }
            return .nan
        }
        if discriminant == 0 {
            let u1 = -ZTransferAndroidMath.fastCbrt(Float(q2))
            let first = validRoot(2 * u1 - Float(a3))
            return first.isNaN ? validRoot(-u1 - Float(a3)) : first
        }
        let sd = sqrt(discriminant)
        let u1 = ZTransferAndroidMath.fastCbrt(Float(-q2 + sd))
        let v1 = ZTransferAndroidMath.fastCbrt(Float(q2 + sd))
        return validRoot(Float(Double(u1 - v1) - a3))
    }
}
