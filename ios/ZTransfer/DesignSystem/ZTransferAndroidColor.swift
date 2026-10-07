// Copyright 2019, 2020, 2021 The Android Open Source Project
// Licensed under the Apache License, Version 2.0.
// See Resources/licenses/Apache-2.0.txt.
// Swift adaptation of Compose 1.7.6 Color.kt, Oklab.kt, Float16.kt and
// MathHelpers.kt; preserves Float32 operations and Color packing boundaries.
import Foundation

/// Exact sRGB -> packed Oklab -> sRGB path used by the Android button palette.
/// Matrices are Float32 bit patterns from the resolved 1.7.6 library, after
/// its Bradford D50 adaptation. See generate-android-color-fixtures.py.
enum ZTransferAndroidColor {
    private static let srgbToD50: [Float] = [0x3edf3e3e, 0x3e63d085, 0x3c6432cf, 0x3ec52cfc, 0x3f378732, 0x3dc6dd2b, 0x3e1283e7, 0x3d784ad4, 0x3f36d31c].map { Float(bitPattern: UInt32($0)) }
    private static let d50ToSrgb: [Float] = [0x40489893, 0xbf7a8ef3, 0x3d93598f, 0xbfcf017d, 0x3ff54339, 0xbe6a7b62, 0xbefb3b32, 0x3d0902ac, 0x3fb3dfe8].map { Float(bitPattern: UInt32($0)) }
    private static let M1: [Float] = [0x3f454c06, 0x3bb90975, 0x3d3ded66, 0x3eb2cde6, 0x3f6fe3a5, 0x3e817c3d, 0xbde5717d, 0x3d8eba37, 0x3f5a0574].map { Float(bitPattern: UInt32($0)) }
    private static let M2: [Float] = [0x3e578152, 0x3ffd2f0e, 0x3cd434b4, 0x3f4b2a89, 0xc01b6e0e, 0x3f4863bb, 0xbb856ece, 0x3ee6b438, 0xbf4f0560].map { Float(bitPattern: UInt32($0)) }
    private static let InverseM1: [Float] = [0x3fa4f1d5, 0xbb2ab843, 0xbd8e1b17, 0xbf09b253, 0x3f8bd206, 0xbe971673, 0x3e5aa850, 0xbdb7c4b3, 0x3f983844].map { Float(bitPattern: UInt32($0)) }
    private static let InverseM2: [Float] = [0x3f800001, 0x3f800000, 0x3f800001, 0x3ecaecca, 0xbdd8308c, 0xbdb7437b, 0x3e5cfba9, 0xbd82c5fb, 0xbfa54f66].map { Float(bitPattern: UInt32($0)) }

    static func lerp(start: UInt32, end: UInt32, fraction: Float) -> UInt32 {
        let a = toLab(start), b = toLab(end)
        let t = min(max(fraction, 0), 1)
        func interpolate(_ x: Float, _ y: Float) -> Float { (1 - t) * x + t * y }
        let lab = SIMD3(half(interpolate(a.x, b.x)), half(interpolate(a.y, b.y)), half(interpolate(a.z, b.z)))
        let alpha = quantizeAlpha(interpolate(a.w, b.w))
        let clamped = SIMD3(min(max(lab.x, 0), 1), min(max(lab.y, -0.5), 0.5), min(max(lab.z, -0.5), 0.5))
        let lms = multiply(InverseM2, clamped)
        let xyz = multiply(InverseM1, SIMD3(lms.x * lms.x * lms.x, lms.y * lms.y * lms.y, lms.z * lms.z * lms.z))
        let rgb = multiply(d50ToSrgb, xyz)
        return pack(red: encode(rgb.x), green: encode(rgb.y), blue: encode(rgb.z), alpha: alpha)
    }

    // Compose Color.VectorConverter (animation 1.7.6), sRGB destination.
    static func animationVector(_ argb: UInt32) -> SIMD4<Float> { toLab(argb) }

    static func fromAnimationVector(_ value: SIMD4<Float>) -> UInt32 {
        let lab = SIMD3(half(min(max(value.x, 0), 1)), half(min(max(value.y, -0.5), 0.5)),
                        half(min(max(value.z, -0.5), 0.5)))
        let lms = multiply(InverseM2, lab)
        let xyz = multiply(InverseM1, SIMD3(lms.x * lms.x * lms.x, lms.y * lms.y * lms.y, lms.z * lms.z * lms.z))
        let rgb = multiply(d50ToSrgb, xyz)
        return pack(red: encode(rgb.x), green: encode(rgb.y), blue: encode(rgb.z), alpha: quantizeAlpha(value.w))
    }

    static func pack(red: Float, green: Float, blue: Float, alpha: Float) -> UInt32 {
        func channel(_ x: Float) -> UInt32 { UInt32(min(max(x, 0), 1) * 255 + 0.5) }
        return channel(alpha) << 24 | channel(red) << 16 | channel(green) << 8 | channel(blue)
    }

    private static func toLab(_ argb: UInt32) -> SIMD4<Float> {
        let rgb = SIMD3(Float((argb >> 16) & 255) / 255, Float((argb >> 8) & 255) / 255, Float(argb & 255) / 255)
        let linear = SIMD3(decode(rgb.x), decode(rgb.y), decode(rgb.z))
        let xyz = multiply(srgbToD50, linear)
        let lms = multiply(M1, xyz)
        let lab = multiply(M2, SIMD3(ZTransferAndroidMath.fastCbrt(lms.x),
                                   ZTransferAndroidMath.fastCbrt(lms.y),
                                   ZTransferAndroidMath.fastCbrt(lms.z)))
        return SIMD4(half(min(max(lab.x, 0), 1)), half(min(max(lab.y, -0.5), 0.5)),
                     half(min(max(lab.z, -0.5), 0.5)), quantizeAlpha(Float(argb >> 24) / 255))
    }

    private static func multiply(_ m: [Float], _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(m[0] * v.x + m[3] * v.y + m[6] * v.z,
              m[1] * v.x + m[4] * v.y + m[7] * v.z,
              m[2] * v.x + m[5] * v.y + m[8] * v.z)
    }

    private static func decode(_ x: Float) -> Float {
        let x = Double(min(max(x, 0), 1))
        return Float(x >= 0.04045 ? pow((1 / 1.055) * x + 0.055 / 1.055, 2.4) : x * (1 / 12.92))
    }

    private static func encode(_ x: Float) -> Float {
        let x = Double(x)
        let value = x >= 0.04045 * (1 / 12.92)
            ? (pow(x, 1 / 2.4) - 0.055 / 1.055) / (1 / 1.055) : x / (1 / 12.92)
        return Float(min(max(value, 0), 1))
    }

    private static func quantizeAlpha(_ value: Float) -> Float {
        Float(Int(min(max(value, 0), 1) * 1023 + 0.5)) / 1023
    }

    /// Compose rounds a halfway significand up, unlike Float16's ties-to-even.
    /// Only finite Oklab components in [-0.5, 1] enter this packing boundary.
    private static func half(_ x: Float) -> Float {
        let bits = x.bitPattern
        let sign = (bits >> 16) & 0x8000
        let exponent = Int((bits >> 23) & 255) - 127 + 15
        var mantissa = bits & 0x7FFFFF
        let packed: UInt32
        if exponent <= 0 {
            if exponent < -10 { packed = sign }
            else {
                mantissa = (mantissa | 0x800000) >> UInt32(1 - exponent)
                if mantissa & 0x1000 != 0 { mantissa += 0x2000 }
                packed = sign | (mantissa >> 13)
            }
        } else {
            var magnitude = UInt32(exponent) << 10 | (mantissa >> 13)
            if mantissa & 0x1000 != 0 { magnitude += 1 }
            packed = sign | magnitude
        }
        return Float(Float16(bitPattern: UInt16(truncatingIfNeeded: packed)))
    }
}
