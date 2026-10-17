import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import ZTransfer

final class CropPreviewTests: XCTestCase {
    @MainActor
    func testConfirmationRejectsNoCropAndDuplicatesAndPreservesRejectedDraft() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let prepared = try preparePhotoCrop(image: image, orientation: 6, embeddedOrientation: nil, rotation: 0)
        let owner = PhotoCropPreparation()
        let selection = JpegCropSelection(bounds: .init(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9), orientation: 1)
        let unprepared = await owner.confirm(selection: selection) { _ in XCTFail("No prepared image"); return true }
        XCTAssertFalse(unprepared)
        _ = await owner.load { prepared }
        let full = JpegCropSelection(bounds: .init(left: 0, top: 0, right: 1, bottom: 1), orientation: 1)
        let noCrop = await owner.confirm(selection: full) { _ in XCTFail("Full image must not submit"); return true }
        XCTAssertFalse(noCrop)
        let gate = PreparedCropGate()
        let first = Task { await owner.confirm(selection: selection) { submitted in
            XCTAssertEqual(submitted.orientation, 6)
            _ = try? await gate.read()
            return false
        } }
        for _ in 0..<1000 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(owner.confirming)
        let duplicate = await owner.confirm(selection: selection) { _ in XCTFail("Duplicate request"); return true }
        XCTAssertFalse(duplicate)
        await gate.finish(value: nil, fails: false)
        let rejected = await first.value
        XCTAssertFalse(rejected)
        XCTAssertFalse(owner.confirming)
        XCTAssertEqual(owner.prepared?.preview, prepared.preview)
        let accepted = await owner.confirm(selection: selection) { _ in true }
        XCTAssertTrue(accepted)
        XCTAssertTrue(owner.confirming)
        let afterAcceptance = await owner.confirm(selection: selection) { _ in XCTFail("Acceptance remains latched"); return true }
        XCTAssertFalse(afterAcceptance)
        owner.reset()
        XCTAssertFalse(owner.confirming)
    }

    func testActualCropToleranceDoesNotDependOnRatioMetadata() {
        let unchanged = JpegCropSelection(bounds: .init(left: 0.000001, top: 0, right: 1, bottom: 1),
            orientation: 1, ratioWidth: 16, ratioHeight: 9)
        XCTAssertFalse(unchanged.hasCrop)
        XCTAssertTrue(JpegCropSelection(bounds: .init(left: 0.0001, top: 0, right: 1, bottom: 1), orientation: 1).hasCrop)
    }

    func testPreviewViewportSnapshotPreservesZoomedSelectionAcrossEditorSizes() throws {
        for (orientation, rotation) in [(1, 0.0), (3, 180.0), (6, 90.0), (8, -90.0)] {
            let preview = try prepareCropPreview(width: 120, height: 80, orientation: orientation,
                embeddedOrientation: nil, rotation: rotation,
                pixel: { x, _ in CGColor(gray: x < 10 || x >= 110 ? 0 : 1, alpha: 1) }).canonicalized()
            for offset in [CGSize.zero, CGSize(width: 75, height: -120)] {
                let snapshot = PhotoPreviewCropViewport(size: CGSize(width: 900, height: 1500),
                    scale: 3, offset: offset, rotation: rotation, infoBottom: 120)
                let initial = try snapshot.visibleBounds(for: preview)
                XCTAssertLessThan(initial.right - initial.left, 1)
                let equivalent = PhotoPreviewCropViewport(size: snapshot.size, scale: snapshot.scale,
                    offset: snapshot.offset, rotation: rotation + 360, infoBottom: snapshot.infoBottom)
                let sameDirection = try equivalent.visibleBounds(for: preview)
                XCTAssertEqual(sameDirection.left, initial.left, accuracy: 0.000001)
                XCTAssertEqual(sameDirection.top, initial.top, accuracy: 0.000001)
                for size in [CGSize(width: 700, height: 1000), CGSize(width: 1000, height: 700)] {
                    var editor = CropEditorGeometry(source: preview.source)
                    try editor.initialize(size, visibleBounds: initial)
                    let actual = editor.selection(orientation: 1).bounds
                    XCTAssertEqual(actual.left, initial.left, accuracy: 0.000001)
                    XCTAssertEqual(actual.top, initial.top, accuracy: 0.000001)
                    XCTAssertEqual(actual.right, initial.right, accuracy: 0.000001)
                    XCTAssertEqual(actual.bottom, initial.bottom, accuracy: 0.000001)
                }
                XCTAssertEqual(snapshot.scale, 3)
                XCTAssertEqual(snapshot.offset, offset)
            }
        }
    }

    func testVisibleViewportMapsThroughRotatedBlackBars() throws {
        for orientation in [1, 3, 6, 8] {
            let preview = try prepareCropPreview(width: 120, height: 80, orientation: orientation,
                embeddedOrientation: nil, rotation: 0, pixel: { x, _ in CGColor(gray: x < 10 || x >= 110 ? 0 : 1, alpha: 1) }).canonicalized()
            let frame = CGRect(x: -60, y: -40, width: 240, height: 160)
            let displayedContent = transformCropBounds(.init(left: 10.0/120, top: 0, right: 110.0/120, bottom: 1), orientation: orientation)
            let content = CGRect(x: frame.minX + displayedContent.left * frame.width,
                y: frame.minY + displayedContent.top * frame.height,
                width: (displayedContent.right - displayedContent.left) * frame.width,
                height: (displayedContent.bottom - displayedContent.top) * frame.height)
            let viewport = CGRect(x: content.minX + content.width * 0.25,
                y: content.minY + content.height * 0.125, width: content.width * 0.5, height: content.height * 0.75)
            let bounds = try preview.visibleBounds(viewport: viewport, imageFrame: frame)
            XCTAssertEqual(bounds.left, 0.25, accuracy: 0.000001)
            XCTAssertEqual(bounds.top, 0.125, accuracy: 0.000001)
            XCTAssertEqual(bounds.right, 0.75, accuracy: 0.000001)
            XCTAssertEqual(bounds.bottom, 0.875, accuracy: 0.000001)
            var editor = CropEditorGeometry(source: preview.source)
            try editor.initialize(CGSize(width: 900, height: 1500), visibleBounds: bounds)
            XCTAssertEqual(editor.selection(orientation: 1).bounds, bounds)
            editor.select(.fixed(1, 1)); editor.reset()
            XCTAssertEqual(editor.selection(orientation: 1).bounds, bounds)
            XCTAssertThrowsError(try preview.visibleBounds(viewport: .zero, imageFrame: frame))
        }
    }

    func testCanonicalRotationKeepsEquivalentAnglesAndUsesShortestCorrection() throws {
        for (orientation, target) in [(1, 0.0), (3, 180.0), (6, 90.0), (8, -90.0)] {
            let preview = try prepareCropPreview(width: 120, height: 80, orientation: orientation,
                embeddedOrientation: nil, rotation: 0, pixel: { _, _ in CGColor(gray: 1, alpha: 1) })
            for turns in -5...5 {
                let equivalent = target + Double(turns) * 360
                XCTAssertEqual(preview.correctedRotation(from: equivalent), equivalent,
                    "Same direction must preserve the existing viewport")
                for quarter in -3...3 {
                    let current = equivalent + Double(quarter) * 90
                    let corrected = preview.correctedRotation(from: current)
                    XCTAssertLessThanOrEqual(abs(corrected - current), 180)
                    XCTAssertEqual(displayOrientation(for: corrected), orientation)
                }
            }
        }
    }

    @MainActor
    func testPreparationOwnerRejectsOldSuccessAndFailureAfterRetryOrReopen() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let oldValue = try preparePhotoCrop(image: image, orientation: 1, embeddedOrientation: nil, rotation: 0)
        let newValue = try preparePhotoCrop(image: image, orientation: 6, embeddedOrientation: nil, rotation: 0)
        for reopen in [false, true] {
            for fails in [false, true] {
                let owner = PhotoCropPreparation()
                let gate = PreparedCropGate()
                let old = Task { await owner.load { try await gate.read() } }
                for _ in 0..<1000 {
                    if await gate.started { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                let started = await gate.started
                XCTAssertTrue(started)
                if reopen { owner.reset() }
                _ = await owner.load { newValue }
                await gate.finish(value: oldValue, fails: fails)
                let ignored = await old.value
                XCTAssertNil(ignored)
                XCTAssertEqual(owner.prepared?.preview, newValue.preview)
                XCTAssertNil(owner.failure)
                owner.reset()
                XCTAssertNil(owner.prepared)
            }
        }
    }

    @MainActor
    func testPreparationOwnerWaitFailureRetryAndCancelledLateResult() async throws {
        let owner = PhotoCropPreparation()
        _ = await owner.load { throw CropPreparationError.connection() }
        XCTAssertEqual(owner.failure, .connection())
        _ = await owner.load { nil } // FHD is still owned by the page request.
        XCTAssertNil(owner.failure)
        XCTAssertNil(owner.prepared)
        let gate = PreparedCropGate()
        let task = Task { await owner.load { try await gate.read() } }
        for _ in 0..<1000 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await gate.finish(value: nil, fails: true)
        _ = await task.value
        XCTAssertNil(owner.failure)
        XCTAssertNil(owner.prepared)
        _ = await owner.load { throw CropPreparationError.previewRead() }
        XCTAssertEqual(owner.failure, .previewRead())
        XCTAssertTrue(owner.failure?.canRetry == true)
        _ = await owner.load { throw CocoaError(.fileReadUnknown) }
        XCTAssertEqual(owner.failure, .unavailable())
        XCTAssertEqual(owner.failure?.messageKey, "crop_unavailable")
    }

    func testPreparedSelectionMatchesNativeCropForDirectionsBarsAndRotatedFHD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 192), format: format).image { ctx in
            for (color, rect) in [(UIColor.red, CGRect(x: 0, y: 0, width: 128, height: 96)),
                                  (.green, CGRect(x: 128, y: 0, width: 128, height: 96)),
                                  (.blue, CGRect(x: 0, y: 96, width: 128, height: 96)),
                                  (.yellow, CGRect(x: 128, y: 96, width: 128, height: 96))] {
                color.setFill(); ctx.fill(rect)
            }
        }
        func sample(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> [UInt8] {
            let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(at: .zero)
            }
            let cg = try XCTUnwrap(normalized.cgImage)
            let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let offset = Int(y * CGFloat(cg.height)) * context.bytesPerRow + Int(x * CGFloat(cg.width)) * 4
            return Array(UnsafeBufferPointer(start: bytes + offset, count: 3))
        }
        for orientation in [1, 3, 6, 8] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(raw.cgImage), [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: 1
            ] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let sourceURL = directory.appendingPathComponent("original-\(orientation).jpg")
            try (data as Data).write(to: sourceURL)
            let source = try XCTUnwrap(parseJpegCropHeader(data as Data))
            for rotatedFHD in orientation >= 5 ? [false, true] : [false] {
                let content = rotatedFHD ? try preparePhotoCrop(image: raw, orientation: orientation,
                    embeddedOrientation: nil, rotation: 0).image : raw
                let padded = UIGraphicsImageRenderer(size: CGSize(width: content.size.width + 32,
                    height: content.size.height), format: format).image { ctx in
                    UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: CGSize(width: content.size.width + 32, height: content.size.height)))
                    content.draw(at: CGPoint(x: 16, y: 0))
                }
                let prepared = try preparePhotoCrop(image: padded, orientation: orientation,
                    embeddedOrientation: rotatedFHD ? 1 : nil, rotation: -90)
                for (left, top) in [(0.0, 0.0), (0.5, 0.0), (0.0, 0.5), (0.5, 0.5)] {
                    let displayed = JpegCropSelection(bounds: .init(left: left, top: top,
                        right: left + 0.5, bottom: top + 0.5), orientation: 1)
                    let selection = prepared.preview.canonicalSelection(displayed)
                    let task = LosslessCropTask(fileID: 1, recipe: try selection.resolve(source))
                    let output = try await LosslessCropProcessor.processAsync(task: task, sourceURL: sourceURL, directory: directory)
                    let actual = try sample(XCTUnwrap(UIImage(contentsOfFile: output.path)), x: 0.5, y: 0.5)
                    let expected = try sample(prepared.image, x: left + 0.25, y: top + 0.25)
                    for channel in 0..<3 {
                        XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), 4,
                            "EXIF \(orientation), rotated FHD \(rotatedFHD), quadrant \(left),\(top)")
                    }
                    XCTAssertEqual(try Data(contentsOf: sourceURL), data as Data)
                }
            }
        }
    }

    func testPreparedPixelsFollowCanonicalRotationAndCancellation() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format).image { ctx in
            for (color, rect) in [(UIColor.red, CGRect(x: 0, y: 0, width: 40, height: 30)),
                                  (.green, CGRect(x: 40, y: 0, width: 40, height: 30)),
                                  (.blue, CGRect(x: 0, y: 30, width: 40, height: 30)),
                                  (.yellow, CGRect(x: 40, y: 30, width: 40, height: 30))] {
                color.setFill(); ctx.fill(rect)
            }
        }
        func quadrants(_ image: UIImage) throws -> [[UInt8]] {
            let cg = try XCTUnwrap(image.cgImage)
            let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let bytes = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
            return [(1, 1), (3, 1), (1, 3), (3, 3)].map { x, y in
                let offset = (y * cg.height / 4) * ctx.bytesPerRow + (x * cg.width / 4) * 4
                return Array(UnsafeBufferPointer(start: bytes + offset, count: 3))
            }
        }
        let baseline = try quadrants(image)
        for (orientation, order) in [(1, [0, 1, 2, 3]), (3, [3, 2, 1, 0]),
                                     (6, [2, 0, 3, 1]), (8, [1, 3, 0, 2])] {
            let result = try preparePhotoCrop(image: image, orientation: orientation,
                embeddedOrientation: nil, rotation: 0)
            XCTAssertEqual(try quadrants(result.image), order.map { baseline[$0] }, "EXIF \(orientation)")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try preparePhotoCrop(image: image, orientation: 1, embeddedOrientation: nil, rotation: 0)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled preparation must not produce an editor image")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFHDPreparationRemovesBarsAndRendersCanonicalDimensions() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 10, y: 0, width: 100, height: 80))
        }
        let original = image.pngData()
        for orientation in [1, 3, 6, 8] {
            let result = try preparePhotoCrop(image: image, orientation: orientation,
                embeddedOrientation: nil, rotation: -90)
            XCTAssertEqual(result.preview.content, CropRect(left: 10, top: 0, right: 110, bottom: 80))
            XCTAssertEqual(result.image.cgImage?.width, orientation >= 5 ? 80 : 100)
            XCTAssertEqual(result.image.cgImage?.height, orientation >= 5 ? 100 : 80)
            XCTAssertEqual(result.image.imageOrientation, .up)
            XCTAssertEqual(result.preview.displayOrientation, orientation)
            XCTAssertEqual(result.preview.originalOrientation, orientation)
            XCTAssertEqual(image.pngData(), original)
        }
        XCTAssertThrowsError(try preparePhotoCrop(image: UIImage(), orientation: 1,
            embeddedOrientation: nil, rotation: 0))
        XCTAssertThrowsError(try preparePhotoCrop(image: image, orientation: 2,
            embeddedOrientation: nil, rotation: 0))
    }

    func testPreparationUsesContentAndKeepsOriginalOrientationForDeferredRecipe() throws {
        for orientation in [1, 3, 6, 8] {
            let prepared = try prepareCropPreview(width: 120, height: 80, orientation: orientation,
                embeddedOrientation: nil, rotation: -90) { x, _ in
                    CGColor(gray: x < 10 || x >= 110 ? 0 : 1, alpha: 1)
                }
            XCTAssertEqual(prepared.content, CropRect(left: 10, top: 0, right: 110, bottom: 80))
            XCTAssertEqual(prepared.displayOrientation, 8)
            XCTAssertEqual(prepared.source.width, 80)
            XCTAssertEqual(prepared.source.height, 100)
            let ready = prepared.canonicalized()
            XCTAssertEqual(ready.source.width, orientation >= 5 ? 80 : 100)
            XCTAssertEqual(ready.source.height, orientation >= 5 ? 100 : 80)
            XCTAssertEqual(ready.source.mcuWidth, 1)
            let selection = ready.canonicalSelection(.init(bounds: .init(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9), orientation: 1))
            XCTAssertEqual(selection.orientation, orientation)
            XCTAssertEqual(selection.bounds.left, 0.1, accuracy: 0.0001)
        }
    }

    func testPreparationRejectsUnsupportedOrientationAndEmptyPreview() {
        for orientation in [0, 2, 4, 5, 7, 9] {
            XCTAssertThrowsError(try prepareCropPreview(width: 120, height: 80, orientation: orientation,
                embeddedOrientation: nil, rotation: 0, pixel: { _, _ in CGColor(gray: 1, alpha: 1) })) { error in
                    guard case CropPreparationError.orientation = error else { return XCTFail("\(error)") }
                }
        }
        XCTAssertThrowsError(try prepareCropPreview(width: 0, height: 80, orientation: 1,
            embeddedOrientation: nil, rotation: 0, pixel: { _, _ in XCTFail("Empty preview must not read pixels"); return CGColor(gray: 0, alpha: 1) }))
    }

    func testRotationMapsToAndroidDisplayOrientations() {
        XCTAssertEqual(displayOrientation(for: 0), 1)
        XCTAssertEqual(displayOrientation(for: 90), 6)
        XCTAssertEqual(displayOrientation(for: 180), 3)
        XCTAssertEqual(displayOrientation(for: 270), 8)
    }
    func testRawSelectionMapsDisplayBoundsIntoContent() {
        let preview = CropPreview(source: .init(width: 1000, height: 800, mcuWidth: 1, mcuHeight: 1, orientation: 1), imageWidth: 1200, imageHeight: 1000, originalOrientation: 1, content: .init(left: 100, top: 50, right: 1100, bottom: 850), displayOrientation: 1, canonicalOrientation: 1)
        let raw = preview.rawSelection(.init(bounds: .init(left: 0.1, top: 0.2, right: 0.9, bottom: 0.8), orientation: 1))
        XCTAssertEqual(raw, .init(left: 200, top: 210, right: 1000, bottom: 690))
    }
    func testCanonicalSelectionSwapsRatioWhenOrientationAxesDiffer() {
        let preview = CropPreview(source: .init(width: 100, height: 200, mcuWidth: 1, mcuHeight: 1, orientation: 1), imageWidth: 200, imageHeight: 100, originalOrientation: 1, content: .init(left: 0, top: 0, right: 200, bottom: 100), displayOrientation: 6, canonicalOrientation: 1)
        let selection = preview.canonicalSelection(.init(bounds: .init(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9), orientation: 1, ratioWidth: 16, ratioHeight: 9))
        XCTAssertEqual(selection.ratioWidth, 9); XCTAssertEqual(selection.ratioHeight, 16)
    }
}

private actor PreparedCropGate {
    private var continuation: CheckedContinuation<PreparedPhotoCrop?, Error>?
    private var finished = false
    var started: Bool { continuation != nil }
    func read() async throws -> PreparedPhotoCrop? {
        if finished { return nil }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(value: PreparedPhotoCrop?, fails: Bool) {
        finished = true
        if fails { continuation?.resume(throwing: CropPreparationError.orientation()) }
        else { continuation?.resume(returning: value) }
        continuation = nil
    }
}
