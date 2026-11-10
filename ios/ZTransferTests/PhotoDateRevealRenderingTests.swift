import XCTest
import SwiftUI
import UIKit
@testable import ZTransfer

@MainActor
final class PhotoDateRevealRenderingTests: XCTestCase {
    func testCollapseMovesEveryRowAndShrinksItsGapBeforeRemovingTheGrid() throws {
        for (progress, expectedHeight) in [(CGFloat(1), 122), (0.5, 66), (0, 10)] {
            let image = try collapsedRows(progress: progress)
            XCTAssertEqual(image.size.height, CGFloat(expectedHeight), accuracy: 0.5)
            if progress > 0 {
                // The second row must already move up at the halfway point.
                // The previous whole-grid clip left it at y=56, then hid it.
                let pixel = try rgba(image, x: 25, y: Int(56 * progress + 10))
                XCTAssertGreaterThan(pixel[1], pixel[0])
            }
        }
    }

    private func collapsedRows(progress: CGFloat) throws -> UIImage {
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(50), spacing: 6), count: 3), spacing: 0) {
                ForEach(0..<6) { index in
                    (index < 3 ? Color.red : Color.green)
                        .frame(width: 50, height: 50)
                        .modifier(PhotoDateCellCollapse(progress: progress))
                }
            }
            Color.blue.frame(height: 10)
        }.frame(width: 162).background(Color.white))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    private func rgba(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -CGFloat(x), y: CGFloat(y + 1 - cgImage.height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return pixel
    }

    func testExpandedCellsAreTransparentBeforeTheirEntranceTaskRuns() throws {
        // Render the real modifier synchronously, before .task has a chance to
        // reset state. The old implementation drew a black first frame here.
        XCTAssertGreaterThan(try centerRed(active: true), 245)
        XCTAssertLessThan(try centerRed(active: false), 10,
                          "Ordinary scrolling must display cached cells immediately")
    }

    private func centerRed(active: Bool) throws -> UInt8 {
        let renderer = ImageRenderer(content:
            Color.black.frame(width: 40, height: 40)
                .modifier(PhotoCellReveal(active: active, trigger: 1, delay: 0))
                .background(Color.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -20, y: -20)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        return pixel[0]
    }
}
