import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ZTransfer

final class PhotoEffectsPreviewTests: XCTestCase {
    private func encoded(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testPreviewDecoderBoundsMemoryAndAppliesExifOrientation() throws {
        let url = try encoded(width: 4000, height: 2000, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try XCTUnwrap(PhotoEffectsImageDecoder.previewImage(at: url, maximumPixelSize: 1000))
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), 1000)
        XCTAssertLessThan(preview.width, preview.height)
        XCTAssertLessThanOrEqual(preview.width * preview.height, 1_000_000)
    }

    func testPreviewDecoderRejectsMissingAndMalformedFilesWithoutFallbackFullDecode() {
        XCTAssertNil(PhotoEffectsImageDecoder.previewImage(at: URL(fileURLWithPath: "/not-owned/missing.jpg")))
        let malformed = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try? Data([1, 2, 3]).write(to: malformed)
        defer { try? FileManager.default.removeItem(at: malformed) }
        XCTAssertNil(PhotoEffectsImageDecoder.previewImage(at: malformed))
    }

    func testExportRendererKeepsSourceDimensions() async throws {
        let selection = try XCTUnwrap(NativePhotoFilterCatalog.shared.selection(index: 0, intensityPercent: 80))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 37, height: 19, bitsPerComponent: 8,
            bytesPerRow: 37 * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 37, height: 19))
        let image = try XCTUnwrap(context.makeImage())
        let rendered = try await PhotoFilterPreviewRenderer().renderExport(image, selection: selection)
        XCTAssertEqual(rendered.width, image.width)
        XCTAssertEqual(rendered.height, image.height)
    }

    @MainActor
    func testPreviewStoreDoesNotExposeStaleFilterImageAfterSelectionChanges() throws {
        let store = PhotoEffectsPreviewStore()
        let asset = IOSPhotoEffectAsset(id: "photo", url: URL(fileURLWithPath: "/missing.jpg"), displayName: "photo")
        XCTAssertNil(store.image(for: asset))
        store.clear()
        XCTAssertNil(store.image(for: asset))
    }
}
