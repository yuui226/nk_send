import Foundation

struct CropGestureState: Equatable, Sendable {
    private(set) var bounds: CropBounds
    let ratioWidth: Int
    let ratioHeight: Int
    init(bounds: CropBounds = .init(left: 0, top: 0, right: 1, bottom: 1), ratioWidth: Int = 0, ratioHeight: Int = 0) {
        precondition(bounds.left >= 0 && bounds.top >= 0 && bounds.right <= 1 && bounds.bottom <= 1 && bounds.left < bounds.right && bounds.top < bounds.bottom)
        self.bounds = bounds; self.ratioWidth = ratioWidth; self.ratioHeight = ratioHeight
    }
    mutating func pan(dx: Double, dy: Double) {
        let w = bounds.right - bounds.left, h = bounds.bottom - bounds.top
        let x = min(max(bounds.left + dx, 0), 1 - w), y = min(max(bounds.top + dy, 0), 1 - h)
        bounds = .init(left: x, top: y, right: x + w, bottom: y + h)
    }
    mutating func zoom(scale: Double, anchor: CropPoint = .init(x: 0.5, y: 0.5)) {
        guard scale.isFinite, scale > 0 else { return }
        let w = min(max((bounds.right - bounds.left) / scale, 0.01), 1), h = min(max((bounds.bottom - bounds.top) / scale, 0.01), 1)
        let ax = min(max(anchor.x, bounds.left), bounds.right), ay = min(max(anchor.y, bounds.top), bounds.bottom)
        let left = min(max(ax - (ax - bounds.left) / scale, 0), 1 - w)
        let top = min(max(ay - (ay - bounds.top) / scale, 0), 1 - h)
        bounds = .init(left: left, top: top, right: left + w, bottom: top + h)
    }
    mutating func setRatio(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let target = Double(width) / Double(height), centerX = (bounds.left + bounds.right) / 2, centerY = (bounds.top + bounds.bottom) / 2
        let current = (bounds.right - bounds.left) / max(bounds.bottom - bounds.top, 0.0001)
        var w = bounds.right - bounds.left, h = bounds.bottom - bounds.top
        if current > target { w = h * target } else { h = w / target }
        if w > 1 { w = 1; h = w / target }; if h > 1 { h = 1; w = h * target }
        let left = min(max(centerX - w / 2, 0), 1 - w), top = min(max(centerY - h / 2, 0), 1 - h)
        bounds = .init(left: left, top: top, right: left + w, bottom: top + h)
    }
    func selection(orientation: Int) -> JpegCropSelection { .init(bounds: bounds, orientation: orientation, ratioWidth: ratioWidth, ratioHeight: ratioHeight) }
}
