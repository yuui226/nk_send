import Foundation

/// GlassButton.kt's three independent animateFloatAsState channels. Input
/// timestamps govern the 90ms hold; display timestamps govern animation frames.
struct ZTransferButtonMotion {
    struct Frame: Equatable {
        var scale: Float = 1
        var light: Float = 0
        var active: Float = 0
    }

    private(set) var press = ZTransferButtonPressState()
    private(set) var scale = ZTransferScalarAnimation(value: 1)
    private(set) var light = ZTransferScalarAnimation(value: 0)
    private(set) var activation: ZTransferScalarAnimation
    private var skin: ZTransferButtonSkin
    private var panel: Bool

    init(skin: ZTransferButtonSkin, panel: Bool, active: Bool, enabled: Bool) {
        self.skin = skin
        self.panel = panel
        activation = ZTransferScalarAnimation(value: active && !panel ? 1 : 0)
        press.setEnabled(enabled)
    }

    var frame: Frame { Frame(scale: scale.value, light: light.value, active: activation.value) }
    var needsFrames: Bool { scale.isRunning || light.isRunning || activation.isRunning }

    mutating func configure(skin: ZTransferButtonSkin, panel: Bool, active: Bool, enabled: Bool) {
        self.skin = skin
        self.panel = panel
        press.setEnabled(enabled)
        updatePressTargets()
        activation.retarget(active && !panel ? 1 : 0, using: .tween(milliseconds: 180))
    }

    mutating func press(_ id: UInt64, at milliseconds: Int64) {
        press.press(id, at: milliseconds)
        updatePressTargets()
    }

    mutating func release(_ id: UInt64, at milliseconds: Int64) {
        press.release(id, at: milliseconds)
        updatePressTargets()
    }

    mutating func cancel(_ id: UInt64) {
        press.cancel(id)
        updatePressTargets()
    }

    mutating func advanceHold(to milliseconds: Int64) {
        press.advance(to: milliseconds)
        updatePressTargets()
    }

    mutating func advanceFrame(nanos: Int64) {
        scale.advance(frameNanos: nanos)
        light.advance(frameNanos: nanos)
        activation.advance(frameNanos: nanos)
    }

    mutating func reset(active: Bool) {
        press.reset()
        scale.reset(to: 1)
        light.reset(to: 0)
        activation.reset(to: active && !panel ? 1 : 0)
    }

    private mutating func updatePressTargets() {
        let pressed = press.visualPressed && press.enabled
        let downScale: Float
        switch skin {
        case .titanium: downScale = 0.970
        case .cameraControls: downScale = 0.982
        case .frostedGlass, .wood: downScale = 0.965
        case .liquidGlass: downScale = 1 // Previously accepted native material.
        }
        let releaseSpec: ZTransferAndroidMotion = skin == .cameraControls
            ? .tween(milliseconds: 140) : .underdampedSpring(stiffness: 400, dampingRatio: 0.5)
        scale.retarget(pressed ? downScale : 1, using: pressed ? .tween(milliseconds: 80) : releaseSpec)
        light.retarget(pressed ? 1 : 0, using: .tween(milliseconds: pressed ? 90 : 220))
    }
}
