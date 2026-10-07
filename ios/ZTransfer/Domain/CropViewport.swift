import CoreGraphics

struct CropViewportState: Equatable, Sendable {
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
    mutating func applyMagnification(_ magnification: CGFloat) { scale = min(max(scale * magnification, 1), 8) }
    mutating func applyTranslation(_ translation: CGSize) { offset = CGPoint(x: offset.x + translation.width, y: offset.y + translation.height) }
    mutating func reset() { scale = 1; offset = .zero }
}

struct CropImagePlacement: Equatable, Sendable {
    let image: CGRect
    let viewport: CGSize
    let rotation: CGFloat
    func contentRect(preview: CropPreview) -> CGRect {
        let c = preview.content
        let bounds = transformCropBounds(.init(left: Double(c.left)/Double(preview.imageWidth), top: Double(c.top)/Double(preview.imageHeight), right: Double(c.right)/Double(preview.imageWidth), bottom: Double(c.bottom)/Double(preview.imageHeight)), orientation: preview.displayOrientation)
        return CGRect(x: image.minX + CGFloat(bounds.left) * image.width,
                      y: image.minY + CGFloat(bounds.top) * image.height,
                      width: CGFloat(bounds.right - bounds.left) * image.width,
                      height: CGFloat(bounds.bottom - bounds.top) * image.height)
    }
}
