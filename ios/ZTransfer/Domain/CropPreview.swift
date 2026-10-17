import Foundation
import CoreGraphics

/// Android prepareCropPreview borrows FHD pixels; these dimensions describe
/// the editor only. Original JPEG dimensions and MCU alignment are resolved later.
func prepareCropPreview(width: Int, height: Int, orientation: Int, embeddedOrientation: Int?,
                        rotation: Double, pixel: (Int, Int) -> CGColor) throws -> CropPreview {
    guard width > 0, height > 0 else { throw CropPreparationError.previewRead(detail: "Empty preview") }
    guard rotation.isFinite, abs(rotation / 90) < Double(Int.max) else {
        throw CropPreparationError.orientation(detail: "Invalid preview rotation")
    }
    let content = cropPreviewBounds(width: width, height: height, pixel: pixel)
    let canonical = cropPreviewOrientation(source: orientation, embedded: embeddedOrientation,
        width: content.width, height: content.height)
    guard [1, 3, 6, 8].contains(canonical) else {
        throw CropPreparationError.orientation(detail: "Unsupported canonical orientation: \(canonical)")
    }
    let display = displayOrientation(for: rotation)
    return CropPreview(source: JpegCropSource(width: display >= 5 ? content.height : content.width,
        height: display >= 5 ? content.width : content.height, mcuWidth: 1, mcuHeight: 1, orientation: 1),
        imageWidth: width, imageHeight: height, originalOrientation: orientation,
        content: content, displayOrientation: display, canonicalOrientation: canonical)
}

struct CropPreview: Equatable, Sendable {
    let source: JpegCropSource
    let imageWidth: Int
    let imageHeight: Int
    let originalOrientation: Int
    let content: CropRect
    let displayOrientation: Int
    let canonicalOrientation: Int

    /// Android keeps the nearest equivalent angle. An unchanged direction
    /// must not trigger the preview's rotation-driven zoom/pan reset.
    func correctedRotation(from current: Double) -> Double {
        let target: Double
        switch canonicalOrientation {
        case 3: target = 180
        case 6: target = 90
        case 8: target = -90
        default: target = 0
        }
        let delta = ((target - current + 540).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) - 180
        return current + delta
    }

    /// Android PreviewCropPlacement.content: map the visible viewport through
    /// the displayed FHD content, excluding embedded black bars.
    func visibleBounds(viewport: CGRect, imageFrame: CGRect) throws -> CropBounds {
        guard viewport.width > 0, viewport.height > 0, imageFrame.width > 0, imageFrame.height > 0,
              [viewport.minX, viewport.minY, viewport.maxX, viewport.maxY,
               imageFrame.minX, imageFrame.minY, imageFrame.maxX, imageFrame.maxY].allSatisfy(\.isFinite) else {
            throw JpegCropError.invalidBounds
        }
        let rawContent = CropBounds(left: Double(content.left) / Double(imageWidth),
            top: Double(content.top) / Double(imageHeight), right: Double(content.right) / Double(imageWidth),
            bottom: Double(content.bottom) / Double(imageHeight))
        let displayed = transformCropBounds(rawContent, orientation: displayOrientation)
        let contentFrame = CGRect(x: imageFrame.minX + displayed.left * imageFrame.width,
            y: imageFrame.minY + displayed.top * imageFrame.height,
            width: (displayed.right - displayed.left) * imageFrame.width,
            height: (displayed.bottom - displayed.top) * imageFrame.height)
        let visible = contentFrame.intersection(viewport)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { throw JpegCropError.invalidBounds }
        return CropBounds(left: (visible.minX - contentFrame.minX) / contentFrame.width,
            top: (visible.minY - contentFrame.minY) / contentFrame.height,
            right: (visible.maxX - contentFrame.minX) / contentFrame.width,
            bottom: (visible.maxY - contentFrame.minY) / contentFrame.height)
    }

    /// Called after the preview adopts the canonical rotation, as in Android's crop entry.
    func canonicalized() -> Self {
        Self(source: JpegCropSource(width: canonicalOrientation >= 5 ? content.height : content.width,
            height: canonicalOrientation >= 5 ? content.width : content.height, mcuWidth: 1, mcuHeight: 1, orientation: 1),
            imageWidth: imageWidth, imageHeight: imageHeight, originalOrientation: originalOrientation,
            content: content, displayOrientation: canonicalOrientation, canonicalOrientation: canonicalOrientation)
    }

    func canonicalSelection(_ displayed: JpegCropSelection) -> JpegCropSelection {
        let raw = transformCropBounds(displayed.bounds, orientation: displayOrientation, inverse: true)
        let canonical = transformCropBounds(raw, orientation: canonicalOrientation)
        let swap = (displayOrientation >= 5) != (canonicalOrientation >= 5)
        return JpegCropSelection(bounds: canonical, orientation: originalOrientation,
                                 ratioWidth: swap ? displayed.ratioHeight : displayed.ratioWidth,
                                 ratioHeight: swap ? displayed.ratioWidth : displayed.ratioHeight)
    }

    func rawSelection(_ displayed: JpegCropSelection) -> CropRect {
        let raw = transformCropBounds(displayed.bounds, orientation: displayOrientation, inverse: true)
        let left = min(max(content.left + Int(raw.left * Double(content.width)), content.left), content.right - 1)
        let top = min(max(content.top + Int(raw.top * Double(content.height)), content.top), content.bottom - 1)
        return CropRect(left: left, top: top,
                        right: min(max(content.left + Int(raw.right * Double(content.width)), left + 1), content.right),
                        bottom: min(max(content.top + Int(raw.bottom * Double(content.height)), top + 1), content.bottom))
    }
}

func cropPreviewOrientation(source: Int, embedded: Int?, width: Int, height: Int) -> Int {
    if let embedded, (2...8).contains(embedded) { return embedded }
    if (5...8).contains(source), height > width { return 1 }
    return source
}

func displayOrientation(for rotation: Double) -> Int {
    switch ((Int((rotation / 90).rounded()) % 4) + 4) % 4 { case 1: return 6; case 2: return 3; case 3: return 8; default: return 1 }
}

func transformCropBounds(_ bounds: CropBounds, orientation: Int, inverse: Bool = false) -> CropBounds {
    let space = JpegCropSource(width: 1, height: 1, mcuWidth: 1, mcuHeight: 1, orientation: orientation)
    let a = inverse ? space.toSource(bounds.left, bounds.top) : space.toDisplay(bounds.left, bounds.top)
    let b = inverse ? space.toSource(bounds.right, bounds.bottom) : space.toDisplay(bounds.right, bounds.bottom)
    return CropBounds(left: min(a.x,b.x), top: min(a.y,b.y), right: max(a.x,b.x), bottom: max(a.y,b.y))
}
