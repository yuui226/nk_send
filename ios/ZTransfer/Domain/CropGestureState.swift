import Foundation
import CoreGraphics

/// Android CropEditorGeometry: pixel-space frame and image placement, with a
/// stable reference for ratio changes. Normalization happens only at export.
struct CropEditorGeometry {
    enum Ratio: Equatable {
        case free, original
        case fixed(Int, Int)
    }
    let source: JpegCropSource
    private(set) var size: CGSize = .zero
    private(set) var frame: CGRect = .zero
    private(set) var image: CGRect = .zero
    private(set) var ratio: Ratio = .original
    private(set) var swapped = false
    private var ratioReference: CGRect?
    private var initialBounds: CropBounds?

    private var ratioPair: (Int, Int) {
        let pair: (Int, Int)
        switch ratio {
        case .free: return (0, 0)
        case .original: pair = (source.displayWidth, source.displayHeight)
        case .fixed(let w, let h): pair = (w, h)
        }
        return swapped ? (pair.1, pair.0) : pair
    }

    private func fit(_ size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect.isFinite, aspect > 0 else { return .zero }
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    mutating func initialize(_ viewport: CGSize, visibleBounds: CropBounds) throws {
        guard size == .zero, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return }
        _ = try source.align(visibleBounds)
        size = viewport
        initialBounds = visibleBounds
        restoreInitialPlacement()
    }

    private mutating func restoreInitialPlacement() {
        let bounds = initialBounds ?? CropBounds(left: 0, top: 0, right: 1, bottom: 1)
        let w = bounds.right - bounds.left, h = bounds.bottom - bounds.top
        frame = fit(size, aspect: CGFloat(w * Double(source.displayWidth) / (h * Double(source.displayHeight))))
        let imageWidth = frame.width / w, imageHeight = frame.height / h
        image = CGRect(x: frame.minX - bounds.left * imageWidth, y: frame.minY - bounds.top * imageHeight,
            width: imageWidth, height: imageHeight)
        ratioReference = frame
    }

    mutating func resize(_ value: CGSize) throws {
        guard value != size, value.width.isFinite, value.height.isFinite,
              value.width > 0, value.height > 0 else { return }
        let previous = image.width > 0 ? try recipe() : nil
        size = value
        image = fit(size, aspect: CGFloat(source.displayWidth) / CGFloat(source.displayHeight))
        frame = image
        if let previous {
            let crop = source.displayBounds(previous.rect)
            let width = crop.right - crop.left, height = crop.bottom - crop.top
            frame = fit(size, aspect: CGFloat(width * Double(source.displayWidth) / (height * Double(source.displayHeight))))
            let w = frame.width / width, h = frame.height / height
            image = CGRect(x: frame.minX - crop.left * w, y: frame.minY - crop.top * h, width: w, height: h)
        }
        ratioReference = frame
    }

    mutating func reset() {
        ratio = .original; swapped = false
        restoreInitialPlacement()
    }

    mutating func select(_ value: Ratio, flip: Bool = false) {
        if case .fixed(let w, let h) = value {
            guard w > 0, h > 0 else { return }
            ratio = flip ? .fixed(h, w) : value
            swapped = false
        } else {
            ratio = value
            swapped = flip ? !swapped : false
        }
        let (w, h) = ratioPair
        guard w > 0, frame.width > 0 else { return }
        let available = image.intersection(CGRect(origin: .zero, size: size))
        let reference = ratioReference ?? frame
        ratioReference = reference
        let fitted = fit(reference.size, aspect: CGFloat(w) / CGFloat(h))
        let shrink = min(1, available.width / fitted.width, available.height / fitted.height)
        let width = fitted.width * shrink, height = fitted.height * shrink
        frame = CGRect(x: min(max(reference.midX - width / 2, available.minX), max(available.minX, available.maxX - width)),
            y: min(max(reference.midY - height / 2, available.minY), max(available.minY, available.maxY - height)), width: width, height: height)
    }

    private var bounds: CropBounds {
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return CropBounds(left: clamp((frame.minX - image.minX) / image.width),
            top: clamp((frame.minY - image.minY) / image.height),
            right: clamp((frame.maxX - image.minX) / image.width),
            bottom: clamp((frame.maxY - image.minY) / image.height))
    }

    func selection(orientation: Int) -> JpegCropSelection {
        let (w, h) = ratioPair
        return JpegCropSelection(bounds: bounds, orientation: orientation,
            ratioWidth: ratio == .original ? 0 : w, ratioHeight: ratio == .original ? 0 : h)
    }

    func recipe() throws -> JpegCropRecipe {
        let (w, h) = ratioPair
        return JpegCropRecipe(source: source, rect: try source.align(bounds, ratioWidth: w, ratioHeight: h))
    }

    func alignedFrame() throws -> CGRect {
        guard image.width > 0 else { return frame }
        let bounds = source.displayBounds(try recipe().rect)
        return CGRect(x: image.minX + bounds.left * image.width, y: image.minY + bounds.top * image.height,
            width: (bounds.right - bounds.left) * image.width, height: (bounds.bottom - bounds.top) * image.height)
    }

    mutating func transform(centroid: CGPoint, pan: CGSize, zoom: CGFloat) throws {
        guard image.width > 0, zoom.isFinite, zoom > 0,
              [centroid.x, centroid.y, pan.width, pan.height].allSatisfy(\.isFinite) else { return }
        let minimum = max(frame.width / image.width, frame.height / image.height)
        let base = fit(size, aspect: CGFloat(source.displayWidth) / CGFloat(source.displayHeight))
        let (w, h) = ratioPair
        let fixed: Bool
        if case .fixed = ratio { fixed = true } else { fixed = false }
        let minPixelsW = fixed ? CGFloat(w) + 0.01 : 1
        let minPixelsH = fixed ? CGFloat(h) + 0.01 : 1
        let pixelLimit = min(frame.width / image.width * CGFloat(source.displayWidth) / minPixelsW,
            frame.height / image.height * CGFloat(source.displayHeight) / minPixelsH)
        let maximum = max(min(base.width * 32 / image.width, pixelLimit), minimum)
        let factor = min(max(zoom, minimum), maximum)
        image = CGRect(x: centroid.x + (image.minX - centroid.x) * factor + pan.width,
            y: centroid.y + (image.minY - centroid.y) * factor + pan.height,
            width: image.width * factor, height: image.height * factor)
        let dx = image.minX > frame.minX ? frame.minX - image.minX : image.maxX < frame.maxX ? frame.maxX - image.maxX : 0
        let dy = image.minY > frame.minY ? frame.minY - image.minY : image.maxY < frame.maxY ? frame.maxY - image.maxY : 0
        image = image.offsetBy(dx: dx, dy: dy)
        let snapped = try alignedFrame()
        let sx = snapped.minX < 0 ? -snapped.minX : snapped.maxX > size.width ? size.width - snapped.maxX : 0
        let sy = snapped.minY < 0 ? -snapped.minY : snapped.maxY > size.height ? size.height - snapped.maxY : 0
        if sx != 0 || sy != 0 {
            frame = snapped.offsetBy(dx: sx, dy: sy)
            image = image.offsetBy(dx: sx, dy: sy)
        }
    }

    func corner(at point: CGPoint, radius: CGFloat = 28) -> Int? {
        let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                       CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
        return corners.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= radius }
    }

    mutating func dragCorner(_ corner: Int, pan: CGSize, minimum: CGFloat) throws {
        guard (0...3).contains(corner), pan.width.isFinite, pan.height.isFinite else { return }
        let left = corner == 0 || corner == 3, top = corner == 0 || corner == 1
        let anchor = CGPoint(x: left ? frame.maxX : frame.minX, y: top ? frame.maxY : frame.minY)
        let old = CGPoint(x: left ? frame.minX : frame.maxX, y: top ? frame.minY : frame.maxY)
        let maxW = left ? anchor.x : size.width - anchor.x, maxH = top ? anchor.y : size.height - anchor.y
        var w = min(max((old.x + pan.width - anchor.x) * (left ? -1 : 1), min(minimum, maxW)), maxW)
        var h = min(max((old.y + pan.height - anchor.y) * (top ? -1 : 1), min(minimum, maxH)), maxH)
        let (rw, rh) = ratioPair
        if rw > 0 {
            let aspect = CGFloat(rw) / CGFloat(rh)
            if abs(pan.width) > abs(pan.height) { h = w / aspect } else { w = h * aspect }
            let shrink = min(1, maxW / w, maxH / h)
            w *= shrink; h *= shrink
        }
        guard w >= 1, h >= 1 else { return }
        frame = CGRect(x: left ? anchor.x - w : anchor.x, y: top ? anchor.y - h : anchor.y, width: w, height: h)
        try transform(centroid: CGPoint(x: frame.midX, y: frame.midY), pan: .zero, zoom: 1)
        ratioReference = frame
    }
}

/// One gesture owns a corner only until a second pointer appears. Pointer
/// identity keeps incremental transforms stable when fingers enter or leave.
struct CropTouchState<ID: Hashable> {
    struct Change {
        let corner: Int?
        let centroid: CGPoint
        let pan: CGSize
        let zoom: CGFloat
    }
    private(set) var points: [ID: CGPoint] = [:]
    private(set) var corner: Int?

    mutating func begin(_ added: [ID: CGPoint], cornerAt: (CGPoint) -> Int?) {
        guard !added.isEmpty else { return }
        if points.isEmpty, let first = added.values.first { corner = cornerAt(first) }
        points.merge(added) { _, new in new }
        if points.count > 1 { corner = nil }
    }

    mutating func move(_ current: [ID: CGPoint]) -> Change? {
        let keys = Array(points.keys)
        guard !keys.isEmpty, keys.allSatisfy({ current[$0] != nil }),
              current.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let before = keys.compactMap { points[$0] }, after = keys.compactMap { current[$0] }
        let delta = previewTouchTransform(previous: before, current: after)
        for key in keys { points[key] = current[key] }
        return Change(corner: corner, centroid: delta.centroid, pan: delta.pan, zoom: delta.factor)
    }

    mutating func end(_ ids: Set<ID>) {
        for id in ids { points.removeValue(forKey: id) }
        if points.isEmpty { corner = nil }
    }

    mutating func reset() { points.removeAll(); corner = nil }
}
