import Foundation

/// CPU equations from Android SkinTexture.kt at the 1.91 baseline.
/// Returns unpremultiplied ARGB, before platform bitmap conversion or sampling.
/// All variants are checked against data executed from the Android source.
/// Rendering/cache integration is separate from this deterministic generator.
enum ZTransferMaterialTexture {
    enum Material: Int, CaseIterable, Sendable {
        case titanium = 1, wood = 2, cameraControls = 3

        var variantCount: Int {
            switch self {
            case .titanium: return 12
            case .wood: return 24
            case .cameraControls: return 4
            }
        }
    }

    static let tile = 256
    private static let tau = Float(2 * Double.pi)

    static func variant(material: Material, seed: Int32) -> Int {
        let remainder = Int(mixSeed(seed)) % material.variantCount
        return (remainder + material.variantCount) % material.variantCount
    }

    static func tileSeed(material: Material, variant: Int) -> Int32 {
        precondition((0..<material.variantCount).contains(variant))
        return mixSeed(Int32(bitPattern: 0x5F3759DF)
            ^ (Int32(material.rawValue) &* Int32(bitPattern: 0x045D9F3B)) ^ Int32(variant))
    }

    static func pixels(material: Material, dark: Bool, variant: Int) -> [UInt32] {
        let seed = tileSeed(material: material, variant: variant)
        switch material {
        case .wood: return woodPixels(dark: dark, seed: seed)
        case .titanium: return titaniumPixels(dark: dark, seed: seed)
        case .cameraControls: return cameraPixels(dark: dark, seed: seed)
        }
    }

    static func mixSeed(_ value: Int32) -> Int32 {
        var bits = UInt32(bitPattern: value)
        bits = (bits ^ (bits >> 16)) &* 0x7FEB352D
        bits = (bits ^ (bits >> 15)) &* 0x846CA68B
        return Int32(bitPattern: bits ^ (bits >> 16))
    }

    private static func cellHash(_ i: Int32, _ j: Int32, _ seed: Int32) -> Float {
        var bits = UInt32(bitPattern: i &* 374_761_393 &+ j &* 668_265_263 &+ seed &* 974_711)
        bits ^= bits >> 13
        bits = bits &* 1_274_126_177
        bits ^= bits >> 16
        return Float(bits & 0x7FFF_FFFF) / Float(Int32.max)
    }

    private static func packSigned(_ value: Float, _ maximumAlpha: Float,
                                   _ lightRGB: UInt32, _ darkRGB: UInt32) -> UInt32 {
        let clamped = min(max(value, -1), 1)
        let alpha = UInt32(min(max(Int(abs(clamped) * maximumAlpha * 255 + 0.5), 0), 255))
        return (alpha << 24) | ((clamped >= 0 ? lightRGB : darkRGB) & 0xFFFFFF)
    }

    // Kotlin/JVM Float math calls java.lang.Math with Double then narrows to Float.
    // Calling sinf/expf directly changes quantization at some alpha boundaries.
    private static func jvmSin(_ x: Float) -> Float { Float(sin(Double(x))) }
    private static func jvmCos(_ x: Float) -> Float { Float(cos(Double(x))) }
    private static func jvmExp(_ x: Float) -> Float { Float(exp(Double(x))) }
    private static func jvmSqrt(_ x: Float) -> Float { Float(sqrt(Double(x))) }

    private static func woodPixels(dark: Bool, seed: Int32) -> [UInt32] {
        let maxAlpha: Float = dark ? 0.30 : 0.21
        let lightRGB = dark ? 0xE0B16E : 0xF6D59A
        let darkRGB = dark ? 0x160B05 : 0x5C3013
        let phase = cellHash(seed, 11, seed &+ 31)
        let ringCount = 4 + Int(cellHash(seed, 29, seed &+ 71) * 3)
        let fiberCount = 24 + Int(cellHash(seed, 31, seed &+ 83) * 8)
        let fineCount = 14 + Int(cellHash(seed, 37, seed &+ 97) * 6)
        let bendStrength = 0.060 + 0.025 * cellHash(seed, 41, seed &+ 109)
        let knotEnabled = cellHash(seed, 43, seed &+ 127) > 0.58
        let knotX = 0.18 + 0.64 * cellHash(seed, 17, seed &+ 43)
        let knotY = 0.18 + 0.64 * cellHash(seed, 23, seed &+ 59)
        var pixels = [UInt32](repeating: 0, count: tile * tile)

        for y in 0..<tile {
            let v = Float(y) / Float(tile)
            for x in 0..<tile {
                let u = Float(x) / Float(tile)
                let low = periodicNoise(u, v, 2, 2, seed &+ 101)
                let mid = periodicNoise(u, v, 5, 4, seed &+ 211)
                let bend = bendStrength * low + 0.028 * mid
                    + 0.018 * jvmSin(tau * (u + phase)) * jvmCos(tau * v)

                let knotDX = torusDelta(u, knotX)
                let knotDY = torusDelta(v, knotY)
                let knotDistance = jvmSqrt(
                    (knotDX / 0.17) * (knotDX / 0.17)
                        + (knotDY / 0.25) * (knotDY / 0.25)
                )
                let knotMask = knotEnabled ? jvmExp(-2.7 * knotDistance * knotDistance) : 0
                let knotWarp = knotMask * 0.48
                    * jvmSin(tau * (u - knotX + periodicNoise(u, v, 3, 3, seed &+ 307)))
                let knotCore = knotEnabled ? jvmExp(-10 * knotDistance * knotDistance) : 0
                let knotRing = knotMask * jvmSin(tau * (3.4 * knotDistance + 0.15 * mid))

                let ringCoordinate = Float(ringCount) * (v + bend)
                    + 0.20 * jvmSin(tau * (u + phase)) + knotWarp
                let ringCycle = fract(ringCoordinate)
                let lateWoodCenter = 0.79 + 0.045 * mid
                let lateWoodDistance = (ringCycle - lateWoodCenter) / 0.075
                let lateWood = jvmExp(-lateWoodDistance * lateWoodDistance)
                let shoulderDistance = (ringCycle - lateWoodCenter + 0.105) / 0.14
                let lateWoodShoulder = jvmExp(-shoulderDistance * shoulderDistance)
                let earlyWood = jvmCos(tau * ringCycle)

                let fiberWarp = periodicNoise(u, v, 9, 7, seed &+ 401)
                let fiber = jvmSin(tau * (Float(fiberCount) * v + 0.55 * fiberWarp + bend * 4))
                let fineCoordinate = Float(fineCount) * (v + 0.55 * bend) + 0.38 * fiberWarp
                let fineCycle = fract(fineCoordinate)
                let fineDistance = (fineCycle - 0.82) / 0.07
                let fineLine = jvmExp(-fineDistance * fineDistance)
                let fibreNoise = periodicNoise(u, v, 7, 3, seed &+ 503)
                let fiberMask = 0.55 + 0.45 * min(max(fibreNoise, -0.8), 0.8)
                let macroTone = periodicNoise(u, v, 3, 2, seed &+ 601)

                let vesselGridX = u * 12
                let vesselGridY = v * 26
                let vesselCellX = Int32(floorf(vesselGridX))
                let vesselCellY = Int32(floorf(vesselGridY))
                let vesselLocalX = fract(vesselGridX)
                let vesselLocalY = fract(vesselGridY)
                let vesselHash = cellHash(vesselCellX, vesselCellY, seed &+ 719)
                let vesselCenterX = 0.18 + 0.64 * cellHash(vesselCellX, vesselCellY, seed &+ 761)
                let vesselCenterY = 0.20 + 0.60 * cellHash(vesselCellX, vesselCellY, seed &+ 809)
                let vesselDX = (vesselLocalX - vesselCenterX) / 0.34
                let vesselDY = (vesselLocalY - vesselCenterY) / 0.09
                let vessel = vesselHash > 0.72
                    ? jvmExp(-3.2 * (vesselDX * vesselDX + vesselDY * vesselDY))
                        * smoothStep(0.72, 0.96, vesselHash)
                    : 0

                let texture = 0.16 * macroTone + 0.14 * earlyWood
                    - 0.72 * lateWood - 0.12 * lateWoodShoulder
                    - 0.12 * fineLine * fiberMask + 0.045 * fiber
                    - 0.18 * vessel - 0.24 * knotCore + 0.08 * knotRing
                pixels[y * tile + x] = packSigned(texture, maxAlpha, UInt32(lightRGB), UInt32(darkRGB))
            }
        }

        return pixels
    }

    private static func titaniumPixels(dark: Bool, seed: Int32) -> [UInt32] {
        let maxAlpha: Float = dark ? 0.115 : 0.080
        let lightRGB: UInt32 = dark ? 0xDDE7EC : 0xFFFFFF
        let darkRGB: UInt32 = dark ? 0x28333A : 0x69747B
        var pixels = [UInt32](repeating: 0, count: tile * tile)
        for y in 0..<tile {
            let v = Float(y) / Float(tile)
            for x in 0..<tile {
                let u = Float(x) / Float(tile)
                let macro = periodicNoise(u, v, 4, 4, seed &+ 101)
                let warp = periodicNoise(u, v, 3, 5, seed &+ 211)
                let brushed = periodicNoise(u + 0.012 * warp, v + 0.004 * macro, 9, 96, seed &+ 307)
                let fine = periodicNoise(u, v, 47, 61, seed &+ 401)
                let micro = cellHash(Int32(x), Int32(y), seed &+ 503) * 2 - 1
                let hairline = jvmSin(tau * (72 * v + 0.18 * macro + 0.04 * jvmSin(tau * u)))
                let texture = 0.10 * macro + 0.34 * brushed + 0.20 * fine + 0.18 * micro + 0.06 * hairline
                pixels[y * tile + x] = packSigned(texture, maxAlpha, lightRGB, darkRGB)
            }
        }
        return pixels
    }

    private static func cameraPixels(dark: Bool, seed: Int32) -> [UInt32] {
        let maxAlpha: Float = dark ? 0.090 : 0.075
        let lightRGB: UInt32 = dark ? 0xAEB5B9 : 0xC5CBCF
        var pixels = [UInt32](repeating: 0, count: tile * tile)
        for y in 0..<tile {
            let v = Float(y) / Float(tile)
            for x in 0..<tile {
                let u = Float(x) / Float(tile)
                let macro = periodicNoise(u, v, 5, 5, seed &+ 101)
                let micro = cellHash(Int32(x), Int32(y), seed &+ 307) * 2 - 1
                let pitNoise = cellHash(Int32(x), Int32(y), seed &+ 401)
                let pit: Float = pitNoise > 0.985 ? smoothStep(0.985, 1, pitNoise) : 0
                let texture = 0.14 * macro + 0.48 * micro - 0.42 * pit
                pixels[y * tile + x] = packSigned(texture, maxAlpha, lightRGB, 0x030405)
            }
        }
        return pixels
    }

    private static func smoothCurve(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }

    private static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return smoothCurve(x)
    }

    private static func fract(_ value: Float) -> Float { value - floorf(value) }

    private static func periodicNoise(
        _ u: Float,
        _ v: Float,
        _ cellsX: Int32,
        _ cellsY: Int32,
        _ seed: Int32
    ) -> Float {
        let gx = u * Float(cellsX)
        let gy = v * Float(cellsY)
        let x0 = Int32(floorf(gx))
        let y0 = Int32(floorf(gy))
        let tx = smoothCurve(gx - floorf(gx))
        let ty = smoothCurve(gy - floorf(gy))
        func sample(_ x: Int32, _ y: Int32) -> Float {
            let wx = ((x % cellsX) + cellsX) % cellsX
            let wy = ((y % cellsY) + cellsY) % cellsY
            return cellHash(wx, wy, seed) * 2 - 1
        }
        let a = sample(x0, y0)
        let b = sample(x0 &+ 1, y0)
        let c = sample(x0, y0 &+ 1)
        let d = sample(x0 &+ 1, y0 &+ 1)
        let top = a + (b - a) * tx
        let bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    private static func torusDelta(_ a: Float, _ b: Float) -> Float {
        let direct = abs(a - b)
        return min(direct, 1 - direct)
    }
}
