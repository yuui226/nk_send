import Foundation

/// ViewfinderViewport.kt. Display-only state: no camera or recorder dependency.
/// Keep Android Float arithmetic, including fitting and normalized crop bounds.
struct RemoteViewfinderViewport {
    private(set) var scale: Float = 1
    private(set) var offset = SIMD2<Float>.zero
    private(set) var size = SIMD2<Float>.zero

    mutating func reset() { scale = 1; offset = .zero }

    mutating func resize(_ newSize: CGSize, aspect: Float) {
        size = SIMD2(Float(newSize.width), Float(newSize.height))
        offset = bounded(offset, zoom: scale, aspect: aspect)
    }

    mutating func transform(centroid: CGPoint, pan: CGSize, zoom: Float, aspect: Float) {
        guard zoom.isFinite, zoom > 0 else { return }
        let next = min(8, max(1, scale * zoom))
        let ratio = next / scale
        let point = SIMD2(Float(centroid.x), Float(centroid.y))
        let delta = SIMD2(Float(pan.width), Float(pan.height))
        offset = bounded(offset * ratio + (point - size / 2) * (1 - ratio) + delta, zoom: next, aspect: aspect)
        scale = next
    }

    private func bounded(_ value: SIMD2<Float>, zoom: Float, aspect: Float) -> SIMD2<Float> {
        let image = RemoteFramingGrid.fit(width: size.x, height: size.y, aspect: aspect)
        let maxX = max(0, image.width * (zoom - 1) / 2)
        let maxY = max(0, image.height * (zoom - 1) / 2)
        return SIMD2(min(maxX, max(-maxX, value.x)), min(maxY, max(-maxY, value.y)))
    }

    func visibleRegion(aspect: Float) -> CGRect {
        let image = RemoteFramingGrid.fit(width: size.x, height: size.y, aspect: aspect)
        guard image.width > 0, image.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        func x(_ value: Float) -> Float {
            min(1, max(0, ((value - size.x / 2 - offset.x) / scale + size.x / 2 - image.left) / image.width))
        }
        func y(_ value: Float) -> Float {
            min(1, max(0, ((value - size.y / 2 - offset.y) / scale + size.y / 2 - image.top) / image.height))
        }
        let left = x(image.left), top = y(image.top)
        return CGRect(x: CGFloat(left), y: CGFloat(top),
                      width: CGFloat(x(image.right) - left), height: CGFloat(y(image.bottom) - top))
    }

    /// Compose inverse-transforms input inside the graphics layer before AF mapping.
    /// Reject the fixed image window's letterbox before performing the inverse.
    func focusPoint(at point: CGPoint, aspect: Float) -> RemoteFocusPoint? {
        let image = RemoteFramingGrid.fit(width: size.x, height: size.y, aspect: aspect)
        let x = Float(point.x), y = Float(point.y)
        guard image.width > 0, image.height > 0,
              x >= image.left, x <= image.right, y >= image.top, y <= image.bottom else { return nil }
        let original = (SIMD2(x, y) - size / 2 - offset) / scale + size / 2
        return RemoteFocusPoint(x: Double(min(1, max(0, (original.x - image.left) / image.width))),
                                y: Double(min(1, max(0, (original.y - image.top) / image.height))))
    }
}
