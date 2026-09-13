import UIKit

/// The workbench renderer is deliberately isolated from SwiftUI.  It keeps the
/// preview and eventual batch exporter on the same ordered pipeline:
/// source -> filter -> frame -> watermark.  The Android exporter is the visual
/// reference; this native implementation only owns the platform drawing work.
enum PhotoEffectsRenderer {
    static func render(_ image: UIImage, settings: PhotoEffectsSettings) throws -> UIImage {
        try Task.checkCancellation()
        var output = image
        if settings.photoFilterEnabled, let filter = settings.selectedFilter {
            output = try applyFilter(output, selection: filter)
        }
        if settings.photoFrameEnabled {
            output = drawDecoration(output, settings: settings)
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

    private static func drawDecoration(_ image: UIImage, settings: PhotoEffectsSettings) -> UIImage {
        let scale = image.scale
        let size = image.size
        let border = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
            ? max(12, min(size.width, size.height) * 0.035)
            : 0
        let canvas = CGSize(width: size.width + border * 2, height: size.height + border * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
            let cg = renderer.cgContext
            let background = frameColor(for: settings.photoFramePreset)
            cg.setFillColor(background.cgColor)
            cg.fill(CGRect(origin: .zero, size: canvas))
            image.draw(in: CGRect(x: border, y: border, width: size.width, height: size.height))
            guard settings.watermark.enabled else { return }
            let watermarkConfig = settings.watermark.normalized(borderEnabled: settings.photoFrameEnabled && settings.photoFrameBorderEnabled)
            if watermarkConfig.content == .image,
               let hash = watermarkConfig.imageHash,
               let watermarkImage = PhotoEffectsStore.watermarkImage(hash: hash) {
                let targetHeight = min(size.width, size.height) * watermarkImageSizeFraction(watermarkConfig.sizePercent)
                let scale = targetHeight / max(watermarkImage.size.height, 1)
                let imageSize = CGSize(width: watermarkImage.size.width * scale, height: watermarkImage.size.height * scale)
                let imageOrigin = watermarkImageOrigin(position: watermarkConfig.position, canvas: canvas, border: border, imageSize: imageSize)
                watermarkImage.draw(in: CGRect(origin: imageOrigin, size: imageSize), blendMode: .normal, alpha: CGFloat(watermarkConfig.opacityPercent) / 100)
                return
            }
            let watermark = watermarkConfig.displayText
            let font = watermarkFont(for: watermarkConfig.font, size: max(12, min(size.width, size.height) * CGFloat(settings.watermark.sizePercent) / 1000))
            let point = watermarkOrigin(
                position: watermarkConfig.position,
                canvas: canvas,
                border: border,
                text: watermark,
                font: font,
            )
            let color: UIColor = switch watermarkConfig.color {
            case .black: .black
            case .white: .white
            case .gold: UIColor(red: 0.80, green: 0.67, blue: 0.44, alpha: 1)
            case .mistBlue: UIColor(red: 0.52, green: 0.62, blue: 0.71, alpha: 1)
            case .roseGold: UIColor(red: 0.73, green: 0.50, blue: 0.47, alpha: 1)
            case .adaptive: background.isLight ? .black : .white
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(CGFloat(watermarkConfig.opacityPercent) / 100)]
            if watermarkConfig.effect == .shadow || watermarkConfig.effect == .auto {
                let shadow = NSShadow(); shadow.shadowColor = UIColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 3; shadow.shadowOffset = CGSize(width: 0, height: 1)
                attributes[.shadow] = shadow
            } else if watermarkConfig.effect == .outline {
                attributes[.strokeWidth] = -1.5
                attributes[.strokeColor] = (color == .white ? UIColor.black : UIColor.white).withAlphaComponent(0.65)
            }
            watermark.draw(at: point.origin, withAttributes: attributes)
        }
    }

    private static func watermarkImageOrigin(position: PhotoFrameWatermarkPosition, canvas: CGSize, border: CGFloat, imageSize: CGSize) -> CGPoint {
        let photo = CGRect(x: border, y: border, width: canvas.width - border * 2, height: canvas.height - border * 2)
        let inset = min(photo.width, photo.height) * 0.04
        if position.isPhotoPlacement {
            let x: CGFloat = switch position {
            case .photoTopLeft, .photoBottomLeft: photo.minX + inset
            case .photoTopRight, .photoBottomRight: photo.maxX - inset - imageSize.width
            default: photo.midX - imageSize.width / 2
            }
            let y: CGFloat = switch position {
            case .photoTopLeft, .photoTopCenter, .photoTopRight: photo.minY + inset
            case .photoCenter: photo.midY - imageSize.height / 2
            default: photo.maxY - inset - imageSize.height
            }
            return CGPoint(x: x, y: y)
        }
        let x: CGFloat
        switch position {
        case .left, .photoTopLeft, .photoBottomLeft: x = border + 12
        case .right, .photoTopRight, .photoBottomRight: x = canvas.width - border - imageSize.width - 12
        default: x = (canvas.width - imageSize.width) / 2
        }
        let y: CGFloat
        switch position {
        case .photoTopLeft, .photoTopCenter, .photoTopRight: y = border + 12
        case .photoCenter: y = (canvas.height - imageSize.height) / 2
        default: y = canvas.height - border - imageSize.height - 12
        }
        return CGPoint(x: max(8, x), y: max(8, y))
    }

    private static func watermarkImageSizeFraction(_ value: Int) -> CGFloat {
        let p = CGFloat(min(max(value, 2), 100))
        if p <= 47 { return 0.035 * p / 47 }
        if p <= 69 { return 0.035 + (p - 47) / 22 * (0.052 - 0.035) }
        return 0.052 + (p - 69) / 31 * (0.075 - 0.052)
    }

    private static func frameColor(for preset: PhotoFramePreset) -> UIColor {
        switch preset {
        case .cinema, .immersive, .colorArchive: UIColor(white: 0.07, alpha: 1)
        case .filmEdge, .filmGallery: UIColor(red: 0.88, green: 0.84, blue: 0.72, alpha: 1)
        case .plaque, .classicSignature: UIColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1)
        default: UIColor(white: 0.94, alpha: 1)
        }
    }

    private static func watermarkOrigin(position: PhotoFrameWatermarkPosition, canvas: CGSize, border: CGFloat, text: String, font: UIFont) -> (origin: CGPoint, fontSize: CGFloat) {
        let fontSize = font.pointSize
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let imageTop = border, imageBottom = canvas.height - border
        let y: CGFloat
        switch position {
        case .photoTopLeft, .photoTopCenter, .photoTopRight: y = imageTop + fontSize + 12
        case .photoCenter: y = (imageTop + imageBottom + fontSize) / 2
        case .left, .center, .right, .auto, .photoBottomLeft, .photoBottomCenter, .photoBottomRight:
            y = border > 0 && position != .photoBottomLeft && position != .photoBottomCenter && position != .photoBottomRight
                ? canvas.height - max(border * 0.8, fontSize * 1.5)
                : imageBottom - max(12, fontSize * 0.5)
        }
        let x: CGFloat
        switch position {
        case .left, .photoTopLeft, .photoBottomLeft: x = border + 12
        case .center, .photoTopCenter, .photoCenter, .photoBottomCenter, .auto: x = (canvas.width - width) / 2
        case .right, .photoTopRight, .photoBottomRight: x = canvas.width - border - width - 12
        }
        return (CGPoint(x: max(8, x), y: max(8, y - fontSize)), fontSize)
    }

    private static func watermarkFont(for style: PhotoFrameWatermarkFont, size: CGFloat) -> UIFont {
        let name: String? = switch style {
        case .signature: "GreatVibes-Regular"
        case .elegant: "CormorantGaramond-MediumItalic"
        case .calligraphy: "BebasNeue-Regular"
        case .simple: nil
        case .bold: nil
        }
        if let name, let font = UIFont(name: name, size: size) { return font }
        return UIFont.systemFont(ofSize: size, weight: style == .bold ? .bold : .regular)
    }
}

private extension PhotoFrameWatermark {
    /// Android hides border-only placements when the border is off. Keep the
    /// saved preference intact while normalizing the effective render position.
    func normalized(borderEnabled: Bool) -> Self {
        guard !borderEnabled else { return self }
        var value = self
        switch value.position {
        case .auto, .left, .center, .right: value.position = .photoBottomCenter
        default: break
        }
        return value
    }
}

private extension PhotoFrameWatermarkPosition {
    var isPhotoPlacement: Bool {
        switch self {
        case .photoTopLeft, .photoTopCenter, .photoTopRight, .photoCenter,
             .photoBottomLeft, .photoBottomCenter, .photoBottomRight: return true
        default: return false
        }
    }
}

private extension UIColor {
    var isLight: Bool {
        var white: CGFloat = 0
        getWhite(&white, alpha: nil)
        return white > 0.6
    }
}
