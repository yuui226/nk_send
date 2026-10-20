import XCTest
import UIKit
import Metal
import MetalKit
import CoreImage
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

    // Android CubeLutParserTest: comments/BOM/CRLF and R-fastest RGB order.
    func testCommentsBeforeAndWithinTableDoNotBecomeDirectives() throws {
        let rows = (0..<8).map { index in
            "\(index & 1) \((index >> 1) & 1) \((index >> 2) & 1)"
        }
        let plain = "LUT_3D_SIZE 2\n" + rows.joined(separator: "\n")
        let annotated = "\u{FEFF}# Exported LUT\r\nTITLE \"Identity\"\r\n# Grid\r\nLUT_3D_SIZE 2 # size\r\n"
            + rows.map { "# Lattice point\r\n\($0) # RGB\r\n" }.joined() + "# End"
        let expected = try CubeLUTParser.parse(Data(plain.utf8))
        let actual = try CubeLUTParser.parse(Data(annotated.utf8))
        XCTAssertEqual(actual.rgb, expected.rgb)
        XCTAssertEqual(Array(actual.rgb.prefix(9)), [0, 0, 0, 1, 0, 0, 0, 1, 0])
        XCTAssertEqual(actual.domainMin, expected.domainMin)
        XCTAssertEqual(actual.domainMax, expected.domainMax)
        XCTAssertNotEqual(actual.digest, expected.digest, "The digest still covers the original file bytes")
    }

    func testMalformedSizeIsInvalidWhileUnsupportedGridIsUnsupported() {
        let table = String(decoding: cube(), as: UTF8.self)
        for source in [
            "LUT_3D_SIZE\n", "LUT_3D_SIZE 2 3\n", "LUT_3D_SIZE two\n",
            "LUT_3D_SIZE 2.0\n", "LUT_3D_SIZE 2147483648\n",
            "LUT_3D_SIZE 2\n" + table, table + "LUT_3D_SIZE 2\n"
        ] {
            XCTAssertThrowsError(try CubeLUTParser.parse(Data(source.utf8))) {
                XCTAssertEqual($0 as? CubeLUTFailure, .invalid, source)
            }
        }
        for size in ["-1", "0", "1", "66", "2147483647"] {
            XCTAssertThrowsError(try CubeLUTParser.parse(Data("LUT_3D_SIZE \(size)\n".utf8))) {
                XCTAssertEqual($0 as? CubeLUTFailure, .unsupported, size)
            }
        }
    }

    func testCommonGridSizesAndCancellationDuringParsing() throws {
        for size in [17, 33, 65] {
            let source = Data(("LUT_3D_SIZE \(size)\n"
                + String(repeating: "0 0 0\n", count: size * size * size)).utf8)
            let lut = try CubeLUTParser.parse(source)
            XCTAssertEqual(lut.size, size)
            XCTAssertEqual(lut.rgb.count, size * size * size * 3)
            var checks = 0
            XCTAssertThrowsError(try CubeLUTParser.parse(source) {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, 4)
        }
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


final class LUTFinishingPerformanceTests: XCTestCase {
    func testSharedImageContextMatchesFreshContextUnderConcurrentRendering() async throws {
        let width = 37, height = 23
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for index in 0..<width * height {
            buffer[index * 4] = UInt8(index * 17 % 256)
            buffer[index * 4 + 1] = UInt8(index * 31 % 256)
            buffer[index * 4 + 2] = UInt8(index * 73 % 256)
            buffer[index * 4 + 3] = 255
        }
        let source = try XCTUnwrap(context.makeImage())
        let rows = (0..<8).map { i in "\(Float(i & 1)) \(Float((i >> 1) & 1)) \(Float((i >> 2) & 1))\n" }.joined()
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + rows).utf8))
        PhotoLUTRuntime.register(lut)
        var configuration = PhotoEffectsSettings()
        configuration.photoFrameEnabled = false
        configuration.photoFilterEnabled = true
        configuration.selectedFilter = .init(preset: .init(id: "cube:\(lut.digest)", name: "Identity"),
            intensityPercent: 100, lutAdjustments: .init(contrast: 21, saturation: -27, shadows: 31))
        let settings = configuration
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    try autoreleasepool {
                        var input = CIImage(cgImage: source).oriented(forExifOrientation: Int32(index % 8 + 1))
                        input = input.transformed(by: CGAffineTransform(
                            translationX: -input.extent.minX, y: -input.extent.minY))
                        let fresh = CIContext(options: [.cacheIntermediates: false])
                        let decoded = try XCTUnwrap(fresh.createCGImage(input, from: input.extent))
                        let expected = try XCTUnwrap(PhotoCubeLUTMapper.apply(decoded, lut: lut,
                            intensityPercent: 100, adjustments: settings.selectedFilter!.lutAdjustments))
                        let actual = try PhotoEffectsRenderer.render(UIImage(ciImage: input), settings: settings,
                            filterExecution: .preview, availableMemory: { Int64.max })
                        let cgImage = try XCTUnwrap(actual.cgImage)
                        XCTAssertEqual(cgImage.width, expected.width)
                        XCTAssertEqual(cgImage.height, expected.height)
                        let pixels = try XCTUnwrap(cgImage.dataProvider?.data) as Data
                        let reference = try XCTUnwrap(expected.dataProvider?.data) as Data
                        for row in 0..<cgImage.height {
                            // CoreGraphics may pad rows differently. Compare every
                            // RGBA pixel, never uninitialized alignment padding.
                            XCTAssertEqual(pixels.subdata(in: row * cgImage.bytesPerRow..<row * cgImage.bytesPerRow + cgImage.width * 4),
                                           reference.subdata(in: row * expected.bytesPerRow..<row * expected.bytesPerRow + expected.width * 4))
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    func testPreparedFinishingMatchesOriginalByteMathIncludingClampsAndAlpha() {
        let configurations: [LUTAdjustments] = [
            .init(), .init(contrast: 100), .init(saturation: -100),
            .init(highlights: -100, shadows: 100),
            .init(contrast: 100, saturation: 100, highlights: 100, shadows: -100),
            .init(contrast: -35, saturation: 27, highlights: -19, shadows: 61),
            .init(contrast: 200, saturation: -200, highlights: 1000, shadows: -1000)
        ]
        var colors: [UInt32] = [0, 0x00112233, 0xffffffff, 0xff000000, 0x80406080]
        var seed: UInt32 = 0x10203040
        for _ in 0..<8192 { seed = seed &* 1664525 &+ 1013904223; colors.append(seed) }
        for value in 0...255 { colors.append(0xff000000 | UInt32(value) * 0x010101) }
        for adjustments in configurations {
            let prepared = LUTColorPipeline.Prepared(adjustments: adjustments)
            for preserveAlpha in [true, false] {
                for color in colors {
                    XCTAssertEqual(prepared.apply(color, preserveAlpha: preserveAlpha),
                                   reference(color, adjustments, preserveAlpha: preserveAlpha))
                }
            }
        }
    }

    func testProductionMapperMatchesOriginalRGBAAtDifferentStrengthsAndAlpha() throws {
        let width = 129, height = 65
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var sourceBytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<width * height {
            let alpha = [0, 1, 64, 128, 254, 255][index % 6]
            sourceBytes[index * 4] = UInt8((index * 17 % 256) * alpha / 255)
            sourceBytes[index * 4 + 1] = UInt8((index * 73 % 256) * alpha / 255)
            sourceBytes[index * 4 + 2] = UInt8((index * 31 % 256) * alpha / 255)
            sourceBytes[index * 4 + 3] = UInt8(alpha)
        }
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: XCTUnwrap(CGDataProvider(data: Data(sourceBytes) as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let lut = CubeLUT(size: 2, domainMin: SIMD3(repeating: 0.1), domainMax: SIMD3(repeating: 0.9),
            rgb: [-0.3, 0.1, 0.2, 1.3, 0.2, 0.4, 0.3, 1.1, 0.1, 0.8, 0.9, 0.2,
                  0.1, 0.1, 1.2, 0.7, 0.2, 0.8, 0.2, 1.1, 0.9, 1.1, 0.9, 1.2], digest: "fixture")
        for strength in [-20, 0, 37, 100, 200] {
            for adjustments: LUTAdjustments in [.init(), .init(saturation: -100),
                .init(contrast: -35, saturation: 27, highlights: -19, shadows: 61)] {
                let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo))
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let intensity = Float(min(max(strength, 0), 100)) / 100
                // Frozen pre-optimization mapper, including per-channel premultiplication.
                for offset in stride(from: 0, to: sourceBytes.count, by: 4) {
                    let alpha = UInt32(buffer[offset + 3])
                    guard alpha != 0 else { continue }
                    let original = SIMD3(Float(buffer[offset]), Float(buffer[offset + 1]), Float(buffer[offset + 2])) / Float(alpha)
                    let mapped = lut.sample(original)
                    func mix(_ input: Float, _ output: Float) -> UInt32 {
                        let originalByte = input * 255
                        let mappedByte = min(max(output, 0), 1) * 255
                        return UInt32(min(max(originalByte + (mappedByte - originalByte) * intensity, 0), 255).rounded())
                    }
                    let mixed = (alpha << 24) | (mix(original.x, mapped.x) << 16) |
                        (mix(original.y, mapped.y) << 8) | mix(original.z, mapped.z)
                    let finished = reference(mixed, adjustments, preserveAlpha: true)
                    for (channel, shift) in [16, 8, 0].enumerated() {
                        buffer[offset + channel] = UInt8((((finished >> shift) & 255) * alpha + 127) / 255)
                    }
                }
                let expected = Data(bytes: buffer, count: sourceBytes.count)
                let actual = try XCTUnwrap(PhotoCubeLUTMapper.apply(source, lut: lut,
                    intensityPercent: strength, adjustments: adjustments))
                let pixels = try XCTUnwrap(actual.dataProvider?.data) as Data
                // Compare complete rows, independent of any CGImage stride padding.
                for row in 0..<height {
                    XCTAssertEqual(pixels.subdata(in: row * actual.bytesPerRow..<row * actual.bytesPerRow + width * 4),
                                   expected.subdata(in: row * width * 4..<(row + 1) * width * 4))
                }
            }
        }
    }

    /// Frozen original LutColorPipeline equations, separate from Prepared.
    private func reference(_ color: UInt32, _ input: LUTAdjustments, preserveAlpha: Bool) -> UInt32 {
        let adjustments = input.normalized
        guard !adjustments.isNeutral else { return color }
        let alpha = preserveAlpha ? (color >> 24) & 255 : 255
        guard alpha != 0 else { return color }
        func clamp(_ value: Float) -> Float { min(max(value, 0), 1) }
        func smooth(_ lower: Float, _ upper: Float, _ value: Float) -> Float {
            let t = clamp((value - lower) / (upper - lower))
            return t * t * (3 - 2 * t)
        }
        var r = Float((color >> 16) & 255) / 255
        var g = Float((color >> 8) & 255) / 255
        var b = Float(color & 255) / 255
        let luma = clamp(r * 0.2126 + g * 0.7152 + b * 0.0722)
        let shadows = -Float(adjustments.shadows) / 100 * 0.28 * smooth(0, 0.68, 1 - luma)
        let highlights = Float(adjustments.highlights) / 100 * 0.28 * smooth(0.32, 1, luma)
        r = clamp(r + shadows + highlights); g = clamp(g + shadows + highlights); b = clamp(b + shadows + highlights)
        let contrast = 1 + Float(adjustments.contrast) / 100 * 0.75
        r = clamp((r - 0.5) * contrast + 0.5); g = clamp((g - 0.5) * contrast + 0.5); b = clamp((b - 0.5) * contrast + 0.5)
        let postLuma = clamp(r * 0.2126 + g * 0.7152 + b * 0.0722)
        let saturation = 1 + Float(adjustments.saturation) / 100
        r = clamp(postLuma + (r - postLuma) * saturation)
        g = clamp(postLuma + (g - postLuma) * saturation)
        b = clamp(postLuma + (b - postLuma) * saturation)
        return (alpha << 24) | (UInt32(r * 255 + 0.5) << 16) | (UInt32(g * 255 + 0.5) << 8) | UInt32(b * 255 + 0.5)
    }
}

@MainActor
final class RemoteLUTDisplayPerformanceTests: XCTestCase {
    private func image(red: CGFloat, green: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    func testRepeatedSourceReusesUploadAndNewImageFailureDoesNotPoisonCache() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var uploads = 0, reject = false
        var loaders: Set<ObjectIdentifier> = []
        var resources = RemoteLUTMetalRenderer.Resources()
        resources.makeImageTexture = { loader, image in
            uploads += 1; loaders.insert(ObjectIdentifier(loader))
            if reject { throw RemoteLUTMetalRenderer.Failure.texture }
            return try loader.newTexture(cgImage: image, options: [.SRGB: false])
        }
        let renderer = try RemoteLUTMetalRenderer(device: device, resources: resources)
        let rows = (0..<8).map { "\($0 & 1) \(($0 >> 1) & 1) \(($0 >> 2) & 1)\n" }.joined()
        try renderer.setLUT(CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + rows).utf8)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .renderTarget]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        func draw(_ image: CGImage) throws -> [UInt8] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.encode(image: image, into: output, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var actual = [UInt8](repeating: 0, count: 16)
            actual.withUnsafeMutableBytes {
                output.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0,0,2,2), mipmapLevel: 0)
            }
            return actual
        }
        let red = try image(red: 1, green: 0), green = try image(red: 0, green: 1)
        let redPixels = Array(repeating: [UInt8]([0,0,255,255]), count: 4).flatMap { $0 }
        let greenPixels = Array(repeating: [UInt8]([0,255,0,255]), count: 4).flatMap { $0 }
        for _ in 0..<20 { XCTAssertEqual(try draw(red), redPixels) }
        XCTAssertEqual(uploads, 1)
        reject = true
        XCTAssertThrowsError(try draw(green))
        XCTAssertEqual(try draw(red), redPixels)
        XCTAssertEqual(uploads, 2, "Failed replacement must not discard the previous upload")
        reject = false
        XCTAssertEqual(try draw(green), greenPixels)
        XCTAssertEqual(uploads, 3)
        XCTAssertEqual(try draw(red), redPixels)
        XCTAssertEqual(uploads, 4, "Only the most recent source is cached")
        XCTAssertEqual(loaders.count, 1)
        let blueLUT = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 1\n", count: 8)).utf8))
        try renderer.setLUT(blueLUT)
        XCTAssertEqual(try draw(red), Array(repeating: [UInt8(255),0,0,255], count: 4).flatMap { $0 })
        XCTAssertEqual(uploads, 4, "Changing the LUT must keep source pixels but change the output")
    }

    func testBusySurfaceEventuallyDrawsFinalPendingImageAndStopsRedundantRequests() async throws {
        let source = try image(red: 1, green: 0), latest = try image(red: 0, green: 1)
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 1\n", count: 8)).utf8))
        var presented = 0
        let coordinator = RemoteLUTMetalView.Coordinator(image: source, lut: lut,
            onPresented: { presented += 1 }, onUnavailable: {}, onFailure: { XCTFail("GPU failure: \($0)") })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let host = UIViewController()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: coordinator.device)
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        window.rootViewController = host; host.view.addSubview(view)
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer {
            RemoteLUTMetalView.dismantleUIView(view, coordinator: coordinator)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        // Submit synchronously before the main-actor GPU callbacks can run.
        coordinator.draw(in: view)
        XCTAssertFalse(coordinator.needsDisplay)
        view.delegate = coordinator
        coordinator.updateImage(latest, in: view)
        coordinator.draw(in: view) // still in flight, must leave the latest demand pending
        XCTAssertTrue(coordinator.needsDisplay)
        let deadline = ContinuousClock.now + .seconds(2)
        while (coordinator.needsDisplay || presented == 0), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(coordinator.needsDisplay, "The final frame must not depend on yet another arrival")
        XCTAssertEqual(presented, 1)
        XCTAssertTrue(coordinator.image === latest)
        for _ in 0..<30 {
            coordinator.updateImage(latest, in: view)
            XCTAssertFalse(coordinator.needsDisplay)
        }
        coordinator.mtkView(view, drawableSizeWillChange: CGSize(width: 80, height: 60))
        XCTAssertTrue(coordinator.needsDisplay, "A new drawable still needs the current image")
    }
}
