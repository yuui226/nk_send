import UIKit
import CoreText

/// Native renderer following PhotoFrameExporter.kt's ordered pipeline.
/// Source -> NP3 filter -> frame backdrop/photo -> metadata/watermark.
enum PhotoEffectsRenderer {
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
                if settings.photoFramePreset == .galleryMat {
                    // Android lifts the black mat as its own Minimal-style
                    // surface before drawing the source photo above it.
                    drawStandardPhotoElevation(cg, rect: outer, radius: 0,
                                                preset: .minimal, canvasSize: layout.canvas)
                }
                cg.setFillColor(UIColor(red: 0.025, green: 0.027, blue: 0.031, alpha: 1).cgColor)
                cg.fill(outer)
            }
            if settings.photoFrameBorderEnabled {
                drawPhoto(cg, image: image, rect: layout.photo, preset: settings.photoFramePreset,
                          metadataBandHeight: layout.canvas.height - layout.metadataTop,
                          canvasSize: layout.canvas)
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
        let px: (CGFloat) -> CGFloat = { max(1, $0.rounded()) }
        switch preset {
        case .plaque:
            let band = px(w * 0.12)
            return Layout(canvas: CGSize(width: w, height: h + band), photo: CGRect(x: 0, y: 0, width: w, height: h), metadataTop: h)
        case .immersive:
            return Layout(canvas: source, photo: CGRect(origin: .zero, size: source), metadataTop: h)
        case .brandInset, .brandGallery:
            let side = px(w * 0.032)
            let bottom = px(w * (preset == .brandInset ? 0.032 : 0.16))
            return Layout(canvas: CGSize(width: w + side * 2, height: h + side + bottom),
                          photo: CGRect(x: side, y: side, width: w, height: h), metadataTop: side + h)
        case .classicSignature, .galleryMat, .colorArchive, .filmGallery, .filmEdge:
            switch preset {
            case .classicSignature:
                let side = px(w * 0.03), top = px(w * 0.095), bottom = px(w * 0.15)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            case .galleryMat:
                let (wf, hf): (CGFloat, CGFloat) = aspect > 1.08 ? (0.80, 0.56) : aspect < 0.92 ? (0.56, 0.80) : (0.68, 0.68)
                let side = max(w / wf, h / hf), left = (side - w) / 2, top = (side - h) * 0.45
                return Layout(canvas: CGSize(width: side, height: side), photo: CGRect(x: left, y: top, width: w, height: h), metadataTop: top + h)
            case .colorArchive:
                let side = px(w * 0.04), top = px(w * 0.04), bottom = px(w * 0.17)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            case .filmGallery:
                let side = px(w * 0.085), top = px(w * 0.16), bar = px(w * 0.09), bottom = px(w * 0.34)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bar * 2 + bottom), photo: CGRect(x: side, y: top + bar, width: w, height: h), metadataTop: top + bar + h + bar)
            case .filmEdge:
                let side = px(w * 0.07), top = px(w * 0.035), bottom = px(w * 0.085)
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
            if preset == .mist {
                cg.setFillColor(UIColor(red: 0.93, green: 0.95, blue: 0.97, alpha: 62.0 / 255.0).cgColor); cg.fill(rect)
                drawGradient(cg, rect: CGRect(x: 0, y: rect.height * 0.58, width: rect.width, height: rect.height * 0.42),
                             top: UIColor(red: 3.0 / 255.0, green: 10.0 / 255.0, blue: 15.0 / 255.0, alpha: 0),
                             bottom: UIColor(red: 3.0 / 255.0, green: 10.0 / 255.0, blue: 15.0 / 255.0, alpha: 178.0 / 255.0))
            }
            if preset == .cinema {
                cg.setFillColor(UIColor(red: 3.0 / 255.0, green: 9.0 / 255.0, blue: 15.0 / 255.0, alpha: 150.0 / 255.0).cgColor); cg.fill(rect)
                drawGradient(cg, rect: CGRect(x: 0, y: rect.height * 0.60, width: rect.width, height: rect.height * 0.40),
                             top: UIColor(white: 0, alpha: 0), bottom: UIColor(white: 0, alpha: 110.0 / 255.0))
            }
            if preset == .frosted {
                drawGradient(cg, rect: rect,
                             top: UIColor(red: 250.0 / 255.0, green: 253.0 / 255.0, blue: 255.0 / 255.0, alpha: 92.0 / 255.0),
                             bottom: UIColor(red: 231.0 / 255.0, green: 239.0 / 255.0, blue: 245.0 / 255.0, alpha: 132.0 / 255.0))
            }
            if preset == .filmGallery {
                cg.setFillColor(UIColor(red: 18.0 / 255.0, green: 12.0 / 255.0, blue: 10.0 / 255.0, alpha: 66.0 / 255.0).cgColor); cg.fill(rect)
                drawGradient(cg, rect: CGRect(x: 0, y: rect.height * 0.48, width: rect.width, height: rect.height * 0.52),
                             top: UIColor(white: 0, alpha: 0), bottom: UIColor(red: 15.0 / 255.0, green: 10.0 / 255.0, blue: 8.0 / 255.0, alpha: 92.0 / 255.0))
            }
        case .plaque, .brandInset, .brandGallery, .classicSignature, .galleryMat, .colorArchive:
            cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(rect)
        case .immersive:
            break
        case .filmEdge:
            cg.setFillColor(UIColor(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 9.0 / 255.0, alpha: 1).cgColor); cg.fill(rect)
        }
    }

    private static func drawPhoto(_ cg: CGContext, image: UIImage, rect: CGRect, preset: PhotoFramePreset, metadataBandHeight: CGFloat, canvasSize: CGSize) {
        let radius: CGFloat = switch preset {
        case .colorArchive: rect.width * 0.012
        case .brandInset, .brandGallery: rect.width * 0.014
        case .mist, .cinema, .minimal, .frosted: max(1, metadataBandHeight * 0.26)
        case .plaque, .immersive, .classicSignature, .galleryMat, .filmGallery, .filmEdge: 0
        default: rect.width * 0.018
        }
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        if [.mist, .cinema, .minimal, .frosted, .brandInset, .brandGallery, .colorArchive].contains(preset) {
            drawStandardPhotoElevation(cg, rect: rect, radius: radius, preset: preset, canvasSize: canvasSize)
        } else if ![.plaque, .immersive, .filmEdge, .classicSignature, .filmGallery].contains(preset) {
            drawPhotoElevation(cg, rect: rect, radius: radius, preset: preset, canvasSize: canvasSize)
        }
        cg.saveGState(); cg.addPath(path); cg.clip(); image.draw(in: rect); cg.restoreGState()
        if preset == .classicSignature {
            cg.setStrokeColor(UIColor(white: 0, alpha: 0.14).cgColor)
            cg.setLineWidth(max(1, rect.width * 0.0008))
            cg.addPath(path)
            cg.strokePath()
        } else if preset != .plaque && preset != .immersive && preset != .filmEdge && preset != .filmGallery {
            let stroke: UIColor
            if preset == .brandInset || preset == .brandGallery {
                stroke = UIColor(red: 0.06, green: 0.08, blue: 0.09, alpha: 0.18)
            } else {
                stroke = UIColor(white: 1, alpha: 0.275)
            }
            cg.setStrokeColor(stroke.cgColor); cg.setLineWidth(max(1, rect.width * 0.0012)); cg.addPath(path); cg.strokePath()
        }
    }

    /// 安卓标准四种照片边框都只有贴边的接触阴影。CoreGraphics 的大半径代理
    /// 阴影在 iOS 预览缩放后会变成照片下方的灰色圆角块，因此这些预设直接在
    /// 主画布绘制窄阴影；毛玻璃的信息面板仍由其独立路径绘制。
    private static func drawStandardPhotoElevation(_ cg: CGContext, rect: CGRect, radius: CGFloat, preset: PhotoFramePreset, canvasSize: CGSize) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        let opacity: CGFloat = preset == .cinema ? 0.20 : 0.16
        cg.saveGState()
        cg.setFillColor(UIColor(white: 0, alpha: 0.01).cgColor)
        cg.setShadow(offset: CGSize(width: 0, height: max(1, canvasSize.height * 0.0012)),
                     blur: max(1, min(canvasSize.width, canvasSize.height) * 0.0028),
                     color: UIColor(red: 8.0 / 255.0, green: 15.0 / 255.0, blue: 21.0 / 255.0,
                                    alpha: opacity).cgColor)
        cg.addPath(path)
        cg.fillPath()
        cg.restoreGState()
    }

    /// Android renders elevation for the other standard presets on a quarter-size proxy.
    private static func drawPhotoElevation(_ cg: CGContext, rect: CGRect, radius: CGFloat, preset: PhotoFramePreset, canvasSize: CGSize) {
        let strength: CGFloat = switch preset {
        case .cinema: 1.15
        case .minimal, .brandInset, .brandGallery, .colorArchive: 0.78
        case .mist, .frosted: 1.0
        default: 0
        }
        guard strength > 0, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let proxyScale: CGFloat = 0.25
        let shortEdge = min(canvasSize.width, canvasSize.height)
        let proxySize = CGSize(width: max(1, (canvasSize.width * proxyScale).rounded()), height: max(1, (canvasSize.height * proxyScale).rounded()))
        let proxyFormat = UIGraphicsImageRendererFormat()
        proxyFormat.scale = 1
        proxyFormat.opaque = false
        let proxy = UIGraphicsImageRenderer(size: proxySize, format: proxyFormat).image { renderer in
            let context = renderer.cgContext
            let proxyRect = CGRect(x: rect.minX * proxyScale, y: rect.minY * proxyScale, width: rect.width * proxyScale, height: rect.height * proxyScale)
            let proxyRadius = radius * proxyScale
            let proxyPath = UIBezierPath(roundedRect: proxyRect, cornerRadius: proxyRadius).cgPath
            context.setFillColor(UIColor(white: 0, alpha: 18.0 / 255.0).cgColor)
            context.setShadow(offset: CGSize(width: 0, height: shortEdge * 0.003 * proxyScale), blur: shortEdge * 0.020 * proxyScale, color: UIColor(red: 8.0 / 255.0, green: 15.0 / 255.0, blue: 21.0 / 255.0, alpha: 48.0 / 255.0 * strength).cgColor)
            context.addPath(proxyPath); context.fillPath(); context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setFillColor(UIColor(white: 0, alpha: 20.0 / 255.0).cgColor)
            context.setShadow(offset: CGSize(width: 0, height: shortEdge * 0.009 * proxyScale), blur: shortEdge * 0.009 * proxyScale, color: UIColor(red: 5.0 / 255.0, green: 11.0 / 255.0, blue: 16.0 / 255.0, alpha: 64.0 / 255.0 * strength).cgColor)
            context.addPath(proxyPath); context.fillPath()
        }
        guard let proxyCG = proxy.cgImage else { return }
        cg.draw(proxyCG, in: CGRect(origin: .zero, size: canvasSize), byTiling: false)
    }

    private static func blurredBackground(_ image: UIImage, size: CGSize) -> UIImage {
        guard let source = image.cgImage, size.width > 0, size.height > 0 else { return image }
        let longEdge: CGFloat = 192
        let proxySize = size.width >= size.height
            ? CGSize(width: longEdge, height: max(96, (longEdge * size.height / size.width).rounded()))
            : CGSize(width: max(96, (longEdge * size.width / size.height).rounded()), height: longEdge)
        var pixels = Array(repeating: UInt8(255), count: Int(proxySize.width * proxySize.height) * 4)
        let proxyFormat = UIGraphicsImageRendererFormat()
        proxyFormat.scale = 1
        proxyFormat.opaque = true
        let proxy = UIGraphicsImageRenderer(size: proxySize, format: proxyFormat).image { renderer in
            let scale = max(proxySize.width / CGFloat(source.width), proxySize.height / CGFloat(source.height))
            let drawSize = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
            let rect = CGRect(x: (proxySize.width - drawSize.width) / 2, y: (proxySize.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height)
            renderer.cgContext.interpolationQuality = .high
            renderer.cgContext.draw(source, in: rect)
        }
        guard let proxyCG = proxy.cgImage,
              let context = CGContext(data: &pixels, width: Int(proxySize.width), height: Int(proxySize.height),
                                       bitsPerComponent: 8, bytesPerRow: Int(proxySize.width) * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return proxy }
        context.interpolationQuality = .high
        context.draw(proxyCG, in: CGRect(origin: .zero, size: proxySize))
        androidBoxBlur(&pixels, width: Int(proxySize.width), height: Int(proxySize.height), radius: 8, passes: 2)
        guard let blurredContext = CGContext(data: &pixels, width: Int(proxySize.width), height: Int(proxySize.height),
                                              bitsPerComponent: 8, bytesPerRow: Int(proxySize.width) * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let blurredCG = blurredContext.makeImage() else { return proxy }
        return UIImage(cgImage: blurredCG)
    }

    /// Two-pass sliding-window box blur used by Android's 192px backdrop proxy.
    private static func androidBoxBlur(_ pixels: inout [UInt8], width: Int, height: Int, radius: Int, passes: Int) {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return }
        var source = pixels
        var target = source
        let diameter = radius * 2 + 1
        for _ in 0..<passes {
            for y in 0..<height {
                var sums = [Int](repeating: 0, count: 4)
                for offset in -radius...radius {
                    let x = min(max(offset, 0), width - 1)
                    let base = (y * width + x) * 4
                    for channel in 0..<4 { sums[channel] += Int(source[base + channel]) }
                }
                for x in 0..<width {
                    let base = (y * width + x) * 4
                    for channel in 0..<4 { target[base + channel] = UInt8(sums[channel] / diameter) }
                    let leavingX = min(max(x - radius, 0), width - 1)
                    let enteringX = min(max(x + radius + 1, 0), width - 1)
                    let leaving = (y * width + leavingX) * 4
                    let entering = (y * width + enteringX) * 4
                    for channel in 0..<4 { sums[channel] += Int(source[entering + channel]) - Int(source[leaving + channel]) }
                }
            }
            source = target
            for x in 0..<width {
                var sums = [Int](repeating: 0, count: 4)
                for offset in -radius...radius {
                    let y = min(max(offset, 0), height - 1)
                    let base = (y * width + x) * 4
                    for channel in 0..<4 { sums[channel] += Int(source[base + channel]) }
                }
                for y in 0..<height {
                    let base = (y * width + x) * 4
                    for channel in 0..<4 { target[base + channel] = UInt8(sums[channel] / diameter) }
                    let leavingY = min(max(y - radius, 0), height - 1)
                    let enteringY = min(max(y + radius + 1, 0), height - 1)
                    let leaving = (leavingY * width + x) * 4
                    let entering = (enteringY * width + x) * 4
                    for channel in 0..<4 { sums[channel] += Int(source[entering + channel]) - Int(source[leaving + channel]) }
                }
            }
            source = target
        }
        pixels = source
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

    private static func drawFrostedMetadataPanel(_ cg: CGContext, panel: CGRect, canvas: CGSize, metadataBandHeight: CGFloat) {
        let radius = min(metadataBandHeight * 0.26, panel.width * 0.5)
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
        if preset == .frosted {
            drawFrostedMetadataPanel(cg, panel: area, canvas: layout.canvas,
                                     metadataBandHeight: layout.canvas.height - layout.metadataTop)
        }
        drawAndroidMetadata(cg, area: area, canvasWidth: layout.canvas.width, preset: preset, metadata: metadata, watermark: watermark, settings: settings,
                            lightText: preset == .mist || preset == .cinema)
        var photoWatermark = watermark
        if !photoPlacement(photoWatermark.position) && photoWatermark.content == .image { photoWatermark.position = .photoBottomCenter }
        // Text watermarks on a frame side are already one of the metadata rows;
        // only photo-anchored text and image logos need a second draw pass.
        if photoPlacement(photoWatermark.position) || photoWatermark.content == .image {
            drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: preset, metadataBand: area)
        }
    }

    private static func metadataText(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
    }

    private static func metadataRow(_ text: String, font: UIFont, color: UIColor) -> PhotoFrameTextRow {
        PhotoFrameTextRow(metadataText(text, font: font, color: color))
    }

    private static func drawMetadataRow(_ row: PhotoFrameTextRow, in cg: CGContext, x: CGFloat,
                                        baseline: CGFloat, scale: CGFloat, shadowOpacity: CGFloat = 0) {
        cg.saveGState()
        if shadowOpacity > 0 {
            cg.setShadow(offset: CGSize(width: 0, height: scale), blur: 3 * scale,
                         color: UIColor.black.withAlphaComponent(shadowOpacity).cgColor)
        }
        row.draw(in: cg, x: x, baseline: baseline, scale: scale)
        cg.restoreGState()
    }

    private static func drawAndroidMetadata(_ cg: CGContext, area: CGRect, canvasWidth: CGFloat,
                                             preset: PhotoFramePreset, metadata: PhotoFrameMetadata,
                                             watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings,
                                             lightText: Bool) {
        let color = lightText
            ? UIColor(red: 248.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0, alpha: 1)
            : UIColor(red: 25.0 / 255.0, green: 31.0 / 255.0, blue: 38.0 / 255.0, alpha: 1)
        let muted = lightText
            ? UIColor(red: 220.0 / 255.0, green: 227.0 / 255.0, blue: 233.0 / 255.0, alpha: 1)
            : UIColor(red: 70.0 / 255.0, green: 79.0 / 255.0, blue: 88.0 / 255.0, alpha: 1)
        let brand = metadata.normalizedMake
        let model = metadata.normalizedModel
        let lens = (metadata.lensModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "   ")
        var rows: [PhotoFrameTextRow] = []
        let titleRuns = [
            metadataText(brand, font: UIFont(name: "HelveticaNeue-BoldItalic", size: canvasWidth * 0.032)
                         ?? UIFont.italicSystemFont(ofSize: canvasWidth * 0.032), color: color),
            metadataText(model, font: UIFont.systemFont(ofSize: canvasWidth * 0.024), color: color),
        ]
        if !brand.isEmpty || !model.isEmpty {
            rows.append(PhotoFrameTextRow(titleRuns, gap: canvasWidth * 0.016)
                .fitting(width: canvasWidth * (preset == .frosted ? 0.78 : 0.86)))
        }
        let detailWidth = canvasWidth * (preset == .frosted ? 0.76 : 0.82)
        if !lens.isEmpty {
            rows.append(metadataRow(lens, font: .systemFont(ofSize: canvasWidth * 0.0185, weight: .medium), color: muted)
                .fitting(width: detailWidth))
        }
        let details = [detail, metadata.locationRow ?? ""].filter { !$0.isEmpty }
        let detailRows = details.map { metadataRow($0, font: .systemFont(ofSize: canvasWidth * 0.020), color: muted) }
        let widestDetail = detailRows.map(\.width).max() ?? 0
        let detailScale = widestDetail > detailWidth ? detailWidth / widestDetail : 1
        rows += detailRows.map { $0.fitting(width: $0.width * detailScale) }
        let watermarkIndex = watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position)
            ? rows.count : nil
        if watermarkIndex != nil {
            rows.append(metadataRow(watermark.displayText,
                                    font: watermarkFont(watermark.font, size: canvasWidth * textSizeFraction(watermark.sizePercent)),
                                    color: watermarkColor(watermark.color, preset).withAlphaComponent(CGFloat(watermark.opacityPercent) / 100))
                .fitting(width: area.width * 0.86))
        }
        let placement = PhotoFrameTextLayout(area: area, bounds: rows.map(\.bounds),
                                             preferredGap: min(canvasWidth * 0.0125, area.height * 0.09),
                                             verticalInset: area.height * PhotoFrameTextLayout.standardPaddingRatio)
        for (index, row) in rows.enumerated() {
            let width = row.width * placement.scale
            let isWatermark = index == watermarkIndex
            let x = isWatermark && watermark.position == .left ? area.minX + area.width * 0.07
                : isWatermark && watermark.position == .right ? area.maxX - area.width * 0.07 - width
                : area.midX - width * 0.5
            drawMetadataRow(row, in: cg, x: x, baseline: placement.baselines[index], scale: placement.scale,
                            shadowOpacity: isWatermark && watermark.effect == .shadow ? 0.35 : 0)
        }
    }

    private static func drawPlaque(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        let band = CGRect(x: 0, y: layout.metadataTop, width: layout.canvas.width, height: layout.canvas.height - layout.metadataTop)
        cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(band)
        cg.setFillColor(UIColor(red: 0.90, green: 0.91, blue: 0.90, alpha: 1).cgColor); cg.fill(CGRect(x: 0, y: band.minY, width: band.width, height: max(1, band.width * 0.0008)))
        // Plaque deliberately keeps the camera maker exactly as supplied by
        // EXIF (Android uppercases it without the standard brand alias map).
        let rawMake = metadata.make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let leftPrimary = rawMake.isEmpty ? (metadata.normalizedModel.isEmpty ? (metadata.lensModel ?? "") : metadata.normalizedModel) : rawMake.uppercased()
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
        let leftX = band.minX + band.width * 0.058
        let rightX = band.minX + band.width * (leftPrimary != nil ? 0.60 : 0.058)
        let leftWidth = band.width * (right.isEmpty ? 0.884 : 0.46)
        let rightWidth = band.width * (leftPrimary != nil ? 0.35 : 0.884)
        func text(_ value: String?, size: CGFloat, primary: Bool, left: Bool) -> PhotoFrameTextRow? {
            guard let value, !value.isEmpty else { return nil }
            return metadataRow(value, font: .systemFont(ofSize: band.width * size, weight: primary && left ? .medium : .regular),
                               color: primary ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 0.40, alpha: 1))
                .fitting(width: left ? leftWidth : rightWidth)
        }
        // Only visible slots consume a baseline or a gap. Both columns in a
        // slot share a baseline even when their fonts have different heights.
        let slots: [(left: PhotoFrameTextRow?, right: PhotoFrameTextRow?)] = [
            (text(leftPrimary, size: 0.027, primary: true, left: true), text(right.first, size: 0.0245, primary: true, left: false)),
            (text(leftSecondary, size: 0.0165, primary: false, left: true), text(right.dropFirst().first, size: 0.018, primary: false, left: false)),
            (nil, text(right.dropFirst(2).first, size: 0.018, primary: false, left: false)),
        ].filter { $0.0 != nil || $0.1 != nil }
        var bounds = slots.map { slot in [slot.left, slot.right].compactMap { $0?.bounds }.reduce(CGRect.null) { $0.union($1) } }
        let watermarkRow = watermark.map {
            metadataRow($0.displayText, font: watermarkFont($0.font, size: band.width * textSizeFraction($0.sizePercent)),
                        color: watermarkColor($0.color, .plaque).withAlphaComponent(CGFloat($0.opacityPercent) / 100))
                .fitting(width: band.width * 0.884)
        }
        if let watermarkRow { bounds.append(watermarkRow.bounds) }
        let placement = PhotoFrameTextLayout(area: band, bounds: bounds,
                                             preferredGap: min(band.width * 0.0115, band.height * 0.095),
                                             verticalInset: band.height * PhotoFrameTextLayout.standardPaddingRatio)
        for (index, slot) in slots.enumerated() {
            slot.left?.draw(in: cg, x: leftX, baseline: placement.baselines[index], scale: placement.scale)
            slot.right?.draw(in: cg, x: rightX, baseline: placement.baselines[index], scale: placement.scale)
        }
        if let watermark, let watermarkRow, let baseline = placement.baselines.last {
            let width = watermarkRow.width * placement.scale
            let x = watermark.position == .left ? band.minX + band.width * 0.07
                : watermark.position == .right ? band.maxX - band.width * 0.07 - width : band.midX - width * 0.5
            drawMetadataRow(watermarkRow, in: cg, x: x, baseline: baseline, scale: placement.scale,
                            shadowOpacity: watermark.effect == .shadow ? 0.35 : 0)
        }
        if leftPrimary != nil, !right.isEmpty, !slots.isEmpty {
            let infoTop = slots.indices.map { placement.baselines[$0] + bounds[$0].minY * placement.scale }.min()!
            let infoBottom = slots.indices.map { placement.baselines[$0] + bounds[$0].maxY * placement.scale }.max()!
            let inset = band.height * 0.075
            cg.setStrokeColor(UIColor(red: 0.87, green: 0.88, blue: 0.87, alpha: 1).cgColor)
            cg.setLineWidth(max(1, band.width * 0.001))
            cg.move(to: CGPoint(x: band.minX + band.width * 0.575, y: max(band.minY + inset, infoTop - inset)))
            cg.addLine(to: CGPoint(x: band.minX + band.width * 0.575, y: min(band.maxY - inset, infoBottom + inset)))
            cg.strokePath()
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
        let textRows = rows.enumerated().map { index, row in
            metadataRow(row.0, font: row.1, color: index == 0 ? .white : UIColor.white.withAlphaComponent(0.90))
                .fitting(width: photo.width * 0.78)
        }
        let blockHeight = textRows.reduce(CGFloat.zero) { $0 + $1.bounds.height } + gap * CGFloat(max(0, textRows.count - 1))
        let blockWidth = textRows.map(\.width).max() ?? photo.width
        let area = placeBrandMetadataBlock(photo: photo, preferredBottom: photo.maxY - min(photo.width, photo.height) * preferredBottomRatio,
                                          blockHeight: blockHeight, blockWidth: blockWidth, occupied: occupied,
                                          gap: min(photo.width, photo.height) * 0.040)
        let target = area ?? photo.insetBy(dx: photo.width * 0.08, dy: photo.height * 0.06)
        let placement = PhotoFrameTextLayout(area: target, bounds: textRows.map(\.bounds), preferredGap: gap)
        for (index, row) in textRows.enumerated() {
            drawMetadataRow(row, in: cg, x: target.midX - row.width * placement.scale * 0.5,
                            baseline: placement.baselines[index], scale: placement.scale, shadowOpacity: 0.70)
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
        let area = CGRect(x: band.minX, y: band.minY + band.height * 0.08, width: band.width, height: band.height * 0.82)
        let textRows = rows.map { metadataRow($0.0, font: $0.1, color: $0.2).fitting(width: band.width * 0.86) }
        let placement = PhotoFrameTextLayout(area: area, bounds: textRows.map(\.bounds), preferredGap: band.height * 0.12)
        for (index, row) in textRows.enumerated() {
            let width = row.width * placement.scale
            let isWatermark = index == 0 && bandWatermark != nil
            let x = isWatermark && bandWatermark?.position == .left ? band.minX + band.width * 0.07
                : isWatermark && bandWatermark?.position == .right ? band.maxX - band.width * 0.07 - width : band.midX - width * 0.5
            drawMetadataRow(row, in: cg, x: x, baseline: placement.baselines[index], scale: placement.scale,
                            shadowOpacity: isWatermark && bandWatermark?.effect == .shadow ? 0.35 : 0)
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
        let photo = layout.photo
        let shortEdge = min(photo.width, photo.height)
        let maxWidth = photo.width * 0.86
        let title = metadata.identity
        let inlineWatermark = watermark.enabled && watermark.content == .text && watermark.position == .auto ? watermark : nil
        let separate = watermark.enabled && watermark.content == .text && watermark.position != .auto && !photoPlacement(watermark.position) ? watermark : nil
        var titleRuns: [NSAttributedString] = []
        if !title.isEmpty {
            titleRuns.append(metadataText(title, font: .systemFont(ofSize: shortEdge * 0.030, weight: .medium), color: .white))
        }
        if let inlineWatermark {
            if !title.isEmpty {
                titleRuns.append(metadataText("|", font: .systemFont(ofSize: shortEdge * 0.025, weight: .light), color: .white.withAlphaComponent(0.80)))
            }
            titleRuns.append(metadataText(inlineWatermark.displayText,
                                          font: watermarkFont(inlineWatermark.font, size: shortEdge * textSizeFraction(inlineWatermark.sizePercent) * 1.35),
                                          color: watermarkColor(inlineWatermark.color, .immersive).withAlphaComponent(CGFloat(inlineWatermark.opacityPercent) / 100)))
        }
        var rows: [PhotoFrameTextRow] = []
        if !titleRuns.isEmpty { rows.append(PhotoFrameTextRow(titleRuns, gap: shortEdge * 0.014).fitting(width: maxWidth)) }
        if let lens = metadata.lensModel, !lens.isEmpty {
            rows.append(metadataRow(lens, font: .systemFont(ofSize: shortEdge * 0.0205, weight: .medium), color: .white.withAlphaComponent(0.92)).fitting(width: maxWidth))
        }
        let detail = [metadata.immersiveDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "  ")
        rows += [detail, metadata.locationRow ?? ""].filter { !$0.isEmpty }.map {
            metadataRow($0, font: .systemFont(ofSize: shortEdge * 0.0235), color: .white.withAlphaComponent(0.92)).fitting(width: maxWidth)
        }
        if let separate {
            rows.append(metadataRow(separate.displayText,
                                    font: watermarkFont(separate.font, size: shortEdge * textSizeFraction(separate.sizePercent)),
                                    color: watermarkColor(separate.color, .immersive).withAlphaComponent(CGFloat(separate.opacityPercent) / 100))
                .fitting(width: maxWidth))
        }
        let gap = shortEdge * 0.013
        let blockHeight = rows.reduce(CGFloat.zero) { $0 + $1.bounds.height } + gap * CGFloat(max(0, rows.count - 1))
        // Android anchors the visible ink above this bottom safety margin, not
        // a percentage of an unrelated font-line-height container.
        let bottom = photo.maxY - max(shortEdge * 0.045, photo.height * 0.025)
        let available = max(0, bottom - photo.minY - shortEdge * 0.045)
        let area = CGRect(x: photo.minX + photo.width * 0.07, y: bottom - min(blockHeight, available),
                          width: maxWidth, height: min(blockHeight, available))
        let veilTop = max(area.minY - shortEdge * 0.10, photo.minY + photo.height * 0.58)
        drawGradient(cg, rect: CGRect(x: photo.minX, y: veilTop, width: photo.width, height: photo.maxY - veilTop),
                     top: UIColor(white: 0, alpha: 0), bottom: UIColor(white: 0, alpha: 0.46))
        if photoPlacement(watermark.position) {
            drawWatermark(cg, watermark: watermark, photo: photo, canvas: layout.canvas, preset: .immersive, metadataBand: area)
        }
        let placement = PhotoFrameTextLayout(area: area, bounds: rows.map(\.bounds), preferredGap: gap)
        for (index, row) in rows.enumerated() {
            let width = row.width * placement.scale
            let isSeparate = separate != nil && index == rows.count - 1
            let x = isSeparate && separate?.position == .left ? area.minX
                : isSeparate && separate?.position == .right ? area.maxX - width : area.midX - width * 0.5
            drawMetadataRow(row, in: cg, x: x, baseline: placement.baselines[index], scale: placement.scale,
                            shadowOpacity: isSeparate ? (separate?.effect == .shadow ? 0.35 : 0) : 0.55)
        }
    }

    private static func drawEditorial(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        // Android composites the editorial photo watermark before each frame's
        // typography and decoration, so labels remain legible above it.
        let photoWatermark = editorialPhotoWatermark(watermark, preset: preset)
        drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas,
                      preset: preset,
                      metadataBand: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width,
                                           height: layout.canvas.height - layout.photo.maxY))
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
            drawFilmEdgeInformation(cg, area: CGRect(x: layout.photo.minX, y: layout.photo.maxY, width: layout.photo.width, height: layout.canvas.height - layout.photo.maxY), rows: [cameraLine, metadata.locationRow ?? ""].filter { !$0.isEmpty })
        case .classicSignature:
            if !metadata.identity.isEmpty {
                let headerArea = CGRect(x: 0, y: 0, width: layout.canvas.width, height: layout.photo.minY)
                let font = UIFont(name: "HelveticaNeue-BlackItalic", size: layout.canvas.width * 0.034)
                    ?? UIFont.italicSystemFont(ofSize: layout.canvas.width * 0.034)
                let row = metadataRow(metadata.identity, font: font, color: UIColor(red: 0.04, green: 0.043, blue: 0.047, alpha: 1))
                    .fitting(width: layout.canvas.width * 0.54)
                let placement = PhotoFrameTextLayout(area: headerArea, bounds: [row.bounds], preferredGap: 0,
                                                     verticalInset: headerArea.height * PhotoFrameTextLayout.standardPaddingRatio)
                row.draw(in: cg, x: headerArea.midX - row.width * placement.scale * 0.5,
                         baseline: placement.baselines[0], scale: placement.scale)
            }
            drawMetadataRows(cg, area: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY), preset: preset, rows: [metadata.lensModel ?? "", metadata.classicSignatureDetailLine, metadata.dateTime ?? "", metadata.locationRow ?? ""].filter { !$0.isEmpty }, watermark: watermark, dark: true, emphasizeFirst: false)
        default: break
        }
    }

    private static func drawMetadataRows(_ cg: CGContext, area: CGRect, preset: PhotoFramePreset, rows: [String], watermark: PhotoFrameWatermark, dark: Bool, insidePhoto: Bool = false, emphasizeFirst: Bool = true) {
        guard area.height > 1 else { return }
        let values = rows.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let supportsBandWatermark = preset == .galleryMat || preset == .filmGallery ||
            (preset == .classicSignature && watermark.position != .auto) ||
            (preset == .brandGallery && watermark.position != .auto)
        let drawsWatermark = !insidePhoto && supportsBandWatermark && watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position)
        let color = dark ? UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1) : UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
        let muted = dark ? UIColor(red: 0.29, green: 0.31, blue: 0.33, alpha: 1) : UIColor(red: 0.86, green: 0.89, blue: 0.91, alpha: 1)
        var textRows = values.enumerated().map { index, value in
            let prominent = emphasizeFirst && index == 0
            let font = prominent ? (UIFont(name: "Georgia-BoldItalic", size: area.width * 0.052) ?? UIFont.italicSystemFont(ofSize: area.width * 0.052))
                : UIFont.systemFont(ofSize: area.width * 0.024)
            return metadataRow(value, font: font, color: index == 0 ? color : muted).fitting(width: area.width * 0.90)
        }
        if drawsWatermark {
            textRows.append(metadataRow(watermark.displayText,
                                        font: watermarkFont(watermark.font, size: area.width * textSizeFraction(watermark.sizePercent)),
                                        color: watermarkColor(watermark.color, preset).withAlphaComponent(CGFloat(watermark.opacityPercent) / 100))
                .fitting(width: area.width * 0.48))
        }
        let placement = PhotoFrameTextLayout(area: area, bounds: textRows.map(\.bounds), preferredGap: area.height * 0.055,
                                             verticalInset: area.height * PhotoFrameTextLayout.standardPaddingRatio)
        for (index, row) in textRows.enumerated() {
            let isWatermark = drawsWatermark && index == textRows.count - 1
            let width = row.width * placement.scale
            let x = isWatermark && watermark.position == .left ? area.minX
                : isWatermark && watermark.position == .right ? area.maxX - width : area.midX - width * 0.5
            drawMetadataRow(row, in: cg, x: x, baseline: placement.baselines[index], scale: placement.scale,
                            shadowOpacity: isWatermark && watermark.effect == .shadow ? 0.35 : 0)
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
        if !metadata.colorArchiveDetailLine.isEmpty { rows.append((metadata.colorArchiveDetailLine, UIFont.systemFont(ofSize: photo.width * 0.022, weight: .bold), .black, .bold)) }
        if let date = metadata.dateTime, !date.isEmpty { rows.append((date, UIFont.systemFont(ofSize: photo.width * 0.0185), .black, .regular)) }
        if let location = metadata.locationRow, !location.isEmpty { rows.append((location, UIFont.systemFont(ofSize: photo.width * 0.0185), .black, .regular)) }
        guard !rows.isEmpty else { return }
        let textRows = rows.map { metadataRow($0.0, font: $0.1, color: $0.2).fitting(width: textArea.width) }
        let placement = PhotoFrameTextLayout(area: textArea, bounds: textRows.map(\.bounds), preferredGap: bandHeight * 0.055)
        for (index, row) in textRows.enumerated() {
            row.draw(in: cg, x: textArea.minX, baseline: placement.baselines[index], scale: placement.scale)
        }
    }

    private static func drawFilmStrip(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata) {
        let photo = layout.photo, unit = photo.width, holeW = unit * 0.025, holeH = unit * 0.04, gap = unit * 0.025
        let outer = CGRect(x: photo.minX - unit * 0.018, y: photo.minY - unit * 0.09, width: photo.width + unit * 0.036, height: photo.height + unit * 0.18)
        cg.setFillColor(UIColor(red: 55.0 / 255.0, green: 55.0 / 255.0, blue: 61.0 / 255.0, alpha: 1).cgColor)
        let count = max(3, Int((outer.width - gap) / (holeW + gap)))
        let occupied = CGFloat(count) * holeW + CGFloat(count - 1) * gap, start = outer.midX - occupied / 2
        for i in 0..<count {
            let x = start + CGFloat(i) * (holeW + gap)
            cg.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: photo.minY - holeH - unit * 0.008, width: holeW, height: holeH), cornerRadius: holeW * 0.34).cgPath)
            cg.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: photo.maxY + unit * 0.008, width: holeW, height: holeH), cornerRadius: holeW * 0.34).cgPath)
        }
        cg.fillPath()
        let filmText = UIColor(red: 184.0 / 255.0, green: 132.0 / 255.0, blue: 99.0 / 255.0, alpha: 1)
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
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var buckets = Array(repeating: (count: 0, r: 0, g: 0, b: 0), count: 512)
        for index in 0..<(sw * sh) {
            let offset = index * 4, alpha = Int(pixels[offset + 3])
            guard alpha >= 128 else { continue }
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
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
        let font = UIFont.boldSystemFont(ofSize: size)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        text.draw(at: CGPoint(x: -width / 2, y: -font.ascender), withAttributes: [.font: font, .foregroundColor: color]); cg.restoreGState()
    }

    private static func drawFilmEdgeInformation(_ cg: CGContext, area: CGRect, rows: [String]) {
        guard area.height > 1, !rows.isEmpty else { return }
        let color = UIColor(red: 0.88, green: 0.67, blue: 0.49, alpha: 1)
        let baseSize = area.width * 0.016
        let font = UIFont(name: "HelveticaNeue-Condensed", size: baseSize) ?? UIFont.systemFont(ofSize: baseSize)
        let textRows = rows.filter { !$0.isEmpty }.map { metadataRow($0, font: font, color: color).fitting(width: area.width * 0.94) }
        let placement = PhotoFrameTextLayout(area: area, bounds: textRows.map(\.bounds), preferredGap: area.height * 0.10,
                                             verticalInset: area.height * PhotoFrameTextLayout.standardPaddingRatio)
        for (index, row) in textRows.enumerated() {
            row.draw(in: cg, x: area.midX - row.width * placement.scale * 0.5,
                     baseline: placement.baselines[index], scale: placement.scale)
        }
    }

    private static func drawWatermark(_ cg: CGContext, watermark: PhotoFrameWatermark, photo: CGRect, canvas: CGSize, preset: PhotoFramePreset, metadataBand: CGRect) {
        guard watermark.enabled else { return }
        if photoPlacement(watermark.position) {
            let radius: CGFloat = switch preset {
            case .colorArchive: photo.width * 0.012
            case .brandInset, .brandGallery: photo.width * 0.014
            case .mist, .cinema, .minimal, .frosted: max(1, metadataBand.height * 0.26)
            default: 0
            }
            cg.saveGState(); cg.addPath(UIBezierPath(roundedRect: photo, cornerRadius: radius).cgPath); cg.clip()
        }
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
        if effective.effect == .outline {
            // Match Android's two-pass Paint.Style.STROKE + fill rendering.
            // A fixed -1.5pt attributed stroke became visibly uneven as the
            // watermark size changed, and the hard-coded white outline was
            // wrong for light watermarks. Scale the stroke from the actual
            // font size and choose the contrasting ink from the fill color.
            let fillColor = watermarkColor(effective.color, preset)
                .withAlphaComponent(CGFloat(effective.opacityPercent) / 100)
            let outline = contrastingWatermarkColor(for: fillColor)
            var outlineAttrs = attrs
            outlineAttrs[.strokeWidth] = font.pointSize * 0.075
            outlineAttrs[.strokeColor] = outline
            text.draw(at: rect.origin, withAttributes: outlineAttrs)
            text.draw(at: rect.origin, withAttributes: attrs)
        } else {
            var drawAttrs = attrs
            if effective.effect == .shadow || effective.effect == .auto {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = CGSize(width: 0, height: 1)
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.35)
                drawAttrs[.shadow] = shadow
            }
            text.draw(at: rect.origin, withAttributes: drawAttrs)
        }
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
        switch color {
        case .black: UIColor(red: 50 / 255, green: 55 / 255, blue: 60 / 255, alpha: 1)
        case .white: UIColor(red: 244 / 255, green: 239 / 255, blue: 228 / 255, alpha: 1)
        case .gold: UIColor(red: 204 / 255, green: 172 / 255, blue: 112 / 255, alpha: 1)
        case .mistBlue: UIColor(red: 132 / 255, green: 157 / 255, blue: 180 / 255, alpha: 1)
        case .roseGold: UIColor(red: 185 / 255, green: 128 / 255, blue: 121 / 255, alpha: 1)
        case .adaptive:
            [PhotoFramePreset.mist, .cinema, .immersive, .brandInset, .brandGallery, .filmGallery, .filmEdge].contains(preset)
                ? UIColor(red: 250 / 255, green: 252 / 255, blue: 253 / 255, alpha: 1)
                : UIColor(red: 24 / 255, green: 31 / 255, blue: 38 / 255, alpha: 1)
        }
    }

    private static func contrastingWatermarkColor(for color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return UIColor(white: 0.05, alpha: alpha)
        }
        let brightness = (red * 299 + green * 587 + blue * 114) / 1000
        return brightness >= 0.588
            ? UIColor(red: 12 / 255, green: 15 / 255, blue: 18 / 255, alpha: alpha)
            : UIColor(red: 248 / 255, green: 249 / 255, blue: 250 / 255, alpha: alpha)
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
    var colorArchiveDetailLine: String {
        [focalLength,
         aperture.map { $0.lowercased().hasPrefix("f/") ? $0.lowercased() : "f/\($0)" },
         iso.map { $0.replacingOccurrences(of: " ", with: "").uppercased().hasPrefix("ISO") ? $0.replacingOccurrences(of: " ", with: "").uppercased() : "ISO\($0.replacingOccurrences(of: " ", with: ""))" },
         shutter.map { $0.lowercased().hasSuffix("s") ? $0 : "\($0)s" }]
            .compactMap { $0 }
            .joined(separator: "  ")
    }
    var immersiveDetailLine: String {
        [focalLength,
         aperture.map { $0.lowercased().hasPrefix("f/") ? $0 : "f/\($0)" },
         shutter.map { $0.lowercased().hasSuffix("s") ? $0 : "\($0)s" },
         iso]
            .compactMap { $0 }
            .joined(separator: "  ")
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
