import SwiftUI
import UIKit

/// AnimatedVisibility's three states matter when a fade is reversed:
/// PreEnter→Visible uses 160ms; Visible→PostExit uses 200ms; PostExit→Visible
/// uses EnterExitTransition's default spring(400). Transition replaces only
/// an interrupted tween with spring(1500), retaining value and velocity.
struct RemoteMonitorHintMotion {
    private(set) var visible = false
    private(set) var retained = false
    private(set) var alpha = ZTransferScalarAnimation(value: 0)

    mutating func setVisible(_ next: Bool) {
        guard next != visible else { return }
        let returning = next && retained
        if next && !retained { alpha = .init(value: 0) }
        let spec: ZTransferAndroidMotion
        if returning { spec = .criticallyDampedSpring(stiffness: 400) }
        else if alpha.isRunning { spec = .criticallyDampedSpring(stiffness: 1500) }
        else { spec = .tween(milliseconds: next ? 160 : 200) }
        visible = next; retained = true
        alpha.retarget(next ? 1 : 0, using: spec)
    }

    mutating func advance(_ now: Int64) {
        alpha.advance(frameNanos: now)
        if !visible && !alpha.isRunning { retained = false }
    }
}

@MainActor
final class RemoteMonitorHintAnimator: NSObject, ObservableObject {
    @Published private(set) var motion = RemoteMonitorHintMotion()
    private var link: CADisplayLink?
    func setVisible(_ visible: Bool) {
        motion.setVisible(visible)
        guard motion.alpha.isRunning, link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000))
        if !motion.alpha.isRunning { link.invalidate(); self.link = nil }
    }
    func stop() { link?.invalidate(); link = nil; motion = .init() }
}

struct RemoteMonitorHintAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// Measure the inner box after padding, like onGloballyPositioned following
/// padding in RemoteScreen. No frame or camera update owns this anchor.
struct RemoteMonitorHintAnchor: View {
    let horizontalInset: CGFloat
    var body: some View {
        Color.clear
            .anchorPreference(key: RemoteMonitorHintAnchorKey.self, value: .bounds) { $0 }
            .padding(.horizontal, horizontalInset)
            .frame(height: 40)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct RemoteMonitorHintStyle: Equatable {
    let compact: Bool
    var fontSize: CGFloat { compact ? 11 : 12 }
    var lineHeight: CGFloat { compact ? 13 : 16 }
    var font: UIFont { .systemFont(ofSize: fontSize, weight: .medium) }
    var naturalLineHeight: CGFloat { font.ascender - font.descender }
    func textHeight(lines: Int) -> CGFloat { naturalLineHeight + CGFloat(max(0, lines - 1)) * lineHeight }
    var trimmedTop: CGFloat { (lineHeight - naturalLineHeight) * font.ascender / naturalLineHeight }
    var horizontalPadding: CGFloat { compact ? 8 : 12 }
    var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // Wrapping belongs to the paragraph; truncation belongs to the last
        // visible container line. Putting truncation on the paragraph makes
        // TextKit truncate its first line even when two lines are available.
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // Type.kt replaces the Material token with its own TextStyle. Its
        // unspecified letterSpacing resolves to 0sp, not the token's 0.5sp.
        return [.font: font,
                .paragraphStyle: paragraph, .kern: 0]
    }
}

struct RemoteMonitorHintBubble: View {
    let text: String
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }
    private var fill: Color {
        compact ? (dark ? Color(white: 30 / 255) : .white).opacity(0.60) : .black.opacity(0.42)
    }
    private var border: Color {
        compact ? (dark ? .white.opacity(0.15) : .black.opacity(0.10)) : .white.opacity(0.15)
    }
    var body: some View {
        RemoteMonitorHintText(text: text, style: .init(compact: compact),
            color: compact ? ZTransferColors.primaryText : .white.opacity(0.95))
            .padding(.horizontal, compact ? 8 : 12).padding(.vertical, 5)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(border, lineWidth: 0.5))
            .background(RemoteMonitorHintTouchShield())
            .frame(maxWidth: 280)
    }
}

/// UIKit supplies native shaping and ellipsis while paragraph style retains
/// Android's explicit line heights. Measurement is cached across alpha frames.
private struct RemoteMonitorHintText: UIViewRepresentable {
    let text: String
    let style: RemoteMonitorHintStyle
    let color: Color
    func makeUIView(context: Context) -> RemoteMonitorHintLabel { RemoteMonitorHintLabel() }
    func updateUIView(_ label: RemoteMonitorHintLabel, context: Context) {
        label.configure(text: text, style: style, color: UIColor(color))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RemoteMonitorHintLabel, context: Context) -> CGSize? {
        uiView.measured(width: proposal.width ?? 280, height: proposal.height ?? .greatestFiniteMagnitude)
    }
}

final class RemoteMonitorHintLabel: UILabel {
    private var style = RemoteMonitorHintStyle(compact: true)
    private var cached: (width: CGFloat, height: CGFloat, size: CGSize, lines: Int)?
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 2; lineBreakMode = .byTruncatingTail
        accessibilityIdentifier = "remote-monitor-hint"
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        manager.addTextContainer(container); storage.addLayoutManager(manager)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(text: String, style: RemoteMonitorHintStyle, color: UIColor) {
        if self.text != text || self.style != style {
            self.style = style
            attributedText = NSAttributedString(string: text, attributes: style.attributes)
            lineBreakMode = .byTruncatingTail
            storage.setAttributedString(NSAttributedString(string: text, attributes: style.attributes))
            cached = nil
        }
        if textColor != color { textColor = color; setNeedsDisplay() }
    }
    private func layout(width: CGFloat, height: CGFloat, measuredLines: Int? = nil) -> NSRange {
        container.size = CGSize(width: max(0, width), height: .greatestFiniteMagnitude)
        // AndroidParagraph remeasures with fewer lines if maxHeight cannot fit
        // them, retaining at least one ellipsized line rather than clipping it.
        container.maximumNumberOfLines = measuredLines ?? (height >= style.textHeight(lines: 2) ? 2 : 1)
        return manager.glyphRange(for: container)
    }
    func measured(width: CGFloat, height: CGFloat) -> CGSize {
        let width = max(0, width), height = max(0, height)
        if let cached, cached.width == width, cached.height == height { return cached.size }
        let glyphs = layout(width: width, height: height)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lines += 1 }
        let used = manager.usedRect(for: container)
        let scale = max(1, traitCollection.displayScale)
        let size = CGSize(width: min(width, ceil(used.width * scale) / scale),
                          height: min(height, ceil(style.textHeight(lines: max(1, lines)) * scale) / scale))
        cached = (width, height, size, max(1, lines))
        return size
    }
    override func drawText(in rect: CGRect) {
        // Use the same layout engine for measurement and paint. UILabel's
        // independent textRect can be shorter than bounds, so it must not
        // become a second height constraint that drops the last line.
        let rect = bounds
        storage.addAttribute(.foregroundColor, value: textColor ?? UIColor.label,
                             range: NSRange(location: 0, length: storage.length))
        // SwiftUI can round the UIView's allocated height down by a fraction
        // of a physical pixel. Retain the measured line count across that
        // rounding, rather than reinterpreting it as room for only one line.
        let glyphs = layout(width: rect.width, height: rect.height, measuredLines: cached?.lines)
        // Compose 1.7.6 defaults to includeFontPadding=false and Trim.Both:
        // 13/16 is the baseline distance, not extra leading on outer edges.
        manager.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: rect.minX, y: rect.minY - style.trimmedTop))
    }
}

/// Material3's non-clickable Surface still blocks touches to content beneath
/// it. Keep that behavior without inventing a dismiss action or click feedback.
private struct RemoteMonitorHintTouchShield: UIViewRepresentable {
    final class Shield: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            UIBezierPath(roundedRect: bounds, cornerRadius: 12).contains(point)
        }
    }
    func makeUIView(context: Context) -> Shield { Shield() }
    func updateUIView(_ view: Shield, context: Context) {}
}

struct RemoteMonitorHintOverlay: View {
    let anchor: Anchor<CGRect>?
    let text: String
    let compact: Bool
    @ObservedObject var animator: RemoteMonitorHintAnimator
    @Environment(\.displayScale) private var density
    var body: some View {
        GeometryReader { proxy in
            if let anchor, animator.motion.retained {
                let rect = proxy[anchor]
                RemoteMonitorHintBubble(text: text, compact: compact)
                    .opacity(Double(animator.motion.alpha.value))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: floor(rect.minX * density + 0.5) / density + rect.width / 2,
                              y: floor(rect.minY * density + 0.5) / density + rect.height / 2)
            }
        }
    }
}
