import UIKit
import CoreImage

/// Native renderer following PhotoFrameExporter.kt's ordered pipeline.
/// Source -> NP3 filter -> frame backdrop/photo -> metadata/watermark.
enum PhotoEffectsRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private struct Layout {
        var canvas: CGSize
        var photo: CGRect
        var metadataTop: CGFloat
    }
    private struct BrandBounds {
        var rect: CGRect
        func intersects(_ other: BrandBounds) -> Bool { rect.intersects(other.rect) }
    }

    static func render(_ image: UIImage, settings: PhotoEffectsSettings, metadata: PhotoFrameMetadata? = nil) throws -> UIImage {
        try Task.checkCancellation()
        var output = image
        if settings.photoFilterEnabled, let filter = settings.selectedFilter {
            output = try applyFilter(output, selection: filter)
        }
        if settings.photoFrameEnabled {
            if !settings.photoFrameBorderEnabled {
                if settings.watermark.enabled { output = drawWatermarkOnly(output, watermark: settings.watermark) }
                try Task.checkCancellation()
                return output
            }
            output = drawDecoration(output, settings: settings, metadata: metadata)
        }
        try Task.checkCancellation()
        return output
    }

    private static func applyFilter(_ image: UIImage, selection: PhotoFilterSelection) throws -> UIImage {
        guard let preset = Np3FilterCatalog.preset(id: selection.preset.id) else {
            throw PhotoEffectsRenderError.unknownFilter
        }
        guard let source = image.cgImage else { throw PhotoEffectsRenderError.invalidBitmap }
        let filtered = try Np3BitmapFilter.apply(source, parameters: preset.parameters,
                                                  intensityPercent: selection.normalizedIntensityPercent)
        return UIImage(cgImage: filtered, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func drawDecoration(_ image: UIImage, settings: PhotoEffectsSettings, metadata: PhotoFrameMetadata?) -> UIImage {
        let sourceSize = CGSize(width: image.cgImage?.width ?? Int(image.size.width),
                                height: image.cgImage?.height ?? Int(image.size.height))
        let layout = makeLayout(sourceSize, preset: settings.photoFramePreset)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: layout.canvas, format: format).image { renderer in
            let cg = renderer.cgContext
            drawBackdrop(cg, image: image, layout: layout, preset: settings.photoFramePreset)
            if settings.photoFramePreset == .galleryMat || settings.photoFramePreset == .filmGallery {
                let photo = layout.photo
                let inset = min(photo.width, photo.height) * 0.045
                let outer = settings.photoFramePreset == .filmGallery
                    ? CGRect(x: photo.minX - photo.width * 0.018, y: photo.minY - photo.width * 0.09,
                             width: photo.width * 1.036, height: photo.height + photo.width * 0.18)
                    : photo.insetBy(dx: -inset, dy: -inset)
                cg.setFillColor(UIColor(red: 0.025, green: 0.027, blue: 0.031, alpha: 1).cgColor)
                cg.fill(outer)
            }
            if settings.photoFrameBorderEnabled {
                drawPhoto(cg, image: image, rect: layout.photo, preset: settings.photoFramePreset,
                          metadataBandHeight: layout.canvas.height - layout.metadataTop)
            } else {
                image.draw(in: layout.photo)
            }
            let visibleMetadata = metadata?.resolved(for: settings.metadata) ?? .empty
            drawPresetDecoration(cg, image: image, layout: layout,
                                 preset: settings.photoFramePreset,
                                 metadata: visibleMetadata,
                                 watermark: settings.watermark,
                                 metadataSettings: settings.metadata)
        }
    }

    /// Android's watermark-only path preserves the source dimensions and does
    /// not create a hidden frame/backdrop when the border switch is off.
    private static func drawWatermarkOnly(_ image: UIImage, watermark: PhotoFrameWatermark) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let photo = CGRect(origin: .zero, size: size)
            image.draw(in: photo)
            var effective = watermark
            if !photoPlacement(effective.position) { effective.position = .photoBottomCenter }
            drawWatermark(renderer.cgContext, watermark: effective, photo: photo, canvas: size,
                          preset: .mist, metadataBand: .zero)
        }
    }

    // MARK: Layout (ratios ported from PhotoFrameExporter.kt)

    private static func makeLayout(_ source: CGSize, preset: PhotoFramePreset) -> Layout {
        let w = max(source.width, 1), h = max(source.height, 1), aspect = w / h
        switch preset {
        case .plaque:
            let band = w * 0.12
            return Layout(canvas: CGSize(width: w, height: h + band), photo: CGRect(x: 0, y: 0, width: w, height: h), metadataTop: h)
        case .immersive:
            return Layout(canvas: source, photo: CGRect(origin: .zero, size: source), metadataTop: h)
        case .brandInset, .brandGallery:
            let side = w * 0.032
            let bottom = w * (preset == .brandInset ? 0.032 : 0.16)
            return Layout(canvas: CGSize(width: w + side * 2, height: h + side + bottom),
                          photo: CGRect(x: side, y: side, width: w, height: h), metadataTop: side + h)
        case .classicSignature, .galleryMat, .colorArchive, .filmGallery, .filmEdge:
            switch preset {
            case .classicSignature:
                let side = w * 0.03, top = w * 0.095, bottom = w * 0.15
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            case .galleryMat:
                let (wf, hf): (CGFloat, CGFloat) = aspect > 1.08 ? (0.80, 0.56) : aspect < 0.92 ? (0.56, 0.80) : (0.68, 0.68)
                let side = max(w / wf, h / hf), left = (side - w) / 2, top = (side - h) * 0.45
                return Layout(canvas: CGSize(width: side, height: side), photo: CGRect(x: left, y: top, width: w, height: h), metadataTop: top + h)
            case .colorArchive:
                let side = w * 0.04, top = w * 0.04, bottom = w * 0.17
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            case .filmGallery:
                let side = w * 0.085, top = w * 0.16, bar = w * 0.09, bottom = w * 0.34
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bar * 2 + bottom), photo: CGRect(x: side, y: top + bar, width: w, height: h), metadataTop: top + bar + h + bar)
            case .filmEdge:
                let side = w * 0.07, top = w * 0.035, bottom = w * 0.085
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            default: fatalError()
            }
        default:
            return standardLayout(source)
        }
    }

    /// Android's original-quality path grows the canvas until the photo
    /// rectangle can keep every source pixel. This is also used for preview;
    /// the picker has already downsampled that source to 1280px.
    private static func standardLayout(_ source: CGSize) -> Layout {
        let w = max(source.width, 1), h = max(source.height, 1), aspect = w / h
        let canvasRatio: CGSize
        if aspect > 1.9 { canvasRatio = CGSize(width: 1, height: 0.5625) }
        else if aspect > 1.1 { canvasRatio = CGSize(width: 1, height: 0.75) }
        else if aspect >= 0.9 { canvasRatio = CGSize(width: 1, height: 1) }
        else if aspect >= 0.72 { canvasRatio = CGSize(width: 0.75, height: 1) }
        else if aspect >= 0.56 { canvasRatio = CGSize(width: 2.0 / 3.0, height: 1) }
        else { canvasRatio = CGSize(width: 0.5625, height: 1) }
        var longEdge = max(w, h)
        for _ in 0..<8 {
            let canvasSize = CGSize(width: canvasRatio.width * longEdge, height: canvasRatio.height * longEdge)
            let portrait = canvasSize.height > canvasSize.width, square = abs(canvasSize.height - canvasSize.width) < 0.5
            let side = canvasSize.width * 0.052
            let top = canvasSize.height * (portrait ? 0.030 : square ? 0.040 : 0.050)
            let metadataTop = canvasSize.height * (portrait ? 0.900 : square ? 0.870 : 0.830)
            let availableWidth = canvasSize.width - side * 2
            let availableHeight = metadataTop - top - canvasSize.height * 0.012
            let scale = min(availableWidth / w, availableHeight / h)
            if scale >= 0.999 {
                let left = (canvasSize.width - w) / 2
                let desiredTop = top + availableHeight / 2 - h / 2
                let maxTop = min(canvasSize.height - h, metadataTop - h)
                let photoTop = min(max(desiredTop, 0), maxTop)
                return Layout(canvas: canvasSize, photo: CGRect(x: left, y: photoTop, width: w, height: h), metadataTop: metadataTop)
            }
            longEdge = ceil(longEdge / max(scale, 0.01))
        }
        return Layout(canvas: CGSize(width: canvasRatio.width * longEdge, height: canvasRatio.height * longEdge), photo: CGRect(x: 0, y: 0, width: w, height: h), metadataTop: h)
    }

    // MARK: Backdrops and photo layer

    private static func drawBackdrop(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset) {
        let rect = CGRect(origin: .zero, size: layout.canvas)
        switch preset {
        case .minimal:
            drawGradient(cg, rect: rect, top: UIColor(red: 0.98, green: 0.976, blue: 0.969, alpha: 1), bottom: UIColor(red: 0.937, green: 0.929, blue: 0.91, alpha: 1))
        case .mist, .cinema, .frosted, .filmGallery:
            let bg = blurredBackground(image, size: layout.canvas)
            bg.draw(in: rect)
            if preset == .mist { cg.setFillColor(UIColor(red: 0.93, green: 0.95, blue: 0.97, alpha: 0.24).cgColor); cg.fill(rect) }
            if preset == .cinema { cg.setFillColor(UIColor(red: 0.01, green: 0.035, blue: 0.06, alpha: 0.59).cgColor); cg.fill(rect) }
            if preset == .frosted {
                drawGradient(cg, rect: rect,
                             top: UIColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 0.36),
                             bottom: UIColor(red: 0.90, green: 0.94, blue: 0.96, alpha: 0.52))
            }
            if preset == .filmGallery { cg.setFillColor(UIColor(red: 0.07, green: 0.05, blue: 0.04, alpha: 0.26).cgColor); cg.fill(rect) }
        case .plaque, .brandInset, .brandGallery, .classicSignature, .galleryMat, .colorArchive:
            cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(rect)
        case .immersive:
            break
        case .filmEdge:
            cg.setFillColor(UIColor(red: 0.027, green: 0.027, blue: 0.031, alpha: 1).cgColor); cg.fill(rect)
        }
    }

    private static func drawPhoto(_ cg: CGContext, image: UIImage, rect: CGRect, preset: PhotoFramePreset, metadataBandHeight: CGFloat) {
        let radius: CGFloat = switch preset {
        case .colorArchive: rect.width * 0.012
        case .brandInset, .brandGallery: rect.width * 0.014
        case .mist, .cinema, .minimal, .frosted: max(1, metadataBandHeight * 0.26)
        case .plaque, .immersive, .classicSignature, .galleryMat, .filmGallery, .filmEdge: 0
        default: rect.width * 0.018
        }
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        if ![.plaque, .immersive, .filmEdge, .classicSignature, .filmGallery].contains(preset) {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: rect.width * 0.009), blur: rect.width * 0.018, color: UIColor.black.withAlphaComponent(0.20).cgColor)
            cg.setFillColor(UIColor.white.cgColor); cg.addPath(path); cg.fillPath()
            cg.restoreGState()
        }
        cg.saveGState(); cg.addPath(path); cg.clip(); image.draw(in: rect); cg.restoreGState()
        if preset == .classicSignature {
            cg.setStrokeColor(UIColor(white: 0, alpha: 0.14).cgColor)
            cg.setLineWidth(max(1, rect.width * 0.0008))
            cg.addPath(path)
            cg.strokePath()
        } else if preset != .plaque && preset != .immersive && preset != .filmEdge && preset != .filmGallery {
            let stroke: UIColor
            if preset == .minimal {
                stroke = UIColor(red: 0.08, green: 0.11, blue: 0.14, alpha: 0.18)
            } else if preset == .brandInset || preset == .brandGallery {
                stroke = UIColor(red: 0.06, green: 0.08, blue: 0.09, alpha: 0.18)
            } else {
                stroke = UIColor(white: 1, alpha: 0.275)
            }
            cg.setStrokeColor(stroke.cgColor); cg.setLineWidth(max(1, rect.width * 0.0012)); cg.addPath(path); cg.strokePath()
        }
    }


    private static func blurredBackground(_ image: UIImage, size: CGSize) -> UIImage {
        guard let source = image.cgImage, size.width > 0, size.height > 0 else { return image }
        let longEdge: CGFloat = 192
        let proxySize = size.width >= size.height
            ? CGSize(width: longEdge, height: max(96, (longEdge * size.height / size.width).rounded()))
            : CGSize(width: max(96, (longEdge * size.width / size.height).rounded()), height: longEdge)
        let proxy = UIGraphicsImageRenderer(size: proxySize).image { renderer in
            let scale = max(proxySize.width / CGFloat(source.width), proxySize.height / CGFloat(source.height))
            let drawSize = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
            let rect = CGRect(x: (proxySize.width - drawSize.width) / 2, y: (proxySize.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height)
            renderer.cgContext.interpolationQuality = .high
            renderer.cgContext.draw(source, in: rect)
        }
        guard let input = CIImage(image: proxy), let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey); filter.setValue(8, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage, let cg = ciContext.createCGImage(output, from: input.extent) else { return proxy }
        return UIImage(cgImage: cg)
    }

    private static func drawGradient(_ cg: CGContext, rect: CGRect, top: UIColor, bottom: UIColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) else { return }
        cg.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    }

    // MARK: Per-preset information and watermark rules

    private static func drawPresetDecoration(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata?, watermark: PhotoFrameWatermark, metadataSettings: PhotoFrameMetadataSettings) {
        let effective = metadata ?? PhotoFrameMetadata.empty
        switch preset {
        case .plaque: drawPlaque(cg, layout: layout, metadata: effective, watermark: watermark, settings: metadataSettings)
        case .immersive: drawImmersive(cg, layout: layout, metadata: effective, watermark: watermark)
        case .brandInset, .brandGallery: drawBrand(cg, layout: layout, preset: preset, metadata: effective, watermark: watermark, settings: metadataSettings)
        case .classicSignature, .galleryMat, .colorArchive, .filmGallery, .filmEdge:
            drawEditorial(cg, image: image, layout: layout, preset: preset, metadata: effective, watermark: watermark, settings: metadataSettings)
        default:
            drawStandardMetadata(cg, layout: layout, preset: preset, metadata: effective, watermark: watermark, settings: metadataSettings)
        }
    }

    private static func frostedMetadataPanelBounds(_ layout: Layout) -> CGRect {
        let bandHeight = layout.canvas.height - layout.photo.maxY
        let horizontalInset = layout.canvas.width * 0.072
        let verticalInset = bandHeight * 0.08
        return CGRect(x: horizontalInset, y: layout.photo.maxY + verticalInset,
                      width: layout.canvas.width - horizontalInset * 2,
                      height: bandHeight - verticalInset * 2)
    }

    private static func drawFrostedMetadataPanel(_ cg: CGContext, panel: CGRect, canvas: CGSize) {
        let radius = min(panel.height * 0.31, panel.width * 0.5)
        let path = UIBezierPath(roundedRect: panel, cornerRadius: radius).cgPath
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: canvas.height * 0.004),
                     blur: canvas.width * 0.009,
                     color: UIColor(red: 0.08, green: 0.14, blue: 0.18, alpha: 0.20).cgColor)
        cg.setFillColor(UIColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 0.59).cgColor)
        cg.addPath(path); cg.fillPath(); cg.restoreGState()
        cg.setStrokeColor(UIColor(white: 1, alpha: 0.70).cgColor)
        cg.setLineWidth(max(1, canvas.width * 0.0011))
        cg.addPath(path); cg.strokePath()
    }

    private static func drawStandardMetadata(_ cg: CGContext, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        let area = preset == .frosted ? frostedMetadataPanelBounds(layout) :
            CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY)
        if preset == .frosted { drawFrostedMetadataPanel(cg, panel: area, canvas: layout.canvas) }
        drawAndroidMetadata(cg, area: area, preset: preset, metadata: metadata, watermark: watermark, settings: settings,
                            lightText: preset == .mist || preset == .cinema)
        var photoWatermark = watermark
        if !photoPlacement(photoWatermark.position) && photoWatermark.content == .image { photoWatermark.position = .photoBottomCenter }
        // Text watermarks on a frame side are already one of the metadata rows;
        // only photo-anchored text and image logos need a second draw pass.
        if photoPlacement(photoWatermark.position) || photoWatermark.content == .image {
            drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: preset, metadataBand: area)
        }
    }

    private static func drawAndroidMetadata(_ cg: CGContext, area: CGRect, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings, lightText: Bool) {
        let brand = settings.showBrand ? metadata.normalizedMake : ""
        let model = settings.showModel ? metadata.normalizedModel : ""
        let lens = settings.showLensModel ? (metadata.lensModel ?? "") : ""
        var detail = ""
        if settings.showFocalLength { detail = metadata.focalLength ?? "" }
        if settings.showExposure {
            let exposure = [metadata.aperture, metadata.shutter, metadata.iso].compactMap { $0 }.joined(separator: "   ")
            if !exposure.isEmpty { detail = detail.isEmpty ? exposure : detail + "   " + exposure }
        }
        var rows: [(text: String, size: CGFloat, weight: UIFont.Weight, kind: Int)] = []
        let title = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !title.isEmpty { rows.append((title, area.width * 0.032, .bold, 0)) }
        if !lens.isEmpty { rows.append((lens, area.width * 0.0185, .medium, 1)) }
        let detailWithDate = [detail, settings.showDate ? (metadata.dateTime ?? "") : ""]
            .filter { !$0.isEmpty }.joined(separator: "   ")
        if !detailWithDate.isEmpty { rows.append((detailWithDate, area.width * 0.020, .regular, 2)) }
        if let location = metadata.locationRow, !location.isEmpty { rows.append((location, area.width * 0.018, .regular, 3)) }
        if watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position) { rows.append((watermark.displayText, area.width * textSizeFraction(watermark.sizePercent), .regular, 4)) }
        guard !rows.isEmpty else { return }
        let fonts = rows.map { UIFont.systemFont(ofSize: max(9, $0.size), weight: $0.weight) }
        let inkHeights = fonts.map { $0.ascender + abs($0.descender) }
        let gap = min(area.width * 0.0125, area.height * 0.09)
        let available = area.height * 0.88
        let inkTotal = inkHeights.reduce(0, +)
        let scale = min(1, max(0.2, available / max(inkTotal, 1)))
        let scaledHeights = inkHeights.map { $0 * scale }
        let total = scaledHeights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1)) * scale
        var cursor = area.midY - total * 0.5
        let color = lightText ? UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1) : UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        let muted = lightText ? UIColor(red: 0.86, green: 0.89, blue: 0.91, alpha: 1) : UIColor(red: 0.29, green: 0.31, blue: 0.33, alpha: 1)
        let titleBrandFont = UIFont(name: "HelveticaNeue-BoldItalic", size: area.width * 0.032) ?? UIFont.italicSystemFont(ofSize: area.width * 0.032)
        let titleModelFont = UIFont.systemFont(ofSize: area.width * 0.024, weight: .regular)
        let titleGap = area.width * 0.016
        for (index, row) in rows.enumerated() {
            let font = fonts[index].withSize(max(9, fonts[index].pointSize * scale))
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: index == 0 ? color : muted]
            if row.kind == 4 {
                attrs[.foregroundColor] = watermarkColor(watermark.color, preset).withAlphaComponent(CGFloat(watermark.opacityPercent) / 100)
                if watermark.effect == .shadow { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowOffset = CGSize(width: 0, height: 1); s.shadowColor = UIColor.black.withAlphaComponent(0.35); attrs[.shadow] = s }
            }
            let baseline = cursor + font.ascender
            if row.kind == 0 && (!brand.isEmpty || !model.isEmpty) {
                let brandFont = titleBrandFont.withSize(max(9, titleBrandFont.pointSize * scale))
                let modelFont = titleModelFont.withSize(max(9, titleModelFont.pointSize * scale))
                let brandWidth = (brand as NSString).size(withAttributes: [.font: brandFont]).width
                let modelWidth = (model as NSString).size(withAttributes: [.font: modelFont]).width
                let totalWidth = brandWidth + (brand.isEmpty || model.isEmpty ? 0 : titleGap * scale) + modelWidth
                var x = area.midX - totalWidth * 0.5
                if !brand.isEmpty {
                    brand.draw(at: CGPoint(x: x, y: baseline - brandFont.ascender), withAttributes: [.font: brandFont, .foregroundColor: color])
                    x += brandWidth + (brand.isEmpty || model.isEmpty ? 0 : titleGap * scale)
                }
                if !model.isEmpty {
                    model.draw(at: CGPoint(x: x, y: baseline - modelFont.ascender), withAttributes: [.font: modelFont, .foregroundColor: color])
                }
            } else {
                let width = (row.text as NSString).size(withAttributes: attrs).width
                let x: CGFloat = row.kind == 4 && watermark.position == .left ? area.minX + area.width * 0.07 : row.kind == 4 && watermark.position == .right ? area.maxX - area.width * 0.07 - width : area.midX - width * 0.5
                row.text.draw(at: CGPoint(x: x, y: baseline - font.ascender), withAttributes: attrs)
            }
            cursor += scaledHeights[index] + gap * scale
        }
    }

    private static func drawPlaque(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        let band = CGRect(x: 0, y: layout.metadataTop, width: layout.canvas.width, height: layout.canvas.height - layout.metadataTop)
        cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(band)
        cg.setFillColor(UIColor(red: 0.90, green: 0.91, blue: 0.90, alpha: 1).cgColor); cg.fill(CGRect(x: 0, y: band.minY, width: band.width, height: max(1, band.width * 0.0008)))
        let leftPrimary = metadata.normalizedMake.isEmpty ? (metadata.normalizedModel.isEmpty ? (metadata.lensModel ?? "") : metadata.normalizedModel) : metadata.normalizedMake.uppercased()
        let leftSecondary = [metadata.normalizedModel, metadata.lensModel ?? ""].filter { !$0.isEmpty && $0 != leftPrimary }.joined(separator: " · ")
        let right = [[metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "   "), metadata.locationRow ?? ""].filter { !$0.isEmpty }
        let sideWatermark = watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position) && watermark.position != .auto ? watermark : nil
        drawPlaqueInformation(cg, band: band,
                              leftPrimary: leftPrimary.isEmpty ? nil : leftPrimary,
                              leftSecondary: leftSecondary.isEmpty ? nil : leftSecondary,
                              right: right, watermark: sideWatermark)
        if photoPlacement(watermark.position) || watermark.content == .image {
            var photoWatermark = watermark
            if !photoPlacement(photoWatermark.position) { photoWatermark.position = .photoBottomCenter }
            drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: .plaque, metadataBand: band)
        }
    }

    private static func drawPlaqueInformation(_ cg: CGContext, band: CGRect, leftPrimary: String?, leftSecondary: String?, right: [String], watermark: PhotoFrameWatermark?) {
        let primaryFont = UIFont.systemFont(ofSize: band.width * 0.027, weight: .medium)
        let secondaryFont = UIFont.systemFont(ofSize: band.width * 0.0165)
        let rightFont = UIFont.systemFont(ofSize: band.width * 0.0245)
        let mutedFont = UIFont.systemFont(ofSize: band.width * 0.018)
        let slots: [(String?, UIFont, UIColor, String?, UIFont, UIColor)] = [
            (leftPrimary, primaryFont, UIColor(white: 0.07, alpha: 1), right.first, rightFont, UIColor(white: 0.07, alpha: 1)),
            (leftSecondary, secondaryFont, UIColor(white: 0.40, alpha: 1), right.dropFirst().first, mutedFont, UIColor(white: 0.40, alpha: 1)),
            (nil, mutedFont, UIColor.clear, right.dropFirst(2).first, mutedFont, UIColor(white: 0.40, alpha: 1)),
        ]
        let watermarkSlot = watermark.map { ($0.displayText, watermarkFont($0.font, size: band.width * textSizeFraction($0.sizePercent)), watermarkColor($0.color, .plaque).withAlphaComponent(CGFloat($0.opacityPercent) / 100)) }
        let slotHeights = slots.map { slot in max(slot.0.map { ($0 as NSString).size(withAttributes: [.font: slot.1]).height } ?? 0, slot.3.map { ($0 as NSString).size(withAttributes: [.font: slot.4]).height } ?? 0) }
        let allHeights = slotHeights + (watermarkSlot.map { [($0.0 as NSString).size(withAttributes: [.font: $0.1]).height] } ?? [])
        guard allHeights.contains(where: { $0 > 0 }) else { return }
        let gap = min(band.width * 0.0115, band.height * 0.095)
        let total = allHeights.reduce(0, +) + gap * CGFloat(max(0, allHeights.count - 1))
        let scale = min(1, band.height / max(total, 1))
        var y = band.midY - total * scale * 0.5
        for (index, slot) in slots.enumerated() {
            if let text = slot.0 { let font = slot.1.withSize(max(9, slot.1.pointSize * scale)); text.draw(at: CGPoint(x: band.width * 0.058, y: y), withAttributes: [.font: font, .foregroundColor: slot.2]) }
            if let text = slot.3 { let font = slot.4.withSize(max(9, slot.4.pointSize * scale)); let width = (text as NSString).size(withAttributes: [.font: font]).width; text.draw(at: CGPoint(x: band.width * 0.94 - width, y: y), withAttributes: [.font: font, .foregroundColor: slot.5]) }
            y += slotHeights[index] * scale + gap * scale
        }
        if let watermark, let slot = watermarkSlot {
            let font = slot.1.withSize(max(9, slot.1.pointSize * scale)); var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: slot.2]
            if watermark.effect == .shadow { let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: 1); shadow.shadowColor = UIColor.black.withAlphaComponent(0.35); attrs[.shadow] = shadow }
            let width = (slot.0 as NSString).size(withAttributes: attrs).width
            let x = watermark.position == .left ? band.minX + band.width * 0.07 : watermark.position == .right ? band.maxX - band.width * 0.07 - width : band.midX - width * 0.5
            slot.0.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        }
        if leftPrimary != nil && !right.isEmpty {
            cg.setStrokeColor(UIColor(red: 0.87, green: 0.88, blue: 0.87, alpha: 1).cgColor)
            cg.setLineWidth(max(1, band.width * 0.001))
            let inset = band.height * 0.075
            cg.move(to: CGPoint(x: band.width * 0.575, y: band.minY + inset)); cg.addLine(to: CGPoint(x: band.width * 0.575, y: band.maxY - inset)); cg.strokePath()
        }
    }

    private static func drawBrand(_ cg: CGContext, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        let photo = layout.photo
        var photoWatermark = watermark
        if !photoPlacement(photoWatermark.position) {
            if preset == .brandGallery { photoWatermark.position = .photoBottomRight }
            else { photoWatermark.position = brandPhotoPosition(photoWatermark.position) }
        }
        if preset == .brandGallery && watermark.content == .text && !photoPlacement(watermark.position) && watermark.position != .auto {
            photoWatermark.enabled = false
        }
        let photoArea = CGRect(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height)
        let identity = metadata.identity
        let details = [[metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "   "), metadata.locationRow ?? ""].filter { !$0.isEmpty }
        let occupied = brandWatermarkBounds(photo: photo, watermark: photoWatermark)
        if preset == .brandInset {
            drawBrandInsetMetadata(cg, photo: photo, brand: identity, lens: metadata.lensModel ?? "", details: details, occupied: occupied)
        } else {
            drawBrandGalleryDetails(cg, photo: photo, lens: metadata.lensModel ?? "", details: details, occupied: occupied)
        }
        drawWatermark(cg, watermark: photoWatermark, photo: photo, canvas: layout.canvas, preset: preset,
                      metadataBand: CGRect(x: 0, y: photo.maxY, width: layout.canvas.width, height: layout.canvas.height - photo.maxY))
        if preset == .brandGallery {
            drawBrandGalleryBand(cg, band: CGRect(x: 0, y: photo.maxY, width: layout.canvas.width, height: layout.canvas.height - photo.maxY), brand: identity, watermark: watermark)
        }
    }

    private static func brandDetailFont(size: CGFloat) -> UIFont {
        UIFont(name: "HelveticaNeue-CondensedBoldOblique", size: size) ?? UIFont.italicSystemFont(ofSize: size)
    }

    private static func drawBrandInsetMetadata(_ cg: CGContext, photo: CGRect, brand: String, lens: String, details: [String], occupied: BrandBounds?) {
        var rows: [(String, UIFont)] = []
        if !brand.isEmpty { rows.append((brand, UIFont.systemFont(ofSize: photo.width * 0.043, weight: .black))) }
        if !lens.isEmpty { rows.append((lens, brandDetailFont(size: photo.width * 0.019))) }
        rows.append(contentsOf: details.filter { !$0.isEmpty }.map { ($0, brandDetailFont(size: photo.width * 0.021)) })
        drawBrandRows(cg, photo: photo, rows: rows, occupied: occupied, preferredBottomRatio: 0.030, gapRatio: 0.020)
    }

    private static func drawBrandGalleryDetails(_ cg: CGContext, photo: CGRect, lens: String, details: [String], occupied: BrandBounds?) {
        var rows: [(String, UIFont)] = []
        if !lens.isEmpty { rows.append((lens, brandDetailFont(size: photo.width * 0.019))) }
        rows.append(contentsOf: details.filter { !$0.isEmpty }.map { ($0, brandDetailFont(size: photo.width * 0.021)) })
        drawBrandRows(cg, photo: photo, rows: rows, occupied: occupied, preferredBottomRatio: 0.035, gapRatio: 0.016)
    }

    private static func drawBrandRows(_ cg: CGContext, photo: CGRect, rows: [(String, UIFont)], occupied: BrandBounds?, preferredBottomRatio: CGFloat, gapRatio: CGFloat) {
        guard !rows.isEmpty else { return }
        let gap = min(photo.width, photo.height) * gapRatio
        let heights = rows.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).height }
        let widths = rows.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).width }
        let blockHeight = heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        let blockWidth = min(photo.width * 0.78, widths.max() ?? photo.width)
        let area = placeBrandMetadataBlock(photo: photo, preferredBottom: photo.maxY - min(photo.width, photo.height) * preferredBottomRatio, blockHeight: blockHeight, blockWidth: blockWidth, occupied: occupied, gap: min(photo.width, photo.height) * 0.040)
        var scale = min(1, (area?.height ?? blockHeight) / max(blockHeight, 1))
        if blockWidth > photo.width * 0.78 { scale = min(scale, photo.width * 0.78 / blockWidth) }
        let target = area ?? photo.insetBy(dx: photo.width * 0.08, dy: photo.height * 0.06)
        var y = target.midY - blockHeight * scale * 0.5
        for (index, row) in rows.enumerated() {
            let font = row.1.withSize(max(9, row.1.pointSize * scale))
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: index == 0 ? UIColor.white : UIColor.white.withAlphaComponent(0.90)]
            let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: 1); shadow.shadowColor = UIColor.black.withAlphaComponent(0.70); attrs[.shadow] = shadow
            let width = (row.0 as NSString).size(withAttributes: attrs).width
            row.0.draw(at: CGPoint(x: target.midX - width * 0.5, y: y), withAttributes: attrs)
            y += heights[index] * scale + gap * scale
        }
    }

    private static func drawBrandGalleryBand(_ cg: CGContext, band: CGRect, brand: String, watermark: PhotoFrameWatermark) {
        let bandWatermark = watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position) && watermark.position != .auto ? watermark : nil
        var rows: [(String, UIFont, UIColor)] = []
        if let bandWatermark {
            let color = bandWatermark.color == .adaptive ? UIColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1) : watermarkColor(bandWatermark.color, .brandGallery)
            rows.append((bandWatermark.displayText, watermarkFont(bandWatermark.font, size: band.width * 0.019), color.withAlphaComponent(CGFloat(bandWatermark.opacityPercent) / 100)))
        }
        if !brand.isEmpty { rows.append((brand, UIFont.systemFont(ofSize: band.width * 0.052, weight: .black), UIColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1))) }
        guard !rows.isEmpty else { return }
        let top = band.minY + band.height * 0.08, bottom = band.maxY - band.height * 0.10
        let gap = band.height * 0.12
        let heights = rows.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).height }
        let total = heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        let scale = min(1, (bottom - top) / max(total, 1))
        var y = (top + bottom - total * scale) * 0.5
        for (index, row) in rows.enumerated() {
            let font = row.1.withSize(max(9, row.1.pointSize * scale))
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: row.2]
            if bandWatermark != nil && index == 0 && bandWatermark?.effect == .shadow { let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: 1); shadow.shadowColor = UIColor.black.withAlphaComponent(0.35); attrs[.shadow] = shadow }
            let width = (row.0 as NSString).size(withAttributes: attrs).width
            let x: CGFloat = index == 0 && bandWatermark?.position == .left ? band.minX + band.width * 0.07 : index == 0 && bandWatermark?.position == .right ? band.maxX - band.width * 0.07 - width : band.midX - width * 0.5
            row.0.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            y += heights[index] * scale + gap * scale
        }
    }

    private static func brandWatermarkBounds(photo: CGRect, watermark: PhotoFrameWatermark) -> BrandBounds? {
        guard watermark.enabled, photoPlacement(watermark.position), watermark.content == .text else { return nil }
        let font = watermarkFont(watermark.font, size: min(photo.width, photo.height) * textSizeFraction(watermark.sizePercent))
        let measured = (watermark.displayText as NSString).size(withAttributes: [.font: font])
        let inset = min(photo.width, photo.height) * 0.04
        return BrandBounds(rect: watermarkRect(position: watermark.position, photo: photo, size: measured, inset: inset))
    }

    private static func placeBrandMetadataBlock(photo: CGRect, preferredBottom: CGFloat, blockHeight: CGFloat, blockWidth: CGFloat, occupied: BrandBounds?, gap: CGFloat) -> CGRect? {
        guard blockHeight > 0 else { return nil }
        let width = min(blockWidth, photo.width)
        let left = photo.midX - width * 0.5
        func block(endingAt bottom: CGFloat) -> CGRect {
            let clamped = min(max(bottom, photo.minY + blockHeight), photo.maxY)
            return CGRect(x: left, y: clamped - blockHeight, width: width, height: blockHeight)
        }
        let preferred = block(endingAt: preferredBottom)
        guard let occupied else { return preferred }
        if !preferred.intersects(occupied.rect) { return preferred }
        let above = block(endingAt: occupied.rect.minY - gap)
        if above.minY >= photo.minY && !above.intersects(occupied.rect) { return above }
        let below = CGRect(x: left, y: occupied.rect.maxY + gap, width: width, height: blockHeight)
        if below.maxY <= photo.maxY && !below.intersects(occupied.rect) { return below }
        let roomAbove = max(0, occupied.rect.minY - gap - photo.minY)
        let roomBelow = max(0, photo.maxY - occupied.rect.maxY - gap)
        return roomAbove >= roomBelow ? block(endingAt: max(photo.minY + blockHeight, occupied.rect.minY - gap)) : block(endingAt: min(photo.maxY, occupied.rect.maxY + gap + blockHeight))
    }

    private static func drawImmersive(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark) {
        let lower = CGRect(x: 0, y: layout.canvas.height * 0.52, width: layout.canvas.width, height: layout.canvas.height * 0.48)
        drawGradient(cg, rect: lower, top: UIColor(white: 0, alpha: 0), bottom: UIColor(white: 0, alpha: 0.46))
        let area = CGRect(x: layout.canvas.width * 0.07, y: layout.canvas.height * 0.66, width: layout.canvas.width * 0.86, height: layout.canvas.height * 0.29)
        let title = metadata.identity
        let inlineWatermark = watermark.enabled && watermark.content == .text && watermark.position == .auto ? watermark : nil
        let separate = watermark.enabled && watermark.content == .text && watermark.position != .auto && !photoPlacement(watermark.position) ? watermark : nil
        let titleFont = UIFont.systemFont(ofSize: min(layout.canvas.width * 0.030, area.width * 0.08), weight: .medium)
        let detailFont = UIFont.systemFont(ofSize: min(layout.canvas.width * 0.021, area.width * 0.058), weight: .regular)
        let inlineFont = inlineWatermark.map { watermarkFont($0.font, size: min(layout.canvas.width, layout.canvas.height) * textSizeFraction($0.sizePercent) * 1.35) }
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white,
            .shadow: { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowOffset = CGSize(width: 0, height: 1); s.shadowColor = UIColor.black.withAlphaComponent(0.55); return s }()]
        let detailAttrs: [NSAttributedString.Key: Any] = [.font: detailFont, .foregroundColor: UIColor.white.withAlphaComponent(0.92)]
        var detailLines = [String](); if let lens = metadata.lensModel, !lens.isEmpty { detailLines.append(lens) }
        let cameraDetail = [metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "  ")
        if !cameraDetail.isEmpty { detailLines.append(cameraDetail) }
        if let location = metadata.locationRow, !location.isEmpty { detailLines.append(location) }
        var rows: [(String, UIFont, [NSAttributedString.Key: Any])] = []
        if !title.isEmpty || inlineWatermark != nil {
            rows.append((title, titleFont, titleAttrs))
        }
        rows += detailLines.map { ($0, detailFont, detailAttrs) }
        if let separate { rows.append((separate.displayText, detailFont, detailAttrs)) }
        let gap = layout.canvas.width * 0.013
        var bounds = rows.map { ($0.0 as NSString).size(withAttributes: $0.2).height }
        if !rows.isEmpty, let inlineWatermark, let inlineFont {
            let inlineHeight = (inlineWatermark.displayText as NSString).size(withAttributes: [.font: inlineFont]).height
            let dividerHeight = ("|" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: layout.canvas.width * 0.025, weight: .light)]).height
            bounds[0] = max(bounds[0], max(inlineHeight, dividerHeight))
        }
        let total = bounds.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        var y = area.maxY - layout.canvas.height * 0.045 - total
        if !rows.isEmpty {
            for (index, row) in rows.enumerated() {
                if index == 0, let inlineWatermark, let inlineFont {
                    let dividerFont = UIFont.systemFont(ofSize: layout.canvas.width * 0.025, weight: .light)
                    let dividerAttrs: [NSAttributedString.Key: Any] = [.font: dividerFont, .foregroundColor: UIColor.white.withAlphaComponent(0.80)]
                    let titleWidth = (title as NSString).size(withAttributes: row.2).width
                    let dividerWidth = ("|" as NSString).size(withAttributes: dividerAttrs).width
                    var inlineAttrs: [NSAttributedString.Key: Any] = [.font: inlineFont, .foregroundColor: watermarkColor(inlineWatermark.color, .immersive).withAlphaComponent(CGFloat(inlineWatermark.opacityPercent) / 100)]
                    if inlineWatermark.effect == .shadow || inlineWatermark.effect == .auto { let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: 1); shadow.shadowColor = UIColor.black.withAlphaComponent(0.35); inlineAttrs[.shadow] = shadow }
                    let inlineWidth = (inlineWatermark.displayText as NSString).size(withAttributes: inlineAttrs).width
                    let componentGap = layout.canvas.width * 0.014
                    let hasDivider = !title.isEmpty
                    let totalWidth = titleWidth + inlineWidth + (hasDivider ? dividerWidth + componentGap * 2 : 0)
                    let baseline = y + max(row.1.ascender, max(dividerFont.ascender, inlineFont.ascender))
                    var x = area.midX - totalWidth * 0.5
                    if !title.isEmpty {
                        title.draw(at: CGPoint(x: x, y: baseline - row.1.ascender), withAttributes: row.2)
                        x += titleWidth + componentGap
                        "|".draw(at: CGPoint(x: x, y: baseline - dividerFont.ascender), withAttributes: dividerAttrs)
                        x += dividerWidth + componentGap
                    }
                    inlineWatermark.displayText.draw(at: CGPoint(x: x, y: baseline - inlineFont.ascender), withAttributes: inlineAttrs)
                } else {
                    let width = (row.0 as NSString).size(withAttributes: row.2).width
                    row.0.draw(at: CGPoint(x: area.midX - width * 0.5, y: y), withAttributes: row.2)
                }
                y += bounds[index] + gap
            }
        }
        var photoWatermark = watermark
        if !photoPlacement(photoWatermark.position) { photoWatermark.position = .photoBottomRight }
        if photoPlacement(watermark.position) || (watermark.content == .image && photoPlacement(watermark.position)) {
            drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: .immersive, metadataBand: area)
        }
    }

    private static func drawEditorial(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        switch preset {
        case .galleryMat:
            drawMetadataRows(cg, area: CGRect(x: layout.canvas.width * 0.08, y: layout.photo.maxY + layout.photo.width * 0.045, width: layout.canvas.width * 0.84, height: layout.canvas.height - layout.photo.maxY - layout.photo.width * 0.05), preset: preset, rows: metadata.editorialRows, watermark: watermark, dark: true, emphasizeFirst: false)
        case .colorArchive:
            drawPalette(cg, image: image, layout: layout)
            drawColorArchiveInformation(cg, layout: layout, metadata: metadata)
        case .filmGallery:
            drawFilmStrip(cg, layout: layout, metadata: metadata)
            drawMetadataRows(cg, area: CGRect(x: layout.canvas.width * 0.08, y: layout.photo.maxY + layout.photo.width * 0.12, width: layout.canvas.width * 0.84, height: layout.canvas.height - layout.photo.maxY - layout.photo.width * 0.12), preset: preset, rows: [metadata.lensModel ?? "", metadata.frameDetailLine, metadata.locationRow ?? ""].filter { !$0.isEmpty }, watermark: watermark, dark: false, emphasizeFirst: false)
        case .filmEdge:
            drawSideLabel(cg, text: "PORTRA 400", x: layout.photo.minX * 0.48, y: layout.photo.midY, angle: -.pi / 2, color: UIColor(red: 0.87, green: 0.65, blue: 0.47, alpha: 1), size: layout.photo.width * 0.028)
            drawSideLabel(cg, text: "▶  20", x: layout.photo.maxX + (layout.canvas.width - layout.photo.maxX) * 0.52, y: layout.photo.minY + layout.photo.height * 0.22, angle: .pi / 2, color: UIColor(red: 0.87, green: 0.65, blue: 0.47, alpha: 1), size: layout.photo.width * 0.028)
            let identity = metadata.identity
            let cameraLine = [identity, metadata.lensModel ?? "", metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "   ")
            drawMetadataRows(cg, area: CGRect(x: layout.photo.minX, y: layout.photo.maxY, width: layout.photo.width, height: layout.canvas.height - layout.photo.maxY), preset: preset, rows: [cameraLine, metadata.locationRow ?? ""].filter { !$0.isEmpty }, watermark: watermark, dark: false, emphasizeFirst: false)
        case .classicSignature:
            if !metadata.identity.isEmpty {
                let headerArea = CGRect(x: 0, y: 0, width: layout.canvas.width, height: layout.photo.minY)
                var font = UIFont(name: "HelveticaNeue-BlackItalic", size: layout.canvas.width * 0.034) ?? UIFont.italicSystemFont(ofSize: layout.canvas.width * 0.034)
                let maxWidth = layout.canvas.width * 0.54
                let measured = (metadata.identity as NSString).size(withAttributes: [.font: font]).width
                if measured > maxWidth { font = font.withSize(font.pointSize * maxWidth / measured) }
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(red: 0.04, green: 0.043, blue: 0.047, alpha: 1)]
                let size = (metadata.identity as NSString).size(withAttributes: attrs)
                metadata.identity.draw(at: CGPoint(x: headerArea.midX - size.width * 0.5, y: headerArea.midY - size.height * 0.5), withAttributes: attrs)
            }
            drawMetadataRows(cg, area: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY), preset: preset, rows: [metadata.lensModel ?? "", metadata.classicSignatureDetailLine, metadata.dateTime ?? "", metadata.locationRow ?? ""].filter { !$0.isEmpty }, watermark: watermark, dark: true, emphasizeFirst: false)
        default: break
        }
        let photoWatermark = editorialPhotoWatermark(watermark, preset: preset)
        drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: preset, metadataBand: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY))
    }

    private static func drawMetadataRows(_ cg: CGContext, area: CGRect, preset: PhotoFramePreset, rows: [String], watermark: PhotoFrameWatermark, dark: Bool, insidePhoto: Bool = false, emphasizeFirst: Bool = true) {
        guard area.height > 1 else { return }
        var values = rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let supportsBandWatermark = preset == .galleryMat || preset == .filmGallery ||
            (preset == .classicSignature && watermark.position != .auto) ||
            (preset == .brandGallery && watermark.position != .auto)
        let drawsWatermark = !insidePhoto && supportsBandWatermark && watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position)
        if drawsWatermark { values.append(watermark.displayText) }
        guard !values.isEmpty else { return }
        let color = dark ? UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1) : UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
        let muted = dark ? UIColor(red: 0.29, green: 0.31, blue: 0.33, alpha: 1) : UIColor(red: 0.86, green: 0.89, blue: 0.91, alpha: 1)
        let fonts: [UIFont] = values.enumerated().map { index, _ in
            let prominent = emphasizeFirst && index == 0
            if prominent { return UIFont(name: "Georgia-BoldItalic", size: area.width * 0.052) ?? UIFont.italicSystemFont(ofSize: area.width * 0.052) }
            return UIFont.systemFont(ofSize: area.width * 0.024, weight: .regular)
        }
        var heights = values.enumerated().map { index, value in
            (value as NSString).size(withAttributes: [.font: fonts[index]]).height
        }
        let gap = area.height * 0.055
        let available = max(0, area.height - gap * CGFloat(max(values.count - 1, 0)))
        let inkTotal = heights.reduce(0, +)
        let scale = min(1, available / max(inkTotal, 1))
        if scale < 1 { heights = heights.map { $0 * scale } }
        var y = area.midY - (heights.reduce(0, +) + gap * CGFloat(max(values.count - 1, 0)) * scale) * 0.5
        for (index, value) in values.enumerated() {
            let font = fonts[index].withSize(max(9, fonts[index].pointSize * scale))
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: index == 0 ? color : muted]
            if drawsWatermark && index == values.count - 1 {
                attrs[.foregroundColor] = watermarkColor(watermark.color, preset).withAlphaComponent(CGFloat(watermark.opacityPercent) / 100)
                if watermark.effect == .shadow { let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: 1); shadow.shadowColor = UIColor.black.withAlphaComponent(0.35); attrs[.shadow] = shadow }
            }
            let line = (value as NSString).size(withAttributes: attrs)
            let x: CGFloat
            if drawsWatermark && index == values.count - 1 && watermark.position == .left {
                x = area.minX
            } else if drawsWatermark && index == values.count - 1 && watermark.position == .right {
                x = area.maxX - line.width
            } else {
                x = area.midX - line.width / 2
            }
            value.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            y += heights[index] + gap * scale
        }
    }

    private static func drawColorArchiveInformation(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata) {
        let photo = layout.photo
        let bandHeight = layout.canvas.height - photo.maxY
        let paletteWidth = photo.width * 0.23
        let textArea = CGRect(x: photo.minX,
                              y: photo.maxY + bandHeight * 0.12,
                              width: max(1, photo.width - paletteWidth - photo.width * 0.063),
                              height: bandHeight * 0.76)
        var rows: [(String, UIFont, UIColor, UIFont.Weight)] = []
        if !metadata.identity.isEmpty { rows.append((metadata.identity.uppercased(), UIFont.systemFont(ofSize: photo.width * 0.027, weight: .bold), .black, .bold)) }
        if let lens = metadata.lensModel, !lens.isEmpty { rows.append((lens, UIFont.systemFont(ofSize: photo.width * 0.0195), .black, .regular)) }
        if !metadata.frameDetailLine.isEmpty { rows.append((metadata.frameDetailLine, UIFont.systemFont(ofSize: photo.width * 0.022, weight: .bold), .black, .bold)) }
        if let date = metadata.dateTime, !date.isEmpty { rows.append((date, UIFont.systemFont(ofSize: photo.width * 0.0185), .black, .regular)) }
        if let location = metadata.locationRow, !location.isEmpty { rows.append((location, UIFont.systemFont(ofSize: photo.width * 0.0185), .black, .regular)) }
        guard !rows.isEmpty else { return }
        let gap = bandHeight * 0.055
        let heights = rows.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).height }
        let total = heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        let scale = min(1, textArea.height / max(total, 1))
        var y = textArea.midY - total * scale * 0.5
        for (index, row) in rows.enumerated() {
            let font = row.1.withSize(max(9, row.1.pointSize * scale))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: row.2]
            row.0.draw(at: CGPoint(x: textArea.minX, y: y), withAttributes: attrs)
            y += heights[index] * scale + gap * scale
        }
    }

    private static func drawFilmStrip(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata) {
        let photo = layout.photo, unit = photo.width, holeW = unit * 0.025, holeH = unit * 0.04, gap = unit * 0.025
        let outer = CGRect(x: photo.minX - unit * 0.018, y: photo.minY - unit * 0.09, width: photo.width + unit * 0.036, height: photo.height + unit * 0.18)
        cg.setFillColor(UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1).cgColor)
        let count = max(3, Int((outer.width - gap) / (holeW + gap)))
        let occupied = CGFloat(count) * holeW + CGFloat(count - 1) * gap, start = outer.midX - occupied / 2
        for i in 0..<count {
            let x = start + CGFloat(i) * (holeW + gap)
            cg.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: photo.minY - holeH - unit * 0.008, width: holeW, height: holeH), cornerRadius: holeW * 0.34).cgPath)
            cg.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: photo.maxY + unit * 0.008, width: holeW, height: holeH), cornerRadius: holeW * 0.34).cgPath)
        }
        cg.fillPath()
        let filmText = UIColor(red: 0.72, green: 0.52, blue: 0.39, alpha: 1)
        let labelFont = UIFont.boldSystemFont(ofSize: unit * 0.021)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: filmText]
        let topBaseline = outer.minY + unit * 0.028
        "2".draw(at: CGPoint(x: outer.minX + unit * 0.018, y: topBaseline - labelFont.ascender), withAttributes: labelAttrs)
        let identity = metadata.identity
        if !identity.isEmpty {
            identity.draw(at: CGPoint(x: outer.minX + unit * 0.15, y: topBaseline - labelFont.ascender), withAttributes: labelAttrs)
        }
        if let date = metadata.dateTime, !date.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: filmText]
            let width = (date as NSString).size(withAttributes: attrs).width
            date.draw(at: CGPoint(x: outer.midX + unit * 0.085 - width * 0.5, y: outer.maxY - unit * 0.014 - labelFont.ascender), withAttributes: attrs)
        }
        let triangle = UIBezierPath(); let tx = outer.maxX - unit * 0.14, ty = outer.minY + unit * 0.020
        triangle.move(to: CGPoint(x: tx, y: ty - unit * 0.010)); triangle.addLine(to: CGPoint(x: tx + unit * 0.022, y: ty)); triangle.addLine(to: CGPoint(x: tx, y: ty + unit * 0.010)); triangle.close()
        cg.setFillColor(filmText.cgColor); cg.addPath(triangle.cgPath); cg.fillPath()
    }

    private static func drawPalette(_ cg: CGContext, image: UIImage, layout: Layout) {
        // Android samples a 24×16 grid and selects the dominant separated
        // colors. Decode into a tiny known RGBA buffer so EXIF/image byte
        // order never changes the palette.
        let sw = 24, sh = 16
        var pixels = Array(repeating: UInt8(0), count: sw * sh * 4)
        guard let context = CGContext(data: &pixels, width: sw, height: sh, bitsPerComponent: 8,
                                       bytesPerRow: sw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let source = image.cgImage else { return }
        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var buckets = Array(repeating: (count: 0, r: 0, g: 0, b: 0), count: 512)
        for index in 0..<(sw * sh) {
            let offset = index * 4, r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            let bucket = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            buckets[bucket].count += 1; buckets[bucket].r += r; buckets[bucket].g += g; buckets[bucket].b += b
        }
        let candidates = buckets.filter { $0.count > 0 }.sorted { $0.count > $1.count }.map { (r: $0.r / $0.count, g: $0.g / $0.count, b: $0.b / $0.count) }
        var selected: [(r: Int, g: Int, b: Int)] = []
        for candidate in candidates where selected.count < 4 {
            if selected.allSatisfy({ let dr = $0.r - candidate.r, dg = $0.g - candidate.g, db = $0.b - candidate.b; return dr * dr + dg * dg + db * db >= 42 * 42 }) { selected.append(candidate) }
        }
        for candidate in candidates where selected.count < 4 && !selected.contains(where: { $0.r == candidate.r && $0.g == candidate.g && $0.b == candidate.b }) { selected.append(candidate) }
        selected.append(contentsOf: [(r: 31, g: 46, b: 61), (r: 194, g: 100, b: 46), (r: 46, g: 115, b: 82), (r: 202, g: 173, b: 97)])
        let sorted = selected.prefix(4).sorted { lhs, rhs in
            let l = lhs.r * 299 + lhs.g * 587 + lhs.b * 114
            let r = rhs.r * 299 + rhs.g * 587 + rhs.b * 114
            return l < r
        }
        let ordered = sorted.count == 4 ? [sorted[0], sorted[1], sorted[3], sorted[2]] : Array(sorted)
        let colors = ordered.map { UIColor(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1) }
        let bandHeight = layout.canvas.height - layout.photo.maxY
        let totalWidth = layout.photo.width * 0.23, size = layout.photo.width * 0.038
        let startX = layout.photo.maxX - layout.photo.width * 0.018 - totalWidth
        let y = layout.photo.maxY + bandHeight * 0.5 - size * 0.5
        for (index, color) in colors.enumerated() { cg.setFillColor(color.cgColor); cg.fill(CGRect(x: startX + CGFloat(index) * totalWidth / 4, y: y, width: totalWidth / 4, height: size)) }
    }

    private static func drawSideLabel(_ cg: CGContext, text: String, x: CGFloat, y: CGFloat, angle: CGFloat, color: UIColor, size: CGFloat) {
        cg.saveGState(); cg.translateBy(x: x, y: y); cg.rotate(by: angle)
        text.draw(at: CGPoint(x: -(text as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: size)]).width / 2, y: -size / 2), withAttributes: [.font: UIFont.boldSystemFont(ofSize: size), .foregroundColor: color]); cg.restoreGState()
    }

    // MARK: Watermark placement and sizing

    private static func drawWatermark(_ cg: CGContext, watermark: PhotoFrameWatermark, photo: CGRect, canvas: CGSize, preset: PhotoFramePreset, metadataBand: CGRect) {
        guard watermark.enabled else { return }
        if photoPlacement(watermark.position) { cg.saveGState(); cg.addPath(UIBezierPath(roundedRect: photo, cornerRadius: photo.width * 0.014).cgPath); cg.clip() }
        defer { if photoPlacement(watermark.position) { cg.restoreGState() } }
        var effective = watermark
        let isPhoto = photoPlacement(effective.position)
        // Android only places image watermarks inside the photo. Text watermarks
        // requested for a frame side are kept in the metadata band.
        if !isPhoto && effective.content == .image { effective.position = .photoBottomCenter }
        let inset = min(photo.width, photo.height) * 0.04
        if effective.content == .image, let hash = effective.imageHash, let image = PhotoEffectsStore.watermarkImage(hash: hash) {
            let height = min(photo.width, photo.height) * imageSizeFraction(effective.sizePercent)
            var width = height * image.size.width / max(image.size.height, 1)
            var targetHeight = height
            let maxWidth = max(1, photo.width - inset * 2)
            if width > maxWidth { let scale = maxWidth / width; width *= scale; targetHeight *= scale }
            let rect = watermarkRect(position: effective.position, photo: photo, size: CGSize(width: width, height: targetHeight), inset: inset)
            image.draw(in: rect, blendMode: .normal, alpha: CGFloat(effective.opacityPercent) / 100)
            return
        }
        let font = watermarkFont(effective.font, size: min(photo.width, photo.height) * textSizeFraction(effective.sizePercent))
        let text = effective.displayText
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: watermarkColor(effective.color, preset).withAlphaComponent(CGFloat(effective.opacityPercent) / 100)]
        let measured = (text as NSString).size(withAttributes: attrs)
        let rect: CGRect
        if isPhoto {
            rect = watermarkRect(position: effective.position, photo: photo, size: measured, inset: inset)
        } else {
            let x: CGFloat = switch effective.position { case .left: metadataBand.minX + metadataBand.width * 0.07; case .right: metadataBand.maxX - metadataBand.width * 0.07 - measured.width; default: metadataBand.midX - measured.width / 2 }
            rect = CGRect(x: max(metadataBand.minX, x), y: metadataBand.maxY - measured.height - metadataBand.height * 0.12, width: measured.width, height: measured.height)
        }
        var drawAttrs = attrs
        if effective.effect == .shadow || effective.effect == .auto { let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: 1); shadow.shadowColor = UIColor.black.withAlphaComponent(0.35); drawAttrs[.shadow] = shadow }
        if effective.effect == .outline { drawAttrs[.strokeWidth] = -1.5; drawAttrs[.strokeColor] = UIColor.white.withAlphaComponent(0.65) }
        text.draw(at: rect.origin, withAttributes: drawAttrs)
    }

    private static func watermarkRect(position: PhotoFrameWatermarkPosition, photo: CGRect, size: CGSize, inset: CGFloat) -> CGRect {
        let x: CGFloat = switch position { case .photoTopLeft, .photoBottomLeft: photo.minX + inset; case .photoTopRight, .photoBottomRight: photo.maxX - inset - size.width; default: photo.midX - size.width / 2 }
        let y: CGFloat = switch position { case .photoTopLeft, .photoTopCenter, .photoTopRight: photo.minY + inset; case .photoCenter: photo.midY - size.height / 2; default: photo.maxY - inset - size.height }
        return CGRect(x: max(photo.minX, x), y: max(photo.minY, y), width: size.width, height: size.height)
    }

    private static func photoPlacement(_ position: PhotoFrameWatermarkPosition) -> Bool {
        switch position { case .photoTopLeft, .photoTopCenter, .photoTopRight, .photoCenter, .photoBottomLeft, .photoBottomCenter, .photoBottomRight: return true; default: return false }
    }
    private static func brandPhotoPosition(_ position: PhotoFrameWatermarkPosition) -> PhotoFrameWatermarkPosition {
        switch position { case .left: return .photoBottomLeft; case .center: return .photoBottomCenter; default: return .photoBottomRight }
    }
    private static func editorialPhotoWatermark(_ value: PhotoFrameWatermark, preset: PhotoFramePreset) -> PhotoFrameWatermark {
        if photoPlacement(value.position) { return value }
        let mapped: PhotoFrameWatermarkPosition = switch value.position {
        case .left: .photoBottomLeft
        case .center: .photoBottomCenter
        case .right: .photoBottomRight
        case .auto: [.galleryMat, .filmGallery].contains(preset) ? .photoBottomCenter : .photoBottomRight
        default: .photoBottomRight
        }
        let usesPhoto: Bool = switch preset {
        case .classicSignature: value.position == .auto || value.content == .image
        case .colorArchive, .filmEdge: true
        case .galleryMat, .filmGallery: value.content == .image
        default: false
        }
        return usesPhoto ? value.withPosition(mapped) : value.copy(enabled: false)
    }
    private static func textSizeFraction(_ value: Int) -> CGFloat {
        let p = CGFloat(min(max(value, 2), 100) + 49)
        if p <= 58 { return 0.0105 * p / 58 }
        if p <= 75 { return 0.0105 + (p - 58) / 17 * (0.0135 - 0.0105) }
        if p <= 100 { return 0.0135 + (p - 75) / 25 * (0.018 - 0.0135) }
        return 0.018 * p / 100
    }
    private static func imageSizeFraction(_ value: Int) -> CGFloat {
        let p = CGFloat(min(max(value, 2), 100) + 49)
        if p <= 47 { return 0.035 * p / 47 }
        if p <= 69 { return 0.035 + (p - 47) / 22 * (0.052 - 0.035) }
        if p <= 100 { return 0.052 + (p - 69) / 31 * (0.075 - 0.052) }
        return 0.075 * p / 100
    }
    private static func watermarkFont(_ style: PhotoFrameWatermarkFont, size: CGFloat) -> UIFont {
        let name: String? = switch style { case .signature: "GreatVibes-Regular"; case .elegant: "CormorantGaramond-MediumItalic"; case .calligraphy: "BebasNeue-Regular"; default: nil }
        return (name.flatMap { UIFont(name: $0, size: size) }) ?? UIFont.systemFont(ofSize: size, weight: style == .bold ? .bold : .regular)
    }
    private static func watermarkColor(_ color: PhotoFrameWatermarkColor, _ preset: PhotoFramePreset) -> UIColor {
        switch color { case .black: .darkText; case .white: .white; case .gold: UIColor(red: 0.80, green: 0.67, blue: 0.44, alpha: 1); case .mistBlue: UIColor(red: 0.52, green: 0.62, blue: 0.71, alpha: 1); case .roseGold: UIColor(red: 0.73, green: 0.50, blue: 0.47, alpha: 1); case .adaptive: [PhotoFramePreset.mist, .cinema, .immersive, .brandInset, .brandGallery, .filmGallery, .filmEdge].contains(preset) ? .white : .black }
    }
}

private extension PhotoFrameMetadata {
    static let empty = PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
    /// Android resolves metadata visibility and date/time formatting before any
    /// frame branch draws. Keep the same single filtered snapshot on iOS so
    /// every border receives identical values and never invents rows.
    func resolved(for settings: PhotoFrameMetadataSettings) -> PhotoFrameMetadata {
        let modelValue = PhotoFrameMetadata(make: make, model: model, lensModel: lensModel,
                                            focalLength: focalLength, aperture: aperture,
                                            shutter: shutter, iso: iso,
                                            exposureCompensation: exposureCompensation,
                                            dateTime: dateTime).normalizedModel
        return PhotoFrameMetadata(
            make: settings.showBrand ? make : nil,
            model: settings.showModel ? modelValue : nil,
            lensModel: settings.showLensModel ? lensModel : nil,
            focalLength: settings.showFocalLength ? focalLength : nil,
            aperture: settings.showExposure ? aperture : nil,
            shutter: settings.showExposure ? shutter : nil,
            iso: settings.showExposure ? iso : nil,
            exposureCompensation: settings.showExposure ? exposureCompensation : nil,
            dateTime: formatDateTime(dateTime, settings: settings),
            latitude: settings.showCoordinates ? latitude : nil,
            longitude: settings.showCoordinates ? longitude : nil,
            altitude: settings.showAltitude ? altitude : nil
        )
    }
    var locationRow: String? {
        let coordinate: String? = {
            guard let latitude, let longitude,
                  latitude.isFinite, longitude.isFinite,
                  latitude != 0, longitude != 0,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            func degree(_ value: Double, positive: Character, negative: Character) -> String {
                let hemisphere = value < 0 ? negative : positive
                return String(format: "%.4f°%@", abs(value), String(hemisphere))
            }
            return "\(degree(latitude, positive: "N", negative: "S")), \(degree(longitude, positive: "E", negative: "W"))"
        }()
        let altitudeText = altitude.flatMap { $0.isFinite && $0 != 0 ? String(format: "%.0fm", $0) : nil }
        return [coordinate, altitudeText].compactMap { $0 }.joined(separator: "  ").nilIfEmpty
    }
    var identity: String { [normalizedMake, normalizedModel].filter { !$0.isEmpty }.joined(separator: " ") }
    var frameDetailLine: String {
        [focalLength,
         aperture?.replacingOccurrences(of: "f/", with: "F", options: .caseInsensitive),
         shutter.map { $0.lowercased().hasSuffix("s") ? $0 : "\($0)s" },
         iso.map { $0.uppercased().hasPrefix("ISO") ? $0 : "ISO\($0)" }]
            .compactMap { $0 }
            .joined(separator: "   ")
    }
    var classicSignatureDetailLine: String {
        [focalLength.map { $0.uppercased().hasPrefix("FL") ? $0 : "FL \($0)" },
         aperture.map { "Aperture \($0)" },
         shutter.map { "Shutter \($0.replacingOccurrences(of: "s", with: "", options: .caseInsensitive))" },
         iso.map { $0.uppercased().hasPrefix("ISO") ? $0 : "ISO\($0)" }]
            .compactMap { $0 }
            .joined(separator: "   ")
    }
    var editorialRows: [String] { [identity, lensModel ?? "", frameDetailLine, dateTime ?? "", locationRow ?? ""].filter { !$0.isEmpty } }
    var normalizedMake: String {
        let value = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let brands: [(String, String)] = [("nikon", "Nikon"), ("canon", "Canon"), ("sony", "SONY"), ("fujifilm", "FUJIFILM"), ("hasselblad", "Hasselblad"), ("leica", "Leica"), ("panasonic", "Panasonic"), ("olympus", "OM SYSTEM"), ("om digital", "OM SYSTEM"), ("pentax", "PENTAX"), ("ricoh", "RICOH"), ("apple", "Apple"), ("samsung", "SAMSUNG"), ("google", "Google"), ("xiaomi", "XIAOMI"), ("redmi", "XIAOMI"), ("huawei", "HUAWEI"), ("honor", "HONOR"), ("oneplus", "ONEPLUS"), ("oppo", "OPPO"), ("vivo", "VIVO"), ("realme", "REALME"), ("motorola", "MOTOROLA")]
        return brands.first(where: { value.localizedCaseInsensitiveContains($0.0) })?.1 ?? value
    }
    var normalizedModel: String {
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return "" }
        let prefixes = [make, normalizedMake].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        if let prefix = prefixes.first(where: { value.range(of: "^\(NSRegularExpression.escapedPattern(for: $0))", options: [.regularExpression, .caseInsensitive]) != nil }) {
            return String(value.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        }
        return value
    }
    func rows(_ settings: PhotoFrameMetadataSettings) -> [String] {
        var values: [String] = []
        if settings.showBrand, !normalizedMake.isEmpty { values.append(normalizedMake) }
        if settings.showModel, !normalizedModel.isEmpty { values.append(normalizedModel) }
        if settings.showLensModel, let lensModel, !lensModel.isEmpty { values.append(lensModel) }
        let detail = [settings.showFocalLength ? focalLength : nil, settings.showExposure ? [aperture, shutter, iso].compactMap { $0 }.joined(separator: "  ") : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ")
        if !detail.isEmpty { values.append(detail) }
        if settings.showDate, let dateTime, !dateTime.isEmpty { values.append(dateTime) }
        if let locationRow, !locationRow.isEmpty { values.append(locationRow) }
        return values
    }

    private func formatDateTime(_ value: String?, settings: PhotoFrameMetadataSettings) -> String? {
        guard let value, !value.isEmpty, settings.showDate || settings.showTime else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        let date = parts.first?.replacingOccurrences(of: ":", with: "-")
        let time = parts.count > 1 ? parts[1] : nil
        var output: [String] = []
        if settings.showDate, let date {
            output.append(applyDatePattern(date, pattern: settings.datePattern))
        }
        if settings.showTime, let time { output.append(applyTimePattern(time, pattern: settings.timePattern)) }
        return output.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty
    }
    private func applyDatePattern(_ value: String, pattern: String) -> String {
        let digits = value.split(separator: "-")
        guard digits.count >= 3 else { return value }
        let map: [String: String] = ["yyyy": String(digits[0]), "MM": String(digits[1]), "dd": String(digits[2])]
        var result = pattern
        for (token, replacement) in map { result = result.replacingOccurrences(of: token, with: replacement) }
        return result
    }
    private func applyTimePattern(_ value: String, pattern: String) -> String {
        let digits = value.split(separator: ":")
        guard digits.count >= 2 else { return value }
        let map: [String: String] = ["HH": String(digits[0]), "mm": String(digits[1]), "ss": digits.count > 2 ? String(digits[2]) : "00"]
        var result = pattern
        for (token, replacement) in map { result = result.replacingOccurrences(of: token, with: replacement) }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension PhotoFrameWatermark {
    func withPosition(_ value: PhotoFrameWatermarkPosition) -> Self { var copy = self; copy.position = value; return copy }
    func copy(enabled: Bool) -> Self { var copy = self; copy.enabled = enabled; return copy }
}
