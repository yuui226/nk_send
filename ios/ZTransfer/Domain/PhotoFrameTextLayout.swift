import CoreGraphics
import CoreText
import Foundation
import UIKit

/// Shared conversion from Android Paint stroke units to attributed-text units.
enum PhotoWatermarkInk {
    static let effectAttribute = NSAttributedString.Key("ZTransferWatermarkEffect")

    static func applying(_ effect: PhotoFrameWatermarkEffect, to text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.addAttribute(effectAttribute, value: effect.rawValue, range: NSRange(location: 0, length: copy.length))
        return copy
    }

    static func contrast(_ color: UIColor) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return UIColor(white: 0.05, alpha: alpha)
        }
        return (red * 299 + green * 587 + blue * 114) / 1000 >= 150.0 / 255
            ? UIColor(red: 12 / 255, green: 15 / 255, blue: 18 / 255, alpha: alpha)
            : UIColor(red: 248 / 255, green: 249 / 255, blue: 250 / 255, alpha: alpha)
    }

    static func outlineAttributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        [.strokeWidth: max(1, font.pointSize * 0.075) / font.pointSize * 100,
         .strokeColor: contrast(color)]
    }

    static func shadow(font: UIFont, color: UIColor) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = font.pointSize * 0.12
        shadow.shadowOffset = CGSize(width: 0, height: font.pointSize * 0.06)
        shadow.shadowColor = contrast(color)
        return shadow
    }
}

/// A baseline-aligned row of text, including mixed-font camera titles.
/// Measurement and drawing use the same CTLines in a top-left canvas coordinate system.
struct PhotoFrameTextRow {
    private let lines: [CTLine]
    private let attributedRuns: [NSAttributedString]
    private var origins: [CGFloat]
    private var leadingGraphic: ((CGContext) -> Void)?
    private var drawingScale: CGFloat = 1
    private var unscaledBounds: CGRect
    private var unscaledWidth: CGFloat

    var bounds: CGRect { unscaledBounds.applying(CGAffineTransform(scaleX: drawingScale, y: drawingScale)) }
    var width: CGFloat { unscaledWidth * drawingScale }
    /// Android FrameTextRun.width includes horizontal ink beyond the advance.
    var layoutWidth: CGFloat { max(width, bounds.maxX) - min(0, bounds.minX) }


    init(_ text: NSAttributedString) { self.init([text]) }

    /// Android FrameTextWrapping: prefer a line boundary only when it uses at
    /// least half the measured span, and never split an extended grapheme.
    static func wrappedDescriptions(_ text: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
        precondition(width.isFinite && width > 0)
        let source = text.string as NSString
        var result: [NSAttributedString] = []
        var paragraphStart = 0
        for paragraph in text.string.components(separatedBy: .newlines) {
            let paragraphLength = (paragraph as NSString).length
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let local = (paragraph as NSString).range(of: trimmed)
                let value = text.attributedSubstring(from: NSRange(location: paragraphStart + local.location, length: local.length))
                if PhotoFrameTextRow(value).width <= width {
                    result.append(value)
                    paragraphStart = min(source.length, paragraphStart + paragraphLength + 1)
                    continue
                }
                let string = value.string as NSString
                let typesetter = CTTypesetterCreateWithAttributedString(value)
                var boundaries = [0]
                for character in value.string { boundaries.append(boundaries.last! + String(character).utf16.count) }
                let boundarySet = Set(boundaries)
                func boundaryIndex(after offset: Int) -> Int {
                    var low = 0, high = boundaries.count
                    while low < high {
                        let middle = low + (high - low) / 2
                        if boundaries[middle] <= offset { low = middle + 1 } else { high = middle }
                    }
                    return low
                }
                var start = 0
                while start < string.length {
                    let raw = start + CTTypesetterSuggestClusterBreak(typesetter, start, Double(width))
                    let preceding = boundaries[max(0, boundaryIndex(after: raw) - 1)]
                    var end = preceding > start ? preceding : boundaries[boundaryIndex(after: start)]
                    let wordEnd = start + CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                    if end < string.length, wordEnd > start, wordEnd <= end, boundarySet.contains(wordEnd), wordEnd - start >= (end - start) / 2 {
                        end = wordEnd
                    }
                    let piece = string.substring(with: NSRange(location: start, length: end - start))
                    let content = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        let range = (piece as NSString).range(of: content)
                        result.append(value.attributedSubstring(from: NSRange(location: start + range.location, length: range.length)))
                    }
                    start = end
                }
            }
            paragraphStart = min(source.length, paragraphStart + paragraphLength + 1)
        }
        return result
    }

    /// Measured frame columns reserve each Android FrameTextRun's full ink width.
    /// Advance-based compositions (including immersive titles) keep the default.
    init(_ runs: [NSAttributedString], gap: CGFloat = 0, includeRunInk: Bool = false, verticalPaddingRatio: CGFloat = 0) {
        attributedRuns = runs.filter { $0.length > 0 }
        lines = attributedRuns.map { CTLineCreateWithAttributedString($0) }
        var x: CGFloat = 0
        var offsets: [CGFloat] = []
        var ink = CGRect.null
        for (index, line) in lines.enumerated() {
            if index > 0 { x += gap }
            let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let hasInk = !glyphs.isNull && !glyphs.isEmpty
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let left = includeRunInk && hasInk ? min(0, glyphs.minX) : 0
            let origin = x - left
            offsets.append(origin)
            if !glyphs.isNull, !glyphs.isEmpty {
                // CoreText is y-up; UIKit and Android canvas baselines are y-down.
                let font = attributedRuns[index].attribute(.font, at: 0, effectiveRange: nil) as? UIFont
                let padding = (font?.pointSize ?? 0) * verticalPaddingRatio
                ink = ink.union(CGRect(x: origin + glyphs.minX, y: -glyphs.maxY - padding,
                                       width: glyphs.width, height: glyphs.height + padding * 2))
            }
            x += includeRunInk && hasInk ? max(advance, glyphs.maxX) - left : advance
        }
        origins = offsets
        unscaledWidth = x
        unscaledBounds = ink.isNull ? .zero : ink
    }

    /// A vector prefix shares the text row's fitting and baseline transform.
    /// Bounds and drawing are supplied together, so layout cannot forget its ink.
    init(leadingBounds: CGRect, drawLeading: @escaping (CGContext) -> Void,
         runs: [NSAttributedString], gap: CGFloat = 0, includeRunInk: Bool = false,
         verticalPaddingRatio: CGFloat = 0, leadingVerticalPadding: CGFloat = 0) {
        self.init(runs, gap: gap, includeRunInk: includeRunInk, verticalPaddingRatio: verticalPaddingRatio)
        let offset = leadingBounds.maxX + (lines.isEmpty ? 0 : gap)
        origins = origins.map { $0 + offset }
        let measuredLeadingBounds = leadingBounds.insetBy(dx: 0, dy: -leadingVerticalPadding)
        unscaledBounds = lines.isEmpty ? measuredLeadingBounds
            : unscaledBounds.offsetBy(dx: offset, dy: 0).union(measuredLeadingBounds)
        unscaledWidth += offset
        leadingGraphic = drawLeading
    }

    /// Keep a composed title's own run spacing while appending separate components.
    init(leadingRow: PhotoFrameTextRow, runs: [NSAttributedString], gap: CGFloat) {
        self.init(runs, gap: gap)
        let offset = leadingRow.width + (lines.isEmpty ? 0 : gap)
        origins = origins.map { $0 + offset }
        unscaledBounds = lines.isEmpty ? leadingRow.bounds
            : unscaledBounds.offsetBy(dx: offset, dy: 0).union(leadingRow.bounds)
        unscaledWidth += offset
        leadingGraphic = { context in leadingRow.draw(in: context, x: 0, baseline: 0) }
    }

    /// Reserve effect ink without changing glyph size, horizontal extent or drawing.
    func addingVerticalPadding(_ padding: CGFloat) -> Self {
        var copy = self
        copy.unscaledBounds = unscaledBounds.insetBy(dx: 0, dy: -max(0, padding) / drawingScale)
        return copy
    }

    func fitting(width maxWidth: CGFloat) -> Self {
        var copy = self
        let extent = layoutWidth
        if extent > maxWidth, extent > 0 {
            copy.drawingScale *= max(0, maxWidth) / extent
        }
        return copy
    }

    func scaled(by scale: CGFloat) -> Self {
        precondition(scale.isFinite && scale > 0)
        var copy = self
        copy.drawingScale *= scale
        return copy
    }

    /// The caller supplies a y-down baseline; do not subtract font ascenders again.
    func draw(in context: CGContext, x: CGFloat, baseline: CGFloat, scale: CGFloat = 1,
              outline: Bool = false, shadow: Bool = false) {
        guard scale > 0, drawingScale > 0 else { return }
        context.saveGState()
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: drawingScale * scale, y: drawingScale * scale)
        leadingGraphic?(context)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        for (index, pair) in zip(lines, origins).enumerated() {
            let (line, origin) = pair
            let run = attributedRuns[index]
            let explicitEffect = (run.attribute(PhotoWatermarkInk.effectAttribute, at: 0, effectiveRange: nil) as? String)
                .flatMap(PhotoFrameWatermarkEffect.init(rawValue:))
            context.saveGState()
            if explicitEffect != nil {
                // An inline watermark must not inherit the camera title's shadow.
                context.setShadow(offset: .zero, blur: 0, color: nil)
            }
            let drawsOutline = explicitEffect.map { $0 == .outline } ?? outline
            let drawsShadow = explicitEffect.map { $0 == .shadow } ?? shadow
            if drawsOutline {
                context.setLineJoin(.round)
                let stroke = NSMutableAttributedString(attributedString: run)
                run.enumerateAttributes(in: NSRange(location: 0, length: run.length)) { attributes, range, _ in
                    guard let font = attributes[.font] as? UIFont,
                          let color = attributes[.foregroundColor] as? UIColor else { return }
                    stroke.addAttributes(PhotoWatermarkInk.outlineAttributes(font: font, color: color), range: range)
                }
                context.textPosition = CGPoint(x: origin, y: 0)
                CTLineDraw(CTLineCreateWithAttributedString(stroke), context)
            }
            if drawsShadow,
               let font = run.attribute(.font, at: 0, effectiveRange: nil) as? UIFont,
               let color = run.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor {
                let effect = PhotoWatermarkInk.shadow(font: font, color: color)
                let factor = drawingScale * scale
                context.setShadow(offset: CGSize(width: 0, height: effect.shadowOffset.height * factor),
                    blur: effect.shadowBlurRadius * factor, color: PhotoWatermarkInk.contrast(color).cgColor)
            }
            context.textPosition = CGPoint(x: origin, y: 0)
            CTLineDraw(line, context)
            context.restoreGState()
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
