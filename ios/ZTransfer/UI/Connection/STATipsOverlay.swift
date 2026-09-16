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
            ZStack(alignment: .topLeading) {
                // Android TipsBubble is a non-dimming AnchorPopup. The clear
                // hit target dismisses it without changing the page colors.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                AdaptiveTipPanel(anchor: anchor, maxWidth: 360) {
                    tipContent
                        .padding(18)
                        .background(ZTransferGlassSurface(cornerRadius: 18, kind: .panel))
                        .scaleEffect(0.94 + progress * 0.06, anchor: .topLeading)
                }
                    .opacity(progress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                progress = 0
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) { progress = 1 }
            }
    }

    @ViewBuilder
    private var tipContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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
