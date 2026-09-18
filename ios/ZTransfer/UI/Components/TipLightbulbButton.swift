import SwiftUI
import UIKit

/// Shared by GPS, STA/AP, both settings pages and the local effects workbench.
/// Each caller owns its Android-equivalent persisted viewed flag. Rendering
/// never marks a tip read; only the caller's tap action does so.
struct TipLightbulbButton: View {
    let attention: Bool
    let size: CGFloat
    let accessibilityLabel: String
    var motionPaused = false
    var embeddedInPanel = false
    let action: () -> Void
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.frostedGlass.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var attentionOrigin = Date()
    @State private var frozenDate: Date?

    private var iconColor: Color {
        zTransferButtonForeground(
            skin: .init(storedValue: skinPreset),
            scheme: colorScheme,
            fallback: ZTransferColors.accentOrange
        )
    }

    var body: some View {
        TimelineView(.animation(paused: !attention || motionPaused || scenePhase != .active)) { context in
            let sampleDate = motionPaused ? (frozenDate ?? context.date) : context.date
            let values = attention
                ? TipAttentionValues(elapsed: sampleDate.timeIntervalSince(attentionOrigin))
                : .read
            Button(action: action) {
                Image(systemName: "lightbulb.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(iconColor)
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
            .buttonStyle(ZTransferGlassButtonStyle(
                tint: iconColor,
                cornerRadius: 12,
                panel: embeddedInPanel,
                materialContentColor: iconColor
            ))
            // Keep the complete glass tile as the physical touch target. The
            // icon and unread-dot overlays are purely visual and must not
            // reduce the tappable region inside transformed popup hosts.
            .contentShape(Rectangle())
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
        .onChange(of: motionPaused) { paused in
            let now = Date()
            if paused {
                frozenDate = now
            } else if let frozenDate {
                // Remove the time spent inside the popup mesh transition from
                // the attention clock. The live bulb resumes from the exact
                // snapshot phase instead of flashing to a differently sized
                // dot at the mesh/live hand-off.
                attentionOrigin = attentionOrigin.addingTimeInterval(now.timeIntervalSince(frozenDate))
                self.frozenDate = nil
            }
        }
    }
}

/// Android AnchorPopup content stays below and clear of its bulb. Measure the
/// natural height and scroll only when the space below cannot fit the text.
struct AdaptiveTipPanel<Content: View>: View {
    let anchor: CGRect
    var maxWidth: CGFloat = 300
    var gap: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            AdaptiveTipPlacementLayout(anchor: anchor, maxWidth: maxWidth, gap: gap) {
                // Layout measures this copy synchronously, then places only
                // the ScrollView below. Unlike a PreferenceKey round trip,
                // the visible viewport can never be left at zero height.
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// One shared visual shell for every lightbulb help panel. Callers may vary
/// their copy and maximum width, but never their presentation material,
/// corner shape, border or shadow.
struct TipBubbleSurface<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(ZTransferColors.primaryText)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZTransferGlassSurface(cornerRadius: 18, kind: .panel))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
    }
}

private struct AdaptiveTipPlacementLayout: Layout {
    let anchor: CGRect
    let maxWidth: CGFloat
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let width = min(maxWidth, max(1, bounds.width - 24))
        let natural = subviews[0].sizeThatFits(
            ProposedViewSize(width: width, height: nil)
        )
        // Every bulb panel belongs below its trigger. Do not flip above or
        // move the anchor when space is tight; constrain only the scrollable
        // content height and preserve the same small visual gap.
        let availableHeight = max(1, bounds.maxY - anchor.maxY - gap - 12)
        let height = min(max(1, natural.height), availableHeight)
        let left = min(
            max(bounds.minX + 12, anchor.midX - width / 2),
            max(bounds.minX + 12, bounds.maxX - width - 12)
        )
        let top = anchor.maxY + gap

        // The hidden copy participates only in measurement.
        subviews[0].place(
            at: CGPoint(x: bounds.minX - width - 1, y: bounds.minY - natural.height - 1),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: natural.height)
        )
        subviews[1].place(
            at: CGPoint(x: left, y: top),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: height)
        )
    }
}
