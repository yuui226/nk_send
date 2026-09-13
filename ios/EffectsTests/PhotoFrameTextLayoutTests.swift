import CoreGraphics
import CoreText
import ImageIO
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferEffects
#elseif !FRAME_TEXT_STANDALONE
@testable import ZTransfer
#endif

final class PhotoFrameTextLayoutTests: XCTestCase {
    // Fixtures from PhotoFrameExporterTest.kt; the geometry must also work at
    // nonzero origins because each preset positions its metadata differently.
    func testAndroidBaselineFixtures() {
        let area = CGRect(x: 0, y: 80, width: 300, height: 140)
        let single = PhotoFrameTextLayout(area: area, bounds: [bounds(-24, 6)], preferredGap: 12)
        XCTAssertEqual(single.baselines, [159])
        XCTAssertTrue(PhotoFrameTextLayout(area: area, bounds: [], preferredGap: 12).baselines.isEmpty)
        let cramped = PhotoFrameTextLayout(area: CGRect(x: 0, y: 0, width: 300, height: 100),
            bounds: [bounds(-30, 10), bounds(-20, 10), bounds(-10, 10)], preferredGap: 20)
        XCTAssertEqual(cramped.baselines, [30, 65, 90])
        XCTAssertEqual(cramped.scale, 1)
        XCTAssertEqual(cramped.gap, 5)
    }

    func testCrowdingCompressesGapsBeforeFontsAndKeepsSymmetricPadding() {
        let rows = [bounds(-20, 10), bounds(-15, 10), bounds(-10, 10)]
        let layout = PhotoFrameTextLayout(area: CGRect(x: 0, y: 100, width: 300, height: 100),
                                         bounds: rows, preferredGap: 10, verticalInset: 6)
        XCTAssertEqual(layout.scale, 1)
        XCTAssertEqual(layout.gap, 6.5)
        XCTAssertEqual(layout.baselines[0] + rows[0].minY, 106)
        XCTAssertEqual(layout.baselines[2] + rows[2].maxY, 194)
    }

    func testLargeWatermarkScalesAllVisibleRowsWithoutOverlap() {
        let rows = [bounds(-60, 10), bounds(-45, 10), bounds(-100, 20)]
        let area = CGRect(x: 0, y: 100, width: 300, height: 100)
        let layout = PhotoFrameTextLayout(area: area, bounds: rows, preferredGap: 12, verticalInset: 6)
        XCTAssertLessThan(layout.scale, 1)
        let drawn = zip(rows, layout.baselines).map { row, baseline in
            CGRect(x: 0, y: baseline + row.minY * layout.scale, width: 1, height: row.height * layout.scale)
        }
        for pair in zip(drawn, drawn.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.maxY, pair.1.minY) }
        XCTAssertGreaterThanOrEqual(drawn.first!.minY, area.minY + 6)
        XCTAssertLessThanOrEqual(drawn.last!.maxY, area.maxY - 6)
        XCTAssertEqual((drawn.first!.minY + drawn.last!.maxY) * 0.5, area.midY, accuracy: 0.001)
    }

    func testActualCoreTextPixelsMatchCenteredInkForMixedFontsAndAllRowCounts() throws {
        // Render with the same y-down CTM as UIGraphicsImageRenderer. Pixel
        // assertions catch reversed glyph bounds even if layout arithmetic passes.
        for width in [320, 960, 1280] {
            for count in [1, 2, 3, 4, 5] {
                let area = CGRect(x: 20, y: 30, width: CGFloat(width - 40), height: CGFloat(width) * 0.16)
                let rows = sampleRows(width: area.width, count: count)
                let (image, layout) = try render(rows: rows, area: area, width: width, height: Int(area.maxY) + 30)
                let pixels = try visibleBounds(image)
                XCTAssertEqual(pixels.midY, area.midY, accuracy: 1.5, "width=\(width), rows=\(count)")
                XCTAssertGreaterThanOrEqual(pixels.minY, area.minY + area.height * 0.06 - 1)
                XCTAssertLessThanOrEqual(pixels.maxY, area.maxY - area.height * 0.06 + 1)
                XCTAssertGreaterThan(layout.scale, 0)
            }
        }
    }

    func testBundledWatermarkFontsRemainCenteredWhenMetadataIsHidden() throws {
        let fontDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ZTransfer/Resources/Fonts")
        for name in ["great_vibes_regular.ttf", "bebas_neue_regular.ttf", "cormorant_garamond_medium_italic.ttf"] {
            let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(fontDirectory.appendingPathComponent(name) as CFURL) as? [CTFontDescriptor])
            let font = CTFontCreateWithFontDescriptor(try XCTUnwrap(descriptors.first), 72, nil)
            let row = PhotoFrameTextRow(attributed("ZTransfer gyp", font: font))
            let area = CGRect(x: 20, y: 40, width: 560, height: 100)
            let (image, _) = try render(rows: [row], area: area, width: 600, height: 180)
            XCTAssertEqual(try visibleBounds(image).midY, area.midY, accuracy: 1.5, name)
        }
    }

    func testFittedTitleScalesComponentGapAndRetainsWidthLimits() throws {
        let title = PhotoFrameTextRow([text("Hasselblad", size: 60, font: "Helvetica-BoldOblique"), text("X2D 100C", size: 44)], gap: 20)
        let fitted = title.fitting(width: 240)
        XCTAssertLessThanOrEqual(fitted.width, 240)
        XCTAssertLessThan(fitted.bounds.height, title.bounds.height)
        let alone = PhotoFrameTextRow([text("", size: 60), text("Z 30", size: 40)], gap: 80)
        XCTAssertEqual(alone.width, PhotoFrameTextRow(text("Z 30", size: 40)).width)
        let area = CGRect(x: 20, y: 40, width: 240, height: 80)
        let (image, _) = try render(rows: [fitted], area: area, width: 280, height: 160)
        XCTAssertEqual(try visibleBounds(image).midY, area.midY, accuracy: 1.5)
    }

    /// Optional visual proof generated by the production text renderer without
    /// building, signing or installing the App.
    func testRenderLayoutProof() throws {
        guard let output = ProcessInfo.processInfo.environment["ZTRANSFER_TEXT_PROOF"] else { return }
        let width = 800, height = 600
        let context = try bitmap(width: width, height: height)
        context.setFillColor(CGColor(red: 250 / 255, green: 249 / 255, blue: 247 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, count) in [1, 3, 4, 5].enumerated() {
            let area = CGRect(x: 30, y: 20 + index * 145, width: 740, height: 125)
            context.setStrokeColor(CGColor(gray: 0.65, alpha: 1))
            context.stroke(area)
            let rows = sampleRows(width: area.width, count: count)
            draw(rows, in: area, context: context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func bounds(_ top: CGFloat, _ bottom: CGFloat) -> CGRect { CGRect(x: 0, y: top, width: 100, height: bottom - top) }
    private func attributed(_ value: String, font: CTFont) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
    }
    private func text(_ value: String, size: CGFloat, font: String = "Helvetica") -> NSAttributedString {
        attributed(value, font: CTFontCreateWithName(font as CFString, size, nil))
    }
    private func sampleRows(width: CGFloat, count: Int) -> [PhotoFrameTextRow] {
        // Android standard frames: title, optional lens, exposure/date together,
        // optional location/altitude together, then the frame watermark LAST.
        let title = PhotoFrameTextRow([text("Nikon", size: width * 0.032, font: "Helvetica-BoldOblique"),
                                       text("Z 30", size: width * 0.024)], gap: width * 0.016)
        let lens = PhotoFrameTextRow(text("NIKKOR Z DX 50-250mm f/4.5-6.3 VR", size: width * 0.0185))
        let details = PhotoFrameTextRow(text("250mm   F6.3   1/200s   ISO2500   2026-07-19 22:15", size: width * 0.020)).fitting(width: width * 0.82)
        let location = PhotoFrameTextRow(text("31.1234°N, 120.1234°E   140m", size: width * 0.020))
        let watermark = PhotoFrameTextRow(text("ZTRANSFER", size: width * 0.026, font: "HelveticaNeue-CondensedBold"))
        switch count {
        case 1: return [watermark]
        case 2: return [title, watermark]
        case 3: return [title, details, watermark]
        case 4: return [title, lens, details, watermark]
        default: return [title, lens, details, location, watermark]
        }
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }
    @discardableResult private func draw(_ rows: [PhotoFrameTextRow], in area: CGRect, context: CGContext) -> PhotoFrameTextLayout {
        let layout = PhotoFrameTextLayout(area: area, bounds: rows.map(\.bounds), preferredGap: min(area.width * 0.0125, area.height * 0.09), verticalInset: area.height * 0.06)
        for (index, row) in rows.enumerated() {
            row.draw(in: context, x: area.midX - row.width * layout.scale * 0.5,
                     baseline: layout.baselines[index], scale: layout.scale)
        }
        return layout
    }
    private func render(rows: [PhotoFrameTextRow], area: CGRect, width: Int, height: Int) throws -> (CGImage, PhotoFrameTextLayout) {
        let context = try bitmap(width: width, height: height)
        let layout = draw(rows, in: area, context: context)
        return (try XCTUnwrap(context.makeImage()), layout)
    }
    private func visibleBounds(_ image: CGImage) throws -> CGRect {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where data[y * image.bytesPerRow + x * 4 + 3] > 32 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxY, 0, "No text was rendered")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
