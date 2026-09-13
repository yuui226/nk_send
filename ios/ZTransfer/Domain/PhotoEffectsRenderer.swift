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

    static func render(_ image: UIImage, settings: PhotoEffectsSettings, metadata: PhotoFrameMetadata? = nil) throws -> UIImage {
        try Task.checkCancellation()
        var output = image
        if settings.photoFilterEnabled, let filter = settings.selectedFilter {
            output = try applyFilter(output, selection: filter)
        }
        if settings.photoFrameEnabled {
            if !settings.photoFrameBorderEnabled && settings.watermark.enabled {
                output = drawWatermarkOnly(output, watermark: settings.watermark)
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
            if settings.photoFrameBorderEnabled {
                drawPhoto(cg, image: image, rect: layout.photo, preset: settings.photoFramePreset)
            } else {
                image.draw(in: layout.photo)
            }
            drawPresetDecoration(cg, image: image, layout: layout,
                                 preset: settings.photoFramePreset,
                                 metadata: metadata,
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
            let canvas: CGSize
            if aspect > 1.9 { canvas = CGSize(width: 1, height: 0.5625) }
            else if aspect > 1.1 { canvas = CGSize(width: 1, height: 0.75) }
            else if aspect >= 0.9 { canvas = CGSize(width: 1, height: 1) }
            else if aspect >= 0.72 { canvas = CGSize(width: 0.75, height: 1) }
            else if aspect >= 0.56 { canvas = CGSize(width: 2.0 / 3.0, height: 1) }
            else { canvas = CGSize(width: 0.5625, height: 1) }
            let longEdge = max(w, h)
            let canvasSize = CGSize(width: canvas.width * longEdge, height: canvas.height * longEdge)
            let portrait = canvasSize.height > canvasSize.width, square = abs(canvasSize.height - canvasSize.width) < 0.5
            let side = canvasSize.width * 0.052
            let top = canvasSize.height * (portrait ? 0.030 : square ? 0.040 : 0.050)
            let metadataTop = canvasSize.height * (portrait ? 0.900 : square ? 0.870 : 0.830)
            let availableWidth = canvasSize.width - side * 2
            let availableHeight = metadataTop - top - canvasSize.height * 0.012
            let scale = min(availableWidth / w, availableHeight / h)
            let photoSize = CGSize(width: w * scale, height: h * scale)
            let left = (canvasSize.width - photoSize.width) / 2
            let centerY = top + availableHeight / 2
            return Layout(canvas: canvasSize, photo: CGRect(x: left, y: centerY - photoSize.height / 2, width: photoSize.width, height: photoSize.height), metadataTop: metadataTop)
        }
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
            if preset == .frosted { drawGradient(cg, rect: rect, top: UIColor(white: 0.98, alpha: 0.36), bottom: UIColor(red: 0.90, green: 0.94, blue: 0.96, alpha: 0.54)) }
            if preset == .filmGallery { cg.setFillColor(UIColor(red: 0.07, green: 0.05, blue: 0.04, alpha: 0.26).cgColor); cg.fill(rect) }
        case .plaque, .brandInset, .brandGallery, .classicSignature, .galleryMat, .colorArchive:
            cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(rect)
        case .immersive:
            break
        case .filmEdge:
            cg.setFillColor(UIColor(red: 0.027, green: 0.027, blue: 0.031, alpha: 1).cgColor); cg.fill(rect)
        }
    }

    private static func drawPhoto(_ cg: CGContext, image: UIImage, rect: CGRect, preset: PhotoFramePreset) {
        let radius = rect.width * (preset == .colorArchive ? 0.012 : preset == .brandInset || preset == .brandGallery ? 0.014 : 0.018)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        if ![.plaque, .immersive, .filmEdge].contains(preset) {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: rect.width * 0.009), blur: rect.width * 0.018, color: UIColor.black.withAlphaComponent(0.20).cgColor)
            cg.setFillColor(UIColor.white.cgColor); cg.addPath(path); cg.fillPath()
            cg.restoreGState()
        }
        cg.saveGState(); cg.addPath(path); cg.clip(); image.draw(in: rect); cg.restoreGState()
        if preset != .plaque && preset != .immersive && preset != .filmEdge {
            cg.setStrokeColor(UIColor(white: 1, alpha: 0.28).cgColor); cg.setLineWidth(max(1, rect.width * 0.0012)); cg.addPath(path); cg.strokePath()
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

    private static func drawStandardMetadata(_ cg: CGContext, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        let area = CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY)
        drawAndroidMetadata(cg, area: area, preset: preset, metadata: metadata, watermark: watermark, settings: settings,
                            lightText: preset == .mist || preset == .cinema)
        var photoWatermark = watermark
        if !photoPlacement(photoWatermark.position) && photoWatermark.content == .image { photoWatermark.position = .photoBottomCenter }
        drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: preset, metadataBand: area)
    }

    private static func drawAndroidMetadata(_ cg: CGContext, area: CGRect, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings, lightText: Bool) {
        let brand = settings.showBrand ? metadata.normalizedMake : ""
        let model = settings.showModel ? metadata.normalizedModel : ""
        let lens = settings.showLensModel ? (metadata.lensModel ?? "") : ""
        var detail = ""
        if settings.showFocalLength { detail = metadata.focalLength ?? "" }
        if settings.showExposure {
            let exposure = [metadata.aperture, metadata.shutter, metadata.iso, metadata.exposureCompensation].compactMap { $0 }.joined(separator: "   ")
            if !exposure.isEmpty { detail = detail.isEmpty ? exposure : detail + "   " + exposure }
        }
        var rows: [(String, CGFloat, UIFont.Weight)] = []
        let title = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !title.isEmpty { rows.append((title, area.width * 0.032, .bold)) }
        if !lens.isEmpty { rows.append((lens, area.width * 0.0185, .medium)) }
        if !detail.isEmpty { rows.append((detail, area.width * 0.020, .regular)) }
        if settings.showDate, let date = metadata.dateTime, !date.isEmpty { rows.append((date, area.width * 0.020, .regular)) }
        if watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position) { rows.append((watermark.displayText, area.width * textSizeFraction(watermark.sizePercent), .regular)) }
        guard !rows.isEmpty else { return }
        let gap = min(area.width * 0.0125, area.height * 0.09)
        let heights = rows.map { ($0.1 * 1.18) }
        let total = heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        let scale = min(1, max(0.2, (area.height * 0.84) / max(total, 1)))
        var y = area.midY - total * scale * 0.5
        let color = lightText ? UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1) : UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        let muted = lightText ? UIColor(red: 0.86, green: 0.89, blue: 0.91, alpha: 1) : UIColor(red: 0.29, green: 0.31, blue: 0.33, alpha: 1)
        for (index, row) in rows.enumerated() {
            let font = UIFont.systemFont(ofSize: max(9, row.1 * scale), weight: row.2)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: index == 0 ? color : muted]
            if row.0 == watermark.displayText && watermark.effect == .shadow { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowOffset = CGSize(width: 0, height: 1); s.shadowColor = UIColor.black.withAlphaComponent(0.35); attrs[.shadow] = s }
            let width = (row.0 as NSString).size(withAttributes: attrs).width
            let x: CGFloat = switch watermark.position { case .left where row.0 == watermark.displayText: area.minX + area.width * 0.07; case .right where row.0 == watermark.displayText: area.maxX - area.width * 0.07 - width; default: area.midX - width * 0.5 }
            row.0.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            y += (heights[index] + gap) * scale
        }
    }

    private static func drawPlaque(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        let band = CGRect(x: 0, y: layout.metadataTop, width: layout.canvas.width, height: layout.canvas.height - layout.metadataTop)
        cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(band)
        cg.setFillColor(UIColor(red: 0.90, green: 0.91, blue: 0.90, alpha: 1).cgColor); cg.fill(CGRect(x: 0, y: band.minY, width: band.width, height: max(1, band.width * 0.0008)))
        let leftPrimary = metadata.normalizedMake.isEmpty ? (metadata.normalizedModel.isEmpty ? (metadata.lensModel ?? "") : metadata.normalizedModel) : metadata.normalizedMake.uppercased()
        let leftSecondary = [metadata.normalizedModel, metadata.lensModel ?? ""].filter { !$0.isEmpty && $0 != leftPrimary }.joined(separator: " · ")
        let left = [leftPrimary, leftSecondary].filter { !$0.isEmpty }
        let right = [metadata.frameDetailLine, metadata.dateTime].compactMap { $0 }.filter { !$0.isEmpty } + metadata.rows(settings).filter { !$0.isEmpty && !$0.contains(metadata.identity) }
        drawTwoColumnRows(cg, band: band, left: left, right: right)
        drawWatermark(cg, watermark: watermark, photo: layout.photo, canvas: layout.canvas, preset: .plaque, metadataBand: CGRect(x: 0, y: layout.metadataTop, width: layout.canvas.width, height: layout.canvas.height - layout.metadataTop))
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
        let rows = metadata.rows(settings)
        // Brand frames use compact white typography over the lower part of the
        // photo. The gallery variant reserves that space for the photo itself
        // and puts the identity in its separate lower band.
        let visibleRows = preset == .brandInset ? rows : Array(rows.dropFirst())
        drawMetadataRows(cg, area: photoArea.insetBy(dx: photo.width * 0.08, dy: photo.height * 0.06), preset: preset,
                         rows: visibleRows, watermark: photoWatermark, dark: false, insidePhoto: true)
        drawWatermark(cg, watermark: photoWatermark, photo: photo, canvas: layout.canvas, preset: preset,
                      metadataBand: CGRect(x: 0, y: photo.maxY, width: layout.canvas.width, height: layout.canvas.height - photo.maxY))
        if preset == .brandGallery {
            var bandRows = [metadata.identity].filter { !$0.isEmpty }
            if watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position), watermark.position != .auto {
                bandRows.insert(watermark.displayText, at: 0)
            }
            drawMetadataRows(cg, area: CGRect(x: 0, y: photo.maxY, width: layout.canvas.width, height: layout.canvas.height - photo.maxY).insetBy(dx: layout.canvas.width * 0.07, dy: layout.canvas.height * 0.02), preset: preset, rows: bandRows, watermark: watermark, dark: true)
        }
    }

    private static func drawImmersive(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark) {
        let lower = CGRect(x: 0, y: layout.canvas.height * 0.52, width: layout.canvas.width, height: layout.canvas.height * 0.48)
        drawGradient(cg, rect: lower, top: UIColor(white: 0, alpha: 0), bottom: UIColor(white: 0, alpha: 0.46))
        let area = CGRect(x: layout.canvas.width * 0.07, y: layout.canvas.height * 0.66, width: layout.canvas.width * 0.86, height: layout.canvas.height * 0.29)
        let title = metadata.identity
        let titleFont = UIFont.systemFont(ofSize: min(layout.canvas.width * 0.030, area.width * 0.08), weight: .medium)
        let detailFont = UIFont.systemFont(ofSize: min(layout.canvas.width * 0.021, area.width * 0.058), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.white, .shadow: { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowOffset = CGSize(width: 0, height: 1); s.shadowColor = UIColor.black.withAlphaComponent(0.55); return s }()]
        let detailAttrs: [NSAttributedString.Key: Any] = [.font: detailFont, .foregroundColor: UIColor.white.withAlphaComponent(0.92)]
        var lines = [String](); if let lens = metadata.lensModel, !lens.isEmpty { lines.append(lens) }; if !metadata.frameDetailLine.isEmpty { lines.append(metadata.frameDetailLine) }; if let date = metadata.dateTime, !date.isEmpty { lines.append(date) }
        let rowCount = (title.isEmpty ? 0 : 1) + lines.count
        let gap = area.height * 0.055, totalHeight = CGFloat(rowCount) * titleFont.lineHeight + CGFloat(max(0, rowCount - 1)) * gap
        var y = area.midY - totalHeight * 0.5
        if !title.isEmpty { title.draw(at: CGPoint(x: area.midX - (title as NSString).size(withAttributes: attrs).width * 0.5, y: y), withAttributes: attrs); y += titleFont.lineHeight + gap }
        for line in lines { let width = (line as NSString).size(withAttributes: detailAttrs).width; line.draw(at: CGPoint(x: area.midX - width * 0.5, y: y), withAttributes: detailAttrs); y += detailFont.lineHeight + gap }
        var photoWatermark = watermark
        if !photoPlacement(photoWatermark.position) { photoWatermark.position = .photoBottomRight }
        drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: .immersive, metadataBand: area)
    }

    private static func drawEditorial(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        switch preset {
        case .galleryMat:
            cg.setFillColor(UIColor.black.cgColor); cg.fill(CGRect(x: layout.photo.minX - layout.photo.width * 0.045, y: layout.photo.minY - layout.photo.height * 0.045, width: layout.photo.width * 1.09, height: layout.photo.height * 1.09))
            drawMetadataRows(cg, area: CGRect(x: layout.canvas.width * 0.08, y: layout.photo.maxY + layout.photo.width * 0.045, width: layout.canvas.width * 0.84, height: layout.canvas.height - layout.photo.maxY - layout.photo.width * 0.05), preset: preset, rows: metadata.editorialRows, watermark: watermark, dark: true)
        case .colorArchive:
            drawPalette(cg, image: image, layout: layout)
            drawMetadataRows(cg, area: CGRect(x: layout.canvas.width * 0.08, y: layout.photo.maxY, width: layout.canvas.width * 0.84, height: layout.canvas.height - layout.photo.maxY), preset: preset, rows: metadata.editorialRows, watermark: watermark, dark: true)
        case .filmGallery:
            drawFilmStrip(cg, layout: layout, metadata: metadata)
            drawMetadataRows(cg, area: CGRect(x: layout.canvas.width * 0.08, y: layout.photo.maxY + layout.photo.width * 0.12, width: layout.canvas.width * 0.84, height: layout.canvas.height - layout.photo.maxY - layout.photo.width * 0.12), preset: preset, rows: metadata.editorialRows.filter { $0 != metadata.identity }, watermark: watermark, dark: false)
        case .filmEdge:
            drawSideLabel(cg, text: "PORTRA 400", x: layout.photo.minX * 0.48, y: layout.photo.midY, angle: -.pi / 2, color: UIColor(red: 0.87, green: 0.65, blue: 0.47, alpha: 1), size: layout.photo.width * 0.028)
            drawSideLabel(cg, text: "▶  20", x: layout.photo.maxX + (layout.canvas.width - layout.photo.maxX) * 0.52, y: layout.photo.minY + layout.photo.height * 0.22, angle: .pi / 2, color: UIColor(red: 0.87, green: 0.65, blue: 0.47, alpha: 1), size: layout.photo.width * 0.028)
            drawMetadataRows(cg, area: CGRect(x: layout.photo.minX, y: layout.photo.maxY, width: layout.photo.width, height: layout.canvas.height - layout.photo.maxY), preset: preset, rows: metadata.rows(settings), watermark: watermark, dark: false)
        case .classicSignature:
            drawMetadataRows(cg, area: CGRect(x: 0, y: 0, width: layout.canvas.width, height: layout.photo.minY), preset: preset, rows: [metadata.identity].filter { !$0.isEmpty }, watermark: watermark, dark: true)
            drawMetadataRows(cg, area: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY), preset: preset, rows: metadata.rows(settings), watermark: watermark, dark: true)
        default: break
        }
        let photoWatermark = editorialPhotoWatermark(watermark, preset: preset)
        drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: preset, metadataBand: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY))
        if let bandWatermark = editorialBandWatermark(watermark, preset: preset) {
            drawWatermark(cg, watermark: bandWatermark, photo: layout.photo, canvas: layout.canvas, preset: preset, metadataBand: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY))
        }
    }

    private static func drawMetadataRows(_ cg: CGContext, area: CGRect, preset: PhotoFramePreset, rows: [String], watermark: PhotoFrameWatermark, dark: Bool, insidePhoto: Bool = false) {
        guard area.height > 1 else { return }
        let values = rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !values.isEmpty else { return }
        let color = dark ? UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1) : UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
        let muted = dark ? UIColor(red: 0.29, green: 0.31, blue: 0.33, alpha: 1) : UIColor(red: 0.86, green: 0.89, blue: 0.91, alpha: 1)
        let gap = min(area.width * 0.0125, area.height * 0.09)
        let rowHeight = min(area.height * 0.82 / CGFloat(values.count), area.width * 0.032)
        let total = rowHeight * CGFloat(values.count) + gap * CGFloat(max(values.count - 1, 0))
        var y = area.midY - total / 2
        for (index, value) in values.enumerated() {
            let font = UIFont.systemFont(ofSize: max(9, rowHeight * (index == 0 ? 0.82 : 0.62)), weight: index == 0 ? .semibold : .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: index == 0 ? color : muted]
            let line = (value as NSString).size(withAttributes: attrs)
            let x = area.midX - min(line.width, area.width * 0.9) / 2
            value.draw(at: CGPoint(x: x, y: y + rowHeight * 0.18), withAttributes: attrs)
            y += rowHeight + gap
        }
    }

    private static func drawTwoColumnRows(_ cg: CGContext, band: CGRect, left: [String], right: [String]) {
        let leftValues = left.filter { !$0.isEmpty }, rightValues = right.filter { !$0.isEmpty }
        let font = UIFont.systemFont(ofSize: band.width * 0.024, weight: .regular)
        let bold = UIFont.systemFont(ofSize: band.width * 0.027, weight: .medium)
        for (index, value) in leftValues.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: index == 0 ? bold : font, .foregroundColor: UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)]
            value.draw(at: CGPoint(x: band.width * 0.058, y: band.minY + band.height * (0.28 + CGFloat(index) * 0.22)), withAttributes: attrs)
        }
        for (index, value) in rightValues.prefix(3).enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: index == 0 ? bold : font, .foregroundColor: UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)]
            let width = (value as NSString).size(withAttributes: attrs).width
            value.draw(at: CGPoint(x: band.width * 0.94 - width, y: band.minY + band.height * (0.22 + CGFloat(index) * 0.23)), withAttributes: attrs)
        }
    }

    private static func drawFilmStrip(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata) {
        let photo = layout.photo, unit = photo.width, holeW = unit * 0.025, holeH = unit * 0.04, gap = unit * 0.025
        let outer = CGRect(x: photo.minX - unit * 0.018, y: photo.minY - unit * 0.09, width: photo.width + unit * 0.036, height: photo.height + unit * 0.18)
        cg.setFillColor(UIColor(red: 0.05, green: 0.055, blue: 0.063, alpha: 1).cgColor); cg.fill(outer)
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
        "2".draw(at: CGPoint(x: outer.minX + unit * 0.018, y: outer.minY + unit * 0.006), withAttributes: labelAttrs)
        let identity = metadata.identity
        if !identity.isEmpty {
            identity.draw(at: CGPoint(x: outer.minX + unit * 0.15, y: outer.minY + unit * 0.006), withAttributes: labelAttrs)
        }
        if let date = metadata.dateTime, !date.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: filmText]
            let width = (date as NSString).size(withAttributes: attrs).width
            date.draw(at: CGPoint(x: outer.midX + unit * 0.085 - width * 0.5, y: outer.maxY - unit * 0.028), withAttributes: attrs)
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
        var colors = buckets.filter { $0.count > 0 }.sorted { $0.count > $1.count }.prefix(4).map {
            UIColor(red: CGFloat($0.r / $0.count) / 255, green: CGFloat($0.g / $0.count) / 255, blue: CGFloat($0.b / $0.count) / 255, alpha: 1)
        }
        colors.append(contentsOf: [UIColor(red: 0.12, green: 0.18, blue: 0.24, alpha: 1), UIColor(red: 0.76, green: 0.39, blue: 0.18, alpha: 1), UIColor(red: 0.18, green: 0.45, blue: 0.32, alpha: 1), UIColor(red: 0.79, green: 0.68, blue: 0.38, alpha: 1)])
        colors = Array(colors.prefix(4))
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
            let width = height * image.size.width / max(image.size.height, 1)
            let rect = watermarkRect(position: effective.position, photo: photo, size: CGSize(width: width, height: height), inset: inset)
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
    private static func editorialBandWatermark(_ value: PhotoFrameWatermark, preset: PhotoFramePreset) -> PhotoFrameWatermark? {
        guard value.enabled, value.content == .text, !photoPlacement(value.position) else { return nil }
        guard [.classicSignature, .galleryMat, .filmGallery].contains(preset) else { return nil }
        return value.withPosition(value.position == .auto ? .center : value.position)
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
    var identity: String { [normalizedMake, normalizedModel].filter { !$0.isEmpty }.joined(separator: " ") }
    var frameDetailLine: String { [focalLength, aperture, shutter, iso, exposureCompensation].compactMap { $0 }.joined(separator: "   ") }
    var editorialRows: [String] { [identity, lensModel ?? "", frameDetailLine, dateTime ?? ""].filter { !$0.isEmpty } }
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
        let detail = [settings.showFocalLength ? focalLength : nil, settings.showExposure ? [aperture, shutter, iso, exposureCompensation].compactMap { $0 }.joined(separator: "  ") : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ")
        if !detail.isEmpty { values.append(detail) }
        if settings.showDate, let dateTime, !dateTime.isEmpty { values.append(dateTime) }
        return values
    }
}

private extension PhotoFrameWatermark {
    func withPosition(_ value: PhotoFrameWatermarkPosition) -> Self { var copy = self; copy.position = value; return copy }
    func copy(enabled: Bool) -> Self { var copy = self; copy.enabled = enabled; return copy }
}
