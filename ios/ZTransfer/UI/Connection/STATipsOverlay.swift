import SwiftUI

/// The STA help content mirrors HomeScreen's TipsBubble. All user-visible copy
/// comes from the Android resource table; this view only provides the iOS
/// presentation and dismissal behavior.
struct STATipsOverlay: View {
    @Binding var isPresented: Bool
    let wirelessMode: WirelessMode
    let anchor: CGRect
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let panelTop = resolvedPanelTop(in: proxy.size)
            ZStack(alignment: .topLeading) {
                // Android TipsBubble is a non-dimming AnchorPopup. The clear
                // hit target dismisses it without changing the page colors.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                tipContent(maxHeight: max(120, proxy.size.height - panelTop - 20))
                    .frame(width: min(360, max(0, proxy.size.width - 40)), alignment: .leading)
                    .padding(18)
                    .background(ZTransferGlassSurface(cornerRadius: 18, kind: .panel))
                    .scaleEffect(0.94 + progress * 0.06, anchor: .topLeading)
                    .opacity(progress)
                    .offset(x: 20, y: panelTop)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                progress = 0
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) { progress = 1 }
            }
        }
    }

    @ViewBuilder
    private func tipContent(maxHeight: CGFloat) -> some View {
        let content = VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalized.resource(wirelessMode == .ap ? "tip_title" : "tip_sta_title"))
                .zTransferTypography(.titleMedium, weight: .bold)
            if wirelessMode == .ap {
                tipBlock(label: AppLocalized.resource("tip_ap_mode"), body: AppLocalized.resource("tip_body"))
                Text(AppLocalized.resource("tip_path"))
                    .zTransferTypography(.bodySmall)
                    .foregroundStyle(ZTransferColors.secondaryText)
            } else {
                tipBlock(
                    label: AppLocalized.resource("tip_sta_first_connection"),
                    body: AppLocalized.resource("tip_sta_step_hotspot") + "\n" + AppLocalized.resource("tip_sta_network_alternative"),
                    detail: AppLocalized.resource("tip_sta_hotspot_help")
                )
                tipBlock(label: AppLocalized.resource("tip_sta_quick_start"), body: AppLocalized.resource("tip_sta_steps_after_hotspot"))
                Text(AppLocalized.resource("tip_path"))
                    .zTransferTypography(.bodySmall)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
        }
        .foregroundStyle(ZTransferColors.primaryText)
        if wirelessMode == .sta {
            ScrollView(.vertical, showsIndicators: false) { content }
                .frame(maxHeight: maxHeight)
        } else {
            content
        }
    }

    private func resolvedPanelTop(in size: CGSize) -> CGFloat {
        let anchored = anchor == .zero
            ? (wirelessMode == .sta ? 156 : 160)
            : (wirelessMode == .sta ? anchor.maxY - 144 : anchor.maxY + 24)
        return min(max(20, anchored), max(20, size.height - 120))
    }

    @ViewBuilder
    private func tipBlock(label: String, body: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).zTransferTypography(.labelMedium, weight: .bold)
                .foregroundStyle(ZTransferColors.accentOrange)
            Text(body).zTransferTypography(.bodySmall)
                .foregroundStyle(ZTransferColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).zTransferTypography(.labelSmall)
                    .foregroundStyle(ZTransferColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dismiss() {
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.18)) { progress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { isPresented = false }
    }
}
