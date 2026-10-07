import Foundation

struct CropPreview: Equatable, Sendable {
    let source: JpegCropSource
    let imageWidth: Int
    let imageHeight: Int
    let originalOrientation: Int
    let content: CropRect
    let displayOrientation: Int
    let canonicalOrientation: Int

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
