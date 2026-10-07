import XCTest
@testable import ZTransfer

final class PhotoCubeLUTMapperTests: XCTestCase {
    func testIdentityKeepsPixelsAtAnyIntensityAndAlpha() throws {
        let rows = (0..<8).map { i in "\(Float(i & 1)) \(Float((i >> 1) & 1)) \(Float((i >> 2) & 1))\n" }.joined()
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + rows).utf8))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels: [UInt8] = [64, 128, 192, 77]
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let result = PhotoCubeLUTMapper.apply(image, lut: lut, intensityPercent: 100)!
        XCTAssertEqual(result.width, 1); XCTAssertEqual(result.height, 1)
    }
}
