import Foundation

// Android 7690172b PhotoFrameWidth / PhotoFrameExporter. Rendering, preview
// transitions and output identity must agree on the actual information band.
extension PhotoFramePreset {
    var supportsUniformBorder: Bool {
        [.mist, .cinema, .minimal, .frosted, .brandGallery, .classicSignature].contains(self)
    }
}

extension PhotoFrameWatermarkPosition {
    var isPhotoPlacement: Bool {
        ![.auto, .left, .center, .right].contains(self)
    }
}

extension PhotoFrameWatermark {
    func forEditorialPhoto(_ preset: PhotoFramePreset) -> Self {
        if position.isPhotoPlacement { return self }
        let mapped: PhotoFrameWatermarkPosition = switch position {
        case .left: .photoBottomLeft
        case .center: .photoBottomCenter
        case .auto: [.galleryMat, .filmGallery].contains(preset) ? .photoBottomCenter : .photoBottomRight
        default: .photoBottomRight
        }
        let usesPhoto: Bool = switch preset {
        case .classicSignature: position == .auto || content == .image
        case .colorArchive, .filmEdge, .parameterPoster: true
        case .galleryMat, .filmGallery, .filmNegative: content == .image
        default: false
        }
        var value = self
        if usesPhoto { value.position = mapped } else { value.enabled = false }
        return value
    }

    func forBrandPhoto(_ preset: PhotoFramePreset) -> Self {
        var value = self
        guard !position.isPhotoPlacement else { return value }
        if preset == .brandGallery {
            value.position = .photoBottomRight
            if content == .text && position != .auto { value.enabled = false }
        } else {
            value.position = position == .left ? .photoBottomLeft : position == .center ? .photoBottomCenter : .photoBottomRight
        }
        return value
    }

    func occupiesFrameBand(_ preset: PhotoFramePreset) -> Bool {
        guard enabled else { return false }
        if [.brandInset, .brandGallery].contains(preset) { return !forBrandPhoto(preset).enabled }
        guard content == .text, !position.isPhotoPlacement else { return false }
        switch preset {
        case .classicSignature: return position != .auto
        case .galleryMat, .filmGallery, .filmNegative: return true
        case .colorArchive, .filmEdge, .parameterPoster: return false
        default: return true
        }
    }

    func hasAmbiguousLegacyPosition(preset: PhotoFramePreset) -> Bool {
        guard enabled, content == .text, [.auto, .center].contains(position),
              [.classicSignature, .galleryMat, .colorArchive, .filmGallery, .filmEdge, .filmNegative, .parameterPoster].contains(preset) else { return false }
        var automatic = self; automatic.position = .auto
        var centered = self; centered.position = .center
        automatic = automatic.forEditorialPhoto(preset); centered = centered.forEditorialPhoto(preset)
        return automatic.enabled != centered.enabled || (automatic.enabled && automatic.position != centered.position)
    }
}

func usesUniformPhotoFrameBorder(preset: PhotoFramePreset, metadata: PhotoFrameMetadataSettings,
                                watermark: PhotoFrameWatermark) -> Bool {
    guard preset.supportsUniformBorder, !watermark.occupiesFrameBand(preset) else { return false }
    let hasInformation = preset == .brandGallery
        ? metadata.showBrand || metadata.showModel
        : metadata.showDate || metadata.showTime || metadata.showFocalLength || metadata.showExposure ||
            metadata.showBrand || metadata.showModel || metadata.showLensModel || metadata.showCoordinates ||
            metadata.showAltitude || metadata.showCity || metadata.showRegion
    return !hasInformation
}

extension PhotoEffectsSettings {
    var usesUniformFrameBorder: Bool {
        photoFrameEnabled && photoFrameBorderEnabled && usesUniformPhotoFrameBorder(
            preset: photoFramePreset, metadata: metadata, watermark: watermark)
    }
    var usesRenderedPlaceIdentity: Bool {
        photoFrameEnabled && photoFrameBorderEnabled && (metadata.showCity || metadata.showRegion)
    }
}

/// Reference geometry follows Android's integer canvas / Float arithmetic.
/// One ceil-rounded margin preserves every source pixel and avoids aspect-ratio
/// threshold changes when the preview was decoded independently of the original.
struct PhotoFrameUniformGeometry {
    let canvas: CGSize
    let photo: CGRect
    let designSize: CGSize
    let designMetadataTop: CGFloat
    var decorationBandHeight: CGFloat { designSize.height - designMetadataTop }

    init(width: Int, height: Int, preset: PhotoFramePreset, percent: Int) throws {
        guard width > 0, height > 0, preset.supportsUniformBorder else { throw CocoaError(.fileReadCorruptFile) }
        let reference: (margin: Float, width: Float, height: Float, metadata: Float)
        switch preset {
        case .brandGallery: reference = (32, 1064, 859, 699)
        case .classicSignature: reference = (30, 1060, 912, 762)
        default: reference = Self.standardReference
        }
        let margin = ceil(Double(reference.margin) * Double(normalizePhotoFrameWidthPercent(percent)) * Double(width) / 100_000)
        let canvasWidth = Double(width) + margin * 2, canvasHeight = Double(height) + margin * 2
        guard margin.isFinite, canvasWidth <= Double(Int32.max), canvasHeight <= Double(Int32.max) else {
            throw CocoaError(.fileReadTooLarge)
        }
        let scale = Float(width) / 1000
        canvas = CGSize(width: canvasWidth, height: canvasHeight)
        photo = CGRect(x: margin, y: margin, width: Double(width), height: Double(height))
        designSize = CGSize(width: CGFloat(reference.width * scale), height: CGFloat(Float(height) + (reference.height - 667) * scale))
        designMetadataTop = CGFloat(Float(height) + (reference.metadata - 667) * scale)
    }

    private static let standardReference: (margin: Float, width: Float, height: Float, metadata: Float) = {
        // calculateOriginalQualityPhotoFrameLayout(1000, 667), evaluated once.
        func fits(_ edge: Int) -> Bool {
            let w = Float(edge), h = Float(edge * 3 / 4)
            let availableWidth = w - w * 0.052 * 2
            let availableHeight = h * 0.830 - h * 0.050 - h * 0.012
            let scale = min(availableWidth / 1000, availableHeight / 667)
            return 1000 * scale >= 1000 && 667 * scale >= 667
        }
        var low = 1000, high = 2000
        while low < high {
            let middle = low + (high - low) / 2
            if fits(middle) { high = middle } else { low = middle + 1 }
        }
        let w = Float(low), h = Float(low * 3 / 4)
        return (((w - 1000) / 2).rounded(), w, h, h * 0.830)
    }()
}
