import SwiftUI
import XCTest
@testable import ZTransfer

@MainActor
final class RemoteViewfinderRenderingTests: XCTestCase {
    func testDesqueezeFitsImageOnceAndKeepsSourceStripeAtOneThirdOfDisplayedWidth() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.white.setFill()
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
        }
        for multiplier in [CGFloat(1), 1.33, 1.5, 1.8, 2] {
            for size in [CGSize(width: 400, height: 400), CGSize(width: 800, height: 200)] {
                let aspect = 1.5 * multiplier
                let view = RemoteViewfinderImage(image: image, aspect: aspect, multiplier: multiplier, size: size)
                    .background(.black)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let rendered = try XCTUnwrap(renderer.cgImage)
                var pixels = [UInt8](repeating: 0, count: rendered.width * rendered.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: rendered.width,
                        height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(rendered, in: CGRect(origin: .zero, size: size))
                }
                let row = rendered.height / 2
                let white = (0..<rendered.width).filter { x in
                    let index = (row * rendered.width + x) * 4
                    return pixels[index] > 240 && pixels[index+1] > 240 && pixels[index+2] > 240
                }
                let expectedWidth = min(size.width, size.height * aspect)
                XCTAssertEqual(CGFloat(white.count), expectedWidth / 3, accuracy: 2,
                               "multiplier=\(multiplier), size=\(size)")
                XCTAssertEqual(CGFloat(try XCTUnwrap(white.first) + (try XCTUnwrap(white.last))) / 2,
                               size.width / 2 - 0.5, accuracy: 1)
            }
        }
    }
}
