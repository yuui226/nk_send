import SwiftUI
import UIKit

/// Shared by GPS, STA/AP, both settings pages, the local effects workbench
/// and the rating filter. All seven entries use a static icon/unread dot:
/// the user explicitly disabled bulb breathing app-wide on 2026-10-18.
/// Each caller owns its Android-equivalent persisted viewed flag. Rendering
/// never marks a tip read; only the caller's tap action does so.
struct TipLightbulbButton: View {
    let attention: Bool
    let size: CGFloat
    let accessibilityLabel: String
    var embeddedInPanel = false
    let action: () -> Void
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var iconColor: Color {
        zTransferButtonForeground(
            skin: .init(storedValue: skinPreset),
            scheme: colorScheme,
            fallback: ZTransferColors.accentOrange
        )
    }

    var body: some View {
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
        .accessibilityLabel(accessibilityLabel)
        // User-approved 2026-10-18 power tradeoff: a static unread dot
        // replaces attention breathing. Keep the original glass and icon;
        // read-state changes still apply immediately inside parent transitions.
        .transaction { $0.animation = nil }
    }
}

/// Android AnchorPopup content stays below and clear of its bulb. Measure the
/// natural height and scroll only when the space below cannot fit the text.
struct AdaptiveTipPanel<Content: View>: View {
    let anchor: Anchor<CGRect>
    var maxWidth: CGFloat = 300
    var gap: CGFloat = 8
    /// Space from this overlay's origin to the page bottom, when its parent
    /// is a small card whose bounds do not represent the available viewport.
    var availableHeight: CGFloat? = nil
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let viewportHeight = availableHeight ?? proxy.size.height
            TipPanelViewport(openingAnchor: proxy[anchor], maxWidth: maxWidth,
                             gap: gap, content: content)
                .frame(width: proxy.size.width, height: viewportHeight)
                // A real viewport resize starts a fresh placement. Breathing
                // changes only the live anchor, not this presentation identity.
                .id(proxy.size.width)
                .id(viewportHeight)
        }
    }
}

/// Capture real geometry once per presentation, before the first visible layout.
/// The card may keep breathing without dragging its independent tooltip along.
private struct TipPanelViewport<Content: View>: View {
    @State private var openingAnchor: CGRect
    let maxWidth: CGFloat
    let gap: CGFloat
    let content: Content

    init(openingAnchor: CGRect, maxWidth: CGFloat, gap: CGFloat, content: Content) {
        _openingAnchor = State(initialValue: openingAnchor)
        self.maxWidth = maxWidth
        self.gap = gap
        self.content = content
    }

    var body: some View {
        AdaptiveTipPlacementLayout(anchor: openingAnchor, maxWidth: maxWidth, gap: gap) {
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
            // The viewport owns the rounded shell. A shadow inside the
            // ScrollView is cut to its rectangular bounds, and a tall
            // content-sized shell loses its bottom corners while scrolling.
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background {
                ZTransferGlassSurface(cornerRadius: 18, kind: .panel)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1)
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
            }
            .accessibilityIdentifier("tip-panel")
        }
    }
}

/// A persistent owner drives both insertion and removal for every bulb.
/// Android Motion.overlayExpand/Collapse: 340/260ms, FastOutSlowIn.
/// The user's tooltip rule uses opacity only, without scaling or movement.
struct TipPopupLayer<Content: View>: View {
    let isPresented: Bool
    @ViewBuilder let content: Content
    @State private var inputRetained = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isPresented {
                content.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keep this OUTSIDE the opacity transition: SwiftUI can leave the
        // inserted hosting layer's model alpha at zero until its fade ends.
        // AP/STA tips also need this boundary despite using AdaptiveTipPanel.
        .background { PopupDragBoundary(enabled: isPresented || inputRetained) }
        .task(id: isPresented) {
            if isPresented { inputRetained = true }
            else if inputRetained {
                do { try await Task.sleep(for: .milliseconds(260)) } catch { return }
                guard !Task.isCancelled else { return }
                inputRetained = false
            }
        }
        .onDisappear { inputRetained = false }
        .animation(.timingCurve(0.4, 0, 0.2, 1,
                               duration: isPresented ? 0.34 : 0.26), value: isPresented)
    }
}

/// Content padding shared by the bulbs. The visible shell and shadow belong
/// to AdaptiveTipPanel's viewport, outside the scrolling content.
struct TipBubbleContent<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(ZTransferColors.primaryText)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// Keep each bulb's real layout anchor through the same SwiftUI hierarchy.
/// Resolve it inside the tooltip; no asynchronous CGRect state or zero fallback.
enum TipPopupTrigger: String, Hashable {
    case settings, photoEffects, gps, sta, ap, localEffects, monitor
}

struct TipPopupAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [TipPopupTrigger: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [TipPopupTrigger: Anchor<CGRect>],
                       nextValue: () -> [TipPopupTrigger: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func tipPopupAnchor(_ trigger: TipPopupTrigger) -> some View {
        anchorPreference(key: TipPopupAnchorPreferenceKey.self, value: .bounds) { [trigger: $0] }
            .accessibilityIdentifier("tip-trigger-\(trigger.rawValue)")
    }
}

// Android TipGuideBubble/TipGuideSection (401f55ff). These guides have a fixed
// header, a bounded body and exactly one expanded section. Legacy short tips
// above deliberately retain their independent layout and text hierarchy.
struct TipGuideItem {
    let textKey: String
    var labelKey: String? = nil
    var tool: RemoteTool? = nil
    var mark: String? = nil
}
struct TipGuideSection: Identifiable {
    let id: String
    let items: [TipGuideItem]
}
struct TipGuideState: Equatable {
    private(set) var expanded: String?
    private(set) var reveal: String?
    init(first: String?) { expanded = first }
    mutating func toggle(_ id: String) {
        expanded = expanded == id ? nil : id
        reveal = expanded
    }
    mutating func revealed(_ id: String) { if reveal == id { reveal = nil } }
}

struct TipGuideBubble: View {
    let anchor: Anchor<CGRect>
    let titleKey: String
    let sections: [TipGuideSection]
    var introductionKey: String? = nil
    var alignLeading = false
    var tools: RemoteToolPreferences? = nil
    let close: () -> Void
    var body: some View {
        GeometryReader { proxy in
            TipGuidePlacement(anchor: proxy[anchor], alignLeading: alignLeading,
                              bottomInset: proxy.safeAreaInsets.bottom) {
                TipGuideContent(titleKey: titleKey, sections: sections,
                                introductionKey: introductionKey, tools: tools, close: close)
            }
        }
        .background(PopupDragBoundary())
    }
}

/// Measure the constrained guide synchronously. No preference round trip or
/// full-height placeholder appears when opening or changing a section.
struct TipGuidePlacement: Layout {
    let anchor: CGRect
    var alignLeading = false
    var bottomInset: CGFloat = 0
    static func limits(host: CGSize, anchor: CGRect, bottomInset: CGFloat) -> CGSize {
        CGSize(width: min(420, max(1, host.width - 36)),
               height: max(1, min(560, host.height - bottomInset - 18 - anchor.maxY - 8)))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let limit = Self.limits(host: bounds.size, anchor: anchor, bottomInset: bottomInset)
        let size = child.sizeThatFits(.init(width: limit.width, height: limit.height))
        child.place(at: CGPoint(x: bounds.minX + (alignLeading ? 18 : bounds.width - 18 - limit.width),
                                y: bounds.minY + anchor.maxY + 8), anchor: .topLeading,
                    proposal: .init(width: limit.width, height: min(limit.height, size.height)))
    }
}

struct TipGuideContent: View {
    let titleKey: String
    let sections: [TipGuideSection]
    var introductionKey: String?
    var tools: RemoteToolPreferences?
    let close: () -> Void
    @State private var state: TipGuideState
    @State private var revealCoordinator = TipGuideRevealCoordinator()
    init(titleKey: String, sections: [TipGuideSection], introductionKey: String? = nil,
         tools: RemoteToolPreferences? = nil, close: @escaping () -> Void) {
        self.titleKey = titleKey; self.sections = sections; self.introductionKey = introductionKey
        self.tools = tools; self.close = close
        _state = State(initialValue: .init(first: sections.first?.id))
    }
    var body: some View {
        TipGuideViewportLayout {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill").resizable().scaledToFit()
                    .foregroundStyle(ZTransferColors.accentOrange).frame(width: 18, height: 18)
                Text(AppLocalized.resource(titleKey)).zTransferTypography(.titleSmall, weight: .bold)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 18))
                        .foregroundStyle(ZTransferColors.secondaryText).frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(AppLocalized.resource("cd_close"))
            }.padding(.horizontal, 18).padding(.top, 12)
            guideBody(measuring: true).hidden().allowsHitTesting(false).accessibilityHidden(true)
            ScrollView(.vertical, showsIndicators: false) { guideBody(measuring: false) }
                .task(id: state.reveal) {
                    revealCoordinator.stop()
                    guard let id = state.reveal else { return }
                    try? await Task.sleep(for: .milliseconds(240))
                    guard !Task.isCancelled, state.expanded == id, state.reveal == id else { return }
                    revealCoordinator.reveal(id)
                }

        }
        .foregroundStyle(ZTransferColors.primaryText)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .background {
            ZTransferGlassSurface(cornerRadius: 18, kind: .panel)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        }
        .contentShape(Rectangle())
        // Absorb blank-area drags behind the content, not on the ancestor of
        // the scroll view and its expanding section buttons.
        .background {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 10).onChanged { _ in })
        }
        .onDisappear { revealCoordinator.stop() }
        .accessibilityIdentifier("tip-guide-panel")
    }
    private func guideBody(measuring: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let introductionKey {
                Text(AppLocalized.resource(introductionKey)).zTransferTypography(.bodySmall, weight: .regular)
                    .foregroundStyle(ZTransferColors.secondaryText).padding(.bottom, 10)
            }
            ForEach(sections) { section in
                TipGuideSectionView(section: section, expanded: state.expanded == section.id,
                                    tools: tools, measuring: measuring, revealCoordinator: revealCoordinator) { state.toggle(section.id) }
            }
        }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The measured body and scroll viewport share one expansion state; the
/// invisible copy has no gestures, subscriptions, clocks or accessibility.
private struct TipGuideViewportLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = proposal.width ?? 300
        let p = ProposedViewSize(width: width, height: nil)
        return CGSize(width: width, height: min(proposal.height ?? 560,
            subviews[0].sizeThatFits(p).height + subviews[1].sizeThatFits(p).height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let p = ProposedViewSize(width: bounds.width, height: nil)
        let header = min(bounds.height, subviews[0].sizeThatFits(p).height)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: header))
        subviews[1].place(at: CGPoint(x: bounds.minX - bounds.width - 1, y: bounds.minY), anchor: .topLeading, proposal: p)
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + header), anchor: .topLeading,
                          proposal: .init(width: bounds.width, height: max(0, bounds.height - header)))
    }
}

private struct TipGuideSectionView: View {
    let section: TipGuideSection
    let expanded: Bool
    var tools: RemoteToolPreferences?
    let measuring: Bool
    let revealCoordinator: TipGuideRevealCoordinator
    let toggle: () -> Void
    @State private var retained: Bool
    init(section: TipGuideSection, expanded: Bool, tools: RemoteToolPreferences?, measuring: Bool,
         revealCoordinator: TipGuideRevealCoordinator, toggle: @escaping () -> Void) {
        self.section = section; self.expanded = expanded; self.tools = tools; self.measuring = measuring
        self.revealCoordinator = revealCoordinator; self.toggle = toggle
        _retained = State(initialValue: expanded)
    }
    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(AppLocalized.resource(section.id)).zTransferTypography(.bodyMedium, weight: .semibold)
                        .foregroundStyle(expanded ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
                    Image(systemName: "chevron.down").font(.system(size: 14)).frame(width: 18, height: 18)
                        .foregroundStyle(ZTransferColors.secondaryText).rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22), value: expanded)
                }.padding(10).frame(minHeight: 48)
                    .background(expanded ? ZTransferColors.accentBlue.opacity(0.07) : .clear,
                                in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
            }.buttonStyle(.plain).id(section.id)
                .background { if !measuring { TipGuideHeadingAnchor(id: section.id, owner: revealCoordinator) } }
                .accessibilityHint(AppLocalized.resource(expanded ? "cd_collapse" : "cd_expand"))
            TipGuideRevealLayout(progress: expanded ? 1 : 0) {
                if expanded || retained {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 12) {
                            if let tool = item.tool {
                                if measuring { Color.clear.frame(width: 36, height: 36) }
                                else { TipGuideToolMark(tool: tool, tools: tools).frame(width: 36, height: 36) }
                            } else if let mark = item.mark {
                                if measuring { Color.clear.frame(width: 36, height: 36) }
                                else { TipGuideToolMark(mark: mark).frame(width: 36, height: 36) }
                            }
                            (Text(item.labelKey.map { AppLocalized.resource($0) + "  " } ?? "").fontWeight(.semibold)
                                .foregroundColor(ZTransferColors.primaryText)
                             + Text(AppLocalized.resource(item.textKey)))
                                .zTransferTypography(.bodyMedium, weight: .regular).foregroundStyle(ZTransferColors.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 12)
                    .opacity(expanded ? 1 : 0)
                    .animation(.timingCurve(0.4, 0, 0.2, 1, duration: expanded ? 0.18 : 0.12), value: expanded)
                }
            }.clipped().animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.24), value: expanded)
                .allowsHitTesting(expanded && !measuring).accessibilityHidden(!expanded || measuring)
        }
        .task(id: expanded) {
            if expanded { retained = true }
            else if retained {
                try? await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled else { return }
                retained = false
            }
        }
    }
}
private struct TipGuideRevealLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.first?.sizeThatFits(.init(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: natural.width, height: natural.height * max(0, min(1, progress)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
    }
}
private struct TipGuideToolMark: View {
    var tool: RemoteTool? = nil
    var tools: RemoteToolPreferences? = nil
    var mark: String? = nil
    var body: some View {
        RemoteMonitorToolButton(active: false, enabled: true, fixed: tool?.fixed ?? false,
            preserveContentColors: tool == .pictureControl, accessibilityLabel: "", label: {
                if tool == .focusMode { Text("AF-S").font(.system(size: 8, weight: .bold)) }
                else if let tool {
                    RemoteToolMark(tool: tool, histogramRGB: tools?.histogram == .rgb,
                        waveformRGB: tools?.waveform == .rgb, falseColor: tools?.exposure == .falseColor,
                        grid: tools?.grid ?? .off, desqueeze: tools?.desqueeze ?? 1, locked: tools?.locked ?? false)
                } else if mark == "manage" { RemoteEditorIcon(kind: .settings).fill(ZTransferColors.secondaryText).frame(width: 19, height: 19) }
                else { Text("DISP").font(.system(size: 8, weight: .bold)) }
            }, action: {}).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A full modal region also blocks the native Home pager before it recognizes
/// a drag. It does not intercept help buttons or the guide's own scroll view.
struct PopupDragBoundary: UIViewRepresentable {
    var enabled = true
    func makeUIView(context: Context) -> PopupDragBoundaryView { PopupDragBoundaryView() }
    func updateUIView(_ uiView: PopupDragBoundaryView, context: Context) { uiView.blocksGestures = enabled }
}
final class PopupDragBoundaryView: UIView {
    var blocksGestures = true
    private static let regions = NSHashTable<PopupDragBoundaryView>.weakObjects()
    init() { super.init(frame: .zero); isUserInteractionEnabled = false; Self.regions.add(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func contains(_ point: CGPoint, in source: UIView? = nil) -> Bool {
        regions.allObjects.contains { region in
            guard region.blocksGestures, let window = region.window, source == nil || (source as? UIWindow ?? source?.window) === window else { return false }
            var ancestor: UIView? = region
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0.01 { return false }
                ancestor = view.superview
            }
            return region.bounds.contains(region.convert(point, from: source ?? window))
        }
    }
}

/// Resource order/conditions from SettingsScreen and RemoteMonitorHelp. Apple
/// subscription management replaces Android renewal/code-transfer/update help
/// under the existing independent-StoreKit platform agreement.
enum TipGuides {
    private static func item(_ label: String, _ text: String) -> TipGuideItem {
        .init(textKey: text, labelKey: label)
    }
    static func settings(showEffects: Bool, isPro: Bool, showManagement: Bool) -> [TipGuideSection] {
        var sections = [TipGuideSection(id: "settings_help_transfer", items: [
            item("transfer_directory", "settings_help_directory"), item("storage_mode", "storage_mode_summary"),
            item("auto_transfer_new_media", "auto_transfer_new_media_summary"), item("defer_transfer_start", "defer_transfer_start_summary")]),
            TipGuideSection(id: "settings_help_photos", items: [item("columns", "settings_help_columns"),
                item("collapse_burst_photos", "collapse_burst_photos_summary"), item("photo_interaction", "settings_help_interaction"),
                item("photo_loading_range", "settings_help_loading_range")])]
        if showEffects { sections.append(.init(id: "settings_help_effects", items: [
            item("settings_help_effects_switch", "settings_help_effects_master"), item("photo_effects_open_editor", "settings_help_effects_editor")])) }
        sections.append(.init(id: "settings_help_appearance", items: [
            item("light_dark_mode", "settings_help_theme"), item("language", "settings_help_language"),
            item("button_style", "settings_help_skin"), item("haptic_feedback", "settings_help_haptics"),
            item("keep_screen_on", "settings_help_screen")]))
        var more: [TipGuideItem] = []
        if !isPro { more.append(item("unlock_pro", "settings_help_pro")) }
        if showManagement { more.append(item("iap_manage", "iap_renewal_terms")) }
        more.append(item("feedback", "settings_help_feedback"))
        sections.append(.init(id: "settings_help_more", items: more))
        return sections
    }
    static func effects(local: Bool) -> [TipGuideSection] {
        let hints = local ? ["local_photo_effects_info_description", "local_photo_effects_exif_hint", "local_photo_ios_save_hint"] : ["photo_effects_info_description"]
        return [.init(id: "photo_effects_help_use", items: hints.map { .init(textKey: $0) } + [
            item("help_preview_label", local ? "local_photo_effects_gesture_hint" : "photo_effects_gesture_hint")]),
            .init(id: "photo_effects_help_color", items: [item("photo_effect_module_filter", "photo_effects_help_filters"),
                item("lut_folder", "photo_lut_help"), item("photo_lut_settings", "photo_effects_help_lut_settings")]),
            .init(id: "photo_effects_help_decoration", items: [item("photo_frame_style_short", "photo_effects_help_frame"),
                item("photo_frame_watermark_short", "photo_effects_help_watermark")]),
            .init(id: "photo_effects_help_shortcuts", items: [item("photo_effect_modules", "photo_effects_help_modules"),
                item("help_favorites_label", "photo_effects_help_favorites"), item("help_wheels_label", "photo_effects_wheel_hint")])]
    }
    static var monitor: [TipGuideSection] {
        func tool(_ tool: RemoteTool) -> TipGuideItem {
            .init(textKey: "monitor_help_tool_" + tool.rawValue, labelKey: tool.titleKey, tool: tool)
        }
        return [.init(id: "monitor_help_section_basic", items: ["capture", "focus", "parameters", "review", "status"].map {
            item("monitor_help_\($0)_label", "monitor_help_\($0)") }),
            .init(id: "monitor_help_section_camera", items: [.whiteBalance, .focusMode, .focusArea, .focusFrame, .pictureControl, .computerControl].map(tool)),
            .init(id: "monitor_help_section_exposure", items: [.histogram, .exposure, .meter, .waveform, .lut].map(tool)),
            .init(id: "monitor_help_section_display", items: [.hd, .fps, .audio].map(tool)),
            .init(id: "monitor_help_section_layout", items: [.grid, .level, .desqueeze, .lock, .rotate].map(tool) + [
                .init(textKey: "monitor_help_manage", labelKey: "remote_tool_manage", mark: "manage"),
                .init(textKey: "monitor_help_disp", labelKey: "monitor_help_disp_label", mark: "disp")])]
    }
}

/// Compose BringIntoViewSpec/UpdatableAnimationState: minimum edge distance,
/// spring() (1500, damping=1), preserve velocity while recomputing geometry,
/// 0.01 physical-pixel finish. No animation is started for a visible heading.
@MainActor final class TipGuideRevealCoordinator {
    private let headings = NSMapTable<NSString, UIView>.strongToWeakObjects()
    private weak var heading: UIView?
    private weak var scroll: UIScrollView?
    private var link: CADisplayLink?
    private var previousNanos: Int64?
    private var velocity: Float = 0
    private var fractionalPixels: CGFloat = 0
    var clockRunning: Bool { link != nil }
    func register(_ view: UIView, id: String) { headings.setObject(view, forKey: id as NSString) }
    static func distance(offset: CGFloat, size: CGFloat, container: CGFloat) -> CGFloat {
        let end = offset + size
        if offset >= 0 && end <= container || offset < 0 && end > container { return 0 }
        return abs(offset) < abs(end - container) ? offset : end - container
    }
    func reveal(_ id: String) {
        stop()
        guard let heading = headings.object(forKey: id as NSString), heading.window != nil else { return }
        var parent = heading.superview
        while parent != nil, !(parent is UIScrollView) { parent = parent?.superview }
        guard let scroll = parent as? UIScrollView else { return }
        self.heading = heading; self.scroll = scroll
        guard abs(distance()) > 0 else { return }
        link = ZTransferDisplayLink.make(owner: self) { $0.advance(Int64($1.timestamp * 1_000_000_000)) }
        link?.add(to: .main, forMode: .common)
    }
    private func distance() -> CGFloat {
        guard let heading, let scroll else { return 0 }
        let frame = heading.convert(heading.bounds, to: scroll)
        return Self.distance(offset: frame.minY - scroll.bounds.minY, size: frame.height, container: scroll.bounds.height)
    }
    func advance(_ nanos: Int64) {
        guard let scroll, heading?.window != nil, !scroll.isTracking, !scroll.isDragging else { stop(); return }
        let scale = scroll.window?.screen.scale ?? 1
        let remaining = Float(distance() * scale - fractionalPixels)
        guard abs(remaining) >= 0.01 else {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + distance()), animated: false)
            stop(); return
        }
        let delta = max(0, nanos - (previousNanos ?? nanos)); previousNanos = nanos
        let sample = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 1500)
            .animationSample(at: delta, from: remaining, to: 0, velocity: velocity)
        velocity = sample.velocity
        // UIScrollView rounds its model offset to pixels. Keep the fraction
        // that was not consumed, as Compose's scroll state does, so the final
        // pixel cannot restart the spring forever.
        let next = scroll.contentOffset.y + (fractionalPixels + CGFloat(remaining - sample.value)) / scale
        let clamped = min(max(-scroll.adjustedContentInset.top, next),
                          max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom))
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: clamped), animated: false)
        fractionalPixels = (clamped - scroll.contentOffset.y) * scale
        if clamped != next { stop() }
    }
    func stop() {
        link?.invalidate(); link = nil; previousNanos = nil; velocity = 0; fractionalPixels = 0
        heading = nil; scroll = nil
    }
}
private struct TipGuideHeadingAnchor: UIViewRepresentable {
    let id: String
    let owner: TipGuideRevealCoordinator
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        owner.register(view, id: id); return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { owner.register(uiView, id: id) }
}
