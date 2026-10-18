import UIKit
import CoreText
import CoreImage
import ImageIO
import os

/// Android serializes full preview composition so a stale frame cannot saturate
/// the CPU while a newer wheel selection is being prepared.  The gate is used
/// only by interactive previews; batch export keeps its own worker policy.
enum PhotoEffectsPreviewRenderGate {
    static let shared = CancellableSerialWorkGate()

    static func render<T: Sendable>(priority: TaskPriority = .utility,
                                   _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try await shared.withPermit {
                let result = try autoreleasepool(invoking: operation)
                try Task.checkCancellation()
                return result
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
}

/// Each owner has its own gate; cancellation removes queued work without
/// waiting for the current CPU operation to finish.
actor CancellableSerialWorkGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var available = true
    private var waiters: [Waiter] = []
    var pendingCount: Int { waiters.count }

    func withPermit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if available {
            available = false
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append(.init(id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            available = true
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Same failure boundary as Android positionFrameRows for a fixed glass column.
struct PhotoFrameColumnOverflow: LocalizedError {
    var errorDescription: String? { "Frame information exceeds its column" }
}

enum PhotoFrameBrandLayoutError: LocalizedError {
    case insufficientHeight
    case watermarkOverlap

    var errorDescription: String? {
        switch self {
        case .insufficientHeight: return "Failed requirement."
        case .watermarkOverlap: return "Frame information and watermark need more space"
        }
    }
}

/// Arithmetic shared with Android PhotoAllocationBudget.kt. The platform memory
/// snapshot is supplied separately; this is an early rejection, not a reservation.
struct PhotoAllocationRejected: Error, Equatable {
    let required: Int64
    let available: Int64
}

enum PhotoAllocationBudget {
    /// Inspect only the container header before UIKit can allocate decoded pixels.
    /// The renderer separately checks the measured, expanded output canvas.
    static func loadOriginalImage(_ url: URL,
                                  availableMemory: () -> Int64 = availableMemory) throws -> UIImage {
        try Task.checkCancellation()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let required = bytes(width: dimension(CGFloat(width.doubleValue)),
                             height: dimension(CGFloat(height.doubleValue)), copies: 2, extra: 8 * 1024 * 1024)
        let available = availableMemory()
        guard fits(required: required, available: available) else {
            throw PhotoAllocationRejected(required: required, available: available)
        }
        try Task.checkCancellation()
        guard let image = UIImage(contentsOfFile: url.path) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    static func availableMemory() -> Int64 {
        #if targetEnvironment(simulator)
        // Simulator processes have no iOS dirty-memory limit; the API returns 0.
        // Budget tests inject finite snapshots. Never apply this to devices,
        // where 0 means no headroom and must reject the allocation.
        return .max
        #else
        return Int64(clamping: os_proc_available_memory())
        #endif
    }

    static func sum(_ values: Int64...) -> Int64 {
        values.reduce(0) { total, value in
            let (next, overflow) = total.addingReportingOverflow(value)
            return value < 0 || overflow ? .max : next
        }
    }

    static func dimension(_ value: CGFloat) -> Int64 {
        guard value.isFinite, value > 0, value < CGFloat(Int64.max) else { return .max }
        return Int64(value.rounded(.up))
    }

    static func bytes(width: Int64, height: Int64, copies: Int64 = 1, extra: Int64 = 0) -> Int64 {
        guard width > 0, height > 0, copies > 0, extra >= 0 else { return .max }
        let (pixels, a) = width.multipliedReportingOverflow(by: height)
        let (pixelBytes, b) = pixels.multipliedReportingOverflow(by: 4)
        let (allCopies, c) = pixelBytes.multipliedReportingOverflow(by: copies)
        let (total, d) = allCopies.addingReportingOverflow(extra)
        return a || b || c || d ? .max : total
    }

    static func fits(required: Int64, available: Int64, threshold: Int64 = 0) -> Bool {
        guard required >= 0, required != .max, available > 0, threshold >= 0 else { return false }
        let reserve = max(64 * 1024 * 1024, threshold)
        return required <= max(0, available - reserve)
    }
}

/// Same four-million-pixel region budget as Android's
/// `photoFrameRegionRows`; one RGBA tile stays near 16 MiB.
func photoEffectsFilterTileRows(sourceWidth: Int) -> Int {
    precondition(sourceWidth > 0)
    return max(1, (4 * 1024 * 1024) / sourceWidth)
}

/// Native renderer following PhotoFrameExporter.kt's ordered pipeline.
/// Source -> NP3 filter -> frame backdrop/photo -> metadata/watermark.
enum PhotoEffectsRenderer {
    // CIContext owns its command queue and compiled kernels. Apple's CIContext
    // contract permits concurrent renders; reuse one for image conversion and
    // tiled export without retaining intermediate image buffers.
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    static func renderWithResolvedPlace(_ image: UIImage, settings: PhotoEffectsSettings,
                                        metadata: PhotoFrameMetadata?, placeResolver: PhotoFramePlaceResolver,
                                        placeAllowed: @escaping @Sendable () async -> Bool = { false },
                                        previewPlaceholders: Bool = false, backdropSource: UIImage? = nil,
                                        previewLongEdge: CGFloat? = nil) async throws -> UIImage {
        try Task.checkCancellation()
        let enriched: PhotoFrameMetadata?
        if let metadata { enriched = await placeResolver.enriching(metadata, settings: settings.metadata, allowed: placeAllowed) } else { enriched = nil }
        try Task.checkCancellation()
        return try render(image, settings: settings, metadata: enriched,
                          previewPlaceholders: previewPlaceholders, backdropSource: backdropSource,
                          previewLongEdge: previewLongEdge)
    }
    private struct Layout {
        var canvas: CGSize
        var photo: CGRect
        var metadataTop: CGFloat
        var parameterPosterPortrait = false
        var standardPlan: MetadataRowsPlan?
        var standardReferenceWidth: CGFloat?
        var photoWatermarkReference: CGFloat?
        var filmStripPlan: FilmStripPlan?
        var plaquePlan: PlaquePlan?
        var captionRows: [PositionedCaptionRow] = []
        var brandPhotoRows: [PositionedCaptionRow] = []
        var posterColumns: [PosterColumn] = []
    }
    private struct BrandBounds {
        var rect: CGRect
        func intersects(_ other: BrandBounds) -> Bool { rect.intersects(other.rect) }
    }

    private static func fitPreviewLayout(_ layout: Layout, longEdge: CGFloat) -> Layout {
        let target = max(1, longEdge.rounded())
        let scale = target / max(layout.canvas.width, layout.canvas.height)
        var result = layout
        result.canvas = CGSize(width: max(1, (layout.canvas.width * scale).rounded()),
                               height: max(1, (layout.canvas.height * scale).rounded()))
        result.photo = layout.photo.applying(CGAffineTransform(scaleX: scale, y: scale))
        result.metadataTop *= scale
        result.standardPlan = layout.standardPlan?.scaled(by: scale)
        result.standardReferenceWidth = layout.standardReferenceWidth.map { $0 * scale }
        result.photoWatermarkReference = layout.photoWatermarkReference.map { $0 * scale }
        result.filmStripPlan = layout.filmStripPlan?.scaled(by: scale)
        result.plaquePlan = layout.plaquePlan?.scaled(by: scale)
        result.captionRows = layout.captionRows.map { $0.scaled(by: scale) }
        result.brandPhotoRows = layout.brandPhotoRows.map { $0.scaled(by: scale) }
        result.posterColumns = layout.posterColumns.map { $0.scaled(by: scale) }
        return result
    }

    static func render(_ image: UIImage, settings: PhotoEffectsSettings,
                       metadata: PhotoFrameMetadata? = nil,
                       previewPlaceholders: Bool = false,
                       backdropSource: UIImage? = nil,
                       previewLongEdge: CGFloat? = nil,
                       filterExecution: PhotoFilterExecution = .original,
                       availableMemory: () -> Int64 = PhotoAllocationBudget.availableMemory) throws -> UIImage {
        try Task.checkCancellation()
        // UIImage keeps the JPEG EXIF transform as presentation metadata.
        // Android applies that transform while decoding source regions and all
        // later layout uses the oriented dimensions. Flatten it here before a
        // filter reads cgImage pixels or a frame calculates its canvas.
        let orientedSource = orientationNormalized(image)
        let orientedBackdrop = backdropSource.map(orientationNormalized) ?? orientedSource
        let visibleMetadata = presentedPhotoFrameMetadata(metadata, settings: settings.metadata, preview: previewPlaceholders)
        let sourceSize = imagePixelSize(orientedSource)
        let baseLayout = makeLayout(sourceSize, preset: settings.photoFramePreset, widthPercent: settings.metadata.widthPercent)
        var preparedLayout = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
            ? expandedStandardLayout(baseLayout, metadata: visibleMetadata, settings: settings) : baseLayout
        if settings.photoFrameEnabled && settings.photoFrameBorderEnabled {
            let reference = makeLayout(CGSize(width: 1000, height: max(1, (sourceSize.height / sourceSize.width * 1000).rounded())),
                                       preset: settings.photoFramePreset, widthPercent: 100)
            preparedLayout.photoWatermarkReference = min(reference.canvas.width, reference.canvas.height) * sourceSize.width / 1000
        }
        if settings.photoFrameEnabled && settings.photoFrameBorderEnabled,
           [.brandInset, .brandGallery].contains(settings.photoFramePreset) {
            preparedLayout.brandPhotoRows = try measuredBrandPhotoRows(layout: preparedLayout,
                preset: settings.photoFramePreset, metadata: visibleMetadata,
                watermark: settings.watermark, settings: settings.metadata)
        }
        if settings.photoFramePreset == .frosted,
           let plan = preparedLayout.standardPlan,
           plan.rows.contains(where: { $0.layoutWidth > preparedLayout.photo.width * 0.88 + 0.01 }) {
            throw PhotoFrameColumnOverflow()
        }
        if let previewLongEdge {
            if settings.photoFramePreset == .immersive {
                preparedLayout = makeImmersivePreviewLayout(sourceSize, longEdge: previewLongEdge)
            } else {
                preparedLayout = fitPreviewLayout(preparedLayout, longEdge: previewLongEdge)
            }
        }
        if filterExecution == .original, previewLongEdge == nil, !previewPlaceholders {
            let source = imagePixelSize(orientedSource)
            let canvas = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
                ? preparedLayout.canvas
                : source
            let width = PhotoAllocationBudget.dimension(source.width)
            let height = PhotoAllocationBudget.dimension(source.height)
            let sourceBytes = PhotoAllocationBudget.bytes(width: width, height: height)
            // CGImage providers may decode lazily; include that source allocation.
            // UIKit may choose an extended-range (8-byte) canvas. Keep its actual
            // format, but account for it and the quarter-scale shadow proxy.
            let canvasBytes = PhotoAllocationBudget.bytes(
                width: PhotoAllocationBudget.dimension(canvas.width),
                height: PhotoAllocationBudget.dimension(canvas.height), copies: 2)
            let rows = max(1, (4 * 1024 * 1024) / width)
            let scratch = settings.photoFilterEnabled && settings.selectedFilter != nil
                ? PhotoAllocationBudget.bytes(width: width, height: min(height, rows), copies: 2) : 0
            let backdropEdge = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
                ? photoFrameBackdropPreviewLongEdge(settings.photoFramePreset, blurPercent: settings.metadata.backgroundBlurPercent) : 192
            // Android also reserves the larger low-blur proxy and its temporary copy.
            let extraBackdrop = backdropEdge > 192
                ? PhotoAllocationBudget.bytes(width: Int64(backdropEdge), height: Int64(backdropEdge), copies: 2) : 0
            let required = PhotoAllocationBudget.sum(sourceBytes, canvasBytes, canvasBytes / 16,
                                                       scratch, extraBackdrop, 8 * 1024 * 1024)
            let available = availableMemory()
            guard PhotoAllocationBudget.fits(required: required, available: available) else {
                throw PhotoAllocationRejected(required: required, available: available)
            }
        }
        var output = orientedSource
        let tiledFrameFilter: PhotoFilterSelection? =
            settings.photoFrameEnabled && settings.photoFrameBorderEnabled &&
            settings.photoFilterEnabled
                ? settings.selectedFilter : nil
        if settings.photoFilterEnabled, let filter = settings.selectedFilter,
           tiledFrameFilter == nil {
            if filterExecution == .original {
                let watermark = settings.photoFrameEnabled && settings.watermark.enabled ? settings.watermark : nil
                return try drawFlatPhoto(output, filter: filter, watermark: watermark)
            }
            output = try applyFilter(output, selection: filter, execution: filterExecution)
        }
        if settings.photoFrameEnabled {
            if !settings.photoFrameBorderEnabled {
                if settings.watermark.enabled { output = try drawFlatPhoto(output, filter: nil, watermark: settings.watermark) }
                try Task.checkCancellation()
                return output
            }
            // Android builds the frame backdrop from the original photo, then
            // applies the selected filter only to the photo layer. Keep both
            // inputs so a filter never recolors the surrounding blur/gradient.
            output = try drawDecoration(output, backdropImage: orientedBackdrop,
                                        settings: settings, metadata: visibleMetadata,
                                        previewPlaceholders: previewPlaceholders,
                                        tiledFilter: tiledFrameFilter,
                                        previewLongEdge: previewLongEdge, preparedLayout: preparedLayout)
        }
        try Task.checkCancellation()
        return output
    }

    private static func orientationNormalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, let source = image.cgImage else { return image }
        // Keep EXIF normalization lazy. Android's region decoder applies the
        // orientation to each source band; eagerly drawing a rotated UIImage
        // here would retain another full-resolution bitmap beside the final
        // canvas. A CI-backed UIImage lets photo/background draws and the tiled
        // filter path request only the pixels needed by their destination.
        let exifOrientation: Int32 = switch image.imageOrientation {
        case .up: 1
        case .upMirrored: 2
        case .down: 3
        case .downMirrored: 4
        case .leftMirrored: 5
        case .right: 6
        case .rightMirrored: 7
        case .left: 8
        @unknown default: 1
        }
        var oriented = CIImage(cgImage: source).oriented(forExifOrientation: exifOrientation)
        if oriented.extent.origin != .zero {
            oriented = oriented.transformed(by: CGAffineTransform(
                translationX: -oriented.extent.minX,
                y: -oriented.extent.minY
            ))
        }
        return UIImage(ciImage: oriented, scale: 1, orientation: .up)
    }

    private static func applyFilter(_ image: UIImage, selection: PhotoFilterSelection,
                                    execution: PhotoFilterExecution = .original) throws -> UIImage {
        if selection.preset.id.hasPrefix("cube:") {
            let loaded = selection.snapshotOwner.map { PhotoLUTRuntime.table(owner: $0) }
                ?? PhotoLUTRuntime.table(digest: String(selection.preset.id.dropFirst(5)))
            guard let table = loaded,
                  let source = processingCGImage(image),
                  let filtered = try PhotoCubeLUTMapper.apply(source, lut: table, intensityPercent: selection.normalizedIntensityPercent,
                                                       adjustments: selection.lutAdjustments) else {
                throw PhotoEffectsRenderError.unknownFilter
            }
            return UIImage(cgImage: filtered, scale: image.scale, orientation: image.imageOrientation)
        }
        guard let preset = Np3FilterCatalog.preset(id: selection.preset.id) else {
            throw PhotoEffectsRenderError.unknownFilter
        }
        guard let source = processingCGImage(image) else { throw PhotoEffectsRenderError.invalidBitmap }
        let filtered = try Np3BitmapFilter.apply(source, parameters: preset.parameters,
                                                  intensityPercent: selection.normalizedIntensityPercent, execution: execution)
        return UIImage(cgImage: filtered, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func processingCGImage(_ image: UIImage) -> CGImage? {
        if let source = image.cgImage { return source }
        guard let source = image.ciImage else { return nil }
        return imageContext.createCGImage(source, from: source.extent)
    }

    private static func drawDecoration(_ image: UIImage, backdropImage: UIImage,
                                       settings: PhotoEffectsSettings,
                                       metadata: PhotoFrameMetadata?,
                                       previewPlaceholders: Bool,
                                       tiledFilter: PhotoFilterSelection?,
                                       previewLongEdge: CGFloat?, preparedLayout: Layout) throws -> UIImage {
        let sourceSize = imagePixelSize(image)
        let layout = preparedLayout
        let basePhotoLayout = makeLayout(sourceSize, preset: settings.photoFramePreset, widthPercent: settings.metadata.widthPercent)
        let photoDecorationBandHeight = (basePhotoLayout.canvas.height - basePhotoLayout.metadataTop)
            * layout.photo.width / basePhotoLayout.photo.width
        let decorationImage = try settings.photoFramePreset == .colorArchive
            ? filteredPalettePreview(image, selection: tiledFilter) : image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var renderError: Error?
        let rendered = UIGraphicsImageRenderer(size: layout.canvas, format: format).image { renderer in
            let cg = renderer.cgContext
            drawBackdrop(cg, image: backdropImage, layout: layout, preset: settings.photoFramePreset,
                         blurPercent: settings.metadata.backgroundBlurPercent,
                         maskPercent: settings.metadata.backgroundMaskPercent)
            if Task.isCancelled {
                renderError = CancellationError()
                return
            }
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
                do {
                    try drawPhoto(cg, image: image, rect: layout.photo,
                                  preset: settings.photoFramePreset,
                                  metadataBandHeight: photoDecorationBandHeight,
                                  canvasSize: layout.canvas, filter: tiledFilter)
                } catch {
                    renderError = error
                    return
                }
            } else {
                image.draw(in: layout.photo)
            }
            if Task.isCancelled {
                renderError = CancellationError()
                return
            }
            do {
                try drawPresetDecoration(cg, image: decorationImage, layout: layout,
                                 preset: settings.photoFramePreset,
                                 metadata: metadata,
                                 watermark: settings.watermark,
                                 metadataSettings: settings.metadata)
            } catch { renderError = error }
        }
        if let renderError { throw renderError }
        return rendered
    }

    private static func imagePixelSize(_ image: UIImage) -> CGSize {
        if let source = image.cgImage {
            return CGSize(width: source.width, height: source.height)
        }
        if let source = image.ciImage {
            return source.extent.size
        }
        return image.size
    }

    /// Android's watermark-only path preserves the source dimensions and does
    /// not create a hidden frame/backdrop when the border switch is off.
    private static func drawFlatPhoto(_ image: UIImage, filter: PhotoFilterSelection?,
                                      watermark: PhotoFrameWatermark?) throws -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale; format.opaque = false
        var renderError: Error?
        let output = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let photo = CGRect(origin: .zero, size: size)
            do {
                if let filter {
                    try drawFilteredPhotoTiles(renderer.cgContext, image: image, rect: photo, selection: filter)
                } else {
                    image.draw(in: photo)
                }
                try Task.checkCancellation()
                if var effective = watermark {
                    if !photoPlacement(effective.position) { effective.position = .photoBottomCenter }
                    try drawWatermark(renderer.cgContext, watermark: effective, photo: photo, canvas: size,
                                  preset: .mist, metadataBand: .zero)
                }
            } catch { renderError = error }
        }
        if let renderError { throw renderError }
        try Task.checkCancellation()
        return output
    }

    // MARK: Layout (ratios ported from PhotoFrameExporter.kt)

    private static func makeLayout(_ source: CGSize, preset: PhotoFramePreset, widthPercent: Int = 100) -> Layout {
        let w = max(source.width, 1), h = max(source.height, 1), aspect = w / h
        let px: (CGFloat) -> CGFloat = { max(1, $0.rounded()) }
        switch preset {
        case .plaque:
            let band = px(w * 0.12 * CGFloat(normalizePhotoFrameWidthPercent(widthPercent)) / 100)
            return Layout(canvas: CGSize(width: w, height: h + band), photo: CGRect(x: 0, y: 0, width: w, height: h), metadataTop: h)
        case .immersive:
            return Layout(canvas: source, photo: CGRect(origin: .zero, size: source), metadataTop: h)
        case .brandInset, .brandGallery:
            let frameScale = CGFloat(normalizePhotoFrameWidthPercent(widthPercent)) / 100
            let side = px(w * 0.032 * frameScale)
            let bottom = px(w * (preset == .brandInset ? 0.032 : 0.16) * frameScale)
            return Layout(canvas: CGSize(width: w + side * 2, height: h + side + bottom),
                          photo: CGRect(x: side, y: side, width: w, height: h), metadataTop: side + h)
        case .classicSignature, .galleryMat, .colorArchive, .filmGallery, .filmEdge, .filmNegative:
            let frameScale = CGFloat(normalizePhotoFrameWidthPercent(widthPercent)) / 100
            switch preset {
            case .classicSignature:
                let side = px(w * 0.03 * frameScale), top = px(w * 0.095 * frameScale), bottom = px(w * 0.15 * frameScale)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            case .galleryMat:
                let (wf, hf): (CGFloat, CGFloat) = aspect > 1.08 ? (0.80, 0.56) : aspect < 0.92 ? (0.56, 0.80) : (0.68, 0.68)
                // Android calculateMeasuredTemplateFrame uses a 1000px photo
                // reference, scales only the margins, then expands to a square.
                // Scaling the canvas itself crops the photo below 100% width.
                let photoHeight = h / w * 1000
                let referenceHeight = max(1, photoHeight.rounded())
                let baseSide = max(1000 / wf, referenceHeight / hf).rounded()
                let clearance = min(1000, photoHeight) * 0.045 + 12
                let padding = 20 * min(max(frameScale, 0.65), 1)
                var left = max((baseSide - 1000) / 2 * frameScale, clearance + padding)
                var top = max((baseSide - referenceHeight) * 0.45 * frameScale, clearance + padding)
                var bottom = max((baseSide - referenceHeight) * 0.55 * frameScale, clearance + padding * 2)
                let edge = max(1000 + left * 2, photoHeight + top + bottom)
                left += (edge - (1000 + left * 2)) / 2
                let extraHeight = edge - (photoHeight + top + bottom)
                top += extraHeight * 0.45
                bottom += extraHeight * 0.55
                let scale = w / 1000
                let x = ceil(left * scale), y = ceil(top * scale)
                let side = max(w + x * 2, h + y + ceil(bottom * scale))
                return Layout(canvas: CGSize(width: side, height: side),
                              photo: CGRect(x: x, y: y, width: w, height: h), metadataTop: y + h)
            case .colorArchive:
                let side = px(w * 0.04 * frameScale), top = px(w * 0.04 * frameScale), bottom = px(w * 0.17 * frameScale)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            case .filmGallery:
                let side = px(w * 0.085 * frameScale), top = px(w * 0.16 * frameScale), bar = px(w * 0.09 * frameScale), bottom = px(w * 0.34 * frameScale)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bar * 2 + bottom), photo: CGRect(x: side, y: top + bar, width: w, height: h), metadataTop: top + bar + h + bar)
            case .filmEdge:
                let side = px(w * 0.07 * frameScale), top = px(w * 0.035 * frameScale), bottom = px(w * 0.085 * frameScale)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom), photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            case .filmNegative:
                // PhotoFrameExporter.kt uses fixed contact-sheet proportions:
                // side 2.6%, top 6%, bottom 16% of the source width.
                let side = px(w * 0.026 * frameScale), top = px(w * 0.060 * frameScale), bottom = px(w * 0.16 * frameScale)
                return Layout(canvas: CGSize(width: w + side * 2, height: h + top + bottom),
                              photo: CGRect(x: side, y: top, width: w, height: h), metadataTop: top + h)
            default: fatalError()
            }
        case .parameterPoster:
            let portrait = h > w
            let left = px(w * (portrait ? 1.10 : 0.10))
            let top = px(w * 0.11)
            let right = px(w * (portrait ? 0.22 : 0.10))
            let bottom = px(w * (portrait ? 0.11 : 0.48))
            return Layout(canvas: CGSize(width: w + left + right, height: h + top + bottom),
                          photo: CGRect(x: left, y: top, width: w, height: h),
                          metadataTop: top + h, parameterPosterPortrait: portrait)
        default:
            let base = standardLayout(source)
            let scale = CGFloat(normalizePhotoFrameWidthPercent(widthPercent)) / 100
            let left = ceil(base.photo.minX * scale)
            let top = ceil(base.photo.minY * scale)
            let right = ceil((base.canvas.width - base.photo.maxX) * scale)
            let bottom = ceil((base.canvas.height - base.photo.maxY) * scale)
            return Layout(canvas: CGSize(width: w + left + right, height: h + top + bottom),
                photo: CGRect(x: left, y: top, width: w, height: h),
                metadataTop: top + h + (base.metadataTop - base.photo.maxY) * scale)
        }
    }

    /// Immersive preview keeps the source aspect and does not upscale.
    private static func makeImmersivePreviewLayout(_ source: CGSize, longEdge: CGFloat) -> Layout {
        let w = max(source.width, 1), h = max(source.height, 1)
        let scale = min(1, max(1, longEdge.rounded()) / max(w, h))
        let canvas = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        return Layout(canvas: canvas, photo: CGRect(origin: .zero, size: canvas), metadataTop: canvas.height)
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
                let left = floor((canvasSize.width - w) / 2)
                let desiredTop = top + availableHeight / 2 - h / 2
                let maxTop = min(canvasSize.height - h, metadataTop - h)
                let photoTop = floor(min(max(desiredTop, 0), maxTop))
                return Layout(canvas: canvasSize, photo: CGRect(x: left, y: photoTop, width: w, height: h), metadataTop: metadataTop)
            }
            longEdge = ceil(longEdge / max(scale, 0.01))
        }
        return Layout(canvas: CGSize(width: canvasRatio.width * longEdge, height: canvasRatio.height * longEdge), photo: CGRect(x: 0, y: 0, width: w, height: h), metadataTop: h)
    }

    // MARK: Backdrops and photo layer

    private static func drawBackdrop(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset,
                                     blurPercent: Int = 100, maskPercent: Int = 100) {
        let rect = CGRect(origin: .zero, size: layout.canvas)
        func mask(_ alpha: Int) -> CGFloat {
            CGFloat(photoFrameBackdropMaskAlpha(alpha, percent: maskPercent)) / 255
        }
        switch preset {
        case .minimal:
            drawGradient(cg, rect: rect, top: UIColor(red: 0.98, green: 0.976, blue: 0.969, alpha: 1), bottom: UIColor(red: 0.937, green: 0.929, blue: 0.91, alpha: 1))
        case .mist, .cinema, .frosted, .filmGallery, .parameterPoster:
            let bg = blurredBackground(image, size: layout.canvas, blurPercent: blurPercent)
            let cinema = preset == .cinema || preset == .filmGallery || preset == .parameterPoster
            if cinema && normalizePhotoFrameBackdropPercent(blurPercent) > 0 {
                cinemaBackdropProxy(bg, maskPercent: maskPercent).draw(in: rect)
            } else {
                bg.draw(in: rect)
                if cinema { drawCinemaBackdropTreatment(cg, size: layout.canvas, maskPercent: maskPercent) }
            }
            if preset == .mist {
                cg.setFillColor(UIColor(red: 0.93, green: 0.95, blue: 0.97, alpha: mask(62)).cgColor); cg.fill(rect)
                drawGradient(cg, rect: CGRect(x: 0, y: rect.height * 0.58, width: rect.width, height: rect.height * 0.42),
                             top: UIColor(red: 3.0 / 255.0, green: 10.0 / 255.0, blue: 15.0 / 255.0, alpha: 0),
                             bottom: UIColor(red: 3.0 / 255.0, green: 10.0 / 255.0, blue: 15.0 / 255.0, alpha: 178.0 / 255.0))
            }
            if preset == .frosted {
                drawGradient(cg, rect: rect,
                             top: UIColor(red: 250.0 / 255.0, green: 253.0 / 255.0, blue: 255.0 / 255.0, alpha: mask(92)),
                             bottom: UIColor(red: 231.0 / 255.0, green: 239.0 / 255.0, blue: 245.0 / 255.0, alpha: mask(132)))
            }
            if preset == .filmGallery {
                cg.setFillColor(UIColor(red: 18.0 / 255.0, green: 12.0 / 255.0, blue: 10.0 / 255.0, alpha: mask(66)).cgColor); cg.fill(rect)
                drawGradient(cg, rect: CGRect(x: 0, y: rect.height * 0.48, width: rect.width, height: rect.height * 0.52),
                             top: UIColor(white: 0, alpha: 0), bottom: UIColor(red: 15.0 / 255.0, green: 10.0 / 255.0, blue: 8.0 / 255.0, alpha: mask(92)))
            }
        case .plaque, .brandInset, .brandGallery, .classicSignature, .galleryMat, .colorArchive:
            cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(rect)
        case .immersive:
            break
        case .filmEdge:
            cg.setFillColor(UIColor(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 9.0 / 255.0, alpha: 1).cgColor); cg.fill(rect)
        case .filmNegative:
            cg.setFillColor(UIColor(red: 7.0 / 255.0, green: 7.0 / 255.0, blue: 8.0 / 255.0, alpha: 1).cgColor); cg.fill(rect)
        }
    }

    /// Android composites this low-frequency treatment before upscaling a blurred proxy.
    static func cinemaBackdropProxy(_ image: UIImage, maskPercent: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            drawCinemaBackdropTreatment(context.cgContext, size: image.size, maskPercent: maskPercent)
        }
    }

    private static func drawCinemaBackdropTreatment(_ cg: CGContext, size: CGSize, maskPercent: Int) {
        let rect = CGRect(origin: .zero, size: size)
        cg.setFillColor(UIColor(red: 3.0 / 255, green: 9.0 / 255, blue: 15.0 / 255,
            alpha: CGFloat(photoFrameBackdropMaskAlpha(150, percent: maskPercent)) / 255).cgColor)
        cg.fill(rect)
        let colors = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 110.0 / 255).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) else { return }
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: size.height * 0.60, width: size.width, height: size.height * 0.40))
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height * 0.62),
                              end: CGPoint(x: 0, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }

    private static func drawPhoto(_ cg: CGContext, image: UIImage, rect: CGRect,
                                  preset: PhotoFramePreset, metadataBandHeight: CGFloat,
                                  canvasSize: CGSize,
                                  filter: PhotoFilterSelection?) throws {
        let radius: CGFloat = switch preset {
        case .colorArchive: rect.width * 0.012
        case .brandInset, .brandGallery: rect.width * 0.014
        case .mist, .cinema, .minimal, .frosted: max(1, metadataBandHeight * 0.26)
        case .plaque, .immersive, .classicSignature, .galleryMat, .filmGallery, .filmEdge, .filmNegative: 0
        case .parameterPoster: min(rect.width, rect.height) * 0.018
        }
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        if [.mist, .cinema, .minimal, .frosted, .brandInset, .brandGallery, .colorArchive].contains(preset) {
            drawStandardPhotoElevation(cg, rect: rect, radius: radius, preset: preset, canvasSize: canvasSize)
        } else if ![.plaque, .immersive, .filmEdge, .filmNegative, .classicSignature, .filmGallery, .galleryMat].contains(preset) {
            drawPhotoElevation(cg, rect: rect, radius: radius, preset: preset, canvasSize: canvasSize)
        }
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        if let filter {
            try drawFilteredPhotoTiles(cg, image: image, rect: rect, selection: filter)
        } else {
            image.draw(in: rect)
        }
        cg.restoreGState()
        if preset == .classicSignature {
            cg.setStrokeColor(UIColor(white: 0, alpha: 0.14).cgColor)
            cg.setLineWidth(max(1, rect.width * 0.0008))
            cg.addPath(path)
            cg.strokePath()
        } else if ![.plaque, .immersive, .filmEdge, .filmNegative, .filmGallery, .galleryMat].contains(preset) {
            let stroke: UIColor
            if preset == .brandInset || preset == .brandGallery {
                stroke = UIColor(red: 0.06, green: 0.08, blue: 0.09, alpha: 0.18)
            } else {
                stroke = UIColor(white: 1, alpha: 0.275)
            }
            cg.setStrokeColor(stroke.cgColor); cg.setLineWidth(max(1, rect.width * 0.0012)); cg.addPath(path); cg.strokePath()
        }
    }

    /// Android decodes and filters roughly four million source pixels at a
    /// time for every bordered full-resolution export. A CGImage can retain a
    /// compressed provider, so crop each horizontal band and release its
    /// mutable filter buffer before moving to the next band instead of holding
    /// a second full-resolution filtered bitmap beside the output canvas.
    private static func drawFilteredPhotoTiles(
        _ context: CGContext, image: UIImage, rect: CGRect,
        selection: PhotoFilterSelection
    ) throws {
        let sourceWidth = Int(imagePixelSize(image).width.rounded())
        let sourceHeight = Int(imagePixelSize(image).height.rounded())
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw PhotoEffectsRenderError.invalidBitmap
        }
        let rowsPerTile = photoEffectsFilterTileRows(sourceWidth: sourceWidth)
        context.interpolationQuality = .none
        var top = 0
        while top < sourceHeight {
            try Task.checkCancellation()
            let bottom = min(sourceHeight, top + rowsPerTile)
            try autoreleasepool {
                let region: CGImage?
                if let source = image.cgImage {
                    region = source.cropping(to: CGRect(
                        x: 0, y: top, width: sourceWidth, height: bottom - top
                    ))
                } else if let source = image.ciImage {
                    let crop = CGRect(
                        x: source.extent.minX,
                        y: source.extent.minY + CGFloat(sourceHeight - bottom),
                        width: CGFloat(sourceWidth),
                        height: CGFloat(bottom - top)
                    )
                    region = imageContext.createCGImage(source, from: crop)
                } else {
                    region = nil
                }
                guard let region else { throw PhotoEffectsRenderError.invalidBitmap }
                let filtered = try applyFilter(
                    UIImage(cgImage: region, scale: 1, orientation: .up),
                    selection: selection
                )
                let scaleY = rect.height / CGFloat(sourceHeight)
                let destination = CGRect(
                    x: rect.minX,
                    y: rect.minY + CGFloat(top) * scaleY,
                    width: rect.width,
                    height: CGFloat(bottom - top) * scaleY
                )
                filtered.draw(in: destination)
            }
            top = bottom
        }
    }

    /// COLOR_ARCHIVE derives its palette from the filtered photo. Android
    /// samples a region-decoder preview whose longest edge is at most 192 px,
    /// rather than retaining the full filtered source solely for four colors.
    private static func filteredPalettePreview(
        _ image: UIImage, selection: PhotoFilterSelection?
    ) throws -> UIImage {
        guard let selection else { return image }
        let sourceSize = imagePixelSize(image)
        var sample = 1
        while max(Int(sourceSize.width) / sample, Int(sourceSize.height) / sample) > 192 { sample *= 2 }
        let target = CGSize(width: CGFloat(max(1, Int(sourceSize.width) / sample)),
                            height: CGFloat(max(1, Int(sourceSize.height) / sample)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let preview = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return try applyFilter(preview, selection: selection)
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
        case .parameterPoster: 1.0
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

    static func blurredBackground(_ image: UIImage, size: CGSize, blurPercent: Int = 100) -> UIImage {
        guard size.width > 0, size.height > 0 else { return image }
        let sourceSize = imagePixelSize(image)
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        let blur = normalizePhotoFrameBackdropPercent(blurPercent)
        let longEdge = CGFloat(photoFrameBackdropPreviewLongEdge(.mist, blurPercent: blur))
        // Android's 96-pixel floor belongs only to the box-blur path.
        // A sharp backdrop must retain the requested crop aspect ratio.
        let minimumShortEdge: CGFloat = blur == 0 ? 1 : 96
        let proxySize = size.width >= size.height
            ? CGSize(width: longEdge, height: max(minimumShortEdge, (longEdge * size.height / size.width).rounded()))
            : CGSize(width: max(minimumShortEdge, (longEdge * size.width / size.height).rounded()), height: longEdge)
        let proxyFormat = UIGraphicsImageRendererFormat()
        proxyFormat.scale = 1
        proxyFormat.opaque = true
        let proxy = UIGraphicsImageRenderer(size: proxySize, format: proxyFormat).image { renderer in
            let scale = max(proxySize.width / sourceSize.width, proxySize.height / sourceSize.height)
            let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let rect = CGRect(x: (proxySize.width - drawSize.width) / 2, y: (proxySize.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height)
            image.draw(in: rect)
        }
        guard blur > 0 else { return proxy }
        var pixels = Array(repeating: UInt8(255), count: Int(proxySize.width * proxySize.height) * 4)
        guard let proxyCG = proxy.cgImage,
              let context = CGContext(data: &pixels, width: Int(proxySize.width), height: Int(proxySize.height),
                                       bitsPerComponent: 8, bytesPerRow: Int(proxySize.width) * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return proxy }
        context.interpolationQuality = .high
        context.draw(proxyCG, in: CGRect(origin: .zero, size: proxySize))
        let radius = max(1, Int(round(8 * CGFloat(blur) / 100 * longEdge / 192)))
        androidBoxBlur(&pixels, width: Int(proxySize.width), height: Int(proxySize.height), radius: radius, passes: 2)
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

    private static func drawPresetDecoration(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata?, watermark: PhotoFrameWatermark, metadataSettings: PhotoFrameMetadataSettings) throws {
        let effective = metadata ?? PhotoFrameMetadata.empty
        switch preset {
        case .plaque: try drawPlaque(cg, layout: layout, metadata: effective, watermark: watermark, settings: metadataSettings)
        case .immersive: try drawImmersive(cg, layout: layout, metadata: effective, watermark: watermark, settings: metadataSettings)
        case .brandInset, .brandGallery: try drawBrand(cg, layout: layout, preset: preset, metadata: effective, watermark: watermark, settings: metadataSettings)
        case .classicSignature, .galleryMat, .colorArchive, .filmGallery, .filmEdge, .filmNegative, .parameterPoster:
            try drawEditorial(cg, image: image, layout: layout, preset: preset, metadata: effective, watermark: watermark, settings: metadataSettings)
        default:
            try drawStandardMetadata(cg, layout: layout, preset: preset, metadata: effective, watermark: watermark, settings: metadataSettings)
        }
    }

    private static func expandedStandardLayout(_ base: Layout, metadata: PhotoFrameMetadata, settings: PhotoEffectsSettings) -> Layout {
        let preset = settings.photoFramePreset
        if preset == .parameterPoster {
            return measuredPosterLayout(base.photo.size, metadata: metadata, settings: settings.metadata)
        }
        if preset == .plaque {
            let plan = makePlaquePlan(width: base.canvas.width, metadata: metadata, watermark: settings.watermark, settings: settings.metadata)
            var result = base
            result.plaquePlan = plan
            result.canvas.width = ceil(base.canvas.width + plan.extraWidth)
            result.photo.origin.x += floor((result.canvas.width - base.canvas.width) / 2)
            result.canvas.height = max(base.canvas.height, ceil(base.photo.maxY + plan.contentHeight / 0.88))
            return result
        }
        if preset == .brandGallery {
            return measuredCaptionLayout(base.photo.size, metadata: metadata, settings: settings)
        }
        if preset == .colorArchive {
            return measuredCaptionLayout(base.photo.size, metadata: metadata, settings: settings)
        }
        if preset == .filmNegative {
            return measuredCaptionLayout(base.photo.size, metadata: metadata, settings: settings)
        }
        if preset == .filmEdge {
            return measuredCaptionLayout(base.photo.size, metadata: metadata, settings: settings)
        }
        if preset == .filmGallery {
            return measuredCaptionLayout(base.photo.size, metadata: metadata, settings: settings)
        }
        if preset == .classicSignature {
            return measuredCaptionLayout(base.photo.size, metadata: metadata, settings: settings)
        }
        if preset == .galleryMat {
            return measuredCaptionLayout(base.photo.size, metadata: metadata, settings: settings)
        }
        guard [.mist, .cinema, .minimal, .frosted].contains(preset) else { return base }
        let area = preset == .frosted ? frostedMetadataPanelBounds(base)
            : CGRect(x: 0, y: base.photo.maxY, width: base.canvas.width, height: base.canvas.height - base.photo.maxY)
        // Android fonts use the unmodified reference design width; border width
        // changes available space, not the user's chosen type size.
        let referenceWidth = standardLayout(base.photo.size).canvas.width
        let plan = standardMetadataPlan(area: area, canvasWidth: referenceWidth, preset: preset,
            metadata: metadata, watermark: settings.watermark, settings: settings.metadata,
            lightText: preset == .mist || preset == .cinema)
        var result = base
        result.standardPlan = plan
        result.standardReferenceWidth = referenceWidth
        if preset != .frosted {
            let requiredWidth = (plan.rows.map(\.layoutWidth).max() ?? 0) + referenceWidth * 0.16
            result.canvas.width = max(base.canvas.width, ceil(requiredWidth))
            result.photo.origin.x += floor((result.canvas.width - base.canvas.width) / 2)
        }
        guard !plan.rows.isEmpty else { return result }
        let gap = referenceWidth * 0.0125
        let content = plan.inkHeight + gap * CGFloat(max(0, plan.rows.count - 1))
        let panelFraction: CGFloat = preset == .frosted ? 0.84 : 1
        let requiredBand = content / (1 - PhotoFrameTextLayout.standardPaddingRatio * 2) / panelFraction
        result.canvas.height = max(base.canvas.height, ceil(base.photo.maxY + requiredBand))
        return result
    }

    static func classicHeaderPlan(_ metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings, width: CGFloat) -> MetadataRowsPlan {
        guard !metadata.identity.isEmpty else { return MetadataRowsPlan(rows: [], watermarkIndex: nil) }
        let font = UIFont(name: "HelveticaNeue-BlackItalic", size: width * 0.034)
            ?? UIFont.italicSystemFont(ofSize: width * 0.034)
        let color = UIColor(red: 0.04, green: 0.043, blue: 0.047, alpha: 1)
        let logo = settings.showBrand && settings.brandStyle == .logo
        let photoWidth = width / 1.06
        let rows = frameIdentityRows(metadata: metadata, logoEnabled: logo, brandFont: font, modelFont: font,
            color: color, gap: photoWidth * 0.012, width: photoWidth * 0.9, logoScale: 1.55,
            uppercaseBrand: true, preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035)
        return MetadataRowsPlan(rows: rows, watermarkIndex: nil)
    }

    private struct PositionedCaptionRow {
        let row: PhotoFrameTextRow
        let x: CGFloat
        let baseline: CGFloat
        let signature: Bool

        func scaled(by scale: CGFloat) -> Self {
            Self(row: row.scaled(by: scale), x: x * scale, baseline: baseline * scale, signature: signature)
        }
    }

    /// Android calculateMeasuredTemplateFrame: measure at fixed photo width,
    /// expand the information band without resampling the photo. GalleryMat then
    /// completes the square; FilmGallery retains its fixed-height film bars.
    private static func measuredCaptionLayout(_ source: CGSize, metadata: PhotoFrameMetadata,
                                               settings: PhotoEffectsSettings) -> Layout {
        let w = source.width, h = source.height
        let photoHeight = h / w * 1000
        let referenceHeight = max(1, photoHeight.rounded())
        let aspect = 1000 / referenceHeight
        let fractions: (CGFloat, CGFloat) = aspect > 1.08 ? (0.80, 0.56) : aspect < 0.92 ? (0.56, 0.80) : (0.68, 0.68)
        let baseSide = max(1000 / fractions.0, referenceHeight / fractions.1).rounded()
        let film = settings.photoFramePreset == .filmGallery
        let negative = settings.photoFramePreset == .filmNegative
        let edgeFrame = settings.photoFramePreset == .filmEdge
        let classic = settings.photoFramePreset == .classicSignature
        let brandGallery = settings.photoFramePreset == .brandGallery
        let archive = settings.photoFramePreset == .colorArchive
        let square = settings.photoFramePreset == .galleryMat
        let header = classic ? classicHeaderPlan(metadata, settings: settings.metadata, width: 1060).rows : []
        let strip = film ? FilmStripPlan(metadata: metadata, settings: settings.metadata, width: 1000) : nil
        let percent = CGFloat(normalizePhotoFrameWidthPercent(settings.metadata.widthPercent)) / 100
        let gap = archive ? 170 * 0.055 * min(percent, 1) : 10 * min(max(percent, 0.65), 1)
        let padding = 20 * min(max(percent, 0.65), 1)
        let clearance: CGFloat = edgeFrame || classic || brandGallery || archive ? 0 : negative ? 42 : film ? 110 : min(1000, photoHeight) * 0.045 + 12
        let ink = negative ? UIColor(red: 238 / 255, green: 173 / 255, blue: 117 / 255, alpha: 1) : film ? UIColor(red: 250 / 255, green: 249 / 255, blue: 246 / 255, alpha: 1)
            : UIColor(red: 24 / 255, green: 27 / 255, blue: 30 / 255, alpha: 1)
        let identityFont = UIFont.systemFont(ofSize: brandGallery ? 1064 * 0.052 : film ? 21 : 28,
                                            weight: film || brandGallery ? .bold : .regular)
        let identity = negative || edgeFrame || classic || archive || strip?.identity != nil ? [] : frameIdentityRows(metadata: metadata,
            logoEnabled: settings.metadata.showBrand && settings.metadata.brandStyle == .logo,
            brandFont: identityFont, modelFont: identityFont,
            color: ink, gap: 12, width: 900, logoScale: brandGallery ? 1.55 : film ? 1.15 : 1.45,
            uppercaseBrand: brandGallery, preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035)
        let detailValues = film
            ? [metadata.lensModel ?? "", metadata.frameDetailLine] + metadata.locationRows + (strip?.date == nil ? [metadata.dateTime ?? ""] : [])
            : [metadata.lensModel ?? "", classic ? metadata.classicSignatureDetailLine : metadata.frameDetailLine, metadata.dateTime ?? ""] + metadata.locationRows
        let detailFont = negative ? (UIFont(name: "HelveticaNeue-Condensed", size: 18) ?? UIFont.systemFont(ofSize: 18))
            : UIFont.systemFont(ofSize: classic ? 1060 * 0.024 : film ? 21 : 20)
        let details = (brandGallery ? [] : detailValues)
            .flatMap { metadataDescriptionRows($0, font: detailFont, color: ink,
                                               width: 900, preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035) }
        let edgePlan = edgeFrame ? filmEdgePlan(metadata: metadata, settings: settings.metadata, width: 1000) : nil
        let info = archive ? colorArchivePlan(metadata: metadata, settings: settings.metadata, width: 1000).rows
            : edgePlan?.rows ?? (identity + details)
        let informationWidth: CGFloat = archive ? 680 : 900
        // Android gives a combined fallback identity row an additional half-gap.
        let identityGap = edgePlan?.identityGap ?? (identity.count == 1 && identity[0].layoutWidth <= 900 ? gap * 0.5 : 0)
        let watermark = settings.watermark
        let hasSignature = !archive && !edgeFrame && (!(classic || brandGallery) || watermark.position != .auto) && watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position)
        let referenceShortEdge: CGFloat
        switch settings.photoFramePreset {
        case .brandGallery: referenceShortEdge = min(1064, referenceHeight + 192)
        case .classicSignature: referenceShortEdge = min(1060, referenceHeight + 245)
        case .filmNegative: referenceShortEdge = min(1052, referenceHeight + 220)
        case .filmGallery: referenceShortEdge = min(1170, referenceHeight + 680)
        default: referenceShortEdge = baseSide
        }
        let signatureColor = brandGallery && watermark.color == .adaptive
            ? watermarkColor(.black, .brandGallery) : watermarkColor(watermark.color, settings.photoFramePreset)
        let signature = hasSignature ? watermarkDescriptionRows(watermark.displayText,
            font: watermarkFont(watermark.font, size: referenceShortEdge * textSizeFraction(watermark.sizePercent)),
            color: signatureColor.withAlphaComponent(CGFloat(watermark.opacityPercent) / 100),
            width: 884) : []
        func height(_ rows: [PhotoFrameTextRow]) -> CGFloat {
            rows.reduce(0) { $0 + $1.bounds.height } + CGFloat(max(0, rows.count - 1)) * gap
        }
        let infoHeight = height(info) + (info.count > 1 ? identityGap : 0)
        let signatureGap: CGFloat = !info.isEmpty && !signature.isEmpty ? gap * 1.5 : 0
        let contentHeight = infoHeight + signatureGap + height(signature)
        let extraWidth = max(0, (info.map(\.layoutWidth).max() ?? 0) - informationWidth,
                             (signature.map(\.layoutWidth).max() ?? 0) - 884,
                             (header.map(\.layoutWidth).max() ?? 0) - 900)
        var left: CGFloat
        var top: CGFloat
        var minimumBottom: CGFloat
        switch settings.photoFramePreset {
        case .colorArchive:
            left = 40 * percent
            top = 40 * percent
            minimumBottom = max(170 * percent, 38 + padding * 2)
        case .brandGallery:
            left = 32 * percent
            top = 32 * percent
            minimumBottom = 160 * percent
        case .classicSignature:
            left = 30 * percent
            top = max(95 * percent, height(header) + padding * 2)
            minimumBottom = 150 * percent
        case .filmEdge:
            left = max(70 * percent, 42)
            top = 35 * percent
            minimumBottom = 85 * percent
        case .filmNegative:
            left = max(26 * percent, 18 + padding)
            top = 60 * percent
            minimumBottom = max(160 * percent, 170 * percent + infoHeight + padding * 2)
        case .filmGallery:
            left = max(85 * percent, 18 + padding)
            top = 90 + 160 * percent
            minimumBottom = 90 + 340 * percent
        default:
            left = max((baseSide - 1000) / 2 * percent, clearance + padding)
            top = max((baseSide - referenceHeight) * 0.45 * percent, clearance + padding)
            minimumBottom = (baseSide - referenceHeight) * 0.55 * percent
        }
        left += extraWidth / 2
        var bottom = max(minimumBottom, clearance + contentHeight + padding * 2)
        if square {
            let edge = max(1000 + left * 2, photoHeight + top + bottom)
            left += (edge - (1000 + left * 2)) / 2
            let verticalExtra = edge - (photoHeight + top + bottom)
            top += verticalExtra * 0.45
            bottom += verticalExtra * 0.55
        }
        let contentY = top + photoHeight + clearance + (bottom - clearance - contentHeight) / 2
        var positioned: [PositionedCaptionRow] = []
        func position(_ rows: [PhotoFrameTextRow], x: CGFloat, width: CGFloat, y: CGFloat, signature: Bool) {
            var rowTop = y
            for (index, row) in rows.enumerated() {
                let origin = archive || (signature && watermark.position == .left) ? x
                    : signature && watermark.position == .right ? x + width - row.layoutWidth
                    : x + (width - row.layoutWidth) / 2
                positioned.append(PositionedCaptionRow(row: row, x: origin - min(0, row.bounds.minX),
                    baseline: rowTop - row.bounds.minY, signature: signature))
                rowTop += row.bounds.height + gap
                if !signature && index == 0 { rowTop += identityGap }
            }
        }
        let signatureFirst = brandGallery && !signature.isEmpty
        let informationY = contentY + (signatureFirst ? height(signature) + signatureGap : 0)
        let signatureY = signatureFirst ? contentY : contentY + infoHeight + signatureGap
        position(info, x: left + (archive ? 0 : 50) - extraWidth / 2, width: informationWidth + extraWidth, y: informationY, signature: false)
        position(signature, x: left + 58 - extraWidth / 2, width: 884 + extraWidth,
                 y: signatureY, signature: true)
        position(header, x: (1000 + left * 2 - 900 - extraWidth) / 2, width: 900 + extraWidth,
                 y: (top - height(header)) / 2, signature: false)
        let scale = w / 1000
        let x = ceil(left * scale), y = ceil(top * scale)
        let width = w + x * 2, height = h + y + ceil(bottom * scale)
        let side = max(width, height)
        var result = Layout(canvas: square ? CGSize(width: side, height: side) : CGSize(width: width, height: height),
            photo: CGRect(x: x, y: y, width: w, height: h), metadataTop: y + h + (film ? 90 * scale : 0))
        result.filmStripPlan = strip?.scaled(by: scale)
        result.captionRows = positioned.map { $0.scaled(by: scale) }
        return result
    }

    private static func drawCaptionRows(_ cg: CGContext, layout: Layout, watermark: PhotoFrameWatermark) {
        for item in layout.captionRows {
            drawMetadataRow(item.row, in: cg, x: item.x, baseline: item.baseline, scale: 1,
                outline: item.signature && watermark.effect == .outline,
                watermarkShadow: item.signature && watermark.effect == .shadow)
        }
    }

    private static func frostedMetadataPanelBounds(_ layout: Layout) -> CGRect {
        let bandHeight = layout.canvas.height - layout.photo.maxY
        let verticalInset = bandHeight * 0.08
        return CGRect(x: layout.photo.minX, y: layout.photo.maxY + verticalInset,
                      width: layout.photo.width,
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

    private static func drawStandardMetadata(_ cg: CGContext, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) throws {
        let area = preset == .frosted ? frostedMetadataPanelBounds(layout) :
            CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width, height: layout.canvas.height - layout.photo.maxY)
        if preset == .frosted {
            drawFrostedMetadataPanel(cg, panel: area, canvas: layout.canvas,
                                     metadataBandHeight: layout.canvas.height - layout.metadataTop)
        }
        drawAndroidMetadata(cg, area: area, canvasWidth: layout.standardReferenceWidth ?? layout.canvas.width, preset: preset, metadata: metadata, watermark: watermark, settings: settings,
                            lightText: preset == .mist || preset == .cinema, preparedPlan: layout.standardPlan)
        var photoWatermark = watermark
        if !photoPlacement(photoWatermark.position) && photoWatermark.content == .image { photoWatermark.position = .photoBottomCenter }
        // Text watermarks on a frame side are already one of the metadata rows;
        // only photo-anchored text and image logos need a second draw pass.
        if photoPlacement(photoWatermark.position) || photoWatermark.content == .image {
            try drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: preset, metadataBand: area, referenceShortEdge: layout.photoWatermarkReference)
        }
    }

    private static func metadataText(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            // Preserve the selected font object. Private system-font names are
            // not public lookup names and can silently resolve to another face.
            .font: font,
            .foregroundColor: color,
        ])
    }

    private static func metadataRow(_ text: String, font: UIFont, color: UIColor) -> PhotoFrameTextRow {
        PhotoFrameTextRow(metadataText(text, font: font, color: color))
    }

    private static func metadataDescriptionRows(_ text: String, font: UIFont, color: UIColor, width: CGFloat,
                                                preserveUnbreakableWidth: Bool = false, verticalPaddingRatio: CGFloat = 0) -> [PhotoFrameTextRow] {
        PhotoFrameTextRow.wrappedDescriptions(metadataText(text, font: font, color: color), width: width)
            .map { value in
                let row = PhotoFrameTextRow([value], verticalPaddingRatio: verticalPaddingRatio)
                return preserveUnbreakableWidth ? row : row.fitting(width: width)
            }
    }

    /// Android FrameTextRun reserves max(1, textSize * 0.2) above/below band signatures.
    /// Measurement happens before canvas expansion; preview scales this allowance with the row.
    static func watermarkDescriptionRows(_ text: String, font: UIFont, color: UIColor, width: CGFloat) -> [PhotoFrameTextRow] {
        metadataDescriptionRows(text, font: font, color: color, width: width, preserveUnbreakableWidth: true)
            .map { $0.addingVerticalPadding(max(1, font.pointSize * 0.2)) }
    }

    static func frameIdentityRow(metadata: PhotoFrameMetadata, logoEnabled: Bool, font: UIFont,
                                 color: UIColor, trailingRuns: [NSAttributedString], gap: CGFloat, logoScale: CGFloat = 1.35, uppercaseBrand: Bool = false, includeRunInk: Bool = true, verticalPaddingRatio: CGFloat = 0) -> PhotoFrameTextRow {
        let brandText = uppercaseBrand ? metadata.normalizedMake.uppercased() : metadata.normalizedMake
        let lettering = metadataRow(brandText, font: font, color: color)
        guard logoEnabled,
              let brand = photoFrameBrandIdentity(make: metadata.make, model: metadata.model).brand,
              let asset = PhotoFrameBrandLogoCatalog.load(brand) else {
            return PhotoFrameTextRow([metadataText(brandText, font: font, color: color)] + trailingRuns, gap: gap, includeRunInk: includeRunInk, verticalPaddingRatio: verticalPaddingRatio)
        }
        let layers = asset.pathDatas.compactMap {
            PhotoFrameBrandLogoAsset(brand: brand, viewBox: asset.viewBox, pathData: $0).makePath()
        }
        guard !layers.isEmpty, asset.viewBox.width > 0, asset.viewBox.height > 0 else {
            return PhotoFrameTextRow([metadataText(brandText, font: font, color: color)] + trailingRuns, gap: gap, includeRunInk: includeRunInk, verticalPaddingRatio: verticalPaddingRatio)
        }
        var height = max(1, lettering.bounds.height) * logoScale * brand.logoHeightFactor
        var width = height * asset.viewBox.width / asset.viewBox.height
        if brand != .nikon, width > max(1, lettering.width) {
            height *= max(1, lettering.width) / width
            width = max(1, lettering.width)
        }
        let bounds = CGRect(x: 0, y: lettering.bounds.midY - height / 2, width: width, height: height)
        return PhotoFrameTextRow(leadingBounds: bounds, drawLeading: { cg in
            cg.saveGState()
            cg.translateBy(x: bounds.minX, y: bounds.minY)
            cg.scaleBy(x: bounds.width / asset.viewBox.width, y: bounds.height / asset.viewBox.height)
            cg.translateBy(x: -asset.viewBox.minX, y: -asset.viewBox.minY)
            cg.setFillColor(color.cgColor)
            for (index, path) in layers.enumerated() {
                drawBrandLogoLayer(cg, path: path, bounds: asset.viewBox, gradient: brand == .nikon, layerIndex: index)
            }
            cg.restoreGState()
        }, runs: trailingRuns, gap: gap, includeRunInk: includeRunInk, verticalPaddingRatio: verticalPaddingRatio,
            leadingVerticalPadding: font.pointSize * verticalPaddingRatio)
    }

    static func cameraIdentityRow(_ metadata: PhotoFrameMetadata, logoEnabled: Bool,
                                  font: UIFont, color: UIColor, logoScale: CGFloat, uppercaseBrand: Bool = false,
                                  separator: String = " ") -> PhotoFrameTextRow {
        guard logoEnabled, photoFrameBrandIdentity(make: metadata.make, model: metadata.model).brand != nil else {
            let brand = uppercaseBrand ? metadata.normalizedMake.uppercased() : metadata.normalizedMake
            return metadataRow([brand, metadata.normalizedModel].filter { !$0.isEmpty }.joined(separator: separator), font: font, color: color)
        }
        return frameIdentityRow(metadata: metadata, logoEnabled: true, font: font, color: color,
            trailingRuns: [metadataText(metadata.normalizedModel.isEmpty ? "" : separator + metadata.normalizedModel, font: font, color: color)],
            gap: 0, logoScale: logoScale, includeRunInk: false)
    }

    static func frameIdentityRows(metadata: PhotoFrameMetadata, logoEnabled: Bool, brandFont: UIFont,
                                  modelFont: UIFont, color: UIColor, gap: CGFloat, width: CGFloat, logoScale: CGFloat = 1.35, uppercaseBrand: Bool = false,
                                  preserveUnbreakableWidth: Bool = false, verticalPaddingRatio: CGFloat = 0) -> [PhotoFrameTextRow] {
        guard !metadata.identity.isEmpty else { return [] }
        let model = metadataText(metadata.normalizedModel, font: modelFont, color: color)
        let combined = frameIdentityRow(metadata: metadata, logoEnabled: logoEnabled, font: brandFont,
            color: color, trailingRuns: [model], gap: gap, logoScale: logoScale, uppercaseBrand: uppercaseBrand, verticalPaddingRatio: verticalPaddingRatio)
        if (preserveUnbreakableWidth ? combined.layoutWidth : combined.width) <= width { return [combined] }
        var rows: [PhotoFrameTextRow] = []
        if !metadata.normalizedMake.isEmpty {
            if logoEnabled, photoFrameBrandIdentity(make: metadata.make, model: metadata.model).brand != nil {
                rows.append(frameIdentityRow(metadata: metadata, logoEnabled: true, font: brandFont,
                    color: color, trailingRuns: [], gap: 0, logoScale: logoScale, uppercaseBrand: uppercaseBrand, verticalPaddingRatio: verticalPaddingRatio))
            } else {
                rows += metadataDescriptionRows(uppercaseBrand ? metadata.normalizedMake.uppercased() : metadata.normalizedMake, font: brandFont, color: color, width: width, preserveUnbreakableWidth: preserveUnbreakableWidth).map { $0.addingVerticalPadding(brandFont.pointSize * verticalPaddingRatio) }
            }
        }
        rows += PhotoFrameTextRow.wrappedDescriptions(model, width: width).map {
            let row = PhotoFrameTextRow([$0], verticalPaddingRatio: verticalPaddingRatio)
            return preserveUnbreakableWidth ? row : row.fitting(width: width)
        }
        return rows
    }

    private static func drawMetadataRow(_ row: PhotoFrameTextRow, in cg: CGContext, x: CGFloat,
                                        baseline: CGFloat, scale: CGFloat, shadowOpacity: CGFloat = 0,
                                        outline: Bool = false, watermarkShadow: Bool = false) {
        cg.saveGState()
        if shadowOpacity > 0 {
            cg.setShadow(offset: CGSize(width: 0, height: scale), blur: 3 * scale,
                         color: UIColor.black.withAlphaComponent(shadowOpacity).cgColor)
        }
        row.draw(in: cg, x: x, baseline: baseline, scale: scale, outline: outline, shadow: watermarkShadow)
        cg.restoreGState()
    }

    struct MetadataRowsPlan {
        let rows: [PhotoFrameTextRow]
        let watermarkIndex: Int?
        var inkHeight: CGFloat { rows.reduce(0) { $0 + $1.bounds.height } }
        func scaled(by scale: CGFloat) -> Self {
            Self(rows: rows.map { $0.scaled(by: scale) }, watermarkIndex: watermarkIndex)
        }
    }

    static func standardMetadataPlan(area: CGRect, canvasWidth: CGFloat,
                                             preset: PhotoFramePreset, metadata: PhotoFrameMetadata,
                                             watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings,
                                             lightText: Bool) -> MetadataRowsPlan {
        let color = lightText
            ? UIColor(red: 248.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0, alpha: 1)
            : UIColor(red: 25.0 / 255.0, green: 31.0 / 255.0, blue: 38.0 / 255.0, alpha: 1)
        let muted = lightText
            ? UIColor(red: 220.0 / 255.0, green: 227.0 / 255.0, blue: 233.0 / 255.0, alpha: 1)
            : UIColor(red: 70.0 / 255.0, green: 79.0 / 255.0, blue: 88.0 / 255.0, alpha: 1)
        let lens = (metadata.lensModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "   ")
        var rows: [PhotoFrameTextRow] = []
        let columnWidth = max(1, preset == .frosted ? area.width * 0.88 : area.width - canvasWidth * 0.16)
        func descriptions(_ text: String, font: UIFont, color: UIColor, width: CGFloat) -> [PhotoFrameTextRow] {
            metadataDescriptionRows(text, font: font, color: color, width: width,
                                    preserveUnbreakableWidth: true).map { $0.addingVerticalPadding(font.pointSize * 0.035) }
        }
        let brandFont = UIFont(name: "HelveticaNeue-BoldItalic", size: canvasWidth * 0.032)
            ?? UIFont.italicSystemFont(ofSize: canvasWidth * 0.032)
        rows += frameIdentityRows(metadata: metadata, logoEnabled: settings.showBrand && settings.brandStyle == .logo,
            brandFont: brandFont, modelFont: .systemFont(ofSize: canvasWidth * 0.024), color: color,
            gap: canvasWidth * 0.016, width: columnWidth,
            preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035)
        let detailWidth = columnWidth
        if !lens.isEmpty {
            rows += descriptions(lens, font: .systemFont(ofSize: canvasWidth * 0.0185, weight: .medium), color: muted, width: detailWidth)
        }
        let details = ([detail].filter { !$0.isEmpty } + metadata.locationRows)
        rows += details.flatMap { descriptions($0, font: .systemFont(ofSize: canvasWidth * 0.020), color: muted, width: detailWidth) }
        let watermarkIndex = watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position)
            ? rows.count : nil
        if watermarkIndex != nil {
            rows += watermarkDescriptionRows(watermark.displayText,
                                    font: watermarkFont(watermark.font, size: canvasWidth * textSizeFraction(watermark.sizePercent)),
                                    color: watermarkColor(watermark.color, preset).withAlphaComponent(CGFloat(watermark.opacityPercent) / 100),
                                    width: columnWidth)
        }
        return MetadataRowsPlan(rows: rows, watermarkIndex: watermarkIndex)
    }

    private static func drawAndroidMetadata(_ cg: CGContext, area: CGRect, canvasWidth: CGFloat,
                                             preset: PhotoFramePreset, metadata: PhotoFrameMetadata,
                                             watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings,
                                             lightText: Bool, preparedPlan: MetadataRowsPlan?) {
        let plan = preparedPlan ?? standardMetadataPlan(area: area, canvasWidth: canvasWidth, preset: preset,
            metadata: metadata, watermark: watermark, settings: settings, lightText: lightText)
        let rows = plan.rows
        let watermarkIndex = plan.watermarkIndex
        let placement = PhotoFrameTextLayout(area: area, bounds: rows.map(\.bounds),
                                             preferredGap: min(canvasWidth * 0.0125, area.height * 0.09),
                                             verticalInset: area.height * PhotoFrameTextLayout.standardPaddingRatio)
        for (index, row) in rows.enumerated() {
            let width = row.layoutWidth * placement.scale
            let isWatermark = watermarkIndex.map { index >= $0 } ?? false
            let horizontalInset = preset == .frosted ? area.width * 0.06 : canvasWidth * 0.08
            let x = isWatermark && watermark.position == .left ? area.minX + horizontalInset
                : isWatermark && watermark.position == .right ? area.maxX - horizontalInset - width
                : area.midX - width * 0.5
            drawMetadataRow(row, in: cg, x: x - min(0, row.bounds.minX) * placement.scale, baseline: placement.baselines[index], scale: placement.scale,
                            outline: isWatermark && watermark.effect == .outline,
                            watermarkShadow: isWatermark && watermark.effect == .shadow)
        }
    }

    private static func drawPlaque(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) throws {
        let band = CGRect(x: 0, y: layout.metadataTop, width: layout.canvas.width, height: layout.canvas.height - layout.metadataTop)
        cg.setFillColor(UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1).cgColor); cg.fill(band)
        cg.setFillColor(UIColor(red: 0.90, green: 0.91, blue: 0.90, alpha: 1).cgColor); cg.fill(CGRect(x: 0, y: band.minY, width: band.width, height: max(1, band.width * 0.0008)))
        // Plaque deliberately keeps the camera maker exactly as supplied by
        // EXIF (Android uppercases it without the standard brand alias map).
        let plan = layout.plaquePlan ?? makePlaquePlan(width: band.width, metadata: metadata, watermark: watermark, settings: settings)
        drawPlaquePlan(plan, in: cg, band: band, watermark: watermark)
        if photoPlacement(watermark.position) || watermark.content == .image {
            var photoWatermark = watermark
            if !photoPlacement(photoWatermark.position) { photoWatermark.position = .photoBottomCenter }
            try drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas, preset: .plaque, metadataBand: band, referenceShortEdge: layout.photoWatermarkReference)
        }
    }

    static func plaqueIdentityLabels(_ metadata: PhotoFrameMetadata) -> (primary: String?, secondary: String?) {
        func cleaned(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let brand = cleaned(metadata.make)?.uppercased()
        let model = cleaned(metadata.model)
        let lens = cleaned(metadata.lensModel)
        let primary = brand ?? model ?? lens
        let secondaryModel = model.flatMap { value in
            guard let brand else { return nil as String? }
            return value.caseInsensitiveCompare(brand) != .orderedSame ? value : nil
        }
        let secondaryLens = lens.flatMap { $0 != primary ? $0 : nil }
        let secondary = [secondaryModel, secondaryLens].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        return (primary, secondary)
    }

    struct PlaquePlan {
        var left: [PhotoFrameTextRow]
        var right: [PhotoFrameTextRow]
        var signature: [PhotoFrameTextRow]
        var leftWatermarkStart: Int?
        var leftWidth: CGFloat
        var rightX: CGFloat
        var rightWidth: CGFloat
        var leftX: CGFloat
        var signatureWidth: CGFloat
        var extraWidth: CGFloat
        var gap: CGFloat
        func height(_ rows: [PhotoFrameTextRow]) -> CGFloat {
            rows.reduce(0) { $0 + $1.bounds.height } + gap * CGFloat(max(0, rows.count - 1))
        }
        var infoHeight: CGFloat { max(height(left), height(right)) }
        var signatureGap: CGFloat { !signature.isEmpty && infoHeight > 0 ? gap * 1.5 : 0 }
        var contentHeight: CGFloat { infoHeight + signatureGap + height(signature) }
        func scaled(by scale: CGFloat) -> Self {
            Self(left: left.map { $0.scaled(by: scale) }, right: right.map { $0.scaled(by: scale) },
                 signature: signature.map { $0.scaled(by: scale) }, leftWatermarkStart: leftWatermarkStart,
                 leftWidth: leftWidth * scale, rightX: rightX * scale, rightWidth: rightWidth * scale,
                 leftX: leftX * scale, signatureWidth: signatureWidth * scale,
                 extraWidth: extraWidth * scale, gap: gap * scale)
        }
    }

    static func makePlaquePlan(width: CGFloat, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) -> PlaquePlan {
        func descriptions(_ text: String, font: UIFont, color: UIColor, width: CGFloat) -> [PhotoFrameTextRow] {
            metadataDescriptionRows(text, font: font, color: color, width: width, preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035)
        }
        let labels = plaqueIdentityLabels(metadata)
        let hasWatermark = watermark.enabled && watermark.content == .text && !photoPlacement(watermark.position)
        let leftSignature = hasWatermark && (watermark.position == .auto || watermark.position == .left)
        let hasIdentity = labels.primary != nil || leftSignature
        let rightWidth = width * (hasIdentity ? 0.35 : 0.884)
        let rightFont = UIFont.systemFont(ofSize: width * 0.020)
        let pieces = [metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }
        let combined = pieces.joined(separator: "   ")
        let rightValues = (metadataRow(combined, font: rightFont, color: .black).width <= rightWidth ? [combined] : pieces) + metadata.locationRows
        let right = rightValues.flatMap { descriptions($0, font: rightFont, color: .black, width: rightWidth) }
        let leftWidth = width * (right.isEmpty ? 0.884 : 0.46)
        var left: [PhotoFrameTextRow] = []
        if let primary = labels.primary {
            let font = UIFont.systemFont(ofSize: width * 0.027, weight: .medium)
            if settings.showBrand && settings.brandStyle == .logo,
               photoFrameBrandIdentity(make: metadata.make, model: metadata.model).brand != nil {
                left.append(frameIdentityRow(metadata: metadata, logoEnabled: true, font: font, color: .black, trailingRuns: [], gap: 0, verticalPaddingRatio: 0.035))
            } else {
                left += descriptions(primary, font: font, color: .black, width: leftWidth)
            }
        }
        left += descriptions(labels.secondary ?? "", font: .systemFont(ofSize: width * 0.0165), color: UIColor(white: 0.4, alpha: 1), width: leftWidth)
        let signature = hasWatermark ? watermarkDescriptionRows(watermark.displayText,
            font: watermarkFont(watermark.font, size: width * textSizeFraction(watermark.sizePercent)),
            color: watermarkColor(watermark.color, .plaque).withAlphaComponent(CGFloat(watermark.opacityPercent) / 100),
            width: leftSignature ? leftWidth : width * 0.884) : []
        let watermarkStart = leftSignature ? left.count : nil
        if leftSignature { left += signature }
        let footer = leftSignature ? [] : signature
        let leftExtra = max(0, (left.map(\.layoutWidth).max() ?? 0) - leftWidth)
        let rightExtra = max(0, (right.map(\.layoutWidth).max() ?? 0) - rightWidth)
        let paired = !left.isEmpty && !right.isEmpty
        let extra = max(paired ? leftExtra + rightExtra : max(leftExtra, rightExtra),
                        (footer.map(\.layoutWidth).max() ?? 0) - width * 0.884)
        // Android measured-template expansion preserves the gap between columns
        // and never enlarges the reference fonts with the resulting canvas.
        return PlaquePlan(left: left, right: right, signature: footer,
            leftWatermarkStart: watermarkStart, leftWidth: leftWidth + (paired ? leftExtra : extra),
            rightX: width * (hasIdentity ? 0.60 : 0.058) + (paired ? leftExtra : 0),
            rightWidth: rightWidth + (paired ? rightExtra : extra), leftX: width * 0.058,
            signatureWidth: width * 0.884 + extra, extraWidth: extra, gap: width * 0.010)
    }

    private static func drawPlaquePlan(_ plan: PlaquePlan, in cg: CGContext, band: CGRect, watermark: PhotoFrameWatermark) {
        let top = band.minY + (band.height - plan.contentHeight) / 2
        func draw(_ rows: [PhotoFrameTextRow], x: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat, watermarkStart: Int?) {
            let area = CGRect(x: x, y: y, width: width, height: height)
            let placement = PhotoFrameTextLayout(area: area, bounds: rows.map(\.bounds), preferredGap: plan.gap)
            for (index, row) in rows.enumerated() {
                let signature = watermarkStart.map { index >= $0 } ?? false
                let rowX = signature && watermark.position == .right ? area.maxX - row.layoutWidth
                    : signature && watermark.position == .center ? area.midX - row.layoutWidth / 2 : x
                drawMetadataRow(row, in: cg, x: rowX - min(0, row.bounds.minX) * placement.scale, baseline: placement.baselines[index], scale: placement.scale,
                    outline: signature && watermark.effect == .outline,
                    watermarkShadow: signature && watermark.effect == .shadow)
            }
        }
        draw(plan.left, x: band.minX + plan.leftX, width: plan.leftWidth, y: top, height: plan.infoHeight, watermarkStart: plan.leftWatermarkStart)
        draw(plan.right, x: band.minX + plan.rightX, width: plan.rightWidth, y: top, height: plan.infoHeight, watermarkStart: nil)
        draw(plan.signature, x: band.minX + plan.leftX, width: plan.signatureWidth,
             y: top + plan.infoHeight + plan.signatureGap, height: plan.height(plan.signature), watermarkStart: 0)
    }

    private static func drawBrand(_ cg: CGContext, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) throws {
        let photo = layout.photo
        let photoWatermark = brandPhotoWatermark(watermark, preset: preset)
        for item in layout.brandPhotoRows {
            drawMetadataRow(item.row, in: cg, x: item.x, baseline: item.baseline,
                            scale: 1, shadowOpacity: 0.70)
        }
        try drawWatermark(cg, watermark: photoWatermark, photo: photo, canvas: layout.canvas, preset: preset,
                      metadataBand: CGRect(x: 0, y: photo.maxY, width: layout.canvas.width, height: layout.canvas.height - photo.maxY),
                      referenceShortEdge: layout.photoWatermarkReference)
        if preset == .brandGallery {
            drawCaptionRows(cg, layout: layout, watermark: watermark)
        }
    }

    private static func brandPhotoWatermark(_ watermark: PhotoFrameWatermark, preset: PhotoFramePreset) -> PhotoFrameWatermark {
        var result = watermark
        if !photoPlacement(result.position) {
            result.position = preset == .brandGallery ? .photoBottomRight : brandPhotoPosition(result.position)
        }
        if preset == .brandGallery && watermark.content == .text && !photoPlacement(watermark.position) && watermark.position != .auto {
            result.enabled = false
        }
        return result
    }

    /// Android measureBrandPhotoText measures once at photo width 1000.
    /// Keep wrapping, placement and collision decisions independent of preview size.
    private static func measuredBrandPhotoRows(layout: Layout, preset: PhotoFramePreset,
        metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark,
        settings: PhotoFrameMetadataSettings) throws -> [PositionedCaptionRow] {
        let scale = layout.photo.width / 1000
        let photo = CGRect(x: 0, y: 0, width: 1000, height: layout.photo.height / scale)
        let occupied = try photoWatermarkOccupiedBounds(photo: photo,
            watermark: brandPhotoWatermark(watermark, preset: preset),
            referenceShortEdge: layout.photoWatermarkReference.map { $0 / scale }).map { BrandBounds(rect: $0) }
        let details = ([[metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "   ")].filter { !$0.isEmpty } + metadata.locationRows)
        let rows = preset == .brandInset
            ? try brandInsetMetadataRows(photo: photo, metadata: metadata, settings: settings,
                lens: metadata.lensModel ?? "", details: details, occupied: occupied)
            : try brandGalleryDetailRows(photo: photo, lens: metadata.lensModel ?? "", details: details, occupied: occupied)
        return rows.map {
            let item = $0.scaled(by: scale)
            return PositionedCaptionRow(row: item.row, x: layout.photo.minX + item.x,
                baseline: layout.photo.minY + item.baseline, signature: false)
        }
    }

    private static func brandDetailFont(size: CGFloat) -> UIFont {
        UIFont(name: "HelveticaNeue-CondensedBoldOblique", size: size) ?? UIFont.italicSystemFont(ofSize: size)
    }

    private static func brandInsetMetadataRows(photo: CGRect, metadata: PhotoFrameMetadata,
                                               settings: PhotoFrameMetadataSettings,
                                               lens: String, details: [String], occupied: BrandBounds?) throws -> [PositionedCaptionRow] {
        let shortEdge = min(photo.width, photo.height)
        var rows: [(String, UIFont)] = []
        if !lens.isEmpty { rows.append((lens, brandDetailFont(size: min(photo.width * 0.019, shortEdge * 0.042)))) }
        rows.append(contentsOf: details.filter { !$0.isEmpty }.map { ($0, brandDetailFont(size: min(photo.width * 0.021, shortEdge * 0.047))) })
        let font = UIFont.systemFont(ofSize: min(photo.width * 0.043, shortEdge * 0.095), weight: .black)
        let identity = frameIdentityRows(metadata: metadata,
            logoEnabled: settings.showBrand && settings.brandStyle == .logo,
            brandFont: font, modelFont: font, color: .white, gap: font.pointSize * 0.3,
            width: photo.width * 0.78, logoScale: 1.45, preserveUnbreakableWidth: true)
        return try brandRows(photo: photo, rows: rows, occupied: occupied,
            preferredBottomRatio: 0.030, gapRatio: 0.020, identity: identity)
    }

    private static func brandGalleryDetailRows(photo: CGRect, lens: String, details: [String], occupied: BrandBounds?) throws -> [PositionedCaptionRow] {
        let shortEdge = min(photo.width, photo.height)
        var rows: [(String, UIFont)] = []
        if !lens.isEmpty { rows.append((lens, brandDetailFont(size: min(photo.width * 0.019, shortEdge * 0.042)))) }
        rows.append(contentsOf: details.filter { !$0.isEmpty }.map { ($0, brandDetailFont(size: min(photo.width * 0.021, shortEdge * 0.047))) })
        return try brandRows(photo: photo, rows: rows, occupied: occupied, preferredBottomRatio: 0.035, gapRatio: 0.016)
    }

    private static func brandRows(photo: CGRect, rows: [(String, UIFont)], occupied: BrandBounds?, preferredBottomRatio: CGFloat, gapRatio: CGFloat, identity: [PhotoFrameTextRow] = []) throws -> [PositionedCaptionRow] {
        guard !rows.isEmpty || !identity.isEmpty else { return [] }
        let gap = min(photo.width, photo.height) * gapRatio
        let textRows = identity + rows.enumerated().flatMap { index, row in
            PhotoFrameTextRow.wrappedDescriptions(metadataText(row.0, font: row.1,
                color: index == 0 ? .white : UIColor.white.withAlphaComponent(0.90)), width: photo.width * 0.78)
                .map { PhotoFrameTextRow($0) }
        }
        let blockHeight = textRows.reduce(CGFloat.zero) { $0 + $1.bounds.height } + gap * CGFloat(max(0, textRows.count - 1))
        let blockWidth = textRows.map(\.layoutWidth).max() ?? photo.width
        guard blockHeight <= photo.height else { throw PhotoFrameBrandLayoutError.insufficientHeight }
        guard blockWidth <= photo.width else { throw PhotoFrameColumnOverflow() }
        let area = placeBrandMetadataBlock(photo: photo, preferredBottom: photo.maxY - min(photo.width, photo.height) * preferredBottomRatio,
                                          blockHeight: blockHeight, blockWidth: blockWidth, occupied: occupied,
                                          gap: min(photo.width, photo.height) * 0.040)
        guard let target = area else { return [] }
        if let occupied, target.intersects(occupied.rect) { throw PhotoFrameBrandLayoutError.watermarkOverlap }
        let placement = PhotoFrameTextLayout(area: target, bounds: textRows.map(\.bounds), preferredGap: gap)
        return textRows.enumerated().map { index, row in
            PositionedCaptionRow(row: row.scaled(by: placement.scale),
                x: target.midX - row.layoutWidth * placement.scale * 0.5 - min(0, row.bounds.minX) * placement.scale,
                baseline: placement.baselines[index], signature: false)
        }
    }

    private static func drawBrandLogoLayer(_ cg: CGContext, path: CGPath, bounds: CGRect, gradient: Bool, layerIndex: Int) {
        guard gradient else { cg.addPath(path); cg.fillPath(); return }
        cg.saveGState(); cg.addPath(path); cg.clip()
        let colors = [UIColor(red: 1, green: 0.894, blue: 0.098, alpha: 1).cgColor,
                      UIColor.white.cgColor, UIColor.white.cgColor,
                      UIColor(red: 1, green: 0.894, blue: 0.098, alpha: 1).cgColor] as CFArray
        guard let shader = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                      locations: [0, 0.34, 0.66, 1]) else { cg.restoreGState(); return }
        let spec = NikonBrandGradients.specs[min(layerIndex, NikonBrandGradients.specs.count - 1)]
        cg.drawLinearGradient(shader, start: spec.start, end: spec.end, options: [])
        cg.restoreGState()
    }

    static func photoWatermarkOccupiedBounds(photo: CGRect, watermark: PhotoFrameWatermark, referenceShortEdge: CGFloat? = nil) throws -> CGRect? {
        guard watermark.enabled, photoPlacement(watermark.position) else { return nil }
        if watermark.content == .image {
            let image = try loadWatermarkImage(watermark)
            return photoWatermarkImageRect(watermark, photo: photo, imageSize: image.size)
        }
        let layout = photoWatermarkTextLayout(watermark, photo: photo, referenceShortEdge: referenceShortEdge)
        let padding: CGFloat = switch resolvedWatermarkEffect(watermark) {
        case .none: 0
        case .shadow: layout.font.pointSize * 0.18
        case .outline: max(1, layout.font.pointSize * 0.075)
        case .auto: 0 // resolvedWatermarkEffect resolves AUTO before this switch.
        }
        return layout.inkBounds.insetBy(dx: -padding, dy: -padding)
    }

    private static func loadWatermarkImage(_ watermark: PhotoFrameWatermark) throws -> UIImage {
        guard let hash = watermark.imageHash, hash.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let image = PhotoEffectsStore.watermarkImage(hash: hash) else {
            throw PhotoEffectsRenderError.invalidWatermarkImage
        }
        return image
    }

    static func photoWatermarkImageRect(_ watermark: PhotoFrameWatermark, photo: CGRect, imageSize: CGSize) -> CGRect {
        let inset = min(photo.width, photo.height) * 0.04
        var height = min(photo.width, photo.height) * imageSizeFraction(watermark.sizePercent)
        var width = height * imageSize.width / max(imageSize.height, 1)
        let maxWidth = max(1, photo.width - inset * 2)
        if width > maxWidth { let scale = maxWidth / width; width *= scale; height *= scale }
        return watermarkRect(position: watermark.position, photo: photo, size: CGSize(width: width, height: height), inset: inset)
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

    static func immersiveDetailRows(_ values: [String], shortEdge: CGFloat, maxWidth: CGFloat) -> [PhotoFrameTextRow] {
        let rows = values.map {
            metadataRow($0, font: .systemFont(ofSize: shortEdge * 0.0235), color: .white.withAlphaComponent(0.92))
        }
        // Android uses one Paint for every detail line, sized by the widest line.
        let widest = rows.map(\.width).max() ?? 0
        let scale = widest > maxWidth ? maxWidth / widest : 1
        return rows.map { $0.scaled(by: scale) }
    }

    static func immersiveTitleRow(metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark,
                                  settings: PhotoFrameMetadataSettings, photoSize: CGSize) -> PhotoFrameTextRow? {
        let shortEdge = min(photoSize.width, photoSize.height)
        let camera = metadata.identity.isEmpty ? nil : cameraIdentityRow(metadata,
            logoEnabled: settings.showBrand && settings.brandStyle == .logo,
            font: .systemFont(ofSize: shortEdge * 0.030, weight: .medium), color: .white, logoScale: 1.30)
        var runs: [NSAttributedString] = []
        if watermark.enabled && watermark.content == .text && watermark.position == .auto {
            if camera != nil {
                runs.append(metadataText("|", font: .systemFont(ofSize: shortEdge * 0.025, weight: .light),
                                         color: .white.withAlphaComponent(0.80)))
            }
            var font = watermarkFont(watermark.font, size: shortEdge * textSizeFraction(watermark.sizePercent))
            for _ in 0..<8 {
                let width = metadataRow(watermark.displayText, font: font, color: .white).width
                guard width > photoSize.width * 0.38 else { break }
                font = font.withSize(font.pointSize * photoSize.width * 0.38 / width * 0.999)
            }
            font = font.withSize(font.pointSize * 1.35)
            runs.append(PhotoWatermarkInk.applying(resolvedWatermarkEffect(watermark),
                to: metadataText(watermark.displayText, font: font,
                    color: watermarkColor(watermark.color, .immersive).withAlphaComponent(CGFloat(watermark.opacityPercent) / 100))))
        }
        guard camera != nil || !runs.isEmpty else { return nil }
        let row = camera.map { PhotoFrameTextRow(leadingRow: $0, runs: runs, gap: shortEdge * 0.014) }
            ?? PhotoFrameTextRow(runs)
        let maxWidth = photoSize.width * 0.86
        return row.width > maxWidth ? row.scaled(by: maxWidth / row.width) : row
    }

    private static func drawImmersive(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) throws {
        let photo = layout.photo
        let shortEdge = min(photo.width, photo.height)
        let maxWidth = photo.width * 0.86
        let separate = watermark.enabled && watermark.content == .text && watermark.position != .auto && !photoPlacement(watermark.position) ? watermark : nil
        var rows = [immersiveTitleRow(metadata: metadata, watermark: watermark, settings: settings, photoSize: photo.size)].compactMap { $0 }
        if let lens = metadata.lensModel, !lens.isEmpty {
            rows.append(metadataRow(lens, font: .systemFont(ofSize: shortEdge * 0.0205, weight: .medium), color: .white.withAlphaComponent(0.92)).fitting(width: maxWidth))
        }
        let detail = [metadata.immersiveDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "  ")
        rows += immersiveDetailRows([detail].filter { !$0.isEmpty } + metadata.locationRows,
                                     shortEdge: shortEdge, maxWidth: maxWidth)
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
        let area = CGRect(x: photo.minX + photo.width * 0.07, y: bottom - blockHeight,
                          width: maxWidth, height: blockHeight)
        if photoPlacement(watermark.position) {
            try drawWatermark(cg, watermark: watermark, photo: photo, canvas: layout.canvas, preset: .immersive, metadataBand: area)
        }
        let placement = PhotoFrameTextLayout(area: area, bounds: rows.map(\.bounds), preferredGap: gap)
        for (index, row) in rows.enumerated() {
            let width = row.width * placement.scale
            let isSeparate = separate != nil && index == rows.count - 1
            let x = isSeparate && separate?.position == .left ? area.minX
                : isSeparate && separate?.position == .right ? area.maxX - width : area.midX - width * 0.5
            drawMetadataRow(row, in: cg, x: x, baseline: placement.baselines[index], scale: placement.scale,
                            shadowOpacity: isSeparate ? 0 : 0.55,
                            outline: isSeparate && separate?.effect == .outline,
                            watermarkShadow: isSeparate && separate?.effect == .shadow)
        }
    }

    private static func drawEditorial(_ cg: CGContext, image: UIImage, layout: Layout, preset: PhotoFramePreset, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) throws {
        // Android composites the editorial photo watermark before each frame's
        // typography and decoration, so labels remain legible above it.
        let photoWatermark = editorialPhotoWatermark(watermark, preset: preset)
        try drawWatermark(cg, watermark: photoWatermark, photo: layout.photo, canvas: layout.canvas,
                      preset: preset,
                      metadataBand: CGRect(x: 0, y: layout.photo.maxY, width: layout.canvas.width,
                                           height: layout.canvas.height - layout.photo.maxY), referenceShortEdge: layout.photoWatermarkReference)
        switch preset {
        case .galleryMat:
            drawCaptionRows(cg, layout: layout, watermark: watermark)
        case .colorArchive:
            drawPalette(cg, image: image, layout: layout)
            drawCaptionRows(cg, layout: layout, watermark: watermark)
        case .filmGallery:
            drawFilmStrip(cg, layout: layout, metadata: metadata, settings: settings)
            drawCaptionRows(cg, layout: layout, watermark: watermark)
        case .filmEdge:
            drawSideLabel(cg, text: "PORTRA 400", x: layout.photo.minX * 0.48, y: layout.photo.midY, angle: -.pi / 2, color: UIColor(red: 0.87, green: 0.65, blue: 0.47, alpha: 1), size: layout.photo.width * 0.028)
            drawSideLabel(cg, text: String(format: "▶  %03d", stableFilmFrameNumber(metadata)), x: layout.photo.maxX + (layout.canvas.width - layout.photo.maxX) * 0.52, y: layout.photo.minY + layout.photo.height * 0.22, angle: .pi / 2, color: UIColor(red: 0.87, green: 0.65, blue: 0.47, alpha: 1), size: layout.photo.width * 0.028)
            drawCaptionRows(cg, layout: layout, watermark: watermark)
        case .filmNegative:
            drawFilmNegative(cg, layout: layout, metadata: metadata, watermark: watermark, settings: settings)
        case .parameterPoster:
            drawParameterPoster(cg, layout: layout, metadata: metadata, settings: settings)
        case .classicSignature:
            drawCaptionRows(cg, layout: layout, watermark: watermark)
        default: break
        }
    }

    /// FILM_NEGATIVE is the Android contact-sheet treatment: a warm near-black
    /// canvas, fine rules around the photo, a camera identity and a stable
    /// frame number with a row of sprocket marks. Keep this branch independent
    /// from FILM_EDGE's side labels so metadata changes cannot alter geometry.
    private static func drawFilmNegative(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark, settings: PhotoFrameMetadataSettings) {
        let photo = layout.photo
        let unit = photo.width
        let ink = UIColor(red: 238 / 255, green: 173 / 255, blue: 117 / 255, alpha: 1)
        let rule = UIColor(red: 238 / 255, green: 173 / 255, blue: 117 / 255, alpha: 130 / 255)
        cg.setStrokeColor(rule.cgColor); cg.setLineWidth(max(1, unit * 0.0012))
        let top = photo.minY - unit * 0.006
        cg.move(to: CGPoint(x: photo.minX, y: top)); cg.addLine(to: CGPoint(x: photo.maxX, y: top))
        let bottom = photo.maxY + unit * 0.018
        cg.move(to: CGPoint(x: photo.minX, y: bottom)); cg.addLine(to: CGPoint(x: photo.maxX, y: bottom)); cg.strokePath()
        let identity = metadata.identity
        let labelFont = UIFont.monospacedSystemFont(ofSize: unit * 0.021, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: ink]
        if !identity.isEmpty {
            let row = cameraIdentityRow(metadata, logoEnabled: settings.showBrand && settings.brandStyle == .logo,
                font: labelFont, color: ink, logoScale: 1.20, separator: " · ").fitting(width: unit * 0.46)
            row.draw(in: cg, x: photo.minX + unit * 0.028, baseline: photo.minY * 0.58)
        }
        let number = stableFilmFrameNumber(metadata)
        let frame = String(format: "FRAME %03d", number)
        let frameWidth = (frame as NSString).size(withAttributes: attrs).width
        frame.draw(at: CGPoint(x: photo.maxX - unit * 0.028 - frameWidth, y: photo.minY * 0.58 - labelFont.ascender), withAttributes: attrs)
        let markWidth = unit * 0.018, markHeight = unit * 0.028, gap = unit * 0.014
        let count = max(6, Int((layout.canvas.width - gap) / (markWidth + gap)))
        let occupied = CGFloat(count) * markWidth + CGFloat(count - 1) * gap
        let start = (layout.canvas.width - occupied) / 2
        let markTop = photo.maxY + unit * 0.035
        cg.setFillColor(ink.cgColor)
        for index in 0..<count {
            let x = start + CGFloat(index) * (markWidth + gap)
            cg.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: markTop, width: markWidth, height: markHeight), cornerRadius: markWidth * 0.28).cgPath)
        }
        cg.fillPath()
        drawCaptionRows(cg, layout: layout, watermark: watermark)
    }

    static func stableFilmFrameNumber(_ metadata: PhotoFrameMetadata) -> Int {
        let value = [metadata.dateTime, metadata.make, metadata.model, metadata.lensModel,
                     metadata.focalLength, metadata.iso, metadata.shutter].compactMap { $0 }.joined(separator: "\u{0}")
        // Android String.hashCode uses UTF-16 units and signed Int overflow.
        var hash: UInt32 = 0
        for unit in value.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return Int((hash & 0x7fff_ffff) % 999) + 1
    }

    /// ParameterPosterFrame.kt: identity, exposure and location groups are
    /// measured before allocating the canvas; preview scales this same plan.
    private struct PosterSpec {
        let text: String
        let font: UIFont
        let alpha: CGFloat
        let logo: Bool
        let label: String?
        var gap: CGFloat
    }

    private struct PosterMeasuredRow {
        let value: PhotoFrameTextRow
        let label: PhotoFrameTextRow?
        let labelBox: CGRect?
        let labelStroke: CGFloat
        let labelRadius: CGFloat
        let labelX: CGFloat
        let labelBaseline: CGFloat
        let valueX: CGFloat
        let valueBaseline: CGFloat
        let height: CGFloat
        let gap: CGFloat
        func scaled(by scale: CGFloat) -> Self {
            Self(value: value.scaled(by: scale), label: label?.scaled(by: scale),
                 labelBox: labelBox?.applying(CGAffineTransform(scaleX: scale, y: scale)),
                 labelStroke: labelStroke * scale, labelRadius: labelRadius * scale,
                 labelX: labelX * scale, labelBaseline: labelBaseline * scale,
                 valueX: valueX * scale, valueBaseline: valueBaseline * scale,
                 height: height * scale, gap: gap * scale)
        }
    }

    private struct PosterColumn {
        var area: CGRect
        let rows: [PosterMeasuredRow]
        var height: CGFloat { rows.reduce(0) { $0 + $1.height + $1.gap } - (rows.last?.gap ?? 0) }
        func scaled(by scale: CGFloat) -> Self {
            Self(area: area.applying(CGAffineTransform(scaleX: scale, y: scale)), rows: rows.map { $0.scaled(by: scale) })
        }
    }

    private static func measuredPosterLayout(_ source: CGSize, metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings) -> Layout {
        let w = source.width, h = source.height, portrait = h > w
        let ratio = CGFloat(normalizePhotoFrameWidthPercent(settings.widthPercent)) / 100
        func spec(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false,
                  alpha: CGFloat = 1, logo: Bool = false, label: String? = nil, gap: CGFloat = 0) -> PosterSpec {
            let font = italic ? UIFont(name: "HelveticaNeue-BoldItalic", size: size) ?? .boldSystemFont(ofSize: size)
                : UIFont.systemFont(ofSize: size, weight: weight)
            return PosterSpec(text: text, font: font, alpha: alpha, logo: logo, label: label, gap: gap)
        }
        let body = w * (portrait ? 0.034 : 0.025)
        let identity = [
            spec(metadata.normalizedMake, size: w * (portrait ? 0.112 : 0.078), weight: .bold, italic: true,
                 logo: settings.showBrand && settings.brandStyle == .logo, gap: w * 0.012),
            spec(metadata.normalizedModel, size: w * (portrait ? 0.068 : 0.047), weight: .medium, alpha: 245 / 255, gap: w * 0.016),
            spec(metadata.lensModel ?? "", size: body * 0.88, alpha: 205 / 255),
        ].filter { !$0.text.isEmpty }
        let exposure = parameterPosterExposure(metadata).map {
            spec($0.value, size: w * (portrait ? 0.052 : 0.038), weight: .bold, italic: true, label: $0.label)
        }
        let location = ([metadata.dateTime].compactMap { $0 }.map { spec($0, size: body * 0.9, alpha: 215 / 255) }
            + metadata.parameterPosterLocationRows.map { spec($0, size: body * 0.88, alpha: 205 / 255) }).filter { !$0.text.isEmpty }
        func joined(_ groups: [[PosterSpec]]) -> [PosterSpec] {
            var result: [PosterSpec] = []
            for group in groups where !group.isEmpty {
                if !result.isEmpty { result[result.count - 1].gap += w * (portrait ? 0.10 : 0.035) }
                result += group
            }
            return result.map { var row = $0; row.gap *= min(ratio, 1); return row }
        }
        func row(_ spec: PosterSpec) -> PhotoFrameTextRow {
            let color = UIColor.white.withAlphaComponent(spec.alpha)
            return spec.logo ? frameIdentityRow(metadata: metadata, logoEnabled: true, font: spec.font, color: color,
                trailingRuns: [], gap: 0, logoScale: 1.65) : metadataRow(spec.text, font: spec.font, color: color)
        }
        func minimumWidth(_ specs: [PosterSpec]) -> CGFloat {
            specs.map { item in
                let measured = row(item).width, size = item.font.pointSize
                if item.logo { return measured / 0.96 }
                if item.label != nil { return size * 4.6 + measured }
                return min(measured / 0.96, size * 6)
            }.max() ?? 0
        }
        func measure(_ specs: [PosterSpec], width: CGFloat) -> PosterColumn {
            let rows = specs.flatMap { item -> [PosterMeasuredRow] in
                let size = item.font.pointSize
                let values = item.logo || item.label != nil ? [row(item)]
                    : metadataDescriptionRows(item.text, font: item.font, color: .white.withAlphaComponent(item.alpha), width: width * 0.96)
                return values.enumerated().map { index, value in
                    // ParameterPosterFrame.drawPosterRows: only the FL/F/ISO/S
                    // label is boxed. Measure once so preview/export scale the
                    // outline, text centering, and value spacing together.
                    let labelFont = item.font.withSize(size * 0.86)
                    let label = item.label.map { metadataRow($0, font: labelFont, color: .white) }
                    let height = label == nil ? max(item.font.lineHeight * 1.16, value.bounds.height + size * 0.16) : size * 2.65
                    let boxWidth = min(width * 0.42, size * 3.65)
                    let boxHeight = size * 1.88
                    let boxTop = (height - boxHeight) / 2
                    let stroke = size * 0.085
                    return PosterMeasuredRow(value: value, label: label,
                        labelBox: label.map { _ in CGRect(x: stroke, y: boxTop, width: boxWidth - stroke, height: boxHeight) },
                        labelStroke: stroke, labelRadius: size * 0.22,
                        labelX: (boxWidth - (label?.width ?? 0)) / 2,
                        labelBaseline: boxTop + (boxHeight + labelFont.ascender + labelFont.descender) / 2,
                        valueX: label == nil ? 0 : boxWidth + size * 0.85,
                        valueBaseline: label == nil ? (height - value.bounds.height) / 2 - value.bounds.minY
                            : boxTop + (boxHeight + item.font.ascender + item.font.descender) / 2,
                        height: height,
                        gap: index == values.count - 1 ? item.gap : 0)
                }
            }
            return PosterColumn(area: CGRect(x: 0, y: 0, width: width, height: 0), rows: rows)
        }
        var left: CGFloat, right: CGFloat, bottom: CGFloat
        var top = w * 0.11 * ratio
        var columns: [PosterColumn] = []
        if portrait {
            let content = joined([identity, exposure, location])
            let outer = w * 0.36 * ratio, inner = w * 0.18 * ratio
            let columnWidth = max(w * 0.56 * ratio, minimumWidth(content))
            var column = measure(content, width: max(1, columnWidth))
            left = content.isEmpty ? w * (0.22 * ratio + 0.88 * min(max((ratio - 0.6) / 0.4, 0), 1)) : outer + columnWidth + inner
            right = w * 0.22 * ratio; bottom = w * 0.11 * ratio
            if !content.isEmpty {
                let extra = max(0, column.height + h * 0.12 - h) / 2
                top += extra; bottom += extra
                column.area = CGRect(x: outer, y: top + (h - column.height) / 2, width: columnWidth, height: column.height)
                columns.append(column)
            }
        } else {
            let first = joined([identity, location]), second = joined([exposure])
            let both = !first.isEmpty && !second.isEmpty
            let inset = w * 0.025, gap = w * 0.105 * ratio
            let secondWidth = max(w * 0.365, minimumWidth(second))
            let required = both ? minimumWidth(first) + gap + secondWidth + inset * 2
                : minimumWidth(first.isEmpty ? second : first) + inset * 2
            let extra = max(0, required - w) / 2
            left = w * 0.10 * ratio + extra; right = left
            let usable = w + extra * 2 - inset * 2
            var a = measure(first.isEmpty ? second : first, width: both ? usable - gap - secondWidth : usable)
            var b = measure(both ? second : [], width: secondWidth)
            bottom = max(w * 0.48 * ratio, max(a.height, b.height) + w * 0.095 * ratio)
            let start = left - extra + inset
            a.area.origin = CGPoint(x: start, y: top + h + (bottom - a.height) / 2); a.area.size.height = a.height
            b.area = CGRect(x: start + usable - secondWidth, y: top + h + (bottom - b.height) / 2, width: secondWidth, height: b.height)
            columns = [a, b].filter { !$0.rows.isEmpty }
        }
        let x = ceil(left), y = ceil(top)
        var result = Layout(canvas: CGSize(width: w + x + ceil(right), height: h + y + ceil(bottom)),
            photo: CGRect(x: x, y: y, width: w, height: h), metadataTop: y + h, parameterPosterPortrait: portrait)
        result.posterColumns = columns
        return result
    }

    static func parameterPosterExposure(_ metadata: PhotoFrameMetadata) -> [(label: String, value: String)] {
        func value(_ source: String?, prefix: String? = nil) -> String? {
            guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let prefix else { return source }
            return source.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return [value(metadata.focalLength).map { ("FL", $0) },
                value(metadata.aperture, prefix: "^f/?").map { ("F", $0) },
                value(metadata.iso, prefix: "^ISO\\s*").map { ("ISO", $0) },
                value(metadata.shutter).map { ("S", $0) }].compactMap { $0 }
    }

    private static func drawParameterPoster(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings) {
        for column in layout.posterColumns {
            var y = column.area.minY
            for row in column.rows {
                if let label = row.label, let box = row.labelBox {
                    cg.saveGState()
                    cg.setStrokeColor(UIColor.white.cgColor)
                    cg.setLineWidth(row.labelStroke)
                    cg.addPath(CGPath(roundedRect: box.offsetBy(dx: column.area.minX, dy: y),
                                      cornerWidth: row.labelRadius, cornerHeight: row.labelRadius, transform: nil))
                    cg.strokePath()
                    cg.restoreGState()
                    label.draw(in: cg, x: column.area.minX + row.labelX,
                        baseline: y + row.labelBaseline)
                }
                row.value.draw(in: cg, x: column.area.minX + row.valueX,
                    baseline: y + row.valueBaseline)
                y += row.height + row.gap
            }
        }
    }

    private static func colorArchivePlan(metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings, width: CGFloat) -> MetadataRowsPlan {
        let photo = CGRect(x: 0, y: 0, width: width, height: 0)
        let textWidth = max(1, width * 0.68)
        var rows: [(String, UIFont, UIColor, UIFont.Weight)] = []
        // Android uppercases the brand only; model spelling remains EXIF data.
        let identity = [metadata.normalizedMake.uppercased(), metadata.normalizedModel].filter { !$0.isEmpty }.joined(separator: " ")
        if !identity.isEmpty { rows.append((identity, UIFont.systemFont(ofSize: photo.width * 0.027, weight: .bold), .black, .bold)) }
        if let lens = metadata.lensModel, !lens.isEmpty { rows.append((lens, UIFont.systemFont(ofSize: photo.width * 0.0195), .black, .regular)) }
        if !metadata.colorArchiveDetailLine.isEmpty { rows.append((metadata.colorArchiveDetailLine, UIFont.systemFont(ofSize: photo.width * 0.022, weight: .bold), .black, .bold)) }
        if let date = metadata.dateTime, !date.isEmpty { rows.append((date, UIFont.systemFont(ofSize: photo.width * 0.0185), .black, .regular)) }
        for location in metadata.locationRows { rows.append((location, UIFont.systemFont(ofSize: photo.width * 0.0185), .black, .regular)) }
        let textRows = rows.enumerated().flatMap { index, row -> [PhotoFrameTextRow] in
            if index == 0, !identity.isEmpty {
                return frameIdentityRows(metadata: metadata, logoEnabled: settings.showBrand && settings.brandStyle == .logo, brandFont: row.1, modelFont: row.1,
                    color: row.2, gap: width * 0.012, width: textWidth, logoScale: 1.30, uppercaseBrand: true, preserveUnbreakableWidth: true)
            }
            return metadataDescriptionRows(row.0, font: row.1, color: row.2, width: textWidth, preserveUnbreakableWidth: true)
        }
        return MetadataRowsPlan(rows: textRows, watermarkIndex: nil)
    }

    struct FilmStripPlan {
        let identity: PhotoFrameTextRow?
        let date: PhotoFrameTextRow?

        init(metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings, width: CGFloat) {
            identity = filmStripIdentityRow(metadata, settings: settings, width: width)
            date = filmStripDateRow(metadata.dateTime, width: width)
        }

        private init(identity: PhotoFrameTextRow?, date: PhotoFrameTextRow?) {
            self.identity = identity
            self.date = date
        }

        func scaled(by scale: CGFloat) -> Self {
            Self(identity: identity?.scaled(by: scale), date: date?.scaled(by: scale))
        }
    }

    static func filmStripIdentityRow(_ metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings, width: CGFloat) -> PhotoFrameTextRow? {
        guard !metadata.identity.isEmpty else { return nil }
        let font = UIFont.boldSystemFont(ofSize: width * 0.021)
        let color = UIColor(red: 184.0 / 255.0, green: 132.0 / 255.0, blue: 99.0 / 255.0, alpha: 1)
        let row = frameIdentityRow(metadata: metadata, logoEnabled: settings.showBrand && settings.brandStyle == .logo,
            font: font, color: color,
            trailingRuns: [metadataText(metadata.normalizedModel, font: font, color: color)],
            gap: width * 0.006, logoScale: 1.15, verticalPaddingRatio: 0.035)
        // Android moves oversized identities into the information band instead of shrinking the strip.
        return row.layoutWidth <= width * 0.58 && row.bounds.height <= width * 0.030 ? row : nil
    }

    static func filmStripDateRow(_ date: String?, width: CGFloat) -> PhotoFrameTextRow? {
        guard let date, !date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let row = metadataRow(date, font: .boldSystemFont(ofSize: width * 0.021),
            color: UIColor(red: 184.0 / 255.0, green: 132.0 / 255.0, blue: 99.0 / 255.0, alpha: 1)).addingVerticalPadding(width * 0.021 * 0.035)
        return row.layoutWidth <= width * 0.72 && row.bounds.height <= width * 0.030 ? row : nil
    }

    private static func drawFilmStrip(_ cg: CGContext, layout: Layout, metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings) {
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
        let strip = layout.filmStripPlan ?? FilmStripPlan(metadata: metadata, settings: settings, width: unit)
        if let row = strip.identity {
            row.draw(in: cg, x: outer.minX + unit * 0.15, baseline: topBaseline)
        }
        if let row = strip.date {
            row.draw(in: cg, x: outer.midX + unit * 0.085 - row.width * 0.5, baseline: outer.maxY - unit * 0.014)
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
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .none
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: sw, height: sh))
        UIGraphicsPopContext()
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

    static func filmEdgeRows(metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings, width: CGFloat) -> [PhotoFrameTextRow] {
        filmEdgePlan(metadata: metadata, settings: settings, width: width).rows
    }

    private static func filmEdgePlan(metadata: PhotoFrameMetadata, settings: PhotoFrameMetadataSettings,
                                     width: CGFloat) -> (rows: [PhotoFrameTextRow], identityGap: CGFloat) {
        let color = UIColor(red: 0.88, green: 0.67, blue: 0.49, alpha: 1)
        let baseSize = width * 0.016
        let font = UIFont(name: "HelveticaNeue-Condensed", size: baseSize) ?? UIFont.systemFont(ofSize: baseSize)
        let maxWidth = width * 0.90
        let percent = CGFloat(normalizePhotoFrameWidthPercent(settings.widthPercent)) / 100
        var identityGap: CGFloat = 0
        let logo = settings.showBrand && settings.brandStyle == .logo
        let details = [metadata.lensModel ?? "", metadata.frameDetailLine, metadata.dateTime ?? ""].filter { !$0.isEmpty }.joined(separator: "   ")
        let tail = [metadata.normalizedModel, details].filter { !$0.isEmpty }.joined(separator: "   ")
        var rows: [PhotoFrameTextRow] = []
        if !metadata.identity.isEmpty || !details.isEmpty {
            let caption = frameIdentityRow(metadata: metadata, logoEnabled: logo, font: font, color: color,
                trailingRuns: [metadataText(tail, font: font, color: color)], gap: width * 0.012 * percent, logoScale: 1.20, verticalPaddingRatio: 0.035)
            if caption.layoutWidth <= maxWidth { rows.append(caption) }
            else {
                if !metadata.identity.isEmpty {
                    let identityFont = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits([.traitCondensed, .traitBold]) ?? font.fontDescriptor,
                                              size: baseSize)
                    let identity = frameIdentityRows(metadata: metadata, logoEnabled: logo, brandFont: identityFont, modelFont: identityFont,
                        color: color, gap: width * 0.012, width: maxWidth, logoScale: 1.20, preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035)
                    rows += identity
                    if identity.count == 1 && identity[0].layoutWidth <= maxWidth {
                        identityGap = width * 0.005 * min(max(percent, 0.65), 1)
                    }
                }
                rows += metadataDescriptionRows(details, font: font, color: color, width: maxWidth, preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035)
            }
        }
        rows += metadata.locationRows.flatMap { metadataDescriptionRows($0, font: font, color: color, width: maxWidth, preserveUnbreakableWidth: true, verticalPaddingRatio: 0.035) }
        return (rows, identityGap)
    }

    private static func drawWatermark(_ cg: CGContext, watermark: PhotoFrameWatermark, photo: CGRect, canvas: CGSize, preset: PhotoFramePreset, metadataBand: CGRect, referenceShortEdge: CGFloat? = nil) throws {
        guard watermark.enabled else { return }
        if photoPlacement(watermark.position) {
            let radius: CGFloat = switch preset {
            case .colorArchive: photo.width * 0.012
            case .brandInset, .brandGallery: photo.width * 0.014
            case .mist, .cinema, .minimal, .frosted: max(1, metadataBand.height * 0.26)
            case .parameterPoster: min(photo.width, photo.height) * 0.018
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
        if effective.content == .image {
            let image = try loadWatermarkImage(effective)
            let rect = photoWatermarkImageRect(effective, photo: photo, imageSize: image.size)
            image.draw(in: rect, blendMode: .normal, alpha: CGFloat(effective.opacityPercent) / 100)
            return
        }
        let photoText = isPhoto ? photoWatermarkTextLayout(effective, photo: photo, referenceShortEdge: referenceShortEdge) : nil
        let font = photoText?.font ?? watermarkFont(effective.font, size: min(photo.width, photo.height) * textSizeFraction(effective.sizePercent))
        let text = effective.displayText
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: watermarkColor(effective.color, preset).withAlphaComponent(CGFloat(effective.opacityPercent) / 100)]
        let measured = (text as NSString).size(withAttributes: attrs)
        let rect: CGRect
        if let photoText {
            rect = CGRect(origin: CGPoint(x: photoText.origin.x, y: photoText.origin.y - font.ascender), size: measured)
        } else {
            let x: CGFloat = switch effective.position { case .left: metadataBand.minX + metadataBand.width * 0.07; case .right: metadataBand.maxX - metadataBand.width * 0.07 - measured.width; default: metadataBand.midX - measured.width / 2 }
            rect = CGRect(x: max(metadataBand.minX, x), y: metadataBand.maxY - measured.height - metadataBand.height * 0.12, width: measured.width, height: measured.height)
        }
        let effect = resolvedWatermarkEffect(effective)
        if effect == .outline {
            let fillColor = watermarkColor(effective.color, preset)
                .withAlphaComponent(CGFloat(effective.opacityPercent) / 100)
            var outlineAttrs = attrs
            outlineAttrs.merge(PhotoWatermarkInk.outlineAttributes(font: font, color: fillColor)) { _, value in value }
            text.draw(at: rect.origin, withAttributes: outlineAttrs)
            text.draw(at: rect.origin, withAttributes: attrs)
        } else {
            var drawAttrs = attrs
            if effect == .shadow {
                drawAttrs[.shadow] = PhotoWatermarkInk.shadow(font: font,
                    color: watermarkColor(effective.color, preset).withAlphaComponent(CGFloat(effective.opacityPercent) / 100))
            }
            text.draw(at: rect.origin, withAttributes: drawAttrs)
        }
    }

    struct PhotoWatermarkTextLayout {
        let font: UIFont
        /// Left-aligned text origin and baseline, with y increasing downwards.
        let origin: CGPoint
        let inkBounds: CGRect
    }

    static func photoWatermarkTextLayout(_ watermark: PhotoFrameWatermark, photo: CGRect, referenceShortEdge: CGFloat? = nil) -> PhotoWatermarkTextLayout {
        precondition(photoPlacement(watermark.position))
        let inset = min(photo.width, photo.height) * 0.04
        var font = watermarkFont(watermark.font, size: (referenceShortEdge ?? min(photo.width, photo.height)) * textSizeFraction(watermark.sizePercent))
        var row = metadataRow(watermark.displayText, font: font, color: .black)
        // Android createWatermarkPaint fits the full advance before positioning actual glyph ink.
        let maxWidth = max(1, photo.width - inset * 2)
        // UIFont may change optical sizing when resized; remeasure instead of
        // assuming the Android Paint's linear text-size scaling.
        for _ in 0..<8 {
            guard row.width > maxWidth else { break }
            font = font.withSize(font.pointSize * maxWidth / row.width * 0.999)
            row = metadataRow(watermark.displayText, font: font, color: .black)
        }
        let ink = row.bounds
        let minX = photo.minX + inset - ink.minX, maxX = photo.maxX - inset - ink.maxX
        let minY = photo.minY + inset - ink.minY, maxY = photo.maxY - inset - ink.maxY
        let centerX = photo.midX - ink.midX, centerY = photo.midY - ink.midY
        let x: CGFloat = switch watermark.position {
        case .photoTopLeft, .photoBottomLeft: minX
        case .photoTopRight, .photoBottomRight: maxX
        default: centerX
        }
        let y: CGFloat = switch watermark.position {
        case .photoTopLeft, .photoTopCenter, .photoTopRight: minY
        case .photoCenter: centerY
        default: maxY
        }
        let origin = CGPoint(x: minX <= maxX ? min(max(x, minX), maxX) : centerX,
                             y: minY <= maxY ? min(max(y, minY), maxY) : centerY)
        return PhotoWatermarkTextLayout(font: font, origin: origin, inkBounds: ink.offsetBy(dx: origin.x, dy: origin.y))
    }

    private static func watermarkRect(position: PhotoFrameWatermarkPosition, photo: CGRect, size: CGSize, inset: CGFloat) -> CGRect {
        let x: CGFloat = switch position { case .photoTopLeft, .photoBottomLeft: photo.minX + inset; case .photoTopRight, .photoBottomRight: photo.maxX - inset - size.width; default: photo.midX - size.width / 2 }
        let y: CGFloat = switch position { case .photoTopLeft, .photoTopCenter, .photoTopRight: photo.minY + inset; case .photoCenter: photo.midY - size.height / 2; default: photo.maxY - inset - size.height }
        return CGRect(x: max(photo.minX, x), y: max(photo.minY, y), width: size.width, height: size.height)
    }

    static func resolvedWatermarkEffect(_ watermark: PhotoFrameWatermark) -> PhotoFrameWatermarkEffect {
        guard watermark.effect == .auto else { return watermark.effect }
        return photoPlacement(watermark.position) ? .shadow : .none
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
        case .colorArchive, .filmEdge, .parameterPoster: true
        case .filmNegative: value.content == .image
        case .galleryMat, .filmGallery: value.content == .image
        default: false
        }
        return usesPhoto ? value.withPosition(mapped) : value.copy(enabled: false)
    }
    private static func textSizeFraction(_ value: Int) -> CGFloat {
        let p = CGFloat(min(max(value, PhotoFrameWatermark.sizeRange.lowerBound), PhotoFrameWatermark.sizeRange.upperBound) + 49)
        if p <= 58 { return 0.0105 * p / 58 }
        if p <= 75 { return 0.0105 + (p - 58) / 17 * (0.0135 - 0.0105) }
        if p <= 100 { return 0.0135 + (p - 75) / 25 * (0.018 - 0.0135) }
        return 0.018 * p / 100
    }
    private static func imageSizeFraction(_ value: Int) -> CGFloat {
        let p = CGFloat(min(max(value, PhotoFrameWatermark.sizeRange.lowerBound), PhotoFrameWatermark.sizeRange.upperBound) + 49)
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
            [PhotoFramePreset.mist, .cinema, .immersive, .brandInset, .brandGallery, .filmGallery, .filmEdge, .filmNegative, .parameterPoster].contains(preset)
                ? UIColor(red: 250 / 255, green: 252 / 255, blue: 253 / 255, alpha: 1)
                : UIColor(red: 24 / 255, green: 31 / 255, blue: 38 / 255, alpha: 1)
        }
    }


}

/// Mirrors Android's `PhotoFrameMetadata.withPresentation`. Interactive
/// previews deliberately substitute conspicuously fake values for unavailable
/// fields so every metadata switch has immediate visible feedback. Exports
/// omit unavailable fields instead.
func presentedPhotoFrameMetadata(
    _ metadata: PhotoFrameMetadata?, settings: PhotoFrameMetadataSettings,
    preview: Bool = false, now: Date = Date(), locale: Locale = photoFramePlaceLocale()
) -> PhotoFrameMetadata {
    (metadata ?? .empty).resolved(for: settings, preview: preview, now: now, locale: locale)
}

extension PhotoFrameMetadata {
    static let empty = PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil)
    /// Android resolves metadata visibility and date/time formatting before any
    /// frame branch draws. Keep the same single filtered snapshot on iOS so
    /// every border receives identical values and never invents rows.
    func resolved(for settings: PhotoFrameMetadataSettings, preview: Bool,
                  now: Date, locale: Locale = photoFramePlaceLocale()) -> PhotoFrameMetadata {
        func cleaned(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let example = preview ? photoFramePreviewPlace(locale: locale) : nil
        let sourceMake = cleaned(make)
        let sourceModel = cleaned(model)
        let sourceLens = cleaned(lensModel)
        let inferredBrand = cameraBrandLabel(make: make, model: model).nilIfEmpty
        let modelValue = normalizedModel.nilIfEmpty
        let validCoordinates = validPhotoFrameCoordinates(latitude, longitude)
        let validAltitude = altitude?.isFinite == true && altitude != 0
        return PhotoFrameMetadata(
            make: !settings.showBrand ? nil
                : sourceMake ?? (settings.brandStyle == .logo && inferredBrand != nil ? inferredBrand
                    : !settings.showModel ? inferredBrand ?? (preview ? "NIKON" : nil)
                    : preview ? inferredBrand ?? "NIKON" : nil),
            model: !settings.showModel ? nil
                : !settings.showBrand ? modelValue ?? (preview ? "Z 233" : nil)
                : sourceModel ?? (preview ? "Z 233" : nil),
            lensModel: settings.showLensModel ? sourceLens ?? (preview ? "1-800mm f/0.1" : nil) : nil,
            focalLength: settings.showFocalLength ? cleaned(focalLength) ?? (preview ? "5100mm" : nil) : nil,
            aperture: settings.showExposure ? cleaned(aperture) ?? (preview ? "f/0.1" : nil) : nil,
            shutter: settings.showExposure ? cleaned(shutter) ?? (preview ? "1/99999" : nil) : nil,
            iso: settings.showExposure ? cleaned(iso) ?? (preview ? "ISO999999" : nil) : nil,
            exposureCompensation: settings.showExposure ? cleaned(exposureCompensation) : nil,
            dateTime: formatDateTime(dateTime, settings: settings, preview: preview, now: now),
            latitude: settings.showCoordinates ? (validCoordinates ? latitude : preview ? 66.6666 : nil) : nil,
            longitude: settings.showCoordinates ? (validCoordinates ? longitude : preview ? 66.6666 : nil) : nil,
            altitude: settings.showAltitude ? (validAltitude ? altitude : preview ? 23_333 : nil) : nil,
            city: settings.showCity ? cleaned(city) ?? example?.city : nil,
            region: settings.showRegion ? cleaned(region) ?? example?.region : nil
        )
    }
    var locationRow: String? { locationRows.joined(separator: "\n").nilIfEmpty }

    private var coordinateRows: [String] {
        guard validPhotoFrameCoordinates(latitude, longitude), let latitude, let longitude else { return [] }
        func degree(_ value: Double, positive: Character, negative: Character) -> String {
            // Round before splitting to carry 59.9995 minutes into the degree.
            let total = Int64((abs(value) * 60_000).rounded())
            return String(format: "%@ %lld°%02lld.%03lld'", locale: Locale(identifier: "en_US_POSIX"),
                String(value < 0 ? negative : positive), total / 60_000, (total % 60_000) / 1_000, total % 1_000)
        }
        return [degree(latitude, positive: "N", negative: "S"), degree(longitude, positive: "E", negative: "W")]
    }

    private var placeRow: String? {
        var places: [String] = []
        for value in [city, region].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }) {
            if !places.contains(value) { places.append(value) }
        }
        return places.joined(separator: " · ").nilIfEmpty
    }

    private func altitudeText(unitSeparator: String) -> String? {
        altitude.flatMap {
            $0.isFinite && $0 != 0
                ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), $0) + unitSeparator + "m" : nil
        }
    }

    var locationRows: [String] {
        let coordinates = [coordinateRows.joined(separator: ", ").nilIfEmpty, altitudeText(unitSeparator: "")]
            .compactMap { $0 }.joined(separator: "  ").nilIfEmpty
        return [placeRow, coordinates].compactMap { $0 }
    }

    /// Android ParameterPosterFrame keeps each coordinate and altitude on its own row.
    var parameterPosterLocationRows: [String] {
        [placeRow].compactMap { $0 } + coordinateRows + [altitudeText(unitSeparator: " ")].compactMap { $0 }
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
    var editorialRows: [String] { [identity, lensModel ?? "", frameDetailLine, dateTime ?? ""].filter { !$0.isEmpty } + locationRows }
    var normalizedMake: String {
        let value = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let brands: [(String, String)] = [("nikon", "Nikon"), ("canon", "Canon"), ("sony", "SONY"), ("fujifilm", "FUJIFILM"), ("hasselblad", "Hasselblad"), ("leica", "Leica"), ("panasonic", "Panasonic"), ("olympus", "OM SYSTEM"), ("om digital", "OM SYSTEM"), ("pentax", "PENTAX"), ("ricoh", "RICOH"), ("apple", "Apple"), ("samsung", "SAMSUNG"), ("google", "Google"), ("xiaomi", "XIAOMI"), ("redmi", "XIAOMI"), ("huawei", "HUAWEI"), ("honor", "HONOR"), ("oneplus", "ONEPLUS"), ("oppo", "OPPO"), ("vivo", "VIVO"), ("realme", "REALME"), ("motorola", "MOTOROLA")]
        if let brand = brands.first(where: { value.localizedCaseInsensitiveContains($0.0) }) { return brand.1 }
        for brand in ["NOKIA", "DJI"] {
            if value.caseInsensitiveCompare(brand) == .orderedSame || value.lowercased().hasPrefix(brand.lowercased() + " ") { return brand }
        }
        return value
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
    func cameraBrandLabel(make: String?, model: String?) -> String {
        let normalized = PhotoFrameMetadata(
            make: make, model: nil, lensModel: nil, focalLength: nil,
            aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil,
            dateTime: nil
        ).normalizedMake.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { return String(normalized.uppercased().prefix(32)) }
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates: [(String, String)] = [
            ("nikon", "NIKON"), ("canon", "CANON"), ("sony", "SONY"),
            ("fujifilm", "FUJIFILM"), ("hasselblad", "HASSELBLAD"),
            ("leica", "LEICA"), ("panasonic", "PANASONIC"),
            ("olympus", "OM SYSTEM"), ("om system", "OM SYSTEM"),
            ("pentax", "PENTAX"), ("ricoh", "RICOH"), ("iphone", "APPLE"),
            ("pixel", "GOOGLE"), ("galaxy", "SAMSUNG"), ("sm-", "SAMSUNG"),
            ("xiaomi", "XIAOMI"), ("redmi", "XIAOMI"), ("huawei", "HUAWEI"),
            ("honor", "HONOR"), ("oneplus", "ONEPLUS"), ("oppo", "OPPO"),
            ("vivo", "VIVO"), ("realme", "REALME")
        ]
        for (needle, label) in candidates {
            if needle == "sm-" {
                if value.lowercased().hasPrefix(needle) { return label }
            } else if value.localizedCaseInsensitiveContains(needle) {
                return label
            }
        }
        return ""
    }
    func rows(_ settings: PhotoFrameMetadataSettings) -> [String] {
        var values: [String] = []
        if settings.showBrand, !normalizedMake.isEmpty { values.append(normalizedMake) }
        if settings.showModel, !normalizedModel.isEmpty { values.append(normalizedModel) }
        if settings.showLensModel, let lensModel, !lensModel.isEmpty { values.append(lensModel) }
        let detail = [settings.showFocalLength ? focalLength : nil, settings.showExposure ? [aperture, shutter, iso].compactMap { $0 }.joined(separator: "  ") : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ")
        if !detail.isEmpty { values.append(detail) }
        if settings.showDate, let dateTime, !dateTime.isEmpty { values.append(dateTime) }
        values += locationRows
        return values
    }

    private func formatDateTime(_ value: String?, settings: PhotoFrameMetadataSettings,
                                preview: Bool, now: Date) -> String? {
        guard settings.showDate || settings.showTime else { return nil }
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized: String = {
            guard raw.count >= 10 else { return raw }
            let characters = Array(raw)
            guard characters[4] == ":", characters[7] == ":",
                  characters[0..<4].allSatisfy(\.isNumber),
                  characters[5..<7].allSatisfy(\.isNumber),
                  characters[8..<10].allSatisfy(\.isNumber) else { return raw }
            return String(characters[0..<4]) + "-" + String(characters[5..<7]) + "-" +
                String(characters[8...])
        }()
        let parts = normalized.split(separator: " ", maxSplits: 1).map(String.init)
        let date = validDate(parts.first)
        let time = parts.count > 1 ? validTime(parts[1]) : nil
        var output: [String] = []
        if settings.showDate, let date = date ?? (preview ? tomorrow(now) : nil) {
            output.append(applyDatePattern(date, pattern: settings.datePattern))
        }
        if settings.showTime {
            if let time { output.append(applyTimePattern(time, pattern: settings.timePattern)) }
            else if preview { output.append(fakeTime(pattern: settings.timePattern)) }
        }
        return output.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty
    }
    private func validDate(_ value: String?) -> String? {
        guard let value,
              value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let values = value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: values[0], month: values[1], day: values[2])
        guard let date = calendar.date(from: components) else { return nil }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == values[0] && result.month == values[1] && result.day == values[2]
            ? value : nil
    }
    private func validTime(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = String(value.prefix(8))
        guard candidate.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = candidate.split(separator: ":").compactMap { Int($0) }
        return parts.count == 3 && (0..<24).contains(parts[0]) &&
            (0..<60).contains(parts[1]) && (0..<60).contains(parts[2]) ? candidate : nil
    }
    private func tomorrow(_ now: Date) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0,
                      components.month ?? 0, components.day ?? 0)
    }
    private func fakeTime(pattern: String) -> String {
        switch pattern.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "HH:mm": return "25:61"
        case "HH.mm": return "25.61"
        case "HH.mm.ss": return "25.61.61"
        default: return "25:61:61"
        }
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
