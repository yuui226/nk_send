import XCTest
import UIKit
import CoreText
@testable import ZTransfer

final class PhotoFrameBrandTests: XCTestCase {
    private let knownMakes = ["nikon", "fujifilm", "panasonic", "samsung", "motorola", "oneplus", "huawei",
                              "xiaomi", "honor", "apple", "google", "nokia", "leica", "sony", "oppo", "vivo", "dji"]

    func testMeasuredIdentityPaddingUsesEachTextRunFont() {
        let large = NSAttributedString(string: "Brand", attributes: [.font: UIFont.boldSystemFont(ofSize: 40)])
        let small = NSAttributedString(string: "Model", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        let first = PhotoFrameTextRow(large).bounds.insetBy(dx: 0, dy: -1.4)
        let second = PhotoFrameTextRow(small).bounds.insetBy(dx: 0, dy: -0.7)
        let row = PhotoFrameTextRow([large, small], gap: 10, includeRunInk: true, verticalPaddingRatio: 0.035)
        XCTAssertEqual(row.bounds.minY, min(first.minY, second.minY), accuracy: 0.001)
        XCTAssertEqual(row.bounds.maxY, max(first.maxY, second.maxY), accuracy: 0.001)
        let camera = metadata(make: "NIKON", model: "Z 8")
        let plain = PhotoEffectsRenderer.frameIdentityRow(metadata: camera, font: .systemFont(ofSize: 40), color: .black, trailingRuns: [], gap: 0)
        let padded = PhotoEffectsRenderer.frameIdentityRow(metadata: camera, font: .systemFont(ofSize: 40), color: .black, trailingRuns: [], gap: 0, verticalPaddingRatio: 0.035)
        XCTAssertEqual(padded.bounds.height, plain.bounds.height + 2.8, accuracy: 0.001)
        XCTAssertEqual(padded.layoutWidth, plain.layoutWidth, accuracy: 0.001)
    }

    func testBandSignatureReservesVerticalEffectInkBeforePreviewScaling() throws {
        for size: CGFloat in [3, 20, 100] {
            let font = UIFont.italicSystemFont(ofSize: size)
            let raw = PhotoFrameTextRow(NSAttributedString(string: "Signature", attributes: [.font: font]))
            let measured = try XCTUnwrap(PhotoEffectsRenderer.watermarkDescriptionRows(
                "Signature", font: font, color: .black, width: 1000).first)
            let padding = max(1, size * 0.2)
            XCTAssertEqual(measured.bounds.minY, raw.bounds.minY - padding, accuracy: 0.001)
            XCTAssertEqual(measured.bounds.maxY, raw.bounds.maxY + padding, accuracy: 0.001)
            XCTAssertEqual(measured.layoutWidth, raw.layoutWidth, accuracy: 0.001)
            XCTAssertEqual(measured.scaled(by: 0.1).bounds.height,
                           (raw.bounds.height + padding * 2) * 0.1, accuracy: 0.001)
        }
    }

    func testMeasuredMixedRunsReserveEachInkOverhang() throws {
        let font = try XCTUnwrap(UIFont(name: "TimesNewRomanPS-ItalicMT", size: 80))
        let runs = ["f", "j", "Wf"].map { NSAttributedString(string: $0, attributes: [.font: font]) }
        let parts = runs.map { PhotoFrameTextRow($0) }
        let expected = parts.reduce(CGFloat.zero) { $0 + $1.layoutWidth } + 14
        let measured = PhotoFrameTextRow(runs, gap: 7, includeRunInk: true)
        XCTAssertEqual(measured.width, expected, accuracy: 0.001)
        XCTAssertEqual(measured.layoutWidth, expected, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(measured.bounds.minX, 0)
        XCTAssertLessThanOrEqual(measured.bounds.maxX, measured.width + 0.001)
        XCTAssertEqual(measured.scaled(by: 0.25).layoutWidth, expected * 0.25, accuracy: 0.001)
        let advanceOnly = PhotoFrameTextRow(runs, gap: 7)
        XCTAssertEqual(advanceOnly.width, parts.reduce(CGFloat.zero) { $0 + $1.width } + 14, accuracy: 0.001)
        XCTAssertGreaterThan(measured.width, advanceOnly.width)
    }

    func testAllTemplatesCombineFullMetadataAndMaximumWatermarkAcrossAspectRatios() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let camera = PhotoFrameMetadata(make: "NIKON", model: "Z 8 Professional Camera",
            lensModel: String(repeating: "NIKKOR Z 24-70mm f/2.8 S ", count: 8),
            focalLength: "70mm", aperture: "f/2.8", shutter: "1/125", iso: "ISO 400",
            exposureCompensation: "+0.7", dateTime: "2026:10:17 12:34:56",
            latitude: 35.6895, longitude: 139.6917, altitude: 123.4,
            city: "Tokyo City", region: "Shinjuku Region")
        for preset in PhotoFramePreset.allCases {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.metadata.showBrand = true; settings.metadata.showModel = true
            settings.metadata.brandStyle = .logo; settings.metadata.showLensModel = true
            settings.metadata.showDate = true; settings.metadata.showTime = true
            settings.metadata.showFocalLength = true; settings.metadata.showExposure = true
            settings.metadata.showCoordinates = true; settings.metadata.showAltitude = true
            settings.metadata.showAddress = true; settings.metadata.showCity = true; settings.metadata.showRegion = true
            settings.watermark.enabled = true; settings.watermark.position = .auto
            settings.watermark.sizePercent = 300; settings.watermark.text = String(repeating: "W", count: 24)
            for size in [CGSize(width: 161, height: 121), CGSize(width: 121, height: 161),
                         CGSize(width: 320, height: 40), CGSize(width: 40, height: 320)] {
                let source = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
                for width in [60, 100, 200] {
                    settings.metadata.widthPercent = width
                    let context = "\(preset) \(size) width \(width)"
                    do {
                        let original = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera)
                        XCTAssertGreaterThanOrEqual(original.size.width, size.width, context)
                        XCTAssertGreaterThanOrEqual(original.size.height, size.height, context)
                        let preview = try PhotoEffectsRenderer.render(source, settings: settings,
                            metadata: camera, previewLongEdge: 128)
                        let scale = 128 / max(original.size.width, original.size.height)
                        XCTAssertEqual(preview.size.width, max(1, (original.size.width * scale).rounded()), accuracy: 1, context)
                        XCTAssertEqual(preview.size.height, max(1, (original.size.height * scale).rounded()), accuracy: 1, context)
                    } catch let error as PhotoFrameBrandLayoutError {
                        // Android rejects an in-photo block that cannot fit or avoid the watermark.
                        XCTAssertTrue([.brandInset, .brandGallery].contains(preset), context)
                        XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings,
                            metadata: camera, previewLongEdge: 128)) { previewError in
                            XCTAssertEqual(previewError.localizedDescription, error.localizedDescription, context)
                        }
                    }
                }
            }
        }
    }

    func testMissingImageWatermarkFailsInsteadOfRenderingText() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { _ in }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.watermark.enabled = true
        settings.watermark.content = .image; settings.watermark.position = .photoCenter
        for preset in PhotoFramePreset.allCases {
            settings.photoFramePreset = preset
            for hash in [nil, "../invalid", String(repeating: "0", count: 64)] {
                settings.watermark.imageHash = hash
                XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings)) { error in
                    guard case PhotoEffectsRenderError.invalidWatermarkImage = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
        settings.photoFrameBorderEnabled = false
        XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings))
        settings.watermark.enabled = false
        XCTAssertNoThrow(try PhotoEffectsRenderer.render(source, settings: settings))
    }

    func testImmersiveInlineWatermarkKeepsIndependentEffects() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
        }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .immersive
        settings.metadata = .defaults(for: .immersive)
        settings.watermark.enabled = true; settings.watermark.position = .auto
        settings.watermark.text = "Inline signature"; settings.watermark.color = .white
        for camera in [PhotoFrameMetadata.empty, metadata(make: "Nikon", model: "Z 8")] {
            for style: PhotoFrameBrandStyle in [.text, .logo] {
                settings.metadata.brandStyle = style
                for preview: CGFloat? in [nil, 256] {
                    func render(_ effect: PhotoFrameWatermarkEffect) throws -> Data? {
                        settings.watermark.effect = effect
                        return try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera, previewLongEdge: preview).pngData()
                    }
                    let none = try render(.none), automatic = try render(.auto)
                    let shadow = try render(.shadow), outline = try render(.outline)
                    XCTAssertEqual(none, automatic)
                    XCTAssertNotEqual(none, shadow)
                    XCTAssertNotEqual(none, outline)
                    XCTAssertNotEqual(shadow, outline)
                }
            }
        }
    }

    func testFramedLongPhotoWatermarkReachesOutputAcrossEffectsAndOpacity() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        for preset in PhotoFramePreset.allCases {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.watermark.enabled = true; settings.watermark.position = .photoBottomRight
            settings.watermark.font = .bold; settings.watermark.color = .black; settings.watermark.sizePercent = 300
            for effect in PhotoFrameWatermarkEffect.allCases {
                settings.watermark.effect = effect
                for opacity in [1, 100] {
                    settings.watermark.opacityPercent = opacity
                    for preview: CGFloat? in [nil, 256] {
                        func render(_ tail: String) throws -> UIImage {
                            settings.watermark.text = String(repeating: "W", count: 21) + tail
                            return try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty, previewLongEdge: preview)
                        }
                        let first = try render("AAA"), second = try render("ZZZ")
                        XCTAssertEqual(first.size, second.size)
                        XCTAssertNotEqual(first.pngData(), second.pngData(), "\(preset) \(effect) \(opacity) preview=\(String(describing: preview))")
                        if let preview { XCTAssertEqual(max(first.size.width, first.size.height), preview, accuracy: 1) }
                    }
                }
            }
        }
    }

    func testWatermarkRowEffectsDoNotLeaveOpaqueInkAtOnePercent() throws {
        for brightness: CGFloat in [0, 1] {
            for outline in [false, true] {
                func maximumAlpha(_ opacity: CGFloat) throws -> UInt8 {
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 100), format: format).image { context in
                        let row = PhotoFrameTextRow(NSAttributedString(string: "Watermark", attributes: [
                            .font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor(white: brightness, alpha: opacity)]))
                        row.draw(in: context.cgContext, x: 30, baseline: 60, outline: outline, shadow: !outline)
                    }
                    let cg = try XCTUnwrap(image.cgImage)
                    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                    let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                    return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
                }
                let faint = try maximumAlpha(0.01), opaque = try maximumAlpha(1)
                XCTAssertGreaterThan(faint, 0)
                XCTAssertLessThanOrEqual(faint, 8) // Allows stroke/fill compositing and byte rounding.
                XCTAssertGreaterThan(opaque, 200)
            }
        }
    }

    func testWatermarkEffectsPreserveOpacityAndUseFontRelativeUnits() throws {
        for size: CGFloat in [4, 20, 100] {
            let font = UIFont.systemFont(ofSize: size)
            for opacity: CGFloat in [0.01, 0.5, 1] {
                for brightness: CGFloat in [0, 1] {
                    let color = UIColor(white: brightness, alpha: opacity)
                    let attributes = PhotoWatermarkInk.outlineAttributes(font: font, color: color)
                    let percent = try XCTUnwrap(attributes[.strokeWidth] as? CGFloat)
                    XCTAssertEqual(percent * size / 100, max(1, size * 0.075), accuracy: 0.0001)
                    let stroke = try XCTUnwrap(attributes[.strokeColor] as? UIColor)
                    XCTAssertEqual(stroke.cgColor.alpha, opacity, accuracy: 0.0001)
                    let shadow = PhotoWatermarkInk.shadow(font: font, color: color)
                    XCTAssertEqual(shadow.shadowBlurRadius, size * 0.12, accuracy: 0.0001)
                    XCTAssertEqual(shadow.shadowOffset.height, size * 0.06, accuracy: 0.0001)
                    let shadowColor = try XCTUnwrap(shadow.shadowColor as? UIColor)
                    XCTAssertEqual(shadowColor.cgColor.alpha, opacity, accuracy: 0.0001)
                    XCTAssertEqual(shadowColor, stroke)
                }
            }
        }
    }

    func testBandWatermarkOutlineAndShadowAreConsumedByTemplates() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
        }
        for preset: PhotoFramePreset in [.mist, .cinema, .minimal, .frosted, .plaque, .brandGallery,
                                          .galleryMat, .filmGallery, .filmNegative, .classicSignature, .immersive] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.watermark.enabled = true; settings.watermark.position = .left
            settings.watermark.text = "Outline watermark"; settings.watermark.sizePercent = 150
            for color: PhotoFrameWatermarkColor in [.black, .white] {
                settings.watermark.color = color
                func render(_ effect: PhotoFrameWatermarkEffect) throws -> Data? {
                    settings.watermark.effect = effect
                    return try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty).pngData()
                }
                let none = try render(.none), outline = try render(.outline), shadow = try render(.shadow)
                XCTAssertNotEqual(none, outline, "\(preset) \(color) outline")
                XCTAssertNotEqual(none, shadow, "\(preset) \(color) shadow")
                XCTAssertNotEqual(outline, shadow, "\(preset) \(color) effects")
            }
        }
    }

    func testWatermarkAutoEffectMatchesExplicitEffectInRenderedTemplates() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        for preset in PhotoFramePreset.allCases {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.watermark.enabled = true; settings.watermark.text = "Watermark"
            settings.watermark.position = .photoCenter
            settings.watermark.effect = .auto
            let automatic = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
            settings.watermark.effect = .shadow
            let explicit = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
            XCTAssertEqual(automatic.pngData(), explicit.pngData(), preset.rawValue)
        }
        for preset: PhotoFramePreset in [.minimal, .plaque, .brandGallery, .galleryMat, .filmNegative, .classicSignature] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.watermark.enabled = true; settings.watermark.text = "Watermark"
            settings.watermark.position = .left
            settings.watermark.effect = .auto
            let automatic = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
            settings.watermark.effect = .none
            let explicit = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
            XCTAssertEqual(automatic.pngData(), explicit.pngData(), preset.rawValue)
        }
        for position in PhotoFrameWatermarkPosition.allCases {
            for effect in [PhotoFrameWatermarkEffect.none, .shadow, .outline] {
                var value = PhotoFrameWatermark(); value.position = position; value.effect = effect
                XCTAssertEqual(PhotoEffectsRenderer.resolvedWatermarkEffect(value), effect)
            }
        }
    }

    func testLongPhotoWatermarkRendersWithoutClippingAcrossFontsAndPreviews() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 320, height: 480), CGSize(width: 480, height: 320)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            for font in PhotoFrameWatermarkFont.allCases {
                for position: PhotoFrameWatermarkPosition in [.photoTopLeft, .photoCenter, .photoBottomRight] {
                    var settings = PhotoEffectsSettings()
                    settings.photoFrameEnabled = true; settings.photoFrameBorderEnabled = false
                    settings.watermark.enabled = true; settings.watermark.font = font
                    settings.watermark.position = position; settings.watermark.sizePercent = 300
                    settings.watermark.opacityPercent = 100; settings.watermark.color = .black
                    settings.watermark.effect = .none
                    for preview: CGFloat? in [nil, 128] {
                        func render(_ tail: String) throws -> UIImage {
                            settings.watermark.text = String(repeating: "W", count: 21) + tail
                            return try PhotoEffectsRenderer.render(source, settings: settings, previewLongEdge: preview)
                        }
                        let first = try render("AAA"), second = try render("ZZZ")
                        XCTAssertNotEqual(first.pngData(), second.pngData())
                        let cg = try XCTUnwrap(first.cgImage)
                        let width = cg.width, height = cg.height
                        var bytes = [UInt8](repeating: 0, count: width * height * 4)
                        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                        var inkCount = 0
                        for y in 0..<height {
                            for x in 0..<width {
                                let offset = (y * width + x) * 4
                                if bytes[offset] < 200 {
                                    inkCount += 1
                                    XCTAssertTrue(x > 0 && x < width - 1 && y > 0 && y < height - 1,
                                        "\(font) \(position) \(size) preview=\(String(describing: preview))")
                                }
                            }
                        }
                        XCTAssertGreaterThan(inkCount, 0)
                    }
                }
            }
        }
    }

    func testPhotoWatermarkFitsFullTextAndPositionsInkInsideSafeArea() {
        let photo = CGRect(x: 31, y: 47, width: 320, height: 480)
        let safe = photo.insetBy(dx: 12.8, dy: 12.8)
        let positions: [PhotoFrameWatermarkPosition] = [.photoTopLeft, .photoTopCenter, .photoTopRight,
            .photoCenter, .photoBottomLeft, .photoBottomCenter, .photoBottomRight]
        for style in PhotoFrameWatermarkFont.allCases {
            for percent in [1, 100, 300] {
                for position in positions {
                    var watermark = PhotoFrameWatermark()
                    watermark.text = String(repeating: "W", count: 24)
                    watermark.font = style; watermark.sizePercent = percent; watermark.position = position
                    let layout = PhotoEffectsRenderer.photoWatermarkTextLayout(watermark, photo: photo)
                    let ink = layout.inkBounds
                    let advance = PhotoFrameTextRow(NSAttributedString(string: watermark.displayText,
                        attributes: [.font: layout.font])).width
                    XCTAssertLessThanOrEqual(advance, safe.width + 0.01)
                    if ink.width <= safe.width {
                        XCTAssertGreaterThanOrEqual(ink.minX, safe.minX - 0.01)
                        XCTAssertLessThanOrEqual(ink.maxX, safe.maxX + 0.01)
                    } else {
                        // Android centers oversized glyph ink when minOriginX exceeds maxOriginX.
                        XCTAssertEqual(ink.midX, photo.midX, accuracy: 0.01)
                    }
                    XCTAssertGreaterThanOrEqual(ink.minY, safe.minY - 0.01)
                    XCTAssertLessThanOrEqual(ink.maxY, safe.maxY + 0.01)
                    if position == .photoCenter {
                        XCTAssertEqual(ink.midX, photo.midX, accuracy: 0.01)
                        XCTAssertEqual(ink.midY, photo.midY, accuracy: 0.01)
                    }
                }
            }
        }
    }

    func testKnownBrandTextKeepsModel() {
        let value = metadata(make: "Nikon Corporation", model: "Z 8")
        XCTAssertEqual(value.normalizedMake, "Nikon")
        XCTAssertEqual(value.normalizedModel, "Z 8")
    }

    func testUnknownMakeRemainsText() {
        XCTAssertEqual(metadata(make: "Acme", model: "X1").identity, "Acme X1")
    }

    func testLegacyLogoUsesTextVisibilityAndModelDerivedBrand() {
        let source = metadata(make: nil, model: "NIKON Z 30")
        var settings = PhotoFrameMetadataSettings.defaults(for: .mist)
        settings.showBrand = true
        settings.showModel = true
        settings.brandStyle = .logo
        let logo = source.resolved(for: settings, preview: false, now: Date())
        XCTAssertNil(logo.make)
        XCTAssertEqual(logo.identity, "NIKON Z 30")
        settings.brandStyle = .text
        XCTAssertNil(source.resolved(for: settings, preview: false, now: Date()).make)
        settings.showModel = false
        XCTAssertEqual(source.resolved(for: settings, preview: false, now: Date()).make, "NIKON")
        settings.showBrand = false
        settings.brandStyle = .logo
        XCTAssertNil(source.resolved(for: settings, preview: false, now: Date()).make)
    }

    func testNokiaAndDJINormalizationUsesWholeBrandPrefix() {
        for (make, expected) in [("Nokia Corporation", "NOKIA"), ("dji Technology", "DJI"),
                                 ("nokia", "NOKIA"), ("DJI", "DJI"),
                                 ("NotNokia", "NotNokia"), ("DJIcam", "DJIcam")] {
            let metadata = metadata(make: make, model: expected + " Model")
            XCTAssertEqual(metadata.normalizedMake, expected)
            XCTAssertEqual(metadata.normalizedModel, "Model")
        }
    }
    func testBrandTextNormalizesKnownMakesAndDeduplicatesModel() {
        for brand in knownMakes {
            let make = brand == "nikon" ? "NIKON CORPORATION" : brand == "nokia" ? "Nokia Corporation" : brand
            let value = metadata(make: make, model: brand.uppercased() + " Model")
            XCTAssertEqual(value.normalizedMake.lowercased(), brand)
            XCTAssertEqual(value.normalizedModel, "Model")
        }
    }

    func testModelCannotRestoreHiddenBrandText() {
        for make: String? in [nil, "Unknown", "Canon"] {
            var settings = PhotoFrameMetadataSettings()
            settings.showBrand = false
            settings.brandStyle = .logo // Legacy input must not restore a logo or hidden Make.
            let value = metadata(make: make, model: "NIKON Z 30")
                .resolved(for: settings, preview: false, now: Date())
            XCTAssertNil(value.make)
            XCTAssertFalse(value.identity.isEmpty)
        }
    }

    func testMeasuredTextIdentityRowsFitLongModels() {
        let font = UIFont.systemFont(ofSize: 32)
        let suffix = NSAttributedString(string: String(repeating: "Long Model ", count: 8), attributes: [.font: font])
        for brand in knownMakes {
            let source = metadata(make: brand, model: "Model")
            let row = PhotoEffectsRenderer.frameIdentityRow(metadata: source,
                font: font, color: .black, trailingRuns: [suffix], gap: 12)
            let expected = PhotoFrameTextRow([
                NSAttributedString(string: source.normalizedMake, attributes: [.font: font, .foregroundColor: UIColor.black]),
                suffix
            ], gap: 12)
            XCTAssertEqual(row.width, expected.width, accuracy: 0.001, brand)
            let fitted = row.fitting(width: 400)
            XCTAssertLessThanOrEqual(max(fitted.width, fitted.bounds.maxX) - min(0, fitted.bounds.minX), 400.001)
            XCTAssertGreaterThan(fitted.bounds.height, 0)
        }
    }

    func testAllTemplatesMigrateLegacyLogoToTextAndRespectHiddenBrand() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        for preset in PhotoFramePreset.allCases {
            for make in knownMakes + ["Canon"] {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true; settings.photoFramePreset = preset
                settings.watermark.enabled = true
                settings.metadata = .defaults(for: preset)
                settings.metadata.showModel = true
                let camera = metadata(make: make, model: "Model 123")
                func render(brandVisible: Bool, style: PhotoFrameBrandStyle) throws -> Data? {
                    settings.metadata.showBrand = brandVisible
                    settings.metadata.brandStyle = style
                    return try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera).pngData()
                }
                let text = try render(brandVisible: true, style: .text)
                let logo = try render(brandVisible: true, style: .logo)
                XCTAssertEqual(text, logo, "Legacy logo must render as text: \(preset.rawValue) \(make)")
                let hidden = try render(brandVisible: false, style: .text)
                XCTAssertNotEqual(text, hidden, "Brand visibility must still affect output: \(preset.rawValue) \(make)")
                XCTAssertEqual(hidden, try render(brandVisible: false, style: .logo), preset.rawValue)
            }
        }
    }

    func testFilmStripUsesMeasuredRunGapForTextAndLegacyLogo() throws {
        var settings = PhotoFrameMetadataSettings.defaults(for: .filmGallery)
        settings.showBrand = true
        for logo in [false, true] {
            settings.brandStyle = logo ? .logo : .text
            for width: CGFloat in [160, 1000] {
                let brand = try XCTUnwrap(PhotoEffectsRenderer.filmStripIdentityRow(
                    metadata(make: "SONY", model: nil), settings: settings, width: width))
                let model = try XCTUnwrap(PhotoEffectsRenderer.filmStripIdentityRow(
                    metadata(make: nil, model: "A7"), settings: settings, width: width))
                let combined = try XCTUnwrap(PhotoEffectsRenderer.filmStripIdentityRow(
                    metadata(make: "SONY", model: "A7"), settings: settings, width: width))
                XCTAssertEqual(combined.width, brand.width + model.width + width * 0.006, accuracy: 0.001)
                XCTAssertLessThanOrEqual(combined.layoutWidth, width * 0.58)
            }
        }
    }

    func testLongFilmIdentityMovesOutOfStrip() {
        var settings = PhotoFrameMetadataSettings.defaults(for: .filmGallery)
        settings.showBrand = true
        for style: PhotoFrameBrandStyle in [.text, .logo] {
            settings.brandStyle = style
            XCTAssertNotNil(PhotoEffectsRenderer.filmStripIdentityRow(metadata(make: "SONY", model: "A7"), settings: settings, width: 1000))
            XCTAssertNil(PhotoEffectsRenderer.filmStripIdentityRow(metadata(make: "SONY", model: String(repeating: "Long Model ", count: 30)), settings: settings, width: 1000))
        }
    }

    func testFilmCaptionSplitsLongIdentityFromDetails() {
        var settings = PhotoFrameMetadataSettings.defaults(for: .filmEdge)
        settings.showBrand = true
        for style: PhotoFrameBrandStyle in [.text, .logo] {
            settings.brandStyle = style
            let short = metadata(make: "SONY", model: "A7")
            XCTAssertEqual(PhotoEffectsRenderer.filmEdgeRows(metadata: short, settings: settings, width: 1000).count, 1)
            let long = PhotoFrameMetadata(make: "SONY", model: String(repeating: "Long Model ", count: 30),
                lensModel: "50mm", focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
            let rows = PhotoEffectsRenderer.filmEdgeRows(metadata: long, settings: settings, width: 1000)
            XCTAssertGreaterThan(rows.count, 1)
            for row in rows { XCTAssertLessThanOrEqual(row.layoutWidth, 900.001) }
        }
    }

    func testPosterAndBrandTemplatesKeepModelInBothOrientations() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 320, height: 240), CGSize(width: 240, height: 320)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.gray.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            for preset: PhotoFramePreset in [.parameterPoster, .brandInset, .brandGallery] {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true; settings.photoFramePreset = preset
                settings.metadata = .defaults(for: preset)
                settings.metadata.showBrand = true; settings.metadata.showModel = true
                settings.metadata.brandStyle = .logo
                settings.watermark.enabled = true
                func render(_ model: String) throws -> Data? {
                    try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata(make: "SONY", model: model)).pngData()
                }
                XCTAssertNotEqual(try render("A7"), try render("A9"), "\(preset.rawValue) \(size)")
            }
        }
    }

    func testIdentityMeasurementPreservesSelectedSystemFont() {
        let text = "Mixed Wide iii WWW 123"
        for font in [UIFont.systemFont(ofSize: 32), UIFont.systemFont(ofSize: 32, weight: .black),
                     UIFont.italicSystemFont(ofSize: 32), UIFont.monospacedSystemFont(ofSize: 32, weight: .medium)] {
            let source = metadata(make: text, model: nil)
            let row = PhotoEffectsRenderer.frameIdentityRow(metadata: source, font: font, color: .black, trailingRuns: [], gap: 0)
            let reference = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            XCTAssertEqual(row.width, CGFloat(CTLineGetTypographicBounds(reference, nil, nil, nil)), accuracy: 0.001)
            let ink = CTLineGetBoundsWithOptions(reference, .useGlyphPathBounds)
            XCTAssertEqual(row.bounds.height, ink.height, accuracy: 0.001)
        }
    }

    func testDescriptionWrappingPreservesGraphemesAndParagraphs() {
        let samples = ["相机镜头参数", "e\u{301}e\u{301}e\u{301}", "👨‍👩‍👧‍👦🇨🇳👍🏽", "abcdefghijk"]
        for sample in samples {
            let input = NSAttributedString(string: sample, attributes: [.font: UIFont.systemFont(ofSize: 20)])
            let rows = PhotoFrameTextRow.wrappedDescriptions(input, width: 1)
            XCTAssertEqual(rows.map(\.string), sample.map(String.init))
            XCTAssertEqual(rows.map(\.string).joined(), sample)
        }
        let input = NSAttributedString(string: "  Alpha\r\n\n Beta  ", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        XCTAssertEqual(PhotoFrameTextRow.wrappedDescriptions(input, width: 1000).map(\.string), ["Alpha", "Beta"])
        XCTAssertTrue(PhotoFrameTextRow.wrappedDescriptions(NSAttributedString(string: " \n "), width: 10).isEmpty)
    }

    func testWrappingKeepsLongTextAndAttributedShortPath() {
        let text = String(repeating: "👨‍👩‍👧‍👦相机e\u{301}", count: 256)
        let source = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.red])
        let rows = PhotoFrameTextRow.wrappedDescriptions(source, width: 1)
        XCTAssertEqual(rows.count, 1024)
        XCTAssertEqual(rows.map(\.string).joined(), text)
        let short = NSAttributedString(string: "  Camera  ", attributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.red])
        let result = PhotoFrameTextRow.wrappedDescriptions(short, width: 1000)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isEqual(to: short.attributedSubstring(from: NSRange(location: 2, length: 6))))
    }

    func testLongStandardIdentitySplitsWithoutShrinkingModelFont() {
        let font = UIFont.systemFont(ofSize: 24)
        let source = metadata(make: "SONY", model: String(repeating: "WWWW ", count: 20))
        let rows = PhotoEffectsRenderer.frameIdentityRows(metadata: source, brandFont: font, modelFont: font, color: .black, gap: 12, width: 160)
        XCTAssertGreaterThan(rows.count, 2)
        let expectedModel = PhotoFrameTextRow.wrappedDescriptions(NSAttributedString(string: source.normalizedModel, attributes: [.font: font]), width: 160)
        XCTAssertEqual(rows.count, expectedModel.count + 1)
        for (row, text) in zip(rows.dropFirst(), expectedModel) {
            let reference = PhotoFrameTextRow(text)
            XCTAssertEqual(row.width, reference.width, accuracy: 0.001)
            XCTAssertEqual(row.bounds.height, reference.bounds.height, accuracy: 0.001)
        }
    }

    func testExpandedFramesKeepOriginalPhotoInteriorPixels() throws {
        for (width, height) in [(80, 60), (81, 61), (61, 81)] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(40 + (x * 2) % 180)
                pixels[offset + 1] = UInt8(30 + (y * 3) % 180)
                pixels[offset + 2] = (x + y).isMultiple(of: 2) ? 80 : 190
            }
        }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = UIImage(cgImage: try XCTUnwrap(context.makeImage()))
        func rgba(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
            let cg = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (bytes, cg.width, cg.height)
        }
        let original = try rgba(UIImage(cgImage: try XCTUnwrap(source.cgImage?.cropping(to: CGRect(x: 16, y: 16, width: width - 32, height: height - 32)))))
        for preset: PhotoFramePreset in [.minimal, .plaque, .classicSignature, .galleryMat, .filmGallery, .filmEdge, .filmNegative, .colorArchive, .brandGallery, .parameterPoster] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.metadata.showModel = true; settings.metadata.showLensModel = preset != .brandGallery
            settings.watermark.enabled = false
            let model = [.galleryMat, .filmGallery].contains(preset) ? String(repeating: "क्", count: 80) + "क"
                : String(repeating: "Model ", count: 50)
            let camera = PhotoFrameMetadata(make: "SONY", model: model,
                lensModel: String(repeating: "Lens ", count: 50), focalLength: nil, aperture: nil,
                shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
            for percent in [.galleryMat, .filmGallery].contains(preset) ? [60, 100, 200] : [100] {
                settings.metadata.widthPercent = percent
                let output = try rgba(PhotoEffectsRenderer.render(source, settings: settings, metadata: camera))
                var found = false
                for y in 0...(output.height - original.height) {
                    for x in 0...(output.width - original.width) {
                        let first = (y * output.width + x) * 4
                        guard output.bytes[first..<(first + 4)].elementsEqual(original.bytes[0..<4]) else { continue }
                        let matches = (0..<original.height).allSatisfy { row in
                            let start = ((y + row) * output.width + x) * 4
                            return output.bytes[start..<(start + original.width * 4)].elementsEqual(original.bytes[(row * original.width * 4)..<((row + 1) * original.width * 4)])
                        }
                        if matches { found = true; break }
                    }
                    if found { break }
                }
                XCTAssertTrue(found, "\(preset.rawValue) \(width)x\(height), width \(percent)")
            }
        }
        }
    }

    func testStandardAndPlaqueWidthSettingsChangeExportMargins() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in }
        for preset: PhotoFramePreset in [.mist, .cinema, .minimal, .frosted, .plaque] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset); settings.watermark.enabled = false
            var sizes: [CGSize] = []
            for percent in [60, 100, 200] {
                settings.metadata.widthPercent = percent
                sizes.append(try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty).size)
            }
            XCTAssertLessThan(sizes[0].height, sizes[1].height, preset.rawValue)
            XCTAssertLessThan(sizes[1].height, sizes[2].height, preset.rawValue)
            if preset == .plaque {
                XCTAssertTrue(sizes.allSatisfy { $0.width == 320 })
            } else {
                XCTAssertLessThan(sizes[0].width, sizes[1].width, preset.rawValue)
                XCTAssertLessThan(sizes[1].width, sizes[2].width, preset.rawValue)
            }
        }
    }

    func testPosterLongExposureExpandsWidthAcrossOrientationsAndFrameWidths() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 160, height: 120), CGSize(width: 120, height: 160), CGSize(width: 240, height: 40), CGSize(width: 40, height: 240)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = .parameterPoster
            settings.metadata = .defaults(for: .parameterPoster); settings.metadata.showExposure = true
            settings.watermark.enabled = false
            func camera(_ long: Bool) -> PhotoFrameMetadata {
                PhotoFrameMetadata(make: "SONY", model: "A7", lensModel: nil, focalLength: nil, aperture: nil,
                    shutter: long ? String(repeating: "1234567890", count: 10) : "1/125", iso: nil,
                    exposureCompensation: nil, dateTime: nil)
            }
            for percent in [60, 100, 200] {
                settings.metadata.widthPercent = percent
                let short = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(false))
                let long = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(true))
                XCTAssertGreaterThan(long.size.width, short.size.width, "\(size) \(percent)")
                let preview = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(true), previewLongEdge: 256)
                let scale = 256 / max(long.size.width, long.size.height)
                XCTAssertEqual(preview.size.width, (long.size.width * scale).rounded(), accuracy: 1)
                XCTAssertEqual(preview.size.height, (long.size.height * scale).rounded(), accuracy: 1)
            }
        }
    }

    func testEmptyPortraitPosterReleasesUnusedColumnWithoutThresholdJump() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image { _ in }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .parameterPoster
        settings.metadata = .defaults(for: .parameterPoster); settings.watermark.enabled = false
        for (percent, expectedWidth) in [(60, 152), (65, 169), (95, 264), (100, 279), (200, 332)] {
            settings.metadata.widthPercent = percent
            let result = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
            XCTAssertEqual(result.size.width, CGFloat(expectedWidth), "\(percent)")
        }
    }

    func testPosterLongFieldTailsRemainVisibleInBothOrientations() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 320, height: 240), CGSize(width: 240, height: 320)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = .parameterPoster
            settings.metadata = .defaults(for: .parameterPoster)
            settings.metadata.showModel = true; settings.metadata.showLensModel = true
            settings.metadata.showExposure = true; settings.metadata.showCity = true
            settings.watermark.enabled = false
            for field in ["model", "lens", "shutter", "city"] {
                func output(_ tail: String) throws -> Data? {
                    let text = String(repeating: "Long value ", count: 30) + tail
                    let camera = PhotoFrameMetadata(make: "SONY", model: field == "model" ? text : "A7",
                        lensModel: field == "lens" ? text : nil, focalLength: nil, aperture: nil,
                        shutter: field == "shutter" ? text : nil, iso: nil, exposureCompensation: nil,
                        dateTime: nil, city: field == "city" ? text : nil)
                    return try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera).pngData()
                }
                XCTAssertNotEqual(try output("AAA"), try output("ZZZ"), "\(field) \(size)")
            }
        }
    }

    func testPosterAllLocationAndLongIdentityFieldsAtNarrowAndWideBorders() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 160, height: 120), CGSize(width: 120, height: 160)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = .parameterPoster
            settings.metadata = .defaults(for: .parameterPoster)
            settings.metadata.showBrand = true; settings.metadata.showModel = true; settings.metadata.showLensModel = true
            settings.metadata.showCity = true; settings.metadata.showRegion = true
            settings.metadata.showCoordinates = true; settings.metadata.showAltitude = true
            settings.watermark.enabled = false
            for percent in [60, 200] {
                settings.metadata.widthPercent = percent
                func output(_ field: String, alternate: Bool, duplicateRegion: Bool = true) throws -> Data? {
                    let long = String(repeating: "Long description ", count: 18) + (alternate ? "ZZZ" : "AAA")
                    let camera = PhotoFrameMetadata(make: field == "brand" ? long : "SONY",
                        model: field == "model" ? long : "A7", lensModel: field == "lens" ? long : "Lens",
                        focalLength: "35mm", aperture: "f/2.8", shutter: "1/125", iso: "ISO 400",
                        exposureCompensation: nil, dateTime: nil,
                        latitude: field == "latitude" && alternate ? 32 : 42,
                        longitude: field == "longitude" && alternate ? 110 : 120,
                        altitude: field == "altitude" && alternate ? 200 : 800,
                        city: field == "city" ? long : "Tokyo",
                        region: field == "region" ? long : duplicateRegion ? "Tokyo" : nil)
                    return try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera).pngData()
                }
                for field in ["brand", "model", "lens", "city", "region", "latitude", "longitude", "altitude"] {
                    XCTAssertNotEqual(try output(field, alternate: false), try output(field, alternate: true), "\(field) \(size) \(percent)")
                }
                XCTAssertEqual(try output("duplicate", alternate: false), try output("duplicate", alternate: false, duplicateRegion: false))
            }
        }
    }

    func testFilmIdentitySeparatorIsPreservedWithTextAndMissingFields() {
        let font = UIFont.monospacedSystemFont(ofSize: 20, weight: .bold)
        func row(_ value: PhotoFrameMetadata, separator: String) -> PhotoFrameTextRow {
            PhotoEffectsRenderer.cameraIdentityRow(value, font: font, color: .black, separator: separator)
        }
        func width(_ text: String) -> CGFloat {
            PhotoFrameTextRow(NSAttributedString(string: text, attributes: [.font: font])).width
        }
        let camera = metadata(make: "Nikon", model: "Z 8")
        XCTAssertEqual(row(camera, separator: " · ").width - row(camera, separator: " ").width,
            width(" · Z 8") - width(" Z 8"), accuracy: 0.001)
        for value in [metadata(make: "Nikon", model: nil), metadata(make: nil, model: "Z 8"), .empty] {
            XCTAssertEqual(row(value, separator: " · ").width, row(value, separator: " ").width, accuracy: 0.001)
        }
        XCTAssertEqual(row(metadata(make: "其他", model: "型号😀"), separator: " · ").width,
            width("其他 · 型号😀"), accuracy: 0.001)
    }

    func testFilmFrameNumberMatchesAndroidUTF16HashVectors() {
        XCTAssertEqual(PhotoEffectsRenderer.stableFilmFrameNumber(.empty), 1)
        XCTAssertEqual(PhotoEffectsRenderer.stableFilmFrameNumber(metadata(make: "SONY", model: "A7")), 986)
        let unicode = PhotoFrameMetadata(make: "尼康", model: "Z 8", lensModel: "镜头😀", focalLength: "35mm",
            aperture: nil, shutter: "1/125", iso: "ISO400", exposureCompensation: nil, dateTime: "2026/10/16")
        XCTAssertEqual(PhotoEffectsRenderer.stableFilmFrameNumber(unicode), 340)
        for (text, expected) in [("😀", 674), ("Aa", 115), ("BB", 115)] {
            let camera = PhotoFrameMetadata(make: text, model: nil, lensModel: nil, focalLength: nil,
                aperture: "f/2.8", shutter: nil, iso: nil, exposureCompensation: "+1", dateTime: nil)
            XCTAssertEqual(PhotoEffectsRenderer.stableFilmFrameNumber(camera), expected)
        }
    }

    func testPosterExposureOnlyRemovesLeadingPrefixesAndOmitsBlankFields() {
        func exposure(_ aperture: String?, _ iso: String?) -> [(label: String, value: String)] {
            PhotoEffectsRenderer.parameterPosterExposure(PhotoFrameMetadata(make: nil, model: nil, lensModel: nil,
                focalLength: " ", aperture: aperture, shutter: "1/125", iso: iso,
                exposureCompensation: nil, dateTime: nil))
        }
        let normal = exposure("F2.8", "iso  400")
        XCTAssertEqual(normal.map(\.label), ["F", "ISO", "S"])
        XCTAssertEqual(normal.map(\.value), ["2.8", "400", "1/125"])
        let embedded = exposure("f/2.8 f/4", "ISO 400 ISO 800")
        XCTAssertEqual(embedded.map(\.value), ["2.8 f/4", "400 ISO 800", "1/125"])
        let blank = exposure("\n", nil)
        XCTAssertEqual(blank.map(\.label), ["S"])
    }

    func testPlaqueIdentityUsesRawLabelsAndAndroidFallbackOrder() {
        let cases: [(String?, String?, String?, String?, String?)] = [
            (" Nikon Corporation ", " NIKON Z 8 ", " Lens ", "NIKON CORPORATION", "NIKON Z 8 · Lens"),
            ("sony", "SoNy", "Lens", "SONY", "Lens"),
            (nil, "Model", "Lens", "Model", "Lens"),
            (nil, "Lens", "Lens", "Lens", nil),
            (" ", nil, " Lens ", "Lens", nil),
            (nil, nil, nil, nil, nil),
        ]
        for (make, model, lens, primary, secondary) in cases {
            let camera = PhotoFrameMetadata(make: make, model: model, lensModel: lens,
                focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
            let labels = PhotoEffectsRenderer.plaqueIdentityLabels(camera)
            XCTAssertEqual(labels.primary, primary)
            XCTAssertEqual(labels.secondary, secondary)
        }
    }

    func testStandardPlaqueAndGalleryLongIdentityTailReachesExportAndPreview() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for size in [CGSize(width: 240, height: 160), CGSize(width: 160, height: 240)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.gray.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            for preset: PhotoFramePreset in [.mist, .cinema, .minimal, .frosted, .plaque, .galleryMat, .filmGallery] {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true; settings.photoFramePreset = preset
                settings.metadata = .defaults(for: preset)
                settings.metadata.showBrand = false; settings.metadata.showModel = true
                settings.watermark.enabled = false
                let prefix = String(repeating: "Long Camera Model ", count: 25)
                for percent in [60, 100, 200] {
                    settings.metadata.widthPercent = percent
                    for edge: CGFloat? in [nil, 512] {
                        let first = try PhotoEffectsRenderer.render(source, settings: settings,
                            metadata: metadata(make: "", model: prefix + "AAA"), previewLongEdge: edge)
                        let second = try PhotoEffectsRenderer.render(source, settings: settings,
                            metadata: metadata(make: "", model: prefix + "ZZZ"), previewLongEdge: edge)
                        XCTAssertEqual(first.size, second.size, "Tail fixture must preserve geometry")
                        let firstPixels = try XCTUnwrap(first.pngData())
                        let secondPixels = try XCTUnwrap(second.pngData())
                        XCTAssertNotEqual(firstPixels, secondPixels,
                            "Tail lost: \(preset.rawValue), \(size), width \(percent), preview \(String(describing: edge))")
                    }
                }
            }
        }
    }

    func testMeasuredTextWidthIncludesItalicInkAndScalesConsistently() throws {
        let font = try XCTUnwrap(UIFont(name: "HelveticaNeue-Italic", size: 40))
        var sawOverhang = false
        for text in ["f", "j", "Af", "ffj", "Áf"] {
            let row = PhotoFrameTextRow(NSAttributedString(string: text,
                attributes: [.font: font, .foregroundColor: UIColor.black]))
            let expected = max(row.width, row.bounds.maxX) - min(0, row.bounds.minX)
            XCTAssertEqual(row.layoutWidth, expected, accuracy: 0.0001)
            if row.layoutWidth > row.width { sawOverhang = true }
            XCTAssertEqual(row.scaled(by: 0.25).layoutWidth, expected * 0.25, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(row.fitting(width: expected / 2).layoutWidth, expected / 2 + 0.0001)
        }
        XCTAssertTrue(sawOverhang, "Fixture must exercise ink outside typographic advance")
    }

    func testFrostedKeepsPhotoWidthAndRejectsUnbreakableColumnOverflow() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 161, height: 121), format: format).image { _ in }
        let cluster = String(repeating: "क्", count: 80) + "क"
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .frosted
        settings.metadata = .defaults(for: .frosted); settings.metadata.showModel = true
        settings.watermark.enabled = false
        for percent in [60, 100, 200] {
            settings.metadata.widthPercent = percent
            let short = try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata(make: "", model: "A7"))
            let long = try PhotoEffectsRenderer.render(source, settings: settings,
                metadata: metadata(make: "", model: String(repeating: "Long Model ", count: 40)))
            XCTAssertEqual(long.size.width, short.size.width)
            XCTAssertGreaterThan(long.size.height, short.size.height)
            for previewEdge: CGFloat? in [nil, 128] {
                XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings,
                    metadata: metadata(make: "", model: cluster), previewLongEdge: previewEdge)) { error in
                    XCTAssertTrue(error is PhotoFrameColumnOverflow)
                }
            }
        }
    }

    func testMeasuredCaptionsExpandUnbreakableTextWithoutShrinking() throws {
        let cluster = String(repeating: "क्", count: 160) + "क"
        XCTAssertEqual(cluster.count, 1)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for preset: PhotoFramePreset in [.galleryMat, .filmGallery, .filmNegative, .filmEdge, .classicSignature, .brandGallery, .colorArchive] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.metadata.showModel = true; settings.metadata.showBrand = false
            settings.metadata.showLensModel = true
            func camera(_ value: String) -> PhotoFrameMetadata {
                guard preset == .filmNegative else { return metadata(make: "", model: value) }
                return PhotoFrameMetadata(make: nil, model: nil, lensModel: value,
                    focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
            }
            settings.watermark.enabled = false
            for size in [CGSize(width: 161, height: 121), CGSize(width: 121, height: 161), CGSize(width: 320, height: 40), CGSize(width: 40, height: 320)] {
                let source = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
                for percent in [60, 100, 200] {
                    settings.metadata.widthPercent = percent
                    let normal = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera("A7"))
                    let expanded = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(cluster))
                    if max(size.width, size.height) / min(size.width, size.height) > 4 {
                        // Existing extreme-aspect margins can absorb the measured extra width.
                        XCTAssertGreaterThanOrEqual(expanded.size.width, normal.size.width)
                    } else {
                        XCTAssertGreaterThan(expanded.size.width, normal.size.width)
                    }
                    if preset == .galleryMat { XCTAssertEqual(expanded.size.width, expanded.size.height) }
                    let preview = try PhotoEffectsRenderer.render(source, settings: settings,
                        metadata: camera(cluster), previewLongEdge: 128)
                    let scale = 128 / max(expanded.size.width, expanded.size.height)
                    XCTAssertEqual(preview.size.width, (expanded.size.width * scale).rounded())
                    XCTAssertEqual(preview.size.height, (expanded.size.height * scale).rounded())
                }
            }
        }
    }

    func testMeasuredCaptionWidthNormalizationMatchesExportBoundaries() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { _ in }
        for preset: PhotoFramePreset in [.galleryMat, .filmGallery, .filmNegative, .filmEdge, .classicSignature, .brandGallery, .colorArchive] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset); settings.watermark.enabled = false
            func render(_ percent: Int) throws -> Data {
                settings.metadata.widthPercent = percent
                return try XCTUnwrap(PhotoEffectsRenderer.render(source, settings: settings,
                    metadata: metadata(make: "SONY", model: "A7")).pngData())
            }
            let minimum = try render(60)
            XCTAssertEqual(try render(-100), minimum, preset.rawValue)
            XCTAssertEqual(try render(20), minimum, preset.rawValue)
            XCTAssertEqual(try render(300), try render(200), preset.rawValue)
        }
    }

    func testStandardUnbreakableIdentityExpandsCanvasAtFixedReferenceFont() throws {
        let cluster = String(repeating: "क्", count: 80) + "क"
        let camera = metadata(make: "", model: cluster)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 161, height: 121), format: format).image { _ in }
        for preset: PhotoFramePreset in [.mist, .cinema, .minimal] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset); settings.metadata.showModel = true
            settings.watermark.enabled = false
            for percent in [60, 100, 200] {
                settings.metadata.widthPercent = percent
                let normal = try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata(make: "", model: "A7"))
                let expanded = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera)
                XCTAssertGreaterThan(expanded.size.width, normal.size.width, preset.rawValue)
                let preview = try PhotoEffectsRenderer.render(source, settings: settings,
                    metadata: camera, previewLongEdge: 128)
                let scale = 128 / max(expanded.size.width, expanded.size.height)
                XCTAssertEqual(preview.size.width, (expanded.size.width * scale).rounded())
                XCTAssertEqual(preview.size.height, (expanded.size.height * scale).rounded())
            }
        }
    }

    func testPlaqueUnbreakableTextExpandsColumnsWithoutScalingPhoto() throws {
        let cluster = String(repeating: "क्", count: 80) + "क"
        XCTAssertEqual(cluster.count, 1)
        let camera = PhotoFrameMetadata(make: nil, model: cluster, lensModel: nil,
            focalLength: "50mm", aperture: "f/2", shutter: "1/100", iso: "ISO 100",
            exposureCompensation: nil, dateTime: "2026/10/17")
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .plaque
        settings.metadata = .defaults(for: .plaque)
        settings.watermark.text = cluster; settings.watermark.position = .left
        settings.watermark.sizePercent = PhotoFrameWatermark.sizeRange.upperBound
        let plan = PhotoEffectsRenderer.makePlaquePlan(width: 320, metadata: camera,
            watermark: settings.watermark, settings: settings.metadata)
        XCTAssertGreaterThan(plan.extraWidth, 0)
        XCTAssertGreaterThanOrEqual(plan.leftWidth, plan.left.map(\.width).max() ?? 0)
        XCTAssertEqual(plan.rightX - plan.leftWidth, 320 * (0.60 - 0.46), accuracy: 0.001)
        let scaled = plan.scaled(by: 0.5)
        XCTAssertEqual(scaled.extraWidth, plan.extraWidth * 0.5, accuracy: 0.001)
        XCTAssertEqual(scaled.signatureWidth, plan.signatureWidth * 0.5, accuracy: 0.001)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in }
        let output = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera)
        XCTAssertEqual(output.size.width, ceil(320 + plan.extraWidth))
        XCTAssertGreaterThan(output.size.height, source.size.height)
    }

    func testPlaqueOverflowPreservesOddSizedPhotoPixelsAndPreviewProportions() throws {
        let cluster = String(repeating: "क्", count: 80) + "क"
        let camera = PhotoFrameMetadata(make: nil, model: cluster, lensModel: nil,
            focalLength: cluster, aperture: "f/2", shutter: "1/100", iso: "ISO 100",
            exposureCompensation: nil, dateTime: "2026/10/17")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func rgba(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        for (width, height) in [(81, 61), (61, 81)] {
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    pixels[index] = UInt8(40 + x * 2)
                    pixels[index + 1] = UInt8(30 + y * 2)
                    pixels[index + 2] = (x + y).isMultiple(of: 2) ? 80 : 190
                }
            }
            let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let original = try XCTUnwrap(context.makeImage())
            let source = UIImage(cgImage: original)
            let interior = CGRect(x: 8, y: 8, width: width - 16, height: height - 16)
            let expected = try rgba(XCTUnwrap(original.cropping(to: interior)))
            for percent in [60, 100, 200] {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true; settings.photoFramePreset = .plaque
                settings.metadata = .defaults(for: .plaque); settings.metadata.widthPercent = percent
                settings.watermark.enabled = false
                let output = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera)
                let rendered = try XCTUnwrap(output.cgImage)
                XCTAssertGreaterThan(rendered.width, width)
                let photoX = floor(CGFloat(rendered.width - width) / 2)
                let crop = try XCTUnwrap(rendered.cropping(to: interior.offsetBy(dx: photoX, dy: 0)))
                XCTAssertEqual(try rgba(crop), expected, "Photo pixels changed at \(width)x\(height), width \(percent)")
                let preview = try PhotoEffectsRenderer.render(source, settings: settings,
                    metadata: camera, previewLongEdge: 128)
                let scale = 128 / max(output.size.width, output.size.height)
                XCTAssertEqual(preview.size.width, (output.size.width * scale).rounded())
                XCTAssertEqual(preview.size.height, (output.size.height * scale).rounded())
            }
        }
    }

    func testPlaqueSignatureStaysInLeftColumnWhenRightColumnIsTaller() throws {
        let camera = PhotoFrameMetadata(make: "SONY", model: "A7", lensModel: nil,
            focalLength: String(repeating: "Long exposure details ", count: 60), aperture: nil,
            shutter: nil, iso: nil, exposureCompensation: nil, dateTime: "2026/10/16")
        let settings = PhotoFrameMetadataSettings.defaults(for: .plaque)
        var watermark = PhotoFrameWatermark()
        watermark.text = "Signature"; watermark.position = .left
        let left = PhotoEffectsRenderer.makePlaquePlan(width: 1000, metadata: camera, watermark: watermark, settings: settings)
        XCTAssertNotNil(left.leftWatermarkStart)
        XCTAssertTrue(left.signature.isEmpty)
        XCTAssertGreaterThan(left.height(left.right), left.height(left.left))
        XCTAssertEqual(left.contentHeight, left.height(left.right), accuracy: 0.001)
        watermark.position = .right
        let footer = PhotoEffectsRenderer.makePlaquePlan(width: 1000, metadata: camera, watermark: watermark, settings: settings)
        XCTAssertNil(footer.leftWatermarkStart)
        XCTAssertFalse(footer.signature.isEmpty)
        XCTAssertGreaterThan(footer.contentHeight, footer.infoHeight)
        for scale: CGFloat in [0.128, 0.512, 2] {
            let preview = left.scaled(by: scale)
            XCTAssertEqual(preview.leftWatermarkStart, left.leftWatermarkStart)
            XCTAssertEqual(preview.left.count, left.left.count)
            XCTAssertEqual(preview.right.count, left.right.count)
            XCTAssertEqual(preview.contentHeight, left.contentHeight * scale, accuracy: 0.001)
            XCTAssertEqual(preview.rightX, left.rightX * scale, accuracy: 0.001)
        }
    }

    func testPlaqueAutomaticTextWatermarkMatchesLeftAndCanBeDisabled() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .plaque
        settings.metadata = .defaults(for: .plaque)
        settings.watermark.enabled = true; settings.watermark.text = "Visible signature"
        settings.watermark.position = .auto
        let automatic = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty).pngData()
        settings.watermark.position = .left
        let left = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty).pngData()
        XCTAssertEqual(automatic, left)
        settings.watermark.enabled = false
        let disabled = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty).pngData()
        XCTAssertNotEqual(automatic, disabled)
    }

    func testLargeStandardWatermarkKeepsAlignmentAndTail() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        for preset: PhotoFramePreset in [.mist, .cinema, .minimal, .frosted, .brandGallery] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.watermark.font = .bold; settings.watermark.sizePercent = 300
            settings.watermark.effect = .shadow
            func render(_ position: PhotoFrameWatermarkPosition, tail: String) throws -> Data? {
                settings.watermark.position = position
                settings.watermark.text = String(repeating: "W", count: 20) + tail
                return try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty).pngData()
            }
            let left = try render(.left, tail: "ABC")
            XCTAssertNotEqual(left, try render(.right, tail: "ABC"), preset.rawValue)
            XCTAssertNotEqual(left, try render(.left, tail: "XYZ"), preset.rawValue)
        }
    }

    func testMeasuredCaptionSignaturesPreserveTailAndDisableState() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let camera = metadata(make: "NIKON", model: String(repeating: "Long Model ", count: 25))
        for size in [CGSize(width: 240, height: 160), CGSize(width: 160, height: 240), CGSize(width: 320, height: 40), CGSize(width: 40, height: 320)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.gray.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            for preset: PhotoFramePreset in [.galleryMat, .filmGallery, .filmNegative] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.metadata.showBrand = true; settings.metadata.showModel = true
            settings.metadata.brandStyle = .logo
            settings.watermark.enabled = true; settings.watermark.sizePercent = 300
            for percent in [60, 100, 200] {
                settings.metadata.widthPercent = percent
                for edge: CGFloat? in [nil, 512] {
                    func render(_ position: PhotoFrameWatermarkPosition, tail: String) throws -> UIImage {
                        settings.watermark.position = position
                        settings.watermark.text = String(repeating: "W", count: 20) + tail
                        return try PhotoEffectsRenderer.render(source, settings: settings,
                            metadata: camera, previewLongEdge: edge)
                    }
                    settings.watermark.enabled = true
                    let automatic = try render(.auto, tail: "AAA")
                    XCTAssertEqual(automatic.pngData(), try render(.center, tail: "AAA").pngData())
                    let left = try render(.left, tail: "AAA")
                    let right = try render(.right, tail: "AAA")
                    XCTAssertEqual(left.size, right.size)
                    XCTAssertNotEqual(left.pngData(), right.pngData())
                    let changedTail = try render(.left, tail: "ZZZ")
                    XCTAssertEqual(left.size, changedTail.size)
                    XCTAssertNotEqual(left.pngData(), changedTail.pngData())
                    settings.watermark.enabled = false
                    let disabled = try render(.left, tail: "AAA")
                    XCTAssertNotEqual(disabled.pngData(), left.pngData())
                    XCTAssertEqual(disabled.pngData(), try render(.right, tail: "ZZZ").pngData())
                    if preset == .galleryMat { XCTAssertEqual(disabled.size.width, disabled.size.height) }
                }
            }
        }
        }
    }

    func testBrandGalleryWatermarkSizeChangesOutputAndPreservesPreview() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .brandGallery
        settings.metadata = .defaults(for: .brandGallery)
        settings.metadata.widthPercent = 20
        settings.watermark.enabled = true; settings.watermark.position = .left
        settings.watermark.text = String(repeating: "W", count: 24)
        settings.watermark.sizePercent = 100
        let small = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
        settings.watermark.sizePercent = 300
        let large = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
        XCTAssertEqual(small.size.width, large.size.width)
        XCTAssertNotEqual(large.pngData(), small.pngData())
        let preview = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty, previewLongEdge: 512)
        let scale = 512 / max(large.size.width, large.size.height)
        XCTAssertEqual(preview.size.width, (large.size.width * scale).rounded(), accuracy: 1)
        XCTAssertEqual(preview.size.height, (large.size.height * scale).rounded(), accuracy: 1)
        settings.watermark.enabled = false
        let hiddenLarge = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
        settings.watermark.sizePercent = 100
        let hiddenSmall = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
        XCTAssertEqual(hiddenLarge.pngData(), hiddenSmall.pngData())
    }

    func testStandardPlanMeasuresAllLongContentBeforeDrawing() {
        var settings = PhotoFrameMetadataSettings.defaults(for: .minimal)
        settings.showBrand = true; settings.showModel = true; settings.brandStyle = .logo
        var watermark = PhotoFrameWatermark()
        watermark.sizePercent = 300; watermark.font = .bold
        watermark.text = String(repeating: "W", count: 24)
        let area = CGRect(x: 0, y: 0, width: 1000, height: 100)
        func plan(_ model: String) -> PhotoEffectsRenderer.MetadataRowsPlan {
            PhotoEffectsRenderer.standardMetadataPlan(area: area, canvasWidth: 1000, preset: .minimal,
                metadata: metadata(make: "SONY", model: model), watermark: watermark, settings: settings, lightText: false)
        }
        let short = plan("A7")
        let long = plan(String(repeating: "Long Model ", count: 40))
        XCTAssertGreaterThan(long.inkHeight, short.inkHeight)
        XCTAssertGreaterThan(long.inkHeight, area.height)
        XCTAssertGreaterThan(long.rows.count, short.rows.count)
        XCTAssertNotNil(long.watermarkIndex)
        if let start = long.watermarkIndex { XCTAssertGreaterThan(long.rows.count - start, 1) }
    }

    func testLongStandardMetadataExpandsCanvasAndBudgetTogether() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { _ in }
        for preset: PhotoFramePreset in [.mist, .cinema, .minimal, .frosted, .galleryMat, .filmGallery, .filmEdge, .colorArchive, .brandGallery, .plaque, .parameterPoster] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset); settings.metadata.showModel = true
            settings.watermark.enabled = false
            let short = metadata(make: "SONY", model: "A7")
            let long = metadata(make: "SONY", model: String(repeating: "Long Model ", count: 160))
            let first = try PhotoEffectsRenderer.render(source, settings: settings, metadata: short)
            let second = try PhotoEffectsRenderer.render(source, settings: settings, metadata: long)
            if preset == .galleryMat {
                XCTAssertEqual(first.size.width, first.size.height)
                XCTAssertEqual(second.size.width, second.size.height)
                XCTAssertGreaterThan(second.size.width, first.size.width)
            } else {
                XCTAssertEqual(first.size.width, second.size.width)
            }
            XCTAssertGreaterThan(second.size.height, first.size.height, preset.rawValue)
            func required(_ metadata: PhotoFrameMetadata) throws -> Int64 {
                do {
                    _ = try PhotoEffectsRenderer.render(source, settings: settings, metadata: metadata, availableMemory: { 0 })
                    XCTFail("Expected memory rejection"); return 0
                } catch let rejection as PhotoAllocationRejected { return rejection.required }
            }
            XCTAssertGreaterThan(try required(long), try required(short), preset.rawValue)
        }
    }

    func testExpandedPreviewFitsRequestedLongEdgeAndExportAspect() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { _ in }
        for preset: PhotoFramePreset in [.mist, .cinema, .minimal, .frosted, .parameterPoster, .galleryMat, .filmGallery, .filmEdge, .colorArchive, .brandGallery, .plaque] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset); settings.metadata.showModel = true
            let camera = metadata(make: "SONY", model: String(repeating: "Long Model ", count: 20))
            let original = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera)
            for target: CGFloat in [128, 512] {
                let preview = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera, previewLongEdge: target)
                XCTAssertEqual(max(preview.size.width, preview.size.height), target)
                let scale = target / max(original.size.width, original.size.height)
                XCTAssertEqual(preview.size.width, (original.size.width * scale).rounded(), accuracy: 1)
                XCTAssertEqual(preview.size.height, (original.size.height * scale).rounded(), accuracy: 1)
            }
        }
    }

    func testPreviewPlanScalingPreservesRowsAndWatermarkBoundary() {
        var watermark = PhotoFrameWatermark(); watermark.sizePercent = 300
        watermark.text = String(repeating: "W", count: 24)
        var settings = PhotoFrameMetadataSettings.defaults(for: .minimal)
        settings.showBrand = true; settings.showModel = true; settings.brandStyle = .logo
        let plan = PhotoEffectsRenderer.standardMetadataPlan(area: CGRect(x: 0, y: 0, width: 1000, height: 200),
            canvasWidth: 1000, preset: .minimal, metadata: metadata(make: "SONY", model: String(repeating: "Model ", count: 30)),
            watermark: watermark, settings: settings, lightText: false)
        for scale: CGFloat in [0.128, 0.512, 2] {
            let preview = plan.scaled(by: scale)
            XCTAssertEqual(preview.rows.count, plan.rows.count)
            XCTAssertEqual(preview.watermarkIndex, plan.watermarkIndex)
            XCTAssertEqual(preview.inkHeight, plan.inkHeight * scale, accuracy: 0.001)
            for (original, scaled) in zip(plan.rows, preview.rows) {
                XCTAssertEqual(scaled.width, original.width * scale, accuracy: 0.001)
                XCTAssertEqual(scaled.bounds.minY, original.bounds.minY * scale, accuracy: 0.001)
            }
        }
    }

    func testFilmStripPreviewPreservesPlacementDecisionsAndInkSize() throws {
        let settings = PhotoFrameMetadataSettings.defaults(for: .filmGallery)
        for longIdentity in [false, true] {
            for longDate in [false, true] {
                let camera = PhotoFrameMetadata(make: "SONY", model: longIdentity ? String(repeating: "Model ", count: 100) : "A7",
                    lensModel: nil, focalLength: nil, aperture: nil, shutter: nil, iso: nil,
                    exposureCompensation: nil, dateTime: longDate ? String(repeating: "2026/10/16 ", count: 100) : "2026/10/16")
                let original = PhotoEffectsRenderer.FilmStripPlan(metadata: camera, settings: settings, width: 1000)
                XCTAssertEqual(original.identity == nil, longIdentity)
                XCTAssertEqual(original.date == nil, longDate)
                for scale: CGFloat in [0.01, 0.128, 0.512, 2] {
                    let preview = original.scaled(by: scale)
                    XCTAssertEqual(preview.identity == nil, longIdentity)
                    XCTAssertEqual(preview.date == nil, longDate)
                    for (source, scaled) in [(original.identity, preview.identity), (original.date, preview.date)] {
                        if let source {
                            let scaled = try XCTUnwrap(scaled)
                            XCTAssertEqual(scaled.width, source.width * scale, accuracy: 0.001)
                            XCTAssertEqual(scaled.bounds.height, source.bounds.height * scale, accuracy: 0.001)
                        }
                    }
                }
            }
        }
    }

    func testFilmStripDateUsesMeasuredWidthAndMissingDateStaysEmpty() {
        for width: CGFloat in [160, 1000] {
            XCTAssertNotNil(PhotoEffectsRenderer.filmStripDateRow("2026/10/16", width: width))
            XCTAssertNil(PhotoEffectsRenderer.filmStripDateRow(String(repeating: "2026/10/16 ", count: 20), width: width))
            XCTAssertNil(PhotoEffectsRenderer.filmStripDateRow(nil, width: width))
            XCTAssertNil(PhotoEffectsRenderer.filmStripDateRow(" \n ", width: width))
        }
    }

    func testEditorialLongDescriptionTailRemainsInOutput() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in }
        for preset: PhotoFramePreset in [.galleryMat, .filmGallery, .classicSignature, .filmEdge, .filmNegative] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset); settings.metadata.showLensModel = true
            settings.watermark.text = String(repeating: "W", count: 24)
            settings.watermark.sizePercent = 300; settings.watermark.position = .right
            func render(_ suffix: String) throws -> Data? {
                let camera = PhotoFrameMetadata(make: "SONY", model: "A7", lensModel: String(repeating: "Long lens ", count: 8) + suffix,
                    focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
                return try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera).pngData()
            }
            XCTAssertNotEqual(try render("AAA"), try render("ZZZ"), preset.rawValue)
        }
    }

    func testFilmNegativeMetadataChangesReachLowerBandAndRespectVisibility() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in }
        let fields = ["lens", "focal", "aperture", "shutter", "iso", "date", "coordinates", "altitude", "city", "region"]
        for field in fields {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = .filmNegative
            settings.metadata = .defaults(for: .filmNegative)
            settings.watermark.enabled = false
            func camera(_ alternate: Bool) -> PhotoFrameMetadata {
                PhotoFrameMetadata(make: "SONY", model: "A7", lensModel: field == "lens" ? (alternate ? "ZZZ" : "AAA") : nil,
                    focalLength: field == "focal" ? (alternate ? "85mm" : "35mm") : nil,
                    aperture: field == "aperture" ? (alternate ? "f/8" : "f/2") : nil,
                    shutter: field == "shutter" ? (alternate ? "1/250" : "1/60") : nil,
                    iso: field == "iso" ? (alternate ? "ISO800" : "ISO100") : nil, exposureCompensation: nil,
                    dateTime: field == "date" ? (alternate ? "2026:10:16 12:00:00" : "2025:10:16 12:00:00") : nil,
                    latitude: field == "coordinates" ? (alternate ? 32 : 42) : nil,
                    longitude: field == "coordinates" ? 120 : nil,
                    altitude: field == "altitude" ? (alternate ? 200 : 800) : nil,
                    city: field == "city" ? (alternate ? "Paris" : "Tokyo") : nil,
                    region: field == "region" ? (alternate ? "France" : "Japan") : nil)
            }
            for visible in [true, false] {
                settings.metadata.showLensModel = visible
                settings.metadata.showFocalLength = visible; settings.metadata.showExposure = visible
                settings.metadata.showDate = visible; settings.metadata.showTime = visible
                settings.metadata.showCoordinates = visible; settings.metadata.showAltitude = visible
                settings.metadata.showCity = visible; settings.metadata.showRegion = visible
                func band(_ alternate: Bool) throws -> Data? {
                    let image = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(alternate))
                    let cg = try XCTUnwrap(image.cgImage)
                    // Exclude the top identity/frame number, whose hash also depends on metadata.
                    let region = CGRect(x: 0, y: cg.height / 2, width: cg.width, height: cg.height - cg.height / 2)
                    return UIImage(cgImage: try XCTUnwrap(cg.cropping(to: region))).pngData()
                }
                if visible { XCTAssertNotEqual(try band(false), try band(true), field) }
                else { XCTAssertEqual(try band(false), try band(true), field) }
            }
        }
    }

    func testNarrowFilmFramesKeepUnicodeDescriptionTailAndPreviewExtent() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in }
        for preset: PhotoFramePreset in [.filmNegative, .filmEdge] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.metadata.widthPercent = 60; settings.metadata.showLensModel = true
            settings.watermark.enabled = false
            let empty = try PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty)
            func camera(_ tail: String) -> PhotoFrameMetadata {
                PhotoFrameMetadata(make: nil, model: nil,
                    lensModel: String(repeating: "长镜头😀描述 ", count: 100) + tail,
                    focalLength: nil, aperture: nil, shutter: nil, iso: nil,
                    exposureCompensation: nil, dateTime: nil)
            }
            let first = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera("AAA"))
            let second = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera("ZZZ"))
            XCTAssertGreaterThan(first.size.height, empty.size.height, preset.rawValue)
            XCTAssertEqual(first.size, second.size)
            func lowerText(_ image: UIImage) throws -> Data? {
                let cg = try XCTUnwrap(image.cgImage)
                // Exclude top and side frame numbers: only the final description can change here.
                let rect = CGRect(x: cg.width / 8, y: cg.height * 3 / 4,
                    width: cg.width * 3 / 4, height: cg.height - cg.height * 3 / 4)
                return UIImage(cgImage: try XCTUnwrap(cg.cropping(to: rect))).pngData()
            }
            XCTAssertNotEqual(try lowerText(first), try lowerText(second), preset.rawValue)
            for value in [PhotoFrameMetadata.empty, camera("AAA")] {
                let full = try PhotoEffectsRenderer.render(source, settings: settings, metadata: value)
                let preview = try PhotoEffectsRenderer.render(source, settings: settings, metadata: value, previewLongEdge: 512)
                let scale = 512 / max(full.size.width, full.size.height)
                XCTAssertEqual(preview.size.width, (full.size.width * scale).rounded(), accuracy: 1)
                XCTAssertEqual(preview.size.height, (full.size.height * scale).rounded(), accuracy: 1)
            }
        }
    }

    func testClassicLongDescriptionExpandsExportAndPreviewTogether() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { _ in }
        var settings = PhotoEffectsSettings()
        func camera(_ count: Int) -> PhotoFrameMetadata {
            PhotoFrameMetadata(make: "SONY", model: "A7", lensModel: String(repeating: "Long lens ", count: count),
                focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
        }
        for preset: PhotoFramePreset in [.classicSignature, .filmNegative] {
        settings.photoFrameEnabled = true; settings.photoFramePreset = preset
        settings.metadata = .defaults(for: preset); settings.metadata.showLensModel = true
        settings.watermark.enabled = false
        let short = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(1))
        let long = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(160))
        XCTAssertEqual(short.size.width, long.size.width)
        XCTAssertGreaterThan(long.size.height, short.size.height)
        let preview = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera(160), previewLongEdge: 512)
        XCTAssertEqual(preview.size.height, 512)
        XCTAssertEqual(preview.size.width, (long.size.width * 512 / long.size.height).rounded(), accuracy: 1)
        }
    }

    func testClassicLongHeaderExpandsWithoutChangingPreviewAspect() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { _ in }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .classicSignature
        settings.metadata = .defaults(for: .classicSignature); settings.metadata.showModel = true
        settings.watermark.enabled = false
        for style: PhotoFrameBrandStyle in [.text, .logo] {
            settings.metadata.brandStyle = style
            let short = metadata(make: "SONY", model: "A7")
            let long = metadata(make: "SONY", model: String(repeating: "Long Model ", count: 100))
            let plan = PhotoEffectsRenderer.classicHeaderPlan(long, settings: settings.metadata, width: 160)
            XCTAssertGreaterThan(plan.rows.count, 2)
            let first = try PhotoEffectsRenderer.render(source, settings: settings, metadata: short)
            let second = try PhotoEffectsRenderer.render(source, settings: settings, metadata: long)
            XCTAssertEqual(first.size.width, second.size.width)
            XCTAssertGreaterThan(second.size.height, first.size.height)
            let preview = try PhotoEffectsRenderer.render(source, settings: settings, metadata: long, previewLongEdge: 512)
            XCTAssertEqual(preview.size.height, 512)
            XCTAssertEqual(preview.size.width, (second.size.width * 512 / second.size.height).rounded(), accuracy: 1)
        }
    }

    func testClassicCombinedHeaderBodyAndSignatureTailsReachExportAndPreview() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .classicSignature
        settings.metadata = .defaults(for: .classicSignature)
        settings.metadata.showBrand = true; settings.metadata.brandStyle = .logo
        settings.metadata.showModel = true; settings.metadata.showLensModel = true
        settings.watermark.enabled = true; settings.watermark.sizePercent = 300
        settings.watermark.position = .right
        for size in [CGSize(width: 240, height: 160), CGSize(width: 160, height: 240)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.gray.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            for percent in [60, 100, 200] {
                settings.metadata.widthPercent = percent
                for edge: CGFloat? in [nil, 512] {
                    func render(header: String = "AAA", body: String = "AAA", signature: String = "AAA") throws -> UIImage {
                        settings.watermark.text = String(repeating: "W", count: 20) + signature
                        let camera = PhotoFrameMetadata(make: "NIKON",
                            model: String(repeating: "Long Model ", count: 35) + header,
                            lensModel: String(repeating: "Long Lens ", count: 35) + body,
                            focalLength: "50mm", aperture: "f/2", shutter: "1/125", iso: "ISO100",
                            exposureCompensation: nil, dateTime: "2026/10/17")
                        return try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera,
                            previewLongEdge: edge)
                    }
                    let baseline = try render()
                    let baselinePixels = try XCTUnwrap(baseline.pngData())
                    for alternate in [try render(header: "ZZZ"), try render(body: "ZZZ"), try render(signature: "ZZZ")] {
                        XCTAssertEqual(alternate.size, baseline.size)
                        XCTAssertNotEqual(try XCTUnwrap(alternate.pngData()), baselinePixels)
                    }
                    if let edge { XCTAssertEqual(max(baseline.size.width, baseline.size.height), edge) }
                }
            }
        }
    }

    func testPhotoWatermarkInkSizeDoesNotChangeWithFrameWidth() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        func pixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
            let cg = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (bytes, cg.width, cg.height)
        }
        for preset in PhotoFramePreset.allCases {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.watermark.position = .photoCenter; settings.watermark.text = "Test"
            settings.watermark.sizePercent = 200; settings.watermark.effect = .none
            settings.watermark.color = .white
            var baselineSize: CGSize?
            for percent in [60, 100, 200] {
                settings.metadata.widthPercent = percent; settings.watermark.enabled = false
                let plain = try pixels(PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty))
                settings.watermark.enabled = true
                let marked = try pixels(PhotoEffectsRenderer.render(source, settings: settings, metadata: .empty))
                XCTAssertEqual(plain.width, marked.width); XCTAssertEqual(plain.height, marked.height)
                var minX = marked.width, minY = marked.height, maxX = -1, maxY = -1
                for y in 0..<marked.height {
                    for x in 0..<marked.width {
                        let i = (y * marked.width + x) * 4
                        if plain.bytes[i..<(i + 4)].elementsEqual(marked.bytes[i..<(i + 4)]) { continue }
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
                XCTAssertGreaterThanOrEqual(maxX, minX, preset.rawValue)
                let size = CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
                if let baselineSize { XCTAssertEqual(size, baselineSize, "\(preset.rawValue), width \(percent)") }
                else { baselineSize = size }
            }
        }
    }

    func testPhotoWatermarkReferenceSizeIsIndependentOfPhotoBounds() throws {
        var watermark = PhotoFrameWatermark()
        watermark.enabled = true; watermark.text = "Test"
        watermark.position = .photoBottomRight; watermark.effect = .none
        let photo = CGRect(x: 10, y: 20, width: 400, height: 300)
        let first = PhotoEffectsRenderer.photoWatermarkTextLayout(watermark, photo: photo, referenceShortEdge: 300)
        let larger = PhotoEffectsRenderer.photoWatermarkTextLayout(watermark, photo: photo, referenceShortEdge: 450)
        XCTAssertEqual(larger.font.pointSize, first.font.pointSize * 1.5, accuracy: 0.001)
        XCTAssertEqual(larger.inkBounds.maxX, first.inkBounds.maxX, accuracy: 0.01)
        XCTAssertEqual(larger.inkBounds.maxY, first.inkBounds.maxY, accuracy: 0.01)
        let occupied = try XCTUnwrap(PhotoEffectsRenderer.photoWatermarkOccupiedBounds(photo: photo,
            watermark: watermark, referenceShortEdge: 450))
        XCTAssertEqual(occupied, larger.inkBounds)
        let preview = PhotoEffectsRenderer.photoWatermarkTextLayout(watermark,
            photo: photo.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)), referenceShortEdge: 225)
        XCTAssertEqual(preview.font.pointSize, larger.font.pointSize * 0.5, accuracy: 0.001)
    }

    func testPhotoWatermarkOccupiedBoundsUseFittedInkAndEffects() throws {
        let photo = CGRect(x: 10, y: 20, width: 240, height: 160)
        var watermark = PhotoFrameWatermark()
        watermark.enabled = true; watermark.position = .photoBottomRight
        watermark.text = String(repeating: "W", count: 24); watermark.sizePercent = 300
        watermark.effect = .none
        let plain = try XCTUnwrap(PhotoEffectsRenderer.photoWatermarkOccupiedBounds(photo: photo, watermark: watermark))
        XCTAssertLessThanOrEqual(plain.width, photo.width - 2 * photo.height * 0.04 + 0.01)
        XCTAssertEqual(plain.maxX, photo.maxX - photo.height * 0.04, accuracy: 0.01)
        XCTAssertEqual(plain.maxY, photo.maxY - photo.height * 0.04, accuracy: 0.01)
        for effect: PhotoFrameWatermarkEffect in [.shadow, .outline, .auto] {
            watermark.effect = effect
            let occupied = try XCTUnwrap(PhotoEffectsRenderer.photoWatermarkOccupiedBounds(photo: photo, watermark: watermark))
            XCTAssertTrue(occupied.contains(plain))
            XCTAssertGreaterThan(occupied.width, plain.width)
            XCTAssertEqual(occupied.midX, plain.midX, accuracy: 0.01)
        }
        watermark.enabled = false
        XCTAssertNil(try PhotoEffectsRenderer.photoWatermarkOccupiedBounds(photo: photo, watermark: watermark))
    }

    func testImageWatermarkParticipatesInOccupiedBounds() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 2), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 2))
        }
        var watermark = PhotoFrameWatermark()
        watermark.enabled = true; watermark.content = .image; watermark.sizePercent = 300
        watermark.imageHash = try XCTUnwrap(PhotoEffectsStore.importWatermarkImageData(XCTUnwrap(image.pngData())))
        watermark.position = .photoBottomRight
        let photo = CGRect(x: 10, y: 20, width: 240, height: 160)
        let occupied = try XCTUnwrap(PhotoEffectsRenderer.photoWatermarkOccupiedBounds(photo: photo, watermark: watermark))
        let inset = photo.height * 0.04
        XCTAssertEqual(occupied.width, photo.width - inset * 2, accuracy: 0.01)
        XCTAssertEqual(occupied.width / occupied.height, 200, accuracy: 0.01)
        XCTAssertEqual(occupied.maxX, photo.maxX - inset, accuracy: 0.01)
        XCTAssertEqual(occupied.maxY, photo.maxY - inset, accuracy: 0.01)
        watermark.imageHash = "invalid"
        XCTAssertThrowsError(try PhotoEffectsRenderer.photoWatermarkOccupiedBounds(photo: photo, watermark: watermark))
    }

    func testImmersiveTitleLimitsInlineSignatureBeforeCombiningCamera() throws {
        var settings = PhotoFrameMetadataSettings.defaults(for: .immersive)
        var watermark = PhotoFrameWatermark()
        watermark.enabled = true; watermark.position = .auto; watermark.sizePercent = 300
        watermark.text = String(repeating: "W", count: 24)
        let size = CGSize(width: 1000, height: 1000)
        let signature = try XCTUnwrap(PhotoEffectsRenderer.immersiveTitleRow(metadata: .empty,
            watermark: watermark, settings: settings, photoSize: size))
        XCTAssertLessThanOrEqual(signature.width, 1000 * 0.38 * 1.35 + 1)
        XCTAssertGreaterThan(signature.width, 500)
        for style: PhotoFrameBrandStyle in [.text, .logo] {
            settings.brandStyle = style; settings.showBrand = true
            let camera = metadata(make: "SONY", model: "A7")
            let combined = try XCTUnwrap(PhotoEffectsRenderer.immersiveTitleRow(metadata: camera,
                watermark: watermark, settings: settings, photoSize: size))
            XCTAssertGreaterThan(combined.width, signature.width)
            XCTAssertLessThan(combined.width, 860)
            let long = try XCTUnwrap(PhotoEffectsRenderer.immersiveTitleRow(
                metadata: metadata(make: "SONY", model: String(repeating: "Long Model ", count: 100)),
                watermark: watermark, settings: settings, photoSize: size))
            XCTAssertEqual(long.width, 860, accuracy: 0.001)
        }
        watermark.enabled = false
        XCTAssertNil(PhotoEffectsRenderer.immersiveTitleRow(metadata: .empty,
            watermark: watermark, settings: settings, photoSize: size))
    }

    func testImmersiveDetailsUseOneScaleForAllLines() throws {
        let short = "50mm  f/2"
        let long = String(repeating: "Long location ", count: 30)
        let natural = PhotoEffectsRenderer.immersiveDetailRows([short, long], shortEdge: 1000, maxWidth: 100_000)
        let fitted = PhotoEffectsRenderer.immersiveDetailRows([short, long], shortEdge: 1000, maxWidth: 300)
        XCTAssertEqual(fitted.count, 2)
        let shortScale = fitted[0].width / natural[0].width
        let longScale = fitted[1].width / natural[1].width
        XCTAssertLessThan(shortScale, 1)
        XCTAssertEqual(shortScale, longScale, accuracy: 0.0001)
        XCTAssertEqual(fitted[1].width, 300, accuracy: 0.001)
    }

    func testImmersiveDoesNotDarkenPhotoOutsideText() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160), format: format).image { context in
            UIColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        func edgePixels(_ image: UIImage) throws -> [UInt8] {
            let cropped = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 2, y: 2, width: 4, height: 156)))
            var bytes = [UInt8](repeating: 0, count: 4 * 156 * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: 4, height: 156, bitsPerComponent: 8,
                bytesPerRow: 16, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 4, height: 156))
            return bytes
        }
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .immersive
        settings.metadata = .defaults(for: .immersive); settings.watermark.enabled = false
        let expected = try edgePixels(source)
        for camera in [PhotoFrameMetadata.empty, metadata(make: "SONY", model: "A7")] {
            let output = try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera)
            XCTAssertEqual(output.size, source.size)
            XCTAssertEqual(try edgePixels(output), expected)
        }
    }

    func testBrandPhotoWatermarkCollisionFailsAndCanRecoverByMovingWatermark() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 60), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 60))
        }
        let hash = try XCTUnwrap(PhotoEffectsStore.importWatermarkImageData(XCTUnwrap(logo.pngData())))
        let camera = PhotoFrameMetadata(make: "SONY", model: "A7",
            lensModel: Array(repeating: "Lens detail", count: 14).joined(separator: "\n"),
            focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
        for preset: PhotoFramePreset in [.brandInset, .brandGallery] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset); settings.metadata.showLensModel = true
            settings.watermark.sizePercent = 300; settings.watermark.text = String(repeating: "W", count: 24)
            settings.watermark.imageHash = hash
            for content: PhotoFrameWatermarkContent in [.text, .image] {
                settings.watermark.content = content
                for edge: CGFloat? in [nil, 512] {
                    settings.watermark.enabled = false
                    XCTAssertNoThrow(try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera, previewLongEdge: edge))
                    settings.watermark.enabled = true; settings.watermark.position = .photoCenter
                    XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera, previewLongEdge: edge)) { error in
                        guard case PhotoFrameBrandLayoutError.watermarkOverlap = error else {
                            return XCTFail("Expected watermark overlap, got \(error)")
                        }
                    }
                    settings.watermark.position = .photoBottomRight
                    XCTAssertNoThrow(try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera, previewLongEdge: edge))
                }
            }
        }
    }

    func testBrandPhotoLayoutDecisionIsIndependentOfPreviewSize() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var accepted = 0
        var rejected = 0
        for size in [CGSize(width: 160, height: 120), CGSize(width: 120, height: 160)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
            for preset: PhotoFramePreset in [.brandInset, .brandGallery] {
                var settings = PhotoEffectsSettings()
                settings.photoFrameEnabled = true; settings.photoFramePreset = preset
                settings.metadata = .defaults(for: preset); settings.metadata.showLensModel = true
                settings.watermark.enabled = true; settings.watermark.position = .photoCenter
                settings.watermark.text = String(repeating: "W", count: 24)
                settings.watermark.sizePercent = 300
                for width in [60, 100, 200] {
                    settings.metadata.widthPercent = width
                    for lineCount in [1, 6, 12, 18, 24] {
                        let metadata = PhotoFrameMetadata(make: "SONY", model: "A7",
                            lensModel: Array(repeating: "Lens detail", count: lineCount).joined(separator: "\n"),
                            focalLength: nil, aperture: nil, shutter: nil, iso: nil,
                            exposureCompensation: nil, dateTime: nil)
                        func outcome(_ edge: CGFloat?) throws -> String {
                            do {
                                _ = try PhotoEffectsRenderer.render(source, settings: settings,
                                    metadata: metadata, previewLongEdge: edge)
                                return "accepted"
                            } catch let error as PhotoFrameBrandLayoutError {
                                return error.localizedDescription
                            }
                        }
                        let original = try outcome(nil)
                        if original == "accepted" { accepted += 1 } else { rejected += 1 }
                        for edge: CGFloat in [32, 127, 512] {
                            XCTAssertEqual(try outcome(edge), original,
                                "\(preset) \(size) width \(width) lines \(lineCount) preview \(edge)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertGreaterThan(rejected, 0)
    }

    func testBrandPhotoInformationRejectsOverflowInsteadOfShrinking() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { _ in }
        for preset: PhotoFramePreset in [.brandInset, .brandGallery] {
            var settings = PhotoEffectsSettings()
            settings.photoFrameEnabled = true; settings.photoFramePreset = preset
            settings.metadata = .defaults(for: preset)
            settings.metadata.showLensModel = true; settings.watermark.enabled = false
            func camera(_ lens: String) -> PhotoFrameMetadata {
                PhotoFrameMetadata(make: "SONY", model: "A7", lensModel: lens,
                    focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
            }
            for edge: CGFloat? in [nil, 512] {
                XCTAssertNoThrow(try PhotoEffectsRenderer.render(source, settings: settings,
                    metadata: camera("50mm"), previewLongEdge: edge))
                XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings,
                    metadata: camera(String(repeating: "Long Lens ", count: 300)), previewLongEdge: edge)) { error in
                    guard case PhotoFrameBrandLayoutError.insufficientHeight = error else {
                        return XCTFail("Expected height rejection, got \(error)")
                    }
                }
                XCTAssertThrowsError(try PhotoEffectsRenderer.render(source, settings: settings,
                    metadata: camera(String(repeating: "क्", count: 160) + "क"), previewLongEdge: edge)) { error in
                    XCTAssertTrue(error is PhotoFrameColumnOverflow, "\(error)")
                }
            }
        }
    }

    func testColorArchiveLongFieldsReachExportAndPreview() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true; settings.photoFramePreset = .colorArchive
        settings.metadata = .defaults(for: .colorArchive)
        settings.metadata.showBrand = true; settings.metadata.brandStyle = .logo
        settings.metadata.showModel = true; settings.metadata.showLensModel = true
        settings.metadata.showAddress = true; settings.metadata.showCity = true
        settings.watermark.enabled = false
        for size in [CGSize(width: 240, height: 160), CGSize(width: 160, height: 240)] {
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.gray.setFill(); context.fill(CGRect(origin: .zero, size: size))
            }
            for percent in [60, 100, 200] {
                settings.metadata.widthPercent = percent
                for edge: CGFloat? in [nil, 512] {
                    func render(model: String = "AAA", lens: String = "AAA", city: String = "AAA") throws -> UIImage {
                        let camera = PhotoFrameMetadata(make: "NIKON",
                            model: String(repeating: "Long Model ", count: 25) + model,
                            lensModel: String(repeating: "Long Lens ", count: 25) + lens,
                            focalLength: "50mm", aperture: "f/2", shutter: "1/125", iso: "ISO100",
                            exposureCompensation: nil, dateTime: "2026/10/17",
                            city: String(repeating: "Long City ", count: 25) + city)
                        return try PhotoEffectsRenderer.render(source, settings: settings, metadata: camera,
                            previewLongEdge: edge)
                    }
                    let baseline = try render()
                    let pixels = try XCTUnwrap(baseline.pngData())
                    for alternate in [try render(model: "ZZZ"), try render(lens: "ZZZ"), try render(city: "ZZZ")] {
                        XCTAssertEqual(alternate.size, baseline.size)
                        XCTAssertNotEqual(try XCTUnwrap(alternate.pngData()), pixels)
                    }
                    if let edge { XCTAssertEqual(max(baseline.size.width, baseline.size.height), edge) }
                }
            }
        }
    }

    private func metadata(make: String?, model: String?) -> PhotoFrameMetadata {
        PhotoFrameMetadata(make: make, model: model, lensModel: nil, focalLength: nil,
                           aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
    }
}
