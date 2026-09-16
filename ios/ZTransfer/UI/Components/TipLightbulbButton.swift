import SwiftUI

/// Shared by GPS, STA/AP, both settings pages and the local effects workbench.
/// Each caller owns its Android-equivalent persisted viewed flag. Rendering
/// never marks a tip read; only the caller's tap action does so.
struct TipLightbulbButton: View {
    let attention: Bool
    let size: CGFloat
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var attentionOrigin = Date()

    var body: some View {
        TimelineView(.animation(paused: !attention || scenePhase != .active)) { context in
            let values = attention
                ? TipAttentionValues(elapsed: context.date.timeIntervalSince(attentionOrigin))
                : .read
            Button(action: action) {
                Image(systemName: "lightbulb.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.45, height: size * 0.45)
                    .frame(width: size, height: size)
                    .overlay(alignment: .topTrailing) {
                        if attention {
                            Circle()
                                .fill(Color(red: 1, green: 77.0 / 255, blue: 61.0 / 255))
                                .frame(width: 7, height: 7)
                                .scaleEffect(values.dotScale)
                                .opacity(values.dotOpacity)
                                .padding(.top, 5)
                                .padding(.trailing, 5)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(ZTransferGlassButtonStyle(tint: ZTransferColors.accentOrange, cornerRadius: 12))
            .scaleEffect(values.buttonScale)
            .accessibilityLabel(accessibilityLabel)
            // Parent popup animations must not animate the read-state reset
            // or interpolate the frame-by-frame attention clock a second time.
            .transaction { $0.animation = nil }
        }
        .onAppear { attentionOrigin = Date() }
        .onChange(of: attention) { unread in
            if unread { attentionOrigin = Date() }
        }
    }
}
