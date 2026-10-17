import Foundation

/// animateColorAsState uses four Oklab components. On interruption, its
/// displayed packed sRGB value is converted back to the animation vector.
struct ZTransferColorAnimation {
    private var components: [ZTransferScalarAnimation]
    private var target: UInt32
    private let durationMilliseconds: Int64
    init(_ color: UInt32, durationMilliseconds: Int64 = 160) {
        self.durationMilliseconds = durationMilliseconds
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
            components[i].retarget(next[i], using: .tween(milliseconds: durationMilliseconds), fromDisplayedValue: displayed[i], force: true)
        }
    }
    mutating func advance(_ nanos: Int64) {
        for i in 0..<4 { components[i].advance(frameNanos: nanos) }
    }
}
