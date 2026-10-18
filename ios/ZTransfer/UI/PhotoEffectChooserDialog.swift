import SwiftUI
import UIKit

/// LutChooserHeader / PresetCategoryBrowser: bounded dialog with a fixed header,
/// 36:64 independently scrolling columns and no system sheet toolbar.
struct PhotoEffectChooserDialog<Header: View, Content: View>: View {
    let categoryLabels: [String]
    let optionLabels: [String]
    let onDismiss: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let width = min(320, max(1, proxy.size.width - 48))
            let innerWidth = width - 20
            let listHeight = PhotoEffectChooserMetrics.listHeight(
                categoryLabels: categoryLabels, optionLabels: optionLabels,
                width: innerWidth, viewportHeight: proxy.size.height)
            ZStack {
                Color.black.opacity(0.32).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: onDismiss)
                VStack(spacing: 6) {
                    header.frame(height: 32)
                    if listHeight > 0 { content(innerWidth).frame(height: listHeight) }
                }
                .padding(10).frame(width: width)
                .background(ZTransferColors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(
                    scheme == .dark ? .white.opacity(0.15) : .black.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .zIndex(200)
    }
}

enum PhotoEffectChooserMetrics {
    /// Resolve final height before presentation; no GeometryReader feedback
    /// that first stretches the dialog and then shrinks it after a frame.
    static func listHeight(categoryLabels: [String], optionLabels: [String], width: CGFloat,
                           viewportHeight: CGFloat) -> CGFloat {
        let available = max(0, min(max(viewportHeight - 120, 120), 440) - 58)
        let categoryHeight = columnHeight(categoryLabels, width: (width - 6) * 0.36, category: true)
        let optionHeight = columnHeight(optionLabels, width: (width - 6) * 0.64, category: false)
        return min(available, max(categoryHeight, optionHeight))
    }
    private static func columnHeight(_ labels: [String], width: CGFloat, category: Bool) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 14, weight: .medium)
        return labels.reduce(CGFloat(max(0, labels.count - 1)) * 2) { height, label in
            let textHeight = (label as NSString).boundingRect(
                with: CGSize(width: max(1, width - (category ? 16 : 20)), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
            return height + ceil(min(font.lineHeight * 2, max(font.lineHeight, textHeight))) + (category ? 20 : 16)
        }
    }
}

struct PhotoEffectChooserAction: View {
    let label: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(selected ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ZTransferColors.secondaryText.opacity(0.28), lineWidth: 0.75))
        }.buttonStyle(.plain)
    }
}

struct PhotoEffectChooserRow: View {
    let label: String
    var selected = false
    var favorite = false
    var category = false
    var accent = ZTransferColors.accentBlue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(favorite ? ZTransferColors.accentYellow :
                    (selected ? accent : (category ? ZTransferColors.secondaryText : ZTransferColors.primaryText)))
                .padding(.horizontal, category ? 8 : 10).padding(.vertical, category ? 10 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? accent.opacity(category ? 0.14 : 0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
