import Foundation

/// animateColorAsState uses four Oklab components. On interruption, its
/// displayed packed sRGB value is converted back to the animation vector.
struct RemoteHorizonColorAnimation {
    private var components: [ZTransferScalarAnimation]
    private var target: UInt32
    init(_ color: UInt32) {
        target = color
        let vector = ZTransferAndroidColor.animationVector(color)
        components = (0..<4).map { ZTransferScalarAnimation(value: vector[$0]) }
    }
    var isRunning: Bool { components.contains { $0.isRunning } }
    var value: UInt32 {
        guard isRunning else { return target }
        return ZTransferAndroidColor.fromAnimationVector(SIMD4(components[0].value,
            components[1].value, components[2].value, components[3].value))
    }
    mutating func retarget(_ color: UInt32) {
        guard color != target else { return }
        let displayed = ZTransferAndroidColor.animationVector(value)
        let next = ZTransferAndroidColor.animationVector(color)
        target = color
        for i in 0..<4 {
            components[i].retarget(next[i], using: .tween(milliseconds: 160), fromDisplayedValue: displayed[i], force: true)
        }
    }
    mutating func advance(_ nanos: Int64) {
        for i in 0..<4 { components[i].advance(frameNanos: nanos) }
    }
}

struct RemoteHorizonAnimation {
    static let green: UInt32 = 0xFF52F58B
    static let amber: UInt32 = 0xFFFFC857
    private(set) var rollAligned: Bool
    private(set) var pitchAligned = false
    private(set) var hasPitch: Bool
    private(set) var angle: ZTransferScalarAnimation
    private(set) var pitchOffset: ZTransferScalarAnimation
    private(set) var stroke: ZTransferScalarAnimation
    private(set) var tint: RemoteHorizonColorAnimation
    private(set) var pitchTint = RemoteHorizonColorAnimation(0xA6FFFFFF)
    private(set) var reference: RemoteHorizonColorAnimation
    var aligned: Bool { rollAligned && (!hasPitch || pitchAligned) }
    var isRunning: Bool { angle.isRunning || pitchOffset.isRunning || stroke.isRunning || tint.isRunning || pitchTint.isRunning || reference.isRunning }

    init(roll: Float, pitch: Float?) {
        rollAligned = RemoteHorizon.aligned(roll, wasAligned: false)
        hasPitch = RemoteHorizon.validPitch(pitch) != nil
        angle = .init(value: roll)
        pitchOffset = .init(value: RemoteHorizon.pitchOffset(pitch))
        stroke = .init(value: rollAligned ? 1.6 : 1.2)
        tint = .init(rollAligned ? Self.green : Self.amber)
        reference = .init(rollAligned && !hasPitch ? 0x6152F58B : 0x42FFFFFF)
    }
    mutating func update(roll: Float, pitch: Float?) {
        rollAligned = RemoteHorizon.aligned(roll, wasAligned: rollAligned)
        hasPitch = RemoteHorizon.validPitch(pitch) != nil
        pitchAligned = RemoteHorizon.pitchAligned(pitch, wasAligned: pitchAligned)
        angle.retarget(RemoteHorizon.displayRoll(roll, previous: angle.target), using: .tween(milliseconds: 100))
        pitchOffset.retarget(RemoteHorizon.pitchOffset(pitch), using: .tween(milliseconds: 100))
        stroke.retarget(rollAligned ? 1.6 : 1.2, using: .tween(milliseconds: 160))
        tint.retarget(rollAligned ? Self.green : Self.amber)
        pitchTint.retarget(pitchAligned ? Self.green : 0xA6FFFFFF)
        reference.retarget(aligned ? 0x6152F58B : 0x42FFFFFF)
    }
    mutating func advance(_ nanos: Int64) {
        angle.advance(frameNanos: nanos); pitchOffset.advance(frameNanos: nanos)
        stroke.advance(frameNanos: nanos)
        tint.advance(nanos); pitchTint.advance(nanos); reference.advance(nanos)
    }
}
