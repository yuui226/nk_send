import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor
final class PremiumFireworksTests: XCTestCase {
    func testRenderedLaunchBurstAndFadeFrames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("premium-firework-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for seed in [1, 4] {
            for elapsed in [0.2, 0.48, 1.2, 1.8] {
                let drawing = PremiumFireworkDrawing(seed: seed)
                let canvas = Canvas { context, size in drawing.draw(context: context, size: size, elapsed: elapsed) }
                    .frame(width: 256, height: 384)
                    .background(Color.white)
                let renderer = ImageRenderer(content: canvas)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage)
                let data = try XCTUnwrap(image.pngData())
                let name = "firework-\(seed)-\(Int(elapsed * 1000))"
                let referenceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "png"))
                let reference = try XCTUnwrap(UIImage(contentsOfFile: referenceURL.path)?.cgImage)
                let actual = try XCTUnwrap(image.cgImage)
                XCTAssertTrue(try pixels(actual) == pixels(reference),
                              "Precomputed particles must preserve the original frame: \(name)")
                try data.write(to: folder.appendingPathComponent(name + ".png"))
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(image.size, CGSize(width: 256, height: 384))
            }
        }
        print("FIREWORK_FRAMES \(folder.path)")
    }

    private func pixels(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }
}
