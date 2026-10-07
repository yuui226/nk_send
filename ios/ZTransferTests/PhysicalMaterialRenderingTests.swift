import SwiftUI
import XCTest
@testable import ZTransfer

@MainActor
final class PhysicalMaterialRenderingTests: XCTestCase {
    private struct Raster {
        let width: Int
        let height: Int
        let rgba: [UInt8]
        func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * width + x) * 4 + 3] }
    }

    private func render<V: View>(_ view: V) throws -> Raster {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Raster(width: image.width, height: image.height, rgba: bytes)
    }

    func testStampKeepsAllFourEdgesInsideOriginalGlyphAndPressChangesOnlyEdges() throws {
        func glyph(_ press: CGFloat) -> some View {
            Rectangle().fill(.white).frame(width: 32, height: 24).padding(8)
                .modifier(ZTransferTitaniumStamp(dark: true, inlay: nil, pressProgress: press))
        }
        let released = try render(glyph(0))
        let pressed = try render(glyph(1))
        XCTAssertEqual(released.width, 192)
        XCTAssertEqual(released.height, 160)
        XCTAssertEqual(pressed.width, released.width)
        for y in 0..<released.height {
            for x in 0..<released.width where x < 32 || x >= 160 || y < 32 || y >= 128 {
                XCTAssertEqual(released.alpha(x, y), 0, "External stamp artifact at \(x),\(y)")
                XCTAssertEqual(pressed.alpha(x, y), 0)
            }
        }
        XCTAssertEqual(Int(released.alpha(96, 80)), 230, accuracy: 1)
        XCTAssertEqual(released.alpha(96, 80), pressed.alpha(96, 80))
        XCTAssertTrue(released.rgba != pressed.rgba, "Subpixel stamp edges must react to pressure")
    }

    func testCameraPanelHasNoCapAndCenteredRimDoesNotEscapeShape() throws {
        func cap(panel: Bool) -> some View {
            ZTransferPhysicalMaterialFinish(skin: .cameraControls, cornerRadius: 12,
                dark: true, panel: panel, activeColor: .blue, pressProgress: 1, activeProgress: 1)
                .frame(width: 52, height: 52)
        }
        let panel = try render(cap(panel: true))
        XCTAssertTrue(stride(from: 3, to: panel.rgba.count, by: 4).allSatisfy { panel.rgba[$0] == 0 })
        let button = try render(cap(panel: false))
        XCTAssertGreaterThan(button.alpha(button.width / 2, button.height / 2), 0)
        for (x, y) in [(0, 0), (button.width - 1, 0), (0, button.height - 1),
                       (button.width - 1, button.height - 1)] {
            XCTAssertEqual(button.alpha(x, y), 0)
        }
    }
}
