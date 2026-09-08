import XCTest
import Foundation
import CoreGraphics
import ImageIO
import ZTransferShared
@testable import ZTransfer

private actor MediaPreviewOwnedSource: OriginalFilesReading {
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var reads = 0
    private(set) var rawReads = 0
    func isHeld() -> Bool { continuation != nil }
    func release(_ bytes: Data) { continuation?.resume(returning: bytes); continuation = nil }
    func originals(since revision: Int64, rescan: Bool) -> OriginalIndexUpdate {
        OriginalIndexUpdate(revision: 0, baseRevision: revision, fullSnapshot: true, entries: [])
    }
    func originalData(locator: String) async throws -> Data {
        guard locator == "owned-photo" else { throw OriginalIndexError.unsafeRoot }
        reads += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func originalRawPreviewData(locator: String) -> Data? { rawReads += 1; return nil }
    func originalExif(locator: String) -> PhotoExif? { nil }
}

@MainActor private final class MediaPreviewCompletion: NSObject, NativeLocalPreviewCompletion {
    private let completed: XCTestExpectation
    private(set) var image: NativeLocalPreviewImage?
    init(_ completed: XCTestExpectation) { self.completed = completed }
    func complete(image: NativeLocalPreviewImage?) { self.image = image; completed.fulfill() }
}

/// Native runtime checks pending Mac. No video player, duration parser, RAW renderer, or
/// full-resolution downsampling is introduced: these fixtures exercise the existing image routes.
final class MediaPreviewCompatibilityTests: XCTestCase {
    private func image(width: Int = 60, height: Int = 40, alpha: Bool = false,
                       space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors: [CGColor] = [CGColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1), CGColor(red: 1, green: 0, blue: 1, alpha: 1),
            CGColor(red: 0, green: 1, blue: 1, alpha: alpha ? 0 : 1)]
        for row in 0..<2 { for column in 0..<3 {
            context.setFillColor(colors[row * 3 + column])
            context.fill(CGRect(x: column * width / 3, y: row * height / 2, width: width / 3 + 1, height: height / 2 + 1))
        } }
        return try XCTUnwrap(context.makeImage())
    }
    private func encoded(_ image: CGImage, type: String = "public.png", orientation: Int = 1) throws -> Data {
        let bytes = NSMutableData()
        let target = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target))
        return bytes as Data
    }
    private func decoded(_ bytes: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func assertPixelsClose(_ first: CGImage, _ second: CGImage, tolerance: Int = 2,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(first.width, second.width, file: file, line: line)
        XCTAssertEqual(first.height, second.height, file: file, line: line)
        let a = try rgba(first), b = try rgba(second)
        guard a.count == b.count else { return }
        // Sample pixels, not bytes: an even byte stride could omit green/alpha entirely.
        let pixelCount = a.count / 4
        for pixel in stride(from: 0, to: pixelCount, by: max(1, pixelCount / 512)) {
            for channel in 0..<4 {
                let index = pixel * 4 + channel
                XCTAssertLessThanOrEqual(abs(Int(a[index]) - Int(b[index])), tolerance,
                    "pixel \(pixel), RGBA channel \(channel)", file: file, line: line)
            }
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        // CGImage cropping addresses raster rows, independent of a CGContext's drawing axes.
        // A one-pixel crop also avoids resampling or vertical-flip ambiguity in the RGBA probe.
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        return try rgba(sample)
    }

    func testDimensionMetadataRejectsBooleanFractionalNonfiniteAndOverflowWithoutDecode() {
        let invalidValues: [Any] = [true, -1, 0, 1.5, Double.nan, Double.infinity, Double(Int32.max) + 1, "12"]
        for invalid in invalidValues {
            XCTAssertNil(PreviewImageDecoder.dimensions([kCGImagePropertyPixelWidth: invalid, kCGImagePropertyPixelHeight: 12]))
            XCTAssertNil(PreviewImageDecoder.dimensions([kCGImagePropertyPixelWidth: 12, kCGImagePropertyPixelHeight: invalid]))
        }
        let bounds = PreviewImageDecoder.dimensions([kCGImagePropertyPixelWidth: Int32.max, kCGImagePropertyPixelHeight: 1])
        XCTAssertEqual(bounds?.width, Int32.max); XCTAssertEqual(bounds?.height, 1)
    }

    func testDirectOriginalKeepsResolutionAboveCameraFhdAndExactOpaquePixels() async throws {
        let original = try image(width: 4200, height: 12), bytes = try encoded(original)
        let before = bytes
        let output = try await PreviewImageDecoder().originalBitmapPNG(bytes)
        let result = try decoded(output)
        XCTAssertEqual(result.width, 4200); XCTAssertEqual(result.height, 12)
        try assertPixelsClose(original, result)
        XCTAssertEqual(bytes, before)
    }

    func testAllExifOrientationsKeepRawOriginalAndFhdGridButGridNormalizesAxes() async throws {
        let decoder = PreviewImageDecoder(), original = try image()
        for orientation in 1...8 {
            let input = try encoded(original, type: "public.jpeg", orientation: orientation)
            let raw = try decoded(input)
            let local = try decoded(await decoder.originalBitmapPNG(input))
            let fhd = try decoded(await decoder.fhdPreviewPNG(input))
            let grid = try decoded(await decoder.gridThumbnailPNG(input))
            XCTAssertEqual(local.width, 60); XCTAssertEqual(local.height, 40)
            XCTAssertEqual(fhd.width, 60); XCTAssertEqual(fhd.height, 40)
            XCTAssertEqual(grid.width, orientation >= 5 ? 40 : 60)
            XCTAssertEqual(grid.height, orientation >= 5 ? 60 : 40)
            try assertPixelsClose(raw, local); try assertPixelsClose(raw, fhd)
            if orientation == 1 { try assertPixelsClose(raw, grid) }
        }
    }

    func testMirroredOrientationIsActuallyTransformedForGridNotOnlyResized() async throws {
        let source = try encoded(image(), type: "public.jpeg", orientation: 2)
        let decoder = PreviewImageDecoder(), local = try decoded(await decoder.originalBitmapPNG(source))
        let grid = try decoded(await decoder.gridThumbnailPNG(source))
        let a = try rgba(local), b = try rgba(grid)
        for y in [10, 30] { for x in [10, 30, 50] { for channel in 0..<4 {
            let expected = (y * local.width + (local.width - 1 - x)) * 4 + channel
            let actual = (y * grid.width + x) * 4 + channel
            XCTAssertLessThanOrEqual(abs(Int(a[expected]) - Int(b[actual])), 3)
        } } }
    }

    func testAllEightGridOrientationsMapActualPixelsUsingAndroidOrientationRules() async throws {
        let decoder = PreviewImageDecoder(), original = try image()
        for orientation in 1...8 {
            let input = try encoded(original, type: "public.jpeg", orientation: orientation)
            let raw = try decoded(input)
            let grid = try decoded(await decoder.gridThumbnailPNG(input))
            let swapsAxes = orientation >= 5
            XCTAssertEqual(grid.width, swapsAxes ? raw.height : raw.width)
            XCTAssertEqual(grid.height, swapsAxes ? raw.width : raw.height)
            // Source -> destination mappings derived from Android ExifBitmapOrientation.kt:
            // horizontal/vertical mirrors, +/-90/180 rotation, transpose and transverse.
            // Compare six distinct color-block interiors, away from JPEG/resampling seams.
            for y in [10, 30] { for x in [10, 30, 50] {
                let destination: (x: Int, y: Int)
                switch orientation {
                case 1: destination = (x, y)
                case 2: destination = (raw.width - 1 - x, y)
                case 3: destination = (raw.width - 1 - x, raw.height - 1 - y)
                case 4: destination = (x, raw.height - 1 - y)
                case 5: destination = (y, x)
                case 6: destination = (raw.height - 1 - y, x)
                case 7: destination = (raw.height - 1 - y, raw.width - 1 - x)
                case 8: destination = (y, raw.width - 1 - x)
                default: return XCTFail("Unexpected EXIF orientation")
                }
                let expected = try pixel(raw, x: x, y: y)
                let actual = try pixel(grid, x: destination.x, y: destination.y)
                for channel in 0..<4 {
                    XCTAssertLessThanOrEqual(abs(Int(expected[channel]) - Int(actual[channel])), 3,
                        "orientation \(orientation), source (\(x),\(y)), RGBA channel \(channel)")
                }
            } }
        }
        // Original and FHD deliberately do NOT apply EXIF orientation; their all-eight
        // raw-grid comparisons live in testAllExifOrientationsKeepRawOriginalAndFhdGridButGridNormalizesAxes.
    }

    func testAlphaAndTransparentPixelsSurviveOriginalAndThumbnailPng() async throws {
        let original = try image(alpha: true), input = try encoded(original)
        let decoder = PreviewImageDecoder()
        let local = try decoded(await decoder.originalBitmapPNG(input))
        let grid = try decoded(await decoder.gridThumbnailPNG(input))
        try assertPixelsClose(original, local); try assertPixelsClose(original, grid)
        let pixels = try rgba(local)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] == 0 })
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { (120...136).contains(pixels[$0]) })
    }

    func testDisplayP3AndSrgbColorMeaningSurvivesTheComposePngBoundary() async throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try XCTUnwrap(CGColorSpace(name: name)), original = try image(space: space)
            let input = try encoded(original), output = try await PreviewImageDecoder().originalBitmapPNG(input)
            let result = try decoded(output)
            XCTAssertEqual(result.colorSpace?.model, .rgb)
            try assertPixelsClose(original, result, tolerance: 3)
        }
    }

    func testGrayscalePngKeepsItsPixelsWithoutInventingAnRgbOnlyInputRule() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let original = try XCTUnwrap(context.makeImage()), input = try encoded(original)
        let output = try await PreviewImageDecoder().originalBitmapPNG(input)
        try assertPixelsClose(original, decoded(output), tolerance: 3)
    }

    func testImageSourceAutoreleaseBoundaryKeepsReturnedImagesAndDataAliveAcrossCalls() async throws {
        let decoder = PreviewImageDecoder(), source = try encoded(image(alpha: true))
        let retained = try await decoder.decode(source)
        let expected = try rgba(retained)
        for _ in 0..<16 {
            let png = try await decoder.gridThumbnailPNG(source)
            XCTAssertFalse(png.isEmpty)
        }
        XCTAssertEqual(try rgba(retained), expected)
        // Lifetime correctness only; peak-memory measurements still require Instruments on Mac.
    }

    func testInvalidPixelLimitsFailBeforeAttemptingMissingFileOrInvalidEncodedSource() async throws {
        let decoder = PreviewImageDecoder()
        for limit in [Int.min, -1, 0, 4097, Int.max] {
            do { _ = try await decoder.decode(Data([1]), maximumPixelSize: limit); XCTFail("Invalid limit") }
            catch { guard let failure = error as? PreviewImageError, case .invalidSize = failure else { return XCTFail("Expected size rejection") } }
            do { _ = try await decoder.decodeFile(URL(fileURLWithPath: "/not-owned/missing.png"), maximumPixelSize: limit); XCTFail("Invalid limit") }
            catch { guard let failure = error as? PreviewImageError, case .invalidSize = failure else { return XCTFail("Expected size rejection") } }
        }
    }

    func testEncodedInputBudgetRejectsBeforeImageIoAndLeavesDataUnchanged() async throws {
        let decoder = PreviewImageDecoder(), bytes = Data(repeating: 37, count: 32 * 1024 * 1024 + 1)
        do { _ = try await decoder.decode(bytes); XCTFail("Over budget") } catch {}
        do { _ = try await decoder.fhdPreviewPNG(bytes); XCTFail("Over budget") } catch {}
        XCTAssertEqual(bytes.first, 37); XCTAssertEqual(bytes.last, 37)
        XCTAssertEqual(bytes.count, 32 * 1024 * 1024 + 1)
    }

    func testMalformedJpegPngAndMovieBytesDoNotProduceFalsePhotoBitmaps() async throws {
        let decoder = PreviewImageDecoder()
        let movie = Data([0, 0, 0, 20, 102, 116, 121, 112, 113, 116, 32, 32, 0, 0, 0, 0, 113, 116, 32, 32])
        for bytes in [Data(), Data([0xff, 0xd8, 0xff, 0xd9]), Data([137, 80, 78, 71, 13, 10, 26, 10]), movie] {
            do { _ = try await decoder.originalBitmapPNG(bytes); XCTFail("No raster") } catch {}
            do { _ = try await decoder.fhdPreviewPNG(bytes); XCTFail("No photo FHD") } catch {}
        }
        // The existing shared MOV/MP4 page remains thumbnail + size/date + unavailable label.
        // No AVFoundation load, duration request, video player or new local materialization path.
    }

    func testCancellationWinsBeforeDecodeOrFileAccessAndDoesNotPoisonNextRead() async throws {
        let decoder = PreviewImageDecoder(), bytes = try encoded(image())
        let first = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await decoder.originalBitmapPNG(bytes)
        }
        do { _ = try await first.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let next = try await decoder.originalBitmapPNG(bytes)
        XCTAssertEqual(try decoded(next).width, 60)
        let file = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await decoder.decodeFile(URL(fileURLWithPath: "/not-owned/missing.png"))
        }
        do { _ = try await file.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testIndexedReadAndAllDecodeRoutesNeverRewriteOriginalOrIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("原图.JPG"), bytes = try encoded(image(), type: "public.jpeg", orientation: 6)
        try bytes.write(to: url)
        let store = CameraOriginalStore(root: root), decoder = PreviewImageDecoder()
        let snapshot = try await store.originals(since: -1, rescan: true)
        let owned = try await store.originalData(locator: url.absoluteString)
        _ = try await decoder.originalBitmapPNG(owned); _ = try await decoder.fhdPreviewPNG(owned)
        _ = try await decoder.gridThumbnailPNG(owned); _ = try await decoder.queueThumbnailPNG(owned)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let unchanged = try await store.originals(since: snapshot.revision, rescan: false)
        XCTAssertEqual(unchanged.revision, snapshot.revision); XCTAssertTrue(unchanged.entries.isEmpty)
    }

    func testIndexedReadCancellationAndChangedSizeHaveNoTemporaryVideoOrImageArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("OWNED.JPG"), bytes = try encoded(image())
        try bytes.write(to: url)
        let entry = OriginalIndexEntry(name: url.lastPathComponent, size: Int64(bytes.count), folder: nil, url: url)
        let cancellation = PreviewExifReadCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try IndexedOriginalReader(root: root, entry: entry, cancellation: cancellation).originalData(locator: url.absoluteString)) {
            XCTAssertTrue($0 is CancellationError)
        }
        try Data([1]).write(to: url)
        XCTAssertThrowsError(try IndexedOriginalReader(root: root, entry: entry).originalData(locator: url.absoluteString))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["OWNED.JPG"])
    }

    @MainActor func testClosedOrReplacedPageRejectsLateOriginalAndReleasesBackgroundSuppression() async throws {
        for close in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let camera = CameraWiFiConnection(command: try CameraTCPStream(host: "127.0.0.1", port: 15740),
                event: try CameraTCPStream(host: "127.0.0.1", port: 15740))
            let source = MediaPreviewOwnedSource(), previews = CameraPreviewStore(source: camera)
            let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
            let page = OriginalFilesPageBridge(connectionID: camera.connectionID,
                catalog: CameraCatalog(source: camera, stationMode: false), queue: queue,
                previews: previews, exifSource: camera, exifCache: NativePreviewExifCache(), stationMode: false, originals: source)
            page.beginPreviewReads(sessionId: 1)
            let done = expectation(description: "late original discarded"), reply = MediaPreviewCompletion(done)
            page.readLocalBitmap(sessionId: 1, requestId: 1, source: "owned-photo", completion: reply)
            try await eventually { await source.isHeld() }
            if close { page.close() } else {
                page.endPreviewReads(sessionId: 1); page.beginPreviewReads(sessionId: 2)
            }
            await source.release(try encoded(image()))
            await fulfillment(of: [done], timeout: 2)
            XCTAssertNil(reply.image)
            page.close()
            try await eventually { await previews.allowsObjectResolution() }
            let readCount = await source.reads
            XCTAssertEqual(readCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            await camera.abort()
        }
    }

    @MainActor func testMissingRawPreviewReturnsMissWithoutReadingRawAsAnOrdinaryBitmap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let camera = CameraWiFiConnection(command: try CameraTCPStream(host: "127.0.0.1", port: 15740),
            event: try CameraTCPStream(host: "127.0.0.1", port: 15740))
        let source = MediaPreviewOwnedSource(), previews = CameraPreviewStore(source: camera)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let page = OriginalFilesPageBridge(connectionID: camera.connectionID,
            catalog: CameraCatalog(source: camera, stationMode: false), queue: queue,
            previews: previews, exifSource: camera, exifCache: NativePreviewExifCache(), stationMode: false, originals: source)
        page.beginPreviewReads(sessionId: 1)
        let done = expectation(description: "RAW miss"), reply = MediaPreviewCompletion(done)
        page.readLocalRaw(sessionId: 1, requestId: 1, source: "owned-raw", completion: reply)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(reply.image)
        let reads = await source.reads, rawReads = await source.rawReads
        XCTAssertEqual(reads, 0); XCTAssertEqual(rawReads, 1)
        page.close(); await camera.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func eventually(_ predicate: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Media preview ownership did not settle")
        throw CameraStreamError.timedOut
    }
}
