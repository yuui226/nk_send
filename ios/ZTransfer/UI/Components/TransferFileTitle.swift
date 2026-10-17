import SwiftUI
import UIKit

/// TransferScreen.TransferFileTitle: preserve the extension and both ends of
/// the stem; binary-search the largest fitting UTF-16 count like Kotlin String.
struct TransferFileTitleText: Equatable {
    let stem: String
    let suffix: String
    var full: String { stem + suffix }

    static func fit(_ name: String, width: CGFloat,
                    measure: (Self) -> CGFloat) -> Self {
        let units = Array(name.utf16)
        let dot = units.lastIndex(of: 46).flatMap { $0 > 0 ? $0 : nil } ?? units.count
        let stem = Array(units[..<dot])
        let suffix = String(decoding: units[dot...], as: UTF16.self)
        let full = Self(stem: String(decoding: stem, as: UTF16.self), suffix: suffix)
        if measure(full) <= width { return full }
        var low = 0, high = max(0, stem.count - 1)
        var result = Self(stem: "…", suffix: suffix)
        while low <= high {
            let kept = (low + high) / 2
            let candidate = Self(stem: String(decoding: stem.prefix((kept + 1) / 2), as: UTF16.self)
                + "…" + String(decoding: stem.suffix(kept / 2), as: UTF16.self), suffix: suffix)
            if measure(candidate) <= width { result = candidate; low = kept + 1 }
            else { high = kept - 1 }
        }
        return result
    }
}

struct TransferFileTitle: UIViewRepresentable {
    let name: String
    let cancelled: Bool
    func makeUIView(context: Context) -> TransferFileTitleLabel { TransferFileTitleLabel() }
    func updateUIView(_ view: TransferFileTitleLabel, context: Context) {
        let traits = UITraitCollection(userInterfaceStyle: context.environment.colorScheme == .dark ? .dark : .light)
        view.configure(name: name,
            primary: UIColor(cancelled ? ZTransferColors.secondaryText : ZTransferColors.primaryText).resolvedColor(with: traits),
            secondary: UIColor(ZTransferColors.secondaryText).resolvedColor(with: traits))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TransferFileTitleLabel, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.fullWidth, height: 20)
    }
}

final class TransferFileTitleLabel: UILabel {
    private var fileName = ""
    private var primary = UIColor.label
    private var secondary = UIColor.secondaryLabel
    private var fittedWidth: CGFloat?
    var fullWidth: CGFloat {
        let full = TransferFileTitleText.fit(fileName, width: .greatestFiniteMagnitude) { attributed($0).size().width }
        return attributed(full).size().width
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 1
        lineBreakMode = .byTruncatingTail // Android's fallback when even “…extension” cannot fit.
        isAccessibilityElement = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    func configure(name: String, primary: UIColor, secondary: UIColor) {
        guard name != fileName || primary != self.primary || secondary != self.secondary else { return }
        fileName = name; self.primary = primary; self.secondary = secondary
        accessibilityLabel = name
        fittedWidth = nil
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let width = (bounds.width * scale).rounded() / scale
        guard fittedWidth != width else { return }
        fittedWidth = width
        let text = TransferFileTitleText.fit(fileName, width: width) {
            ceil(self.attributed($0).size().width * scale) / scale
        }
        attributedText = attributed(text)
        accessibilityLabel = fileName
    }
    private func attributed(_ text: TransferFileTitleText) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text.stem, attributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: primary])
        result.append(NSAttributedString(string: text.suffix, attributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .regular), .foregroundColor: secondary]))
        return result
    }
}
