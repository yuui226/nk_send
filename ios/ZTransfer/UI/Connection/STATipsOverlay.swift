import SwiftUI
import UIKit

/// The STA help content mirrors HomeScreen's TipsBubble. All user-visible copy
/// comes from the Android resource table; this view only provides the iOS
/// presentation and dismissal behavior.
struct STATipsOverlay: View {
    @Binding var isPresented: Bool
    let wirelessMode: WirelessMode
    let anchor: Anchor<CGRect>
    @State private var hotspotHelpVisible = false

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                // Android TipsBubble is a non-dimming AnchorPopup. The clear
                // hit target dismisses it without changing the page colors.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                AdaptiveTipPanel(anchor: anchor, maxWidth: 360, gap: 8) {
                    TipBubbleContent(padding: 18) {
                        tipContent
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var tipContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill").resizable().scaledToFit()
                    .foregroundStyle(ZTransferColors.accentOrange).frame(width: 18, height: 18)
                Text(AppLocalized.resource(wirelessMode == .ap ? "tip_title" : "tip_sta_title"))
                    .zTransferTypography(.titleSmall, weight: .bold)
            }
            if wirelessMode == .ap {
                emphasizedTip(AppLocalized.resource("tip_sta_quick_start"),
                              AppLocalized.resource("tip_sta_quick_enable"))
                    .padding(.top, 10)
            } else {
                Text(AppLocalized.resource("tip_sta_no_mobile_data"))
                    .zTransferTypography(.bodyMedium, weight: .regular)
                    .foregroundStyle(ZTransferColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                emphasizedTip(label: AppLocalized.resource("tip_sta_first_connection")) {
                    VStack(alignment: .leading, spacing: 0) {
                        STAHotspotHelpLine(expanded: hotspotHelpVisible, textColor: ZTransferColors.accentBlue,
                                           font: .systemFont(ofSize: 14, weight: .medium)) {
                            hotspotHelpVisible.toggle()
                        }
                        TipGuideRevealLayout(progress: hotspotHelpVisible ? 1 : 0, fromBottom: true) {
                            Text(AppLocalized.resource("tip_sta_hotspot_help"))
                                .zTransferTypography(.bodySmall, weight: .regular)
                                .foregroundStyle(ZTransferColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                                .opacity(hotspotHelpVisible ? 1 : 0)
                        }
                        .clipped()
                        .accessibilityHidden(!hotspotHelpVisible)
                        Text(AppLocalized.resource("tip_sta_steps_after_hotspot"))
                            .zTransferTypography(.bodyMedium)
                            .foregroundStyle(ZTransferColors.accentBlue)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                }
                .padding(.top, 12)
                emphasizedTip(AppLocalized.resource("tip_sta_quick_start"),
                              AppLocalized.resource("tip_sta_quick_enable"))
                    .padding(.top, 12)
            }
        }
        .foregroundStyle(ZTransferColors.primaryText)
        // Compose fadeIn/out + expand/shrink use the medium-low spring.
        .animation(.interpolatingSpring(mass: 1, stiffness: 400, damping: 40), value: hotspotHelpVisible)
    }

    private func emphasizedTip(_ label: String, _ text: String) -> some View {
        emphasizedTip(label: label) {
            Text(text).zTransferTypography(.bodyMedium).foregroundStyle(ZTransferColors.accentBlue)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emphasizedTip<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).zTransferTypography(.labelSmall).foregroundStyle(ZTransferColors.accentOrange)
            content()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ZTransferColors.primaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

}

/// An inline attachment keeps the question mark inside the paragraph, including
/// narrow screens and translated text. Only the attachment is an action.
struct STAHotspotHelpLine: UIViewRepresentable {
    let expanded: Bool
    var textColor: Color = ZTransferColors.primaryText
    var font: UIFont = .systemFont(ofSize: 14)
    let toggle: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(toggle: toggle) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.isEditable = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.toggle = toggle
        let font = self.font
        let text = NSMutableAttributedString(string: AppLocalized.resource("tip_sta_step_hotspot") + "\u{00A0}",
            attributes: [.font: font, .foregroundColor: UIColor(textColor)])
        let size = font.pointSize * 1.45
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            UIColor(ZTransferColors.accentYellow).withAlphaComponent(expanded ? 1 : 0.82).setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2)).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor(ZTransferColors.onAccent)]
            let glyph = "?" as NSString
            let measured = glyph.size(withAttributes: attributes)
            glyph.draw(at: CGPoint(x: (size - measured.width) / 2, y: (size - measured.height) / 2), withAttributes: attributes)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
        let question = NSMutableAttributedString(attachment: attachment)
        question.addAttribute(.link, value: "ztransfer-help://hotspot", range: NSRange(location: 0, length: question.length))
        text.append(question)
        text.append(NSAttributedString(string: AppLocalized.resource("tip_sta_network_alternative"),
            attributes: [.font: font, .foregroundColor: UIColor(textColor)]))
        view.attributedText = text
        view.linkTextAttributes = [:]
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var toggle: () -> Void
        init(toggle: @escaping () -> Void) { self.toggle = toggle }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            toggle()
            return false
        }
    }
}
