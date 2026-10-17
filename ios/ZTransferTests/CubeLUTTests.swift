import XCTest
import UIKit
import Metal
@testable import ZTransfer

final class CubeLUTTests: XCTestCase {
    func testActiveMappingCancellationReleasesPreviewPermitForNextRender() async throws {
        let lut = try CubeLUTParser.parse(cube())
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256,
            bitsPerComponent: 8, bytesPerRow: 256 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let source = try XCTUnwrap(context.makeImage())
        let entered = expectation(description: "First 4096 pixels processed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let old = Task {
            try await PhotoEffectsPreviewRenderGate.render {
                var checks = 0
                return try PhotoCubeLUTMapper.apply(source, lut: lut, intensityPercent: 80) {
                    checks += 1
                    if checks == 3 { // Entry, first batch, then second batch.
                        entered.fulfill()
                        guard release.wait(timeout: .now() + 5) == .success else {
                            throw NSError(domain: "active-mapping-timeout", code: 1)
                        }
                    }
                    try Task.checkCancellation()
                }
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        old.cancel()
        let replacement = Task {
            try await PhotoEffectsPreviewRenderGate.render {
                try PhotoCubeLUTMapper.apply(source, lut: lut, intensityPercent: 100)
            }
        }
        release.signal()
        do { _ = try await old.value; XCTFail("Cancelled mapping published an image") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let output = try await replacement.value
        XCTAssertEqual(output?.width, 256)
        XCTAssertEqual(output?.height, 256)
        let pending = await PhotoEffectsPreviewRenderGate.shared.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testMappingCancellationStopsAtBatchBoundaryAndBeforePublishing() throws {
        let lut = try CubeLUTParser.parse(cube())
        let width = 129, height = 65 // Three batches, including a short tail.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for alpha: UInt8 in [0, 255] {
            var pixels = [UInt8](repeating: 64, count: width * height * 4)
            for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = alpha }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            // Entry, three batch starts, then the publication checkpoint.
            for cancelledAt in 1...5 {
                var checks = 0
                XCTAssertThrowsError(try PhotoCubeLUTMapper.apply(source, lut: lut, intensityPercent: 80) {
                    checks += 1
                    if checks == cancelledAt { throw CancellationError() }
                }) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertEqual(checks, cancelledAt)
            }
            var checks = 0
            XCTAssertNotNil(try PhotoCubeLUTMapper.apply(source, lut: lut, intensityPercent: 80) { checks += 1 })
            XCTAssertEqual(checks, 5)
        }
    }

    func testRejectsOverflowingDomainRangeAndSubnormalReciprocal() {
        for bounds in [
            "DOMAIN_MIN -3e38 0 0\nDOMAIN_MAX 3e38 1 1\n",
            "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 3e38 1 1\n"
        ] {
            XCTAssertThrowsError(try CubeLUTParser.parse(cube(bounds))) {
                XCTAssertEqual($0 as? CubeLUTFailure, .invalid)
            }
        }
    }

    func testExtendedLUTOutputClampsBeforeMixingWithOpaqueAndPremultipliedPixels() throws {
        let text = "DOMAIN_MIN 0.25 0.25 0.25\nDOMAIN_MAX 0.75 0.75 0.75\nLUT_3D_SIZE 2\n"
            + String(repeating: "-0.5 1.5 0.5\n", count: 8)
        let lut = try CubeLUTParser.parse(Data(text.utf8))
        let bytes = Data([128, 64, 32, 255, 64, 32, 16, 128, 0, 0, 0, 0])
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let source = try XCTUnwrap(CGImage(width: 3, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 12, space: space, bitmapInfo: info,
            provider: XCTUnwrap(CGDataProvider(data: bytes as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for (strength, expected): (Int, [UInt8]) in [
            (50, [64, 160, 80, 255, 32, 80, 40, 128, 0, 0, 0, 0]),
            (100, [0, 255, 128, 255, 0, 128, 64, 128, 0, 0, 0, 0])
        ] {
            let output = try XCTUnwrap(PhotoCubeLUTMapper.apply(source, lut: lut, intensityPercent: strength))
            let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8,
                bytesPerRow: 12, space: space, bitmapInfo: info.rawValue))
            context.draw(output, in: CGRect(x: 0, y: 0, width: 3, height: 1))
            let result = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: result, count: 12)), expected)
        }
    }

    func testProductionRendererFinishesAfterLUTMixAndPreservesAlpha() throws {
        let lut = try CubeLUTParser.parse(cube())
        PhotoLUTRuntime.register(lut)
        let bytes = Data([255, 0, 0, 255, 128, 0, 0, 128, 0, 0, 0, 0])
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let source = try XCTUnwrap(CGImage(width: 3, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 12, space: space, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = false
        settings.photoFilterEnabled = true
        settings.selectedFilter = .init(preset: .init(id: "cube:\(lut.digest)", name: "Black"),
            intensityPercent: 50, lutAdjustments: .init(saturation: -100))
        let output = try PhotoEffectsRenderer.render(UIImage(cgImage: source), settings: settings)
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8,
            bytesPerRow: 12, space: space, bitmapInfo: bitmapInfo.rawValue))
        context.draw(try XCTUnwrap(output.cgImage), in: CGRect(x: 0, y: 0, width: 3, height: 1))
        let result = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // 50% black LUT maps red to 128; Rec709 gray rounds to 27.
        XCTAssertEqual(Array(UnsafeBufferPointer(start: result, count: 12)),
                       [27, 27, 27, 255, 14, 14, 14, 128, 0, 0, 0, 0])
    }

    func testAndroidLUTFinishingPreservesNeutralGrayAndTransparency() {
        XCTAssertEqual(LUTColorPipeline.apply(0x80406080, adjustments: .init(), preserveAlpha: true), 0x80406080)
        XCTAssertEqual(LUTColorPipeline.apply(0xff808080, adjustments: .init(saturation: 100), preserveAlpha: false), 0xff808080)
        XCTAssertEqual(LUTColorPipeline.apply(0x00112233, adjustments: .init(contrast: 100), preserveAlpha: true), 0x00112233)
        let result = LUTColorPipeline.apply(0xff102030, adjustments: .init(contrast: 100, saturation: 100, highlights: 100, shadows: -100), preserveAlpha: false)
        XCTAssertEqual(result >> 24, 255)
        XCTAssertNotEqual(result, 0xff102030)
        XCTAssertEqual(LUTColorPipeline.apply(0xffff0000, adjustments: .init(saturation: -100), preserveAlpha: true), 0xff363636)
    }

    func testLUTSelectionMigratesOldJSONAndRetainsNormalizedAdjustments() throws {
        let legacy = Data(#"{"preset":{"id":"cube:test","name":"Name"},"intensityPercent":80}"#.utf8)
        var selection = try JSONDecoder().decode(PhotoFilterSelection.self, from: legacy)
        XCTAssertTrue(selection.lutAdjustments.isNeutral)
        selection.lutAdjustments = .init(contrast: 200, saturation: -200, highlights: 25, shadows: -30)
        let restored = try JSONDecoder().decode(PhotoFilterSelection.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(restored.lutAdjustments, .init(contrast: 100, saturation: -100, highlights: 25, shadows: -30))
    }

    func testMonitorMetalReportsUnavailableAndPipelineFailure() throws {
        XCTAssertThrowsError(try RemoteLUTMetalRenderer(device: nil)) {
            XCTAssertEqual($0 as? RemoteLUTMetalRenderer.Failure, .unavailable)
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var resources = RemoteLUTMetalRenderer.Resources()
        resources.makePipeline = { _, _ in throw NSError(domain: "InjectedPipelineFailure", code: 1) }
        XCTAssertThrowsError(try RemoteLUTMetalRenderer(device: device, resources: resources)) {
            XCTAssertEqual($0 as? RemoteLUTMetalRenderer.Failure, .pipeline)
        }
    }

    func testMonitorMetalKeepsPreviousTableOnTextureFailureAndValidatesInputColor() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var rejectTexture = false
        var resources = RemoteLUTMetalRenderer.Resources()
        resources.makeTexture = { device, descriptor in rejectTexture ? nil : device.makeTexture(descriptor: descriptor) }
        let renderer = try RemoteLUTMetalRenderer(device: device, resources: resources)
        func table(_ rgb: String) throws -> CubeLUT {
            try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "\(rgb)\n", count: 8)).utf8))
        }
        try renderer.setLUT(table("1 0 0"))
        rejectTexture = true
        XCTAssertThrowsError(try renderer.setLUT(table("0 0 1"))) {
            XCTAssertEqual($0 as? RemoteLUTMetalRenderer.Failure, .texture)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [255,0,0,255, 0,255,0,255, 50,80,110,255, 255,255,255,255]
        bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,2,2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        for useImage in [false, true] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            if useImage {
                let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                    bytesPerRow: 8, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
                try renderer.encode(image: XCTUnwrap(context.makeImage()), into: output, commandBuffer: command)
            } else {
                try renderer.encode(source: source, destination: output, commandBuffer: command)
            }
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var actual = [UInt8](repeating: 0, count: 16)
            actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0,0,2,2), mipmapLevel: 0) }
            XCTAssertEqual(actual, Array(repeating: [UInt8(0),0,255,255], count: 4).flatMap { $0 })
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(try renderer.encode(image: XCTUnwrap(context.makeImage()), into: output, commandBuffer: command)) {
            XCTAssertEqual($0 as? RemoteLUTMetalRenderer.Failure, .inputColor)
        }
    }

    private func cube(_ body: String = "") -> Data {
        Data(("LUT_3D_SIZE 2\n" + body + (0..<8).map { _ in "0 0 0\n" }.joined()).utf8)
    }

    func testParsesDefaultsAndRFastestData() throws {
        let lut = try CubeLUTParser.parse(cube())
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.domainMin, SIMD3(repeating: 0))
        XCTAssertEqual(lut.domainMax, SIMD3(repeating: 1))
        XCTAssertEqual(lut.rgb.count, 24)
        XCTAssertEqual(lut.digest.count, 64)
        XCTAssertEqual(lut.rgba16FloatUploadValues.count, 32)
        XCTAssertEqual(lut.rgba16FloatUploadValues[3], Float16(1))
    }

    func testParsesDomainAndRejectsMalformedBounds() throws {
        let lut = try CubeLUTParser.parse(cube("DOMAIN_MIN -0.1 0 0\nDOMAIN_MAX 1.2 1 1\n"))
        XCTAssertEqual(lut.domainMin.x, -0.1, accuracy: 0.0001)
        XCTAssertThrowsError(try CubeLUTParser.parse(cube("DOMAIN_MIN 1 0 0\nDOMAIN_MAX 0 1 1\n")))
    }

    func testRejectsIncompleteUnsupportedAndOversizedLines() {
        XCTAssertThrowsError(try CubeLUTParser.parse(Data("LUT_3D_SIZE 2\n0 0\n".utf8)))
        XCTAssertThrowsError(try CubeLUTParser.parse(Data("LUT_3D_SIZE 1\n".utf8)))
        XCTAssertThrowsError(try CubeLUTParser.parse(Data(("#" + String(repeating: "x", count: CubeLUTParser.maxLine + 1)).utf8)))
    }

    func testTrilinearSamplingUsesRFastestIndexAndClampsDomain() throws {
        let rows = (0..<8).map { index -> String in
            let r = Float(index & 1), g = Float((index >> 1) & 1), b = Float((index >> 2) & 1)
            return "\(r) \(g) \(b)\n"
        }.joined()
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + rows).utf8))
        let midpoint = lut.sample(SIMD3<Float>(0.25, 0.5, 0.75))
        XCTAssertEqual(midpoint.x, 0.25, accuracy: 0.0001); XCTAssertEqual(midpoint.y, 0.5, accuracy: 0.0001); XCTAssertEqual(midpoint.z, 0.75, accuracy: 0.0001)
        let clamped = lut.sample(SIMD3<Float>(-1, 2, 1))
        XCTAssertEqual(clamped.x, 0, accuracy: 0.0001); XCTAssertEqual(clamped.y, 1, accuracy: 0.0001); XCTAssertEqual(clamped.z, 1, accuracy: 0.0001)
    }

    func testRejectsValuesOutsideRGBA16FRange() {
        let source = "LUT_3D_SIZE 2\n" + Array(repeating: "70000 0 0\n", count: 8).joined()
        XCTAssertThrowsError(try CubeLUTParser.parse(Data(source.utf8))) { error in
            XCTAssertEqual(error as? CubeLUTFailure, .invalid)
        }
    }

    func testRejectsGpuUnrepresentableDomain() {
        let source = "DOMAIN_MIN 0.00000000000000000000000000000000000001 0 0\n" +
            "LUT_3D_SIZE 2\n" + Array(repeating: "0 0 0\n", count: 8).joined()
        XCTAssertThrowsError(try CubeLUTParser.parse(Data(source.utf8)))
    }
}
