import SwiftUI
import XCTest
@testable import ZTransfer

@MainActor
final class RemoteHorizonRenderingTests: XCTestCase {
    private func raster(roll: Float, pitch: Float?, size: CGSize = CGSize(width: 400, height: 300)) throws -> (Int, Int, [UInt8]) {
        var state = RemoteHorizonAnimation(roll: roll, pitch: pitch)
        state.update(roll: roll, pitch: pitch)
        state.advance(0); state.advance(160_000_000)
        let renderer = ImageRenderer(content: RemoteHorizonDrawing(state: state).frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, bytes)
    }

    func testSmallViewportIsEmptyAndNormalDrawingStaysAtSpecifiedRadius() throws {
        let small = try raster(roll: 0, pitch: 0, size: CGSize(width: 80, height: 60))
        XCTAssertTrue(stride(from: 3, to: small.2.count, by: 4).allSatisfy { small.2[$0] == 0 })
        let normal = try raster(roll: 23, pitch: 15)
        var visible = 0
        for y in 0..<normal.1 {
            for x in 0..<normal.0 where normal.2[(y * normal.0 + x) * 4 + 3] != 0 {
                visible += 1
                XCTAssertLessThanOrEqual(hypot(Double(x) + 0.5 - 200, Double(y) + 0.5 - 150), 78)
            }
        }
        XCTAssertGreaterThan(visible, 500)
    }

    func testPitchAddsChordWhileQuarterTurnRotatesRollDiameter() throws {
        let single = try raster(roll: 0, pitch: nil)
        let dual = try raster(roll: 0, pitch: 20)
        func alpha(_ raster: (Int, Int, [UInt8]), _ x: Int, _ y: Int) -> UInt8 {
            raster.2[(y * raster.0 + x) * 4 + 3]
        }
        // Chord is at +/-37px from center (bitmap row origin may be flipped).
        let chordPixels = [112, 113, 186, 187].map { alpha(dual, 220, $0) }
        XCTAssertGreaterThan(chordPixels.max() ?? 0, 100)
        XCTAssertTrue([112, 113, 186, 187].allSatisfy { alpha(single, 220, $0) == 0 })
        let vertical = try raster(roll: 90, pitch: nil)
        XCTAssertGreaterThan(alpha(single, 230, 150), 100)
        XCTAssertEqual(alpha(vertical, 230, 150), 0)
        XCTAssertGreaterThan(alpha(vertical, 200, 180), 100)
    }
}
