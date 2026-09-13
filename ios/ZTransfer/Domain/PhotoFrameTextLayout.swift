import CoreGraphics
import CoreText
import Foundation

/// A baseline-aligned row of text, including mixed-font camera titles.
/// Measurement and drawing use the same CTLines in a top-left canvas coordinate system.
struct PhotoFrameTextRow {
    private let lines: [CTLine]
    private let origins: [CGFloat]
    private var drawingScale: CGFloat = 1
    private var unscaledBounds: CGRect
    private var unscaledWidth: CGFloat

    var bounds: CGRect { unscaledBounds.applying(CGAffineTransform(scaleX: drawingScale, y: drawingScale)) }
    var width: CGFloat { unscaledWidth * drawingScale }

    init(_ text: NSAttributedString) { self.init([text]) }

    init(_ runs: [NSAttributedString], gap: CGFloat = 0) {
        lines = runs.filter { $0.length > 0 }.map { CTLineCreateWithAttributedString($0) }
        var x: CGFloat = 0
        var offsets: [CGFloat] = []
        var ink = CGRect.null
        for (index, line) in lines.enumerated() {
            if index > 0 { x += gap }
            offsets.append(x)
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if !glyphs.isNull, !glyphs.isEmpty {
                // CoreText is y-up; UIKit and Android canvas baselines are y-down.
                ink = ink.union(CGRect(x: x + glyphs.minX, y: -glyphs.maxY,
                                       width: glyphs.width, height: glyphs.height))
            }
            x += CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        origins = offsets
        unscaledWidth = x
        unscaledBounds = ink.isNull ? .zero : ink
    }

    func fitting(width maxWidth: CGFloat) -> Self {
        var copy = self
        let extent = max(width, bounds.maxX) - min(0, bounds.minX)
        if extent > maxWidth, extent > 0 {
            copy.drawingScale *= max(0, maxWidth) / extent
        }
        return copy
    }

    /// The caller supplies a y-down baseline; do not subtract font ascenders again.
    func draw(in context: CGContext, x: CGFloat, baseline: CGFloat, scale: CGFloat = 1) {
        guard scale > 0, drawingScale > 0 else { return }
        context.saveGState()
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: drawingScale * scale, y: -drawingScale * scale)
        context.textMatrix = .identity
        for (line, origin) in zip(lines, origins) {
            context.textPosition = CGPoint(x: origin, y: 0)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

/// Android's frameTextScaleToFit / centeredFrameTextBaselines, shared by all
/// metadata bands. Empty rows are removed by the caller before layout.
struct PhotoFrameTextLayout {
    static let standardPaddingRatio: CGFloat = 0.06

    let scale: CGFloat
    let gap: CGFloat
    let baselines: [CGFloat]

    init(area: CGRect, bounds: [CGRect], preferredGap: CGFloat, verticalInset: CGFloat = 0) {
        let inset = min(max(0, verticalInset), max(0, area.height) * 0.5)
        let top = area.minY + inset
        let availableHeight = max(0, area.height - inset * 2)
        let inkHeight = bounds.reduce(CGFloat.zero) { $0 + $1.height }
        // First compress gaps; shrink all text together only when the ink itself
        // cannot fit, preserving the Android 2% antialiasing allowance.
        scale = inkHeight > availableHeight && inkHeight > 0
            ? availableHeight / inkHeight * 0.98 : 1
        let textHeight = inkHeight * scale
        let gapCount = max(0, bounds.count - 1)
        gap = gapCount > 0
            ? min(max(0, preferredGap), max(0, availableHeight - textHeight) / CGFloat(gapCount)) : 0
        let blockHeight = textHeight + gap * CGFloat(gapCount)
        var cursor = top + max(0, availableHeight - blockHeight) * 0.5
        var positions: [CGFloat] = []
        for row in bounds {
            positions.append(cursor - row.minY * scale)
            cursor += row.height * scale + gap
        }
        baselines = positions
    }
}
