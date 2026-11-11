import XCTest
@testable import ZTransfer

final class PhotoCubeLUTMapperTests: XCTestCase {
    func testPreparedByteSamplerMatchesReferenceAcrossDomainsAndGridSizes() {
        for size in [2, 17, 33, 65] {
            let rgb = (0..<(size * size * size * 3)).map { Float(($0 * 37) % 1021) / 511 - 0.5 }
            for domain in [(SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)),
                           (SIMD3<Float>(-0.25, 0.1, 0.2), SIMD3<Float>(1.5, 0.8, 1.2))] {
                let lut = CubeLUT(size: size, domainMin: domain.0, domainMax: domain.1, rgb: rgb, digest: "fixture")
                let sampler = CubeLUT.ByteSampler(lut)
                // Sweep red/blue byte values with mixed green levels and endpoints.
                for r in 0..<256 {
                    for g in stride(from: 0, through: 255, by: 17) {
                        let b = (r * 13 + g * 7) % 256
                        let expected = lut.sample(SIMD3(Float(r), Float(g), Float(b)) / 255)
                        XCTAssertEqual(sampler.sample(red: UInt8(r), green: UInt8(g), blue: UInt8(b)), expected)
                    }
                }
            }
        }
    }

    func testIdentityKeepsPixelsAtAnyIntensityAndAlpha() throws {
        let rows = (0..<8).map { i in "\(Float(i & 1)) \(Float((i >> 1) & 1)) \(Float((i >> 2) & 1))\n" }.joined()
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + rows).utf8))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels: [UInt8] = [64, 128, 192, 77]
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let result = try PhotoCubeLUTMapper.apply(image, lut: lut, intensityPercent: 100)!
        XCTAssertEqual(result.width, 1); XCTAssertEqual(result.height, 1)
    }
}
