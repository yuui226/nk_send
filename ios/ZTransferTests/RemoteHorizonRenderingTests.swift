import SwiftUI
import XCTest
@testable import ZTransfer

@MainActor
final class RemoteHorizonRenderingTests: XCTestCase {
    private final class Inputs: ObservableObject { @Published var roll: Float = 0 }
    private struct LiveOverlay: View {
        @ObservedObject var inputs: Inputs
        var body: some View {
            RemoteHorizonOverlay(roll: inputs.roll, pitch: nil).equatable()
                .frame(width: 400, height: 300).background(.black).ignoresSafeArea()
        }
    }

    func testEquatableOverlayStillRunsItsOwnAnimationWhenAngleChanges() async throws {
        let input = Inputs()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let host = UIHostingController(rootView: LiveOverlay(inputs: input))
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func pixels() throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: 400, height: 300), afterScreenUpdates: true)
            }
            var bytes = [UInt8](repeating: 0, count: 400 * 300 * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: 400, height: 300, bitsPerComponent: 8,
                bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 400, height: 300))
            return bytes
        }
        try await Task.sleep(for: .milliseconds(300))
        let horizontal = try pixels()
        input.roll = 90
        try await Task.sleep(for: .milliseconds(300))
        let vertical = try pixels()
        func green(_ data: [UInt8], x: Int, y: Int) -> UInt8 {
            (-1...1).flatMap { dy in (-1...1).map { dx in data[((y + dy) * 400 + x + dx) * 4 + 1] } }.max() ?? 0
        }
        XCTAssertGreaterThan(green(horizontal, x: 230, y: 150), 100)
        XCTAssertLessThan(green(vertical, x: 230, y: 150), 20)
        XCTAssertGreaterThan(green(vertical, x: 200, y: 180), 100)
    }

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
