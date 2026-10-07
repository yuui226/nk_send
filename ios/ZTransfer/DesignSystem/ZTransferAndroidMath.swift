// Adapted from AndroidX ui-util MathHelpers.kt, Copyright 2019 The Android
// Open Source Project. Licensed under Apache-2.0; see Resources/licenses.
import Foundation

enum ZTransferAndroidMath {
    /// Compose's two-step Float32 cube-root approximation. Both its color
    /// connector and Bézier root solver depend on this rounding behavior.
    static func fastCbrt(_ x: Float) -> Float {
        let signed = Int64(Int32(bitPattern: x.bitPattern))
        let bits = UInt64(bitPattern: signed) & 0x1FFFFFFFF
        var estimate = Float(bitPattern: UInt32(truncatingIfNeeded: 0x2A510554 + bits / 3))
        estimate -= (estimate - x / (estimate * estimate)) * (Float(1) / 3)
        estimate -= (estimate - x / (estimate * estimate)) * (Float(1) / 3)
        return estimate
    }
}
