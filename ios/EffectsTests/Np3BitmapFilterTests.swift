import CoreGraphics
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferEffects
#else
@testable import ZTransfer
#endif

final class Np3BitmapFilterTests: XCTestCase {
    func testSRGBAdapterPreservesPixelOrderAndMatchesOpaqueAndroidPixels() throws {
        let pixels: [UInt32] = [0xffff_0000, 0xff00_ff00, 0xff00_00ff, 0xffa2_8e43]
        let source = try image(pixels, width: 2)
        let preset = Np3FilterCatalog.presets[0]
        let filtered = try Np3BitmapFilter.apply(source, parameters: preset.parameters, intensityPercent: 80)
        let engine = Np3FilterEngine(parameters: preset.parameters, intensityPercent: 80)
        XCTAssertEqual(try rgbaBytes(filtered), pixels.flatMap { rgba(engine.filterPixel($0)) })
        XCTAssertEqual(filtered.width, source.width)
        XCTAssertEqual(filtered.height, source.height)
        XCTAssertEqual(filtered.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testTranslucentInputIsUnpremultipliedForFilteringAndPremultipliedForDrawing() throws {
        let pixels: [UInt32] = [0x80ff_8000, 0x0000_0000]
        let source = try image(pixels, width: 2)
        let preset = Np3FilterCatalog.presets[1]
        let filtered = try Np3BitmapFilter.apply(source, parameters: preset.parameters, intensityPercent: 100)
        let engine = Np3FilterEngine(parameters: preset.parameters, intensityPercent: 100)
        let straight = rgba(engine.filterPixel(pixels[0]))
        let premultiplied = straight.prefix(3).map { UInt8((UInt32($0) * 128 + 127) / 255) } + [128]
        XCTAssertEqual(try rgbaBytes(filtered), premultiplied + [0, 0, 0, 0])
    }

    func testCancelledRenderDoesNotAllocateOrReturnAFilteredImage() async throws {
        let source = try image([0xffff_0000], width: 1)
        let render = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Np3BitmapFilter.apply(source, parameters: Np3FilterCatalog.presets[0].parameters,
                                            intensityPercent: 80)
        }
        do { _ = try await render.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOriginalIsSerialAndPreviewHasAtMostTwoWorkers() {
        for processors in [1, 2, 3, 8, 64] {
            XCTAssertEqual(PhotoFilterExecution.original.workers(width: 6000, height: 4000, processors: processors), 1)
            XCTAssertEqual(PhotoFilterExecution.preview.workers(width: 511, height: 512, processors: processors), 1)
            XCTAssertEqual(PhotoFilterExecution.preview.workers(width: 512, height: 512, processors: processors), min(max(processors - 1, 1), 2))
        }
    }

    func testSerialAndParallelPathsProduceIdenticalPixelsIncludingOddFinalRow() throws {
        // Above the Android parallel threshold; 513 rows exercises uneven partitioning.
        let palette: [UInt32] = [0xffff0000, 0xff00ff00, 0xff0000ff, 0x80804020, 0x00000000]
        let pixels = (0..<(512 * 513)).map { palette[$0 % palette.count] }
        let source = try image(pixels, width: 512)
        let parameters = Np3FilterCatalog.presets[1].parameters
        let original = try Np3BitmapFilter.apply(source, parameters: parameters, intensityPercent: 80, execution: .original)
        let preview = try Np3BitmapFilter.apply(source, parameters: parameters, intensityPercent: 80, execution: .preview)
        XCTAssertEqual(try rgbaBytes(original), try rgbaBytes(preview))
        XCTAssertEqual(original.width, 512)
        XCTAssertEqual(original.height, 513)
        XCTAssertEqual(try rgbaBytes(source), pixels.flatMap(rgba))
    }

    private func image(_ argb: [UInt32], width: Int) throws -> CGImage {
        let bytes = argb.flatMap(rgba)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: argb.count / width,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgba(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255), UInt8(value >> 24)]
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return (0..<image.height).flatMap { row in
            Array(data[(row * image.bytesPerRow)..<(row * image.bytesPerRow + image.width * 4)])
        }
    }
}
