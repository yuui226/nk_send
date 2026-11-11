import SwiftUI
import UIKit

enum PhotoEffectControlMetrics {
    static let height: CGFloat = 50
    static let gap: CGFloat = 8
    // Android SettingsScreen expanded frame/watermark parameters, and
    // PhotoLutEditor expanded LUT parameters. Main selection rows stay 50pt.
    static let parameterWheel = DetentWheelSizing(height: 34, rowHeight: 18, cornerRadius: 10, fontSize: 12, fontWeight: .medium)
    static let lutParameterWheel = DetentWheelSizing(height: 34, rowHeight: 16, cornerRadius: 10, fontSize: 13)
}

/// Installs the focus-dismiss tap behind interactive content. Unlike a tap
/// gesture on the enclosing ScrollView, child TextFields, buttons and wheels
/// remain the hit-test winner; only otherwise empty content reaches this layer.
extension View {
    func photoEffectsBackgroundFocusDismiss(_ action: @escaping () -> Void) -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        }
    }
}

/// Android WatermarkTextField waits one frame + 180 ms after focus, then
/// brings its entire 34 dp control into view. Native TextField scrolling can
/// expose only the glyphs, leaving the surrounding control behind QuickType.
/// Keep the request local to the existing scroll view in both editor entries.
private struct PhotoEffectsFocusedFieldVisibility: UIViewRepresentable {
    let focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> PhotoEffectsFocusedFieldVisibilityProbe {
        PhotoEffectsFocusedFieldVisibilityProbe()
    }

    func updateUIView(_ view: PhotoEffectsFocusedFieldVisibilityProbe, context: Context) {
        view.configure(focused: focused, active: scenePhase == .active)
    }

    static func dismantleUIView(_ view: PhotoEffectsFocusedFieldVisibilityProbe, coordinator: ()) {
        view.cancel()
    }
}

@MainActor
final class PhotoEffectsFocusedFieldVisibilityProbe: UIView {
    private var focusRequested = false
    private var active = false
    private var frameLink: CADisplayLink?
    private var requestTask: Task<Void, Never>?
    #if DEBUG
    var keyboardFrameInWindowOverride: CGRect?
    #endif

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(focused: Bool, active: Bool) {
        guard self.focusRequested != focused || self.active != active else { return }
        self.focusRequested = focused
        self.active = active
        schedule()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        schedule()
    }

    func cancel() {
        frameLink?.invalidate()
        frameLink = nil
        requestTask?.cancel()
        requestTask = nil
    }

    private func schedule() {
        cancel()
        guard focusRequested, active, window != nil else { return }
        let link = ZTransferDisplayLink.make(owner: self) { owner, link in
            link.invalidate()
            owner.frameLink = nil
            owner.requestTask = Task { [weak owner] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard !Task.isCancelled, let owner, owner.focusRequested, owner.active,
                      owner.window != nil else { return }
                owner.requestTask = nil
                owner.revealControl()
            }
        }
        frameLink = link
        link.add(to: .main, forMode: .common)
    }

    private func revealControl() {
        guard let window, let root = window.rootViewController?.view else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView else { return }

        // UIKit's guide includes the keyboard's accessory/suggestion area.
        // Do not use XCUI's main-key frame or change either host's safe area.
        let guide = root.keyboardLayoutGuide
        window.layoutIfNeeded()
        var keyboard = root.convert(guide.layoutFrame, to: scroll)
        #if DEBUG
        if let keyboardFrameInWindowOverride {
            keyboard = window.convert(keyboardFrameInWindowOverride, to: scroll)
        }
        #endif
        let viewport = scroll.bounds.inset(by: scroll.adjustedContentInset)
        var target = convert(bounds, to: scroll)
        guard target.width > 0, target.height > 0 else { return }
        if keyboard.height > 0, keyboard.minY < viewport.maxY, keyboard.maxY > viewport.minY,
           keyboard.minX < target.maxX, keyboard.maxX > target.minX {
            // Extend the request by only the occluded viewport portion. Native
            // scrolling then makes the full control clear the keyboard with
            // the minimum offset, even in hosts that manage their own insets.
            target.size.height += viewport.maxY - max(viewport.minY, keyboard.minY)
        }
        scroll.scrollRectToVisible(target, animated: true)
    }
}

/// Android SettingsScreen.PhotoFilterEditor / PhotoFrameWatermarkEditor are
/// shared by transfer settings and LocalPhotoEffectsPage. The caller owns the
/// draft, persistence scope, keyboard focus, and image picker lifecycle.
struct PhotoEffectsControls: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var entitlements = PremiumEntitlementStore.shared
    @State private var premiumHint: PhotoEffectsHint?
    @Binding var draft: PhotoEffectsSettings
    @Binding var showingWatermarkPicker: Bool
    @FocusState.Binding var textFieldFocused: Bool
    var showLocationFields = false
    var imageImporting = false
    @State private var metadataExpanded = false
    @State private var watermarkExpanded = false
    let photoLUTEditor: PhotoLUTEditorState
    private var photoLUTStore: PhotoLUTStore { photoLUTEditor.store }
    let photoFilterSession: PhotoFilterEditorSession
    let onFilterFavorite: (PhotoFilterSelection) -> Void
    var onWatermarkTextCommitted: (String) -> Void = { _ in }
    var onFavoriteImageMissing: () -> Void = {}

    private var visibleModules: Int { effectivePhotoEffectModules(draft.photoEffectModules, isPro: isPro) }
    private var showFrame: Bool { photoEffectModuleIsVisible(visibleModules, .frame) }
    private var showWatermark: Bool { photoEffectModuleIsVisible(visibleModules, .watermark) }
    private var frameEnabled: Bool { showFrame && draft.photoFrameEnabled && draft.photoFrameBorderEnabled }
    private var isPro: Bool { entitlements.access.isPro }
    private var colorEditorVisibility: PhotoColorEffectEditorVisibility {
        .init(settings: draft, isPro: isPro)
    }
    private var shownWatermark: PhotoFrameWatermark {
        effectivePhotoEffectsSettings(draft, isPro: isPro).watermark
    }
    private var watermarkEnabled: Bool { showWatermark && draft.photoFrameEnabled && shownWatermark.enabled }
    private var activeMetadata: PhotoFrameMetadataSettings {
        draft.metadataByPreset[draft.photoFramePreset.rawValue] ?? PhotoFrameMetadataSettings.defaults(for: draft.photoFramePreset)
    }
    private var orderedFrameOptions: [PhotoFramePreset?] {
        [nil] + draft.orderedFramePresets
    }
    private var photoWatermarkPositions: [PhotoFrameWatermarkPosition] {
        [.photoTopLeft, .photoTopCenter, .photoTopRight, .photoCenter,
         .photoBottomLeft, .photoBottomCenter, .photoBottomRight]
    }
    private var textWatermarkPositions: [PhotoFrameWatermarkPosition] {
        frameEnabled ? PhotoFrameWatermarkPosition.allCases : photoWatermarkPositions
    }
    private func updateMetadata(_ update: (inout PhotoFrameMetadataSettings) -> Void) {
        var value = draft
        var metadata = activeMetadata
        update(&metadata)
        value.metadata = metadata
        value.metadataByPreset[value.photoFramePreset.rawValue] = metadata
        if let index = value.favoriteFrameEffects.firstIndex(where: { $0.preset == value.photoFramePreset }) {
            value.favoriteFrameEffects[index].updateFrameMetadata(metadata)
        }
        draft = value
    }
    private func updateWatermark(_ update: (inout PhotoFrameWatermark) -> Void) {
        guard isPro else { return }
        var value = draft
        update(&value.watermark)
        if frameEnabled, let index = value.favoriteFrameEffects.firstIndex(where: { $0.preset == value.photoFramePreset }) {
            value.favoriteFrameEffects[index].watermark = value.watermark
        }
        draft = value
    }

    var body: some View {
        VStack(spacing: 0) {
            PhotoEffectModuleSection(visible: colorEditorVisibility.filter) {
                PhotoNP3Chooser(session: photoFilterSession, draft: $draft, onFavorite: onFilterFavorite)
            }
            PhotoEffectModuleSection(visible: colorEditorVisibility.lut) {
                PhotoLUTChooser(editor: photoLUTEditor, draft: $draft)
            }
            PhotoEffectModuleSection(visible: photoEffectModuleIsVisible(visibleModules, .grain)) {
                grainCard
            }
            frameCard
        }
        .onChange(of: colorEditorVisibility) { visibility in
            // Cancel immediately when a module leaves, before its 240ms exit
            // transition disposes the retained content.
            if !visibility.lut { photoLUTEditor.close() }
        }
        .photoEffectsHint($premiumHint, duration: 2)
        .onChange(of: draft.selectedFilter) { selection in
            // Covers both the wheel and the category chooser. A newly selected
            // NP3 must not leave a role recipe that restores the previous Cube.
            if let selection, !selection.preset.id.hasPrefix("cube:") {
                photoLUTEditor.cancelPending()
                photoLUTStore.select(nil)
            }
        }
        .onChange(of: entitlements.entitlement) { _ in
            if !isPro { textFieldFocused = false; showingWatermarkPicker = false }
        }
        .onChange(of: textFieldFocused) { focused in
            guard !focused, isPro else { return }
            let text = draft.watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? PhotoFrameWatermark.defaultText : draft.watermark.text
            if text != draft.watermark.text { updateWatermark { $0.text = text } }
            onWatermarkTextCommitted(text)
        }
        .onChange(of: frameEnabled) { value in
            if !value { metadataExpanded = false }
        }
        .onChange(of: watermarkEnabled) { value in
            if !value { watermarkExpanded = false }
        }
    }

    private var grainCard: some View {
        // Android PhotoGrainEditor: muted olive, two compact wheels, 3:2.
        let accent = colorScheme == .dark
            ? Color(red: 227 / 255, green: 238 / 255, blue: 187 / 255)
            : Color(red: 89 / 255, green: 104 / 255, blue: 45 / 255)
        let style = draft.photoGrain.style
        return PhotoEffectsCard(accent: accent) {
            PhotoEffectControlRow(primaryWeight: 3, secondaryWeight: 2) {
                DetentWheel(label: AppLocalized.resource("photo_grain"),
                    options: [nil] + PhotoGrainStyle.allCases.map(Optional.some),
                    selected: draft.photoGrain.enabled ? style : nil,
                    optionLabel: { AppLocalized.resource($0?.localizationKey ?? "setting_off") },
                    onCommit: { selected in
                        var value = draft
                        value.photoGrain = value.photoGrain.selecting(selected, memories: value.grainIntensities)
                        value.grainIntensities[value.photoGrain.style.rawValue] = value.photoGrain.normalizedIntensity
                        draft = value
                    }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: accent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photo-grain-style")
                DetentWheel(label: AppLocalized.resource("photo_filter_intensity"),
                    options: Array(stride(from: 100, through: 0, by: -1)), selected: draft.photoGrain.normalizedIntensity,
                    optionLabel: { "\($0)%" }, onCommit: { intensity in
                        guard draft.photoGrain.enabled, draft.photoGrain.style == style else { return }
                        var value = draft
                        value.photoGrain = value.photoGrain.changingIntensity(intensity, for: style)
                        value.grainIntensities[style.rawValue] = value.photoGrain.normalizedIntensity
                        draft = value
                    }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height,
                    enabled: draft.photoGrain.enabled, accentColor: accent)
                    .id(style)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("photo-grain-intensity")
            }
        }
    }

    private var frameCard: some View {
        PhotoEffectModuleSection(visible: showFrame || showWatermark, spacing: 0) {
            PhotoEffectsCard(accent: ZTransferColors.accentOrange) {
                VStack(spacing: 0) {
                    PhotoEffectModuleSection(visible: showFrame, spacing: 0) {
                        VStack(spacing: 0) { frameControls }
                    }
                    PhotoEffectModuleSection(visible: showWatermark, spacing: 0) {
                        VStack(spacing: 0) {
                            PhotoEffectModuleSection(visible: showFrame, spacing: 0) {
                                Color.clear.frame(height: 8)
                            }
                            watermarkControls
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var frameControls: some View {
        PhotoEffectControlRow {
            DetentWheel(label: AppLocalized.resource("photo_frame_style_short"), options: orderedFrameOptions,
                        selected: frameEnabled ? draft.photoFramePreset : nil,
                        optionLabel: { $0.map(frameName) ?? AppLocalized.resource("photo_frame_off") }, onCommit: { value in
                            textFieldFocused = false
                            var updated = draft
                            guard let value else {
                                updated.photoFrameBorderEnabled = false
                                updated.photoFrameEnabled = isPro && updated.watermark.enabled
                                draft = updated
                                return
                            }
                            if isPro, showWatermark, let favorite = updated.favoriteFrameEffects.first(where: { $0.preset == value }) {
                                guard let watermark = favorite.applying(to: updated.watermark) else {
                                    onFavoriteImageMissing()
                                    return
                                }
                                updated.watermark = watermark
                            }
                            updated.photoFramePreset = value
                            updated.photoFrameEnabled = true
                            updated.photoFrameBorderEnabled = true
                            let metadata = updated.metadataByPreset[value.rawValue] ?? PhotoFrameMetadataSettings.defaults(for: value)
                            updated.metadata = updated.favoriteFrameEffects.first(where: { $0.preset == value })?.applying(to: metadata) ?? metadata
                            updated.metadataByPreset[value.rawValue] = updated.metadata
                            draft = updated
                        }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentOrange,
                        favoriteOption: { preset in preset.map { p in draft.favoriteFrameEffects.contains { $0.preset == p } } ?? false },
                        favoriteIconColor: ZTransferColors.accentOrange)
            .frame(maxWidth: .infinity)
            DetentWheel(label: "", options: [false], selected: false,
                        optionLabel: { _ in AppLocalized.resource("photo_frame_metadata_button") }, onCommit: { _ in },
                        rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, enabled: frameEnabled,
                        accentColor: ZTransferColors.accentOrange,
                        emphasized: metadataExpanded, showDragHint: false,
                        onActivated: {
                            playPhotoEffectDisclosureFeedback()
                            withAnimation(ZTransferMotion.inlineExpansion) { metadataExpanded.toggle() }
                        })
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("photo-frame-settings")
            PhotoEffectFavoriteButton(
                favorite: frameEnabled && draft.favoriteFrameEffects.contains { $0.preset == draft.photoFramePreset },
                enabled: frameEnabled,
                action: toggleFrameFavorite
            )
        }
        PhotoEffectInlineDisclosure(expanded: frameEnabled && metadataExpanded) {
            VStack(spacing: 8) {
                if draft.photoFramePreset.supportsWidthControl {
                    DetentWheel(label: AppLocalized.resource("photo_frame_width"), options: Array(stride(from: 60, through: 200, by: 5)), selected: activeMetadata.widthPercent,
                                optionLabel: { "\($0)%" }, onCommit: { value in updateMetadata { $0.widthPercent = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentOrange)
                        .id(draft.photoFramePreset)
                }
                if draft.photoFramePreset.supportsBackdropControls {
                    HStack(spacing: 8) {
                        DetentWheel(label: AppLocalized.resource("photo_frame_background_blur"), options: Array(stride(from: 0, through: 200, by: 10)), selected: activeMetadata.backgroundBlurPercent,
                                    optionLabel: { "\($0)%" }, onCommit: { value in updateMetadata { $0.backgroundBlurPercent = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentOrange)
                        DetentWheel(label: AppLocalized.resource("photo_frame_background_mask"), options: Array(stride(from: 0, through: 200, by: 10)), selected: activeMetadata.backgroundMaskPercent,
                                    optionLabel: { "\($0)%" }, onCommit: { value in updateMetadata { $0.backgroundMaskPercent = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentOrange)
                    }
                    .id(draft.photoFramePreset)
                }
                if draft.photoFramePreset.supportsWidthControl {
                    Rectangle().fill(ZTransferColors.primaryText.opacity(0.10)).frame(height: 1)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                }
                HStack(spacing: 8) {
                    metadataButton(AppLocalized.resource(activeMetadata.brandControlLabelKey), activeMetadata.showBrand) { updateMetadata { $0.cycleBrandStyle() } }
                    metadataButton(AppLocalized.resource("photo_frame_metadata_model"), activeMetadata.showModel) { updateMetadata { $0.showModel.toggle() } }
                    metadataButton(AppLocalized.resource("photo_frame_metadata_lens_model"), activeMetadata.showLensModel) { updateMetadata { $0.showLensModel.toggle() } }
                }
                HStack(spacing: 8) {
                    metadataButton(AppLocalized.resource("photo_frame_metadata_focal_length"), activeMetadata.showFocalLength) { updateMetadata { $0.showFocalLength.toggle() } }
                    metadataButton(AppLocalized.resource("photo_frame_metadata_exposure"), activeMetadata.showExposure) { updateMetadata { $0.showExposure.toggle() } }
                    if showLocationFields {
                        metadataButton(AppLocalized.resource("photo_frame_metadata_coordinates"), activeMetadata.showCoordinates) { updateMetadata { $0.showCoordinates.toggle() } }
                    } else { Color.clear.frame(maxWidth: .infinity) }
                }
                if showLocationFields {
                    HStack(spacing: 8) {
                        metadataButton(AppLocalized.resource("photo_frame_metadata_altitude"), activeMetadata.showAltitude) { updateMetadata { $0.showAltitude.toggle() } }
                        metadataButton(AppLocalized.resource("photo_frame_metadata_city"), activeMetadata.showCity) { updateMetadata { $0.showCity.toggle() } }
                        metadataButton(AppLocalized.resource("photo_frame_metadata_region"), activeMetadata.showRegion) { updateMetadata { $0.showRegion.toggle() } }
                    }
                }
                HStack(spacing: 8) {
                    let datePatterns: [String?] = [nil, "yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "MM-dd-yyyy"]
                    let timePatterns: [String?] = [nil, "HH:mm", "HH:mm:ss", "HH.mm", "HH.mm.ss"]
                    DetentWheel(label: AppLocalized.resource("photo_frame_metadata_date_format"), options: datePatterns, selected: activeMetadata.showDate ? activeMetadata.datePattern : nil,
                                optionLabel: { value in
                                    guard let value else { return AppLocalized.resource("photo_frame_off") }
                                    switch value { case "yyyy-MM-dd": return "2026-08-17"; case "yyyy/MM/dd": return "2026/08/17"; case "yyyy.MM.dd": return "2026.08.17"; default: return "08-17-2026" }
                                }, onCommit: { value in updateMetadata { $0.showDate = value != nil; if let value { $0.datePattern = value } } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentOrange)
                    DetentWheel(label: AppLocalized.resource("photo_frame_metadata_time_format"), options: timePatterns, selected: activeMetadata.showTime ? activeMetadata.timePattern : nil,
                                optionLabel: { value in
                                    guard let value else { return AppLocalized.resource("photo_frame_off") }
                                    switch value { case "HH:mm": return "14:32"; case "HH:mm:ss": return "14:32:08"; case "HH.mm": return "14.32"; default: return "14.32.08" }
                                }, onCommit: { value in updateMetadata { $0.showTime = value != nil; if let value { $0.timePattern = value } } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentOrange)
                }
            }
            .padding(8)
            .background(.thinMaterial.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ZTransferColors.secondaryText.opacity(0.18), lineWidth: 1))
            .padding(.top, 8)
        }
    }

    private var watermarkControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_short"), options: [false, true], selected: watermarkEnabled,
                            optionLabel: { $0 ? AppLocalized.resource("photo_frame_on") : AppLocalized.resource("photo_frame_off") }, onCommit: { value in
                                guard isPro else { return }
                                textFieldFocused = false
                                let borderWasEnabled = frameEnabled
                                var updated = draft
                                if !updated.photoFrameEnabled {
                                    let preferredPosition = updated.watermark.position
                                    updated.watermark = PhotoFrameWatermark(enabled: false)
                                    updated.watermark.position = preferredPosition
                                }
                                updated.watermark.enabled = value
                                updated.photoFrameEnabled = borderWasEnabled || value
                                if borderWasEnabled, let index = updated.favoriteFrameEffects.firstIndex(where: { $0.preset == updated.photoFramePreset }) {
                                    updated.favoriteFrameEffects[index].watermark = updated.watermark
                                }
                                draft = updated
                            }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, enabled: isPro, accentColor: ZTransferColors.accentPurple,
                            onDetent: { ZTransferHaptics.shared.play(.toggle) })
                .overlay {
                    if !isPro {
                        Color.clear.contentShape(Rectangle()).onTapGesture { showPremiumHint() }
                    }
                }
                DetentWheel(label: "", options: [false], selected: false,
                            optionLabel: { _ in AppLocalized.resource("photo_frame_watermark_settings_button") }, onCommit: { _ in }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height,
                            enabled: watermarkEnabled, accentColor: ZTransferColors.accentPurple,
                            emphasized: watermarkExpanded, showDragHint: false,
                            onActivated: {
                                playPhotoEffectDisclosureFeedback()
                                withAnimation(ZTransferMotion.inlineExpansion) { watermarkExpanded.toggle() }
                            })
                .accessibilityIdentifier("photo-watermark-settings")
            }
            PhotoEffectInlineDisclosure(expanded: watermarkExpanded && watermarkEnabled) {
                VStack(spacing: 8) {
                    // Android keeps the content wheel and its editor on
                    // one row: one third for the type and two thirds for
                    // the text field / logo button. Keeping that geometry
                    // here prevents the editor from becoming a separate,
                    // oversized row on iOS.
                    GeometryReader { proxy in
                        let typeWidth = (proxy.size.width - 8) / 3
                        HStack(spacing: 8) {
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_content"), options: PhotoFrameWatermarkContent.allCases,
                                        selected: shownWatermark.content,
                                        optionLabel: { $0 == .text ? AppLocalized.resource("photo_frame_content_text") : AppLocalized.resource("photo_frame_content_image") },
                                        onCommit: { value in
                                            if value == .image && shownWatermark.imageHash == nil {
                                                showingWatermarkPicker = true
                                            } else {
                                                updateWatermark { $0.content = value }
                                            }
                                        }, sizing: PhotoEffectControlMetrics.parameterWheel,
                                        enabled: !imageImporting, accentColor: ZTransferColors.accentPurple)
                            .frame(width: typeWidth)
                            if shownWatermark.content == .text {
                                TextField("", text: Binding(
                                    get: { shownWatermark.text },
                                    set: { value in
                                        updateWatermark {
                                            $0.text = PhotoFrameWatermark.limitText(value)
                                        }
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.center)
                                .focused($textFieldFocused)
                                .submitLabel(.done)
                                .onSubmit { textFieldFocused = false }
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ZTransferColors.secondaryText.opacity(0.15)))
                                .background(PhotoEffectsFocusedFieldVisibility(focused: textFieldFocused))
                            } else {
                                DetentWheel(label: "", options: [false], selected: false,
                                    optionLabel: { _ in AppLocalized.resource("photo_frame_replace_image") },
                                    onCommit: { _ in }, sizing: PhotoEffectControlMetrics.parameterWheel,
                                    enabled: !imageImporting, accentColor: ZTransferColors.accentPurple,
                                    showDragHint: false, onActivated: { showingWatermarkPicker = true },
                                    centerIcon: imageImporting ? { tint in
                                        AnyView(ProgressView().controlSize(.mini).tint(tint).frame(width: 12, height: 12))
                                    } : nil)
                            }
                        }
                    }
                    .frame(height: 34)
                    if shownWatermark.content == .text {
                        PhotoEffectParameterRow(weights: [0.42, 0.29, 0.29]) {
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_font"), options: PhotoFrameWatermarkFont.allCases, selected: shownWatermark.font, optionLabel: fontName, onCommit: { value in updateWatermark { $0.font = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_size"), options: Array(PhotoFrameWatermark.sizeRange.reversed()), selected: shownWatermark.sizePercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.sizePercent = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_opacity"), options: Array(PhotoFrameWatermark.opacityRange.reversed()), selected: shownWatermark.opacityPercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.opacityPercent = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                        }
                        PhotoEffectParameterRow(weights: [0.42, 0.29, 0.29]) {
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_position"), options: textWatermarkPositions, selected: textWatermarkPositions.contains(shownWatermark.position) ? shownWatermark.position : .photoBottomCenter, optionLabel: positionName, onCommit: { value in updateWatermark { $0.position = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_color"), options: PhotoFrameWatermarkColor.allCases, selected: shownWatermark.color, optionLabel: colorName, onCommit: { value in updateWatermark { $0.color = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_effect"), options: PhotoFrameWatermarkEffect.allCases, selected: shownWatermark.effect, optionLabel: effectName, onCommit: { value in updateWatermark { $0.effect = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                        }
                    } else {
                        PhotoEffectParameterRow(weights: [0.29, 0.29, 0.42]) {
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_size"), options: Array(PhotoFrameWatermark.sizeRange.reversed()), selected: shownWatermark.sizePercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.sizePercent = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_opacity"), options: Array(PhotoFrameWatermark.opacityRange.reversed()), selected: shownWatermark.opacityPercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.opacityPercent = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_position"), options: photoWatermarkPositions, selected: photoWatermarkPositions.contains(shownWatermark.position) ? shownWatermark.position : .photoBottomCenter, optionLabel: positionName, onCommit: { value in updateWatermark { $0.position = value } }, sizing: PhotoEffectControlMetrics.parameterWheel, accentColor: ZTransferColors.accentPurple)
                        }
                    }
                }
                .disabled(!isPro)
                .opacity(isPro ? 1 : 0.45)
                .overlay {
                    if !isPro {
                        Color.clear.contentShape(Rectangle()).onTapGesture { showPremiumHint() }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(8)
        .background(ZTransferColors.accentPurple.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ZTransferColors.accentPurple.opacity(0.18), lineWidth: 1))
    }

    private func showPremiumHint() {
        premiumHint = .init(resource: "photo_frame_watermark_pro_only")
    }

    private func metadataButton(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        FilterChip(label: title, selected: selected, accentColor: ZTransferColors.accentOrange) {
            ZTransferHaptics.shared.play(.toggle)
            action()
        }
    }

    private func toggleFrameFavorite() {
        guard frameEnabled else { return }
        var value = draft
        let preset = value.photoFramePreset
        if let index = value.favoriteFrameEffects.firstIndex(where: { $0.preset == preset }) {
            value.favoriteFrameEffects.remove(at: index)
            value.favoriteFramePresets.remove(preset)
        } else {
            value.favoriteFrameEffects.append(.init(preset: preset, watermark: value.watermark, metadata: activeMetadata))
            value.favoriteFramePresets.insert(preset)
        }
        draft = value
    }
    private func frameName(_ value: PhotoFramePreset) -> String {
        switch value {
        case .mist: return AppLocalized.resource("photo_frame_mist"); case .cinema: return AppLocalized.resource("photo_frame_cinema"); case .minimal: return AppLocalized.resource("photo_frame_minimal"); case .frosted: return AppLocalized.resource("photo_frame_frosted"); case .plaque: return AppLocalized.resource("photo_frame_plaque"); case .immersive: return AppLocalized.resource("photo_frame_immersive"); case .brandInset: return AppLocalized.resource("photo_frame_brand_inset"); case .brandGallery: return AppLocalized.resource("photo_frame_brand_gallery"); case .classicSignature: return AppLocalized.resource("photo_frame_classic_signature"); case .galleryMat: return AppLocalized.resource("photo_frame_gallery_mat"); case .colorArchive: return AppLocalized.resource("photo_frame_color_archive"); case .filmGallery: return AppLocalized.resource("photo_frame_film_gallery"); case .filmEdge: return AppLocalized.resource("photo_frame_film_edge"); case .filmNegative: return AppLocalized.resource("photo_frame_film_negative"); case .parameterPoster: return AppLocalized.resource("photo_frame_parameter_poster")
        }
    }
    private func fontName(_ value: PhotoFrameWatermarkFont) -> String {
        switch value { case .signature: return AppLocalized.resource("photo_frame_font_signature"); case .elegant: return AppLocalized.resource("photo_frame_font_elegant"); case .calligraphy: return AppLocalized.resource("photo_frame_font_calligraphy"); case .simple: return AppLocalized.resource("photo_frame_font_simple"); case .bold: return AppLocalized.resource("photo_frame_font_bold") }
    }
    private func positionName(_ value: PhotoFrameWatermarkPosition) -> String {
        switch value { case .auto: return AppLocalized.resource("photo_frame_position_auto"); case .left: return AppLocalized.resource("photo_frame_position_left"); case .center: return AppLocalized.resource("photo_frame_position_center"); case .right: return AppLocalized.resource("photo_frame_position_right"); case .photoTopLeft: return AppLocalized.resource("photo_frame_position_photo_top_left"); case .photoTopCenter: return AppLocalized.resource("photo_frame_position_photo_top_center"); case .photoTopRight: return AppLocalized.resource("photo_frame_position_photo_top_right"); case .photoCenter: return AppLocalized.resource("photo_frame_position_photo_center"); case .photoBottomLeft: return AppLocalized.resource("photo_frame_position_photo_bottom_left"); case .photoBottomCenter: return AppLocalized.resource("photo_frame_position_photo_bottom_center"); case .photoBottomRight: return AppLocalized.resource("photo_frame_position_photo_bottom_right") }
    }
    private func colorName(_ value: PhotoFrameWatermarkColor) -> String {
        switch value { case .adaptive: return AppLocalized.resource("photo_frame_color_adaptive"); case .white: return AppLocalized.resource("photo_frame_color_white"); case .black: return AppLocalized.resource("photo_frame_color_black"); case .gold: return AppLocalized.resource("photo_frame_color_gold"); case .mistBlue: return AppLocalized.resource("photo_frame_color_mist_blue"); case .roseGold: return AppLocalized.resource("photo_frame_color_rose_gold") }
    }
    private func effectName(_ value: PhotoFrameWatermarkEffect) -> String {
        switch value { case .auto: return AppLocalized.resource("photo_frame_effect_auto"); case .none: return AppLocalized.resource("photo_frame_effect_none"); case .shadow: return AppLocalized.resource("photo_frame_effect_shadow"); case .outline: return AppLocalized.resource("photo_frame_effect_outline") }
    }

}

struct PhotoEffectsPreviewFrame {
    let image: UIImage
    let comparison: UIImage?
    let canvasKey: String
}

/// Shared waiting surface for camera effects and local workbench previews.
struct PhotoEffectsLoadingIndicator: View {
    var body: some View {
        RemoteCameraToolLoading(diameter: 22, strokeWidth: 2,
                                color: ZTransferColors.accentBlue.opacity(0.76))
    }
}

/// SettingsScreen.PhotoEffectsPreviewLoadingPlaceholder: the source has not
/// arrived yet. Rendering an existing source uses only the indicator above.
private struct PhotoEffectsPreviewLoadingPlaceholder: View {
    @StateObject private var clock = RemoteCameraToolLoop()
    var body: some View {
        let cycle = max(0, clock.milliseconds).truncatingRemainder(dividingBy: 1800)
        let fraction = Float(cycle <= 900 ? cycle / 900 : (1800 - cycle) / 900)
        let alpha = 0.28 + 0.34 * Double(ZTransferAndroidMotion.fastOutSlowIn(fraction))
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(ZTransferColors.surface.opacity(alpha))
            PhotoEffectsLoadingIndicator()
        }
        .onAppear { clock.start() }.onDisappear { clock.stop() }
    }
}

/// Matches Android's completed-frame transition: ordinary effect changes keep
/// the old frame opaque while the new frame fades in for 220 ms. Rotation or a
/// border canvas change fades the old frame out for 110 ms, swaps only after
/// the new bitmap is ready, then fades it in for 190 ms. Comparison updates use
/// the same bitmap identity and therefore never restart the transition.
struct PhotoEffectsAnimatedImage: View {
    let frame: PhotoEffectsPreviewFrame
    let requestedCanvasKey: String
    let showComparison: Bool
    var source: UIImage? = nil
    var sourceRotationQuarterTurns = 0
    var onPresentedFrame: ((PhotoEffectsPreviewFrame?) -> Void)? = nil
    var cornerRadius: CGFloat = 0
    var restoreRevision = 0
    var failed = false
    #if DEBUG
    // Tests can present a real system cover at the otherwise one-frame-wide
    // cancellation boundary. Nil in ordinary builds; never used for rendering.
    var crossfadePrepared: (() async -> Void)?
    var visibilityStarted: ((Bool) -> Void)?
    #endif

    @State private var visible: PhotoEffectsPreviewFrame?
    @State private var outgoing: PhotoEffectsPreviewFrame?
    @State private var incomingOpacity: CGFloat = 0
    @State private var replacementOpacity: CGFloat = 1
    @State private var updates = ConflatedPreviewUpdates<Update>()
    private struct Update: Equatable {
        let frame: PhotoEffectsPreviewFrame
        let canvas: String
        let restore: Int
        let failed: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.frame.image === rhs.frame.image &&
                lhs.frame.comparison === rhs.frame.comparison &&
                lhs.frame.canvasKey == rhs.frame.canvasKey &&
                lhs.canvas == rhs.canvas &&
                lhs.restore == rhs.restore &&
                lhs.failed == rhs.failed
        }
    }
    private var update: Update {
        .init(frame: frame, canvas: requestedCanvasKey, restore: restoreRevision, failed: failed)
    }

    init(
        frame: PhotoEffectsPreviewFrame,
        requestedCanvasKey: String,
        showComparison: Bool,
        cornerRadius: CGFloat = 0,
        restoreRevision: Int = 0,
        failed: Bool = false,
        source: UIImage? = nil, sourceRotationQuarterTurns: Int = 0,
        onPresentedFrame: ((PhotoEffectsPreviewFrame?) -> Void)? = nil
    ) {
        self.frame = frame
        self.requestedCanvasKey = requestedCanvasKey
        self.showComparison = showComparison
        self.cornerRadius = cornerRadius
        self.restoreRevision = restoreRevision
        self.failed = failed
        self.source = source; self.sourceRotationQuarterTurns = sourceRotationQuarterTurns
        self.onPresentedFrame = onPresentedFrame
        // Keep visibility at Android's initial 1. A stale first result is
        // rejected by the planner, not by hiding the next accepted canvas and
        // accidentally adding another 190ms fade after its initial 220ms fade.
    }

    private func currentValue(for stored: PhotoEffectsPreviewFrame) -> PhotoEffectsPreviewFrame {
        ObjectIdentifier(stored.image) == ObjectIdentifier(frame.image) ? frame : stored
    }

    @ViewBuilder
    private func layer(_ stored: PhotoEffectsPreviewFrame, opacity: CGFloat) -> some View {
        let value = currentValue(for: stored)
        Image(uiImage: showComparison ? (value.comparison ?? value.image) : value.image)
            .resizable()
            .scaledToFit()
            .opacity(opacity)
    }

    var body: some View {
        ZStack {
            if let outgoing {
                layer(outgoing, opacity: replacementOpacity)
            }
            if let visible {
                layer(visible, opacity: replacementOpacity * incomingOpacity)
            } else if failed {
                PhotoEffectsSourceImage(source: source ?? frame.image, quarterTurns: sourceRotationQuarterTurns)
            } else {
                PhotoEffectsLoadingIndicator()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            // A system picker can remove this view while the incoming frame
            // is still transparent. Its cancelled task will never finish the
            // fade; the same-image update on return must not retain that state.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                outgoing = nil
                incomingOpacity = visible == nil ? 0 : 1
            }
            onPresentedFrame?(visible.map(currentValue))
            enqueue(update)
        }
        .onChange(of: update) { value in
            // SwiftUI can invoke this callback with the previous view value.
            // Carry the new image and canvas in its argument, rather than
            // rebuilding them from that captured self after a key-only change.
            enqueue(value)
        }
        .onDisappear { updates.close(); onPresentedFrame?(nil) }
    }

    private func install(_ next: PhotoEffectsPreviewFrame) {
        visible = next
        onPresentedFrame?(next)
    }

    private func fadeInAcceptedFrame() async -> Bool {
        #if DEBUG
        await crossfadePrepared?()
        #endif
        do { try await ZTransferNextDisplayFrame.wait() } catch { return false }
        guard !Task.isCancelled else { return false }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)) { incomingOpacity = 1 }
        do { try await Task.sleep(for: .milliseconds(220)) } catch { return false }
        return true
    }

    private func enqueue(_ value: Update) {
        updates.submit(value) { target, latest in
            let transition = planPhotoEffectsPreviewTransition(current: visible, next: target.frame,
                requestedCanvas: latest().canvas, canvasOf: { $0.canvasKey },
                sameImage: { $0.image === $1.image })
            if let next = transition.frame {
                switch transition.change {
                case .initial:
                    install(next); outgoing = nil; incomingOpacity = 0
                    guard await fadeInAcceptedFrame() else { return }
                case .update:
                    install(next)
                case .replaceCanvas:
                    withAnimation(.linear(duration: 0.11)) { replacementOpacity = 0 }
                    do { try await Task.sleep(for: .milliseconds(110)) } catch { return }
                    outgoing = nil; install(next); incomingOpacity = 1
                case .crossfade:
                    outgoing = visible; install(next); incomingOpacity = 0
                    guard await fadeInAcceptedFrame() else { return }
                    outgoing = nil
                case .keep: break
                }
            }
            guard !Task.isCancelled, let visible else { return }
            let current = latest()
            let show = photoEffectsPreviewCanvasVisible(displayedCanvas: visible.canvasKey,
                requestedCanvas: current.canvas, failed: current.failed)
            guard replacementOpacity != (show ? 1 : 0) else { return }
            if show {
                do { try await ZTransferNextDisplayFrame.wait() } catch { return }
            }
            guard !Task.isCancelled else { return }
            #if DEBUG
            visibilityStarted?(show)
            #endif
            // Finish both accepted legs before consuming the newest pending frame.
            withAnimation(show ? .timingCurve(0.4, 0, 0.2, 1, duration: 0.19) : .linear(duration: 0.11)) {
                replacementOpacity = show ? 1 : 0
            }
            do { try await Task.sleep(for: .milliseconds(show ? 190 : 110)) } catch { return }
        }
    }
}

func photoEffectsPreviewCanvasKey(_ settings: PhotoEffectsSettings, rotationQuarterTurns: Int = 0) -> String {
    let border = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
        ? settings.photoFramePreset.rawValue
        : "none"
    return "rotation:\(rotationQuarterTurns)|frame:\(border)|uniform:\(settings.usesUniformFrameBorder)"
}

/// Local view state (comparison, transitions, layout) must not serialize the
/// full filter recipe again. Equality compares normalized pixel inputs; the
/// memo retains only one identity and never shares independent editor drafts.
@MainActor
final class PhotoEffectsPreviewIdentityCache {
    private var settings: PhotoEffectsSettings?
    private var source: UIImage?
    private var metadata: PhotoFrameMetadata?
    private var identity: String?
    private var grainSeed: Int32?
    func key(settings: PhotoEffectsSettings, source: UIImage?, metadata: PhotoFrameMetadata?, sourceName: String = "",
             build: ((PhotoEffectsSettings, UIImage?, PhotoFrameMetadata?) -> String)? = nil) -> String {
        let pixels = photoEffectsPreviewPixelSettings(settings)
        let seed = pixels.photoGrain.isEnabled ? photoGrainSeed(sourceName) : nil
        if let identity, self.settings == pixels, self.source === source, self.metadata == metadata, grainSeed == seed { return identity }
        let key = build?(pixels, source, metadata)
            ?? PhotoEffectsSettingsPreview.makeRenderKey(settings: pixels, source: source, metadata: metadata, sourceName: sourceName)
        grainSeed = seed
        self.settings = pixels; self.source = source; self.metadata = metadata; identity = key
        return key
    }
}

/// Metadata-only rotation for the temporary original/failure view. Creating a
/// physically rotated UIImage in body redraws every pixel during layout updates.
struct PhotoEffectsSourceImage: View {
    let source: UIImage
    let quarterTurns: Int
    @State private var cache = PhotoEffectsDisplaySourceCache()
    var body: some View {
        Image(uiImage: cache.image(source, quarterTurns: quarterTurns)).resizable().scaledToFit()
    }
}

/// Android keeps the last rendered effect visible while a new preview is
/// prepared. Rendering is detached from SwiftUI so wheel interaction remains
/// responsive and a cancelled generation cannot replace a newer one.
struct PhotoEffectsSettingsPreview: View {
    @ObservedObject private var placeAvailability = PhotoFramePlaceAvailability.shared
    @AppStorage("app_language") private var appLanguage = "system"
    @State private var cachedPlaceContextKey = ""
    let source: UIImage?
    let metadata: PhotoFrameMetadata?
    let settings: PhotoEffectsSettings
    let onRequest: () -> Void
    @State private var completeCache = PhotoEffectsPreviewCachePool<UIImage>()
    @State private var intermediateCache = PhotoEffectsPreviewCachePool<UIImage>(capacity: 1)
    @State private var comparisonCache = PhotoEffectsPreviewCachePool<UIImage>(capacity: 1)
    @State private var rotatedSourceCache = PhotoEffectsRotatedSourceCache()
    @State private var identityCache = PhotoEffectsPreviewIdentityCache()
    @State private var rendered: UIImage?
    @State private var renderedRequestKey = ""
    @State private var renderedCanvasKey = ""
    @State private var unfiltered: UIImage?
    @State private var previewRestoreRevision = 0
    @State private var previewFailed = false
    @State private var fallbackReady = false
    #if DEBUG
    var lifecycleObserver: ((String) -> Void)?
    var renderedImageObserver: ((UIImage) -> Void)?
    #endif
    @State private var showUnfiltered = false
    @State private var lastPreviewSettings: PhotoEffectsSettings?
    @State private var rotationQuarterTurns = 0
    @State private var expanded = false
    @State private var geometry = PhotoEffectsGeometrySnapshot()
    @Environment(\.photoEffectsExpandedPresentation) private var expandedPresentation

    let sourceName: String
    init(source: UIImage?, metadata: PhotoFrameMetadata?, settings: PhotoEffectsSettings,
         onRequest: @escaping () -> Void, initialRotationQuarterTurns: Int = 0,
         sourceName: String = "") {
        self.source = source; self.metadata = metadata; self.settings = settings; self.onRequest = onRequest
        self.sourceName = sourceName
        _rotationQuarterTurns = State(initialValue: ((initialRotationQuarterTurns % 4) + 4) % 4)
    }

    private var sourceIsPortrait: Bool {
        let portrait = source.map { $0.size.height > $0.size.width } ?? false
        return rotationQuarterTurns.isMultiple(of: 2) ? portrait : !portrait
    }

    private var renderKey: String {
        identityCache.key(settings: settings, source: source, metadata: metadata, sourceName: sourceName)
    }

    static func makeRenderKey(
        settings: PhotoEffectsSettings,
        source: UIImage?,
        metadata: PhotoFrameMetadata?, sourceName: String = "",
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try? encoder.encode(photoEffectsPreviewPixelSettings(settings))
        let settingsKey = String(data: data ?? Data(), encoding: .utf8) ?? ""
        let sourceKey: String
        if let source {
            sourceKey = "source:\(ObjectIdentifier(source)):\(source.size.width)x\(source.size.height)"
        } else {
            sourceKey = "source:none"
        }
        let metadataKey = Self.metadataKey(metadata)
        return settingsKey + "|" + sourceKey + "|" + metadataKey
            + (settings.photoGrain.isEnabled ? "|grainSeed:\(photoGrainSeed(sourceName))" : "")
    }

    private static func metadataKey(_ metadata: PhotoFrameMetadata?) -> String {
        guard let metadata else { return "meta:none" }
        let fields = [
            metadata.make ?? "", metadata.model ?? "", metadata.aperture ?? "",
            metadata.shutter ?? "", metadata.iso ?? "", metadata.focalLength ?? "",
            metadata.lensModel ?? "", metadata.dateTime ?? "",
            metadata.exposureCompensation ?? "",
            metadata.latitude.map { String($0) } ?? "",
            metadata.longitude.map { String($0) } ?? "",
            metadata.altitude.map { String($0) } ?? "",
            metadata.city ?? "", metadata.region ?? "",
        ]
        return "meta:" + fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private var placeContextKey: String {
        // Android SettingsScreen includes availability in completed-frame cache
        // identity only when place fields are requested; filter pixels are independent.
        let enabled = settings.metadata.showCity || settings.metadata.showRegion
        return "place:\(enabled ? String(placeAvailability.allowed) : "unused")|language:\(appLanguage)"
    }

    private var renderKeyWithRotation: String {
        "\(renderKey)|rotation:\(rotationQuarterTurns)|\(placeContextKey)|fallback:\(fallbackReady)"
    }

    private static func resolvedPreviewMetadata(
        _ metadata: PhotoFrameMetadata?, settings: PhotoEffectsSettings
    ) async -> PhotoFrameMetadata? {
        guard settings.photoFrameEnabled, settings.photoFrameBorderEnabled, let metadata else {
            return metadata
        }
        return await PhotoFramePlaceResolver.shared.enriching(
            metadata, settings: settings.metadata,
            allowed: { await PhotoFramePlaceAvailability.shared.allowed }
        )
    }

    private var requestedCanvasKey: String {
        photoEffectsPreviewCanvasKey(settings, rotationQuarterTurns: rotationQuarterTurns)
    }

    private static func makeSourceContextKey(
        source: UIImage?, metadata: PhotoFrameMetadata?, rotationQuarterTurns: Int
    ) -> String {
        let sourceKey = source.map {
            "source:\(ObjectIdentifier($0)):\($0.size.width)x\($0.size.height)"
        } ?? "source:none"
        let metadataKey = Self.metadataKey(metadata)
        return "\(sourceKey)|\(metadataKey)|rotation:\(rotationQuarterTurns)"
    }

    private var prefetchRequest: ConnectedPhotoEffectsPrefetchRequest {
        let selections = nextPhotoFilterSelections(for: settings)
        let keys = selections.map { "\($0.preset.id):\($0.normalizedIntensityPercent)" }
        return ConnectedPhotoEffectsPrefetchRequest(
            renderKey: renderKeyWithRotation,
            orderedSelections: keys,
            enabled: renderedRequestKey == renderKeyWithRotation && source != nil &&
                settings.photoFilterEnabled && settings.selectedFilter != nil
        )
    }

    private static func differsOnlyInWatermarkText(
        _ previous: PhotoEffectsSettings, _ current: PhotoEffectsSettings
    ) -> Bool {
        guard previous.watermark.text != current.watermark.text else { return false }
        var lhs = previous
        var rhs = current
        lhs.watermark.text = ""
        rhs.watermark.text = ""
        return lhs == rhs
    }

    private static func cachedPreview(
        image: UIImage, sourceIdentity: UIImage, settings: PhotoEffectsSettings,
        metadata: PhotoFrameMetadata?, originalMetadata: PhotoFrameMetadata?, rotation: Int,
        placeContext: String, cache: PhotoEffectsPreviewCachePool<UIImage>,
        intermediate: PhotoEffectsPreviewCachePool<UIImage>?, comparison: Bool = false, sourceName: String
    ) async throws -> UIImage {
        var decoration = settings
        decoration.photoFilterEnabled = false; decoration.selectedFilter = nil
        if comparison { decoration.photoGrain = .off }
        let context = makeRenderKey(settings: decoration, source: sourceIdentity, metadata: originalMetadata, sourceName: sourceName)
            + "|rotation:\(rotation)|\(placeContext)"
        let key = comparison ? context : makeRenderKey(settings: settings, source: sourceIdentity, metadata: originalMetadata, sourceName: sourceName)
        let decorationSettings = decoration
        let filterContext = makeSourceContextKey(source: sourceIdentity, metadata: nil, rotationQuarterTurns: rotation)
        return try await cache.value(key: key, context: context) { cancelled in
            let filtered: UIImage?
            if !comparison, settings.photoFilterEnabled, let selection = settings.selectedFilter {
                if let intermediate {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(selection)
                    filtered = try await intermediate.value(key: data.base64EncodedString(), context: filterContext) { cancelled in
                        if cancelled() { throw CancellationError() }
                        return try await LocalPhotoOutput.filteredSource(image: image, selection: selection)
                    }
                } else { filtered = try await LocalPhotoOutput.filteredSource(image: image, selection: selection) }
            } else { filtered = nil }
            if cancelled() { throw CancellationError() }
            if comparison { return try await LocalPhotoOutput.unfilteredPreview(image: image, settings: decorationSettings, metadata: metadata) }
            return try await LocalPhotoOutput.preview(image: image, settings: settings, metadata: metadata, filteredSource: filtered, sourceName: sourceName).filtered
        }
    }

    private static func prefetchedPreviews(
        image: UIImage, sourceIdentity: UIImage, settings: PhotoEffectsSettings,
        metadata: PhotoFrameMetadata?, rotationQuarterTurns: Int, placeContextKey: String,
        cache: PhotoEffectsPreviewCachePool<UIImage>, sourceName: String
    ) async {
        let resolvedMetadata = await resolvedPreviewMetadata(metadata, settings: settings)
        do {
            for selection in nextPhotoFilterSelections(for: settings) {
                try Task.checkCancellation()
                var next = settings
                next.photoFilterEnabled = true
                next.selectedFilter = selection
                _ = try await cachedPreview(image: image, sourceIdentity: sourceIdentity,
                    settings: next, metadata: resolvedMetadata, originalMetadata: metadata,
                    rotation: rotationQuarterTurns, placeContext: placeContextKey, cache: cache, intermediate: nil, sourceName: sourceName)
            }
        } catch {}
    }


    var body: some View {
        Group {
            if let rendered {
                PhotoEffectsAnimatedImage(
                    frame: .init(
                        image: rendered,
                        comparison: unfiltered,
                        canvasKey: renderedCanvasKey
                    ),
                    requestedCanvasKey: requestedCanvasKey,
                    showComparison: showUnfiltered,
                    cornerRadius: 12,
                    restoreRevision: previewRestoreRevision, failed: previewFailed,
                    source: source, sourceRotationQuarterTurns: rotationQuarterTurns,
                    onPresentedFrame: { geometry.presentedFrame = $0 }
                )
                .overlay(alignment: .bottom) {
                    if previewFailed { previewUnavailableBadge }
                }
            } else if previewFailed, let source {
                PhotoEffectsSourceImage(source: source, quarterTurns: rotationQuarterTurns)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottom) { previewUnavailableBadge }
            } else if previewFailed {
                previewUnavailableBadge.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Keep a real 4:3 preview surface while the connected list is
                // still resolving its latest file. An EmptyView collapses the
                // aspect-ratio proposal to zero, which prevents the fallback
                // render task from ever producing a visible preview in the
                // settings page.
                PhotoEffectsPreviewLoadingPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        // Android keeps a stable 4:3 / 3:4 viewport and fits the rendered
        // canvas inside it. The frame can add a metadata band, so using the
        // rendered bitmap's ratio here would make the preview jump in height.
        .aspectRatio(source == nil || !sourceIsPortrait ? CGFloat(4) / 3 : CGFloat(3) / 4,
                     contentMode: .fit)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.34), value: sourceIsPortrait)
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear
                    .allowsHitTesting(false)
                    .preference(
                        key: PhotoEffectsPreviewAnchorPreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
            }
        }
        .onPreferenceChange(PhotoEffectsPreviewAnchorPreferenceKey.self) { geometry.previewAnchor = $0 }
        #if DEBUG
        .overlay(alignment: .bottom) {
            if ProcessInfo.processInfo.arguments.contains("--gesture-audit-ui-test") {
                Text("ready=\(unfiltered != nil ? 1 : 0);comparison=\(showUnfiltered ? 1 : 0);rotation=\(rotationQuarterTurns);expanded=\(expanded ? 1 : 0)")
                    .font(.system(size: 8)).allowsHitTesting(false).accessibilityIdentifier("effects-gesture-state")
            }
        }
        .onChange(of: showUnfiltered) { ButtonInteractionTrace.recordNow($0 ? "comparison-on" : "comparison-off") }
        .onChange(of: expanded) { ButtonInteractionTrace.recordNow($0 ? "effects-open" : "effects-close") }
        #endif
        .overlay { PhotoEffectsImageInput(comparing: $showUnfiltered, comparisonEnabled: unfiltered != nil,
            onTap: { _ in
                guard let displayed = geometry.presentedFrame else { return }
                guard let expandedPresentation else { return }
                expanded = true
                expandedPresentation.present(.init(image: displayed.image,
                    initialComparison: displayed.comparison, anchor: geometry.previewAnchor)) {
                    expanded = false
                }
            }, onDoubleTap: { _ in
                guard !expanded, geometry.presentedFrame != nil else { return }
                rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
            }) }
        .onChange(of: unfiltered) { _ in
            expandedPresentation?.updateComparison(image: rendered, unfiltered: unfiltered)
        }
        .onDisappear {
            // The inline overlay keeps this source mounted while previewing.
            // A real removal must stop its render work even if the retained
            // expanded snapshot is still finishing its close animation.
            completeCache.close(); intermediateCache.close(); comparisonCache.close(); rotatedSourceCache.close()
        }

        // Android keys the 2200 ms camera-source grace to the page/source,
        // not to pixel settings. Wheel edits must not restart this timer.
        .task(id: source == nil) {
            fallbackReady = false
            guard source == nil else { return }
            #if DEBUG
            lifecycleObserver?("fallback.grace.begin")
            #endif
            do { try await Task.sleep(for: .milliseconds(2200)) } catch { return }
            guard !Task.isCancelled else { return }
            fallbackReady = true
            #if DEBUG
            lifecycleObserver?("fallback.grace.end")
            #endif
        }
        .task(id: renderKeyWithRotation) {
            var demanded = [Self.makeRenderKey(settings: settings, source: source, metadata: metadata, sourceName: sourceName)]
            for selection in nextPhotoFilterSelections(for: settings) {
                var next = settings; next.photoFilterEnabled = true; next.selectedFilter = selection
                demanded.append(Self.makeRenderKey(settings: next, source: source, metadata: metadata, sourceName: sourceName))
            }
            completeCache.request(Set(demanded))
            let pixelSettings = photoEffectsPreviewPixelSettings(settings)
            if let previous = lastPreviewSettings,
               Self.differsOnlyInWatermarkText(previous, pixelSettings) {
                // Android delays only text-only edits. Each new keystroke
                // cancels this task before any pixel work begins.
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }
            lastPreviewSettings = pixelSettings
            if cachedPlaceContextKey != placeContextKey {
                cachedPlaceContextKey = placeContextKey
                unfiltered = nil
                showUnfiltered = false
            }
            previewFailed = false
            guard let source else {
                onRequest()
                guard fallbackReady, !Task.isCancelled else { return }
                let rotation = rotationQuarterTurns
                let fallbackSettings = settings
                let fallbackResult = try? await PhotoEffectsPreviewRenderGate.render {
                    let rotatedFallback = PhotoEffectsSourceRotation.rotate(
                        PhotoEffectsFallbackSource.make(), quarterTurns: rotation)
                    return try PhotoEffectsRenderer.render(
                        rotatedFallback, settings: fallbackSettings, metadata: nil,
                        previewPlaceholders: true, previewLongEdge: 1_920, filterExecution: .preview
                    )
                }
                guard !Task.isCancelled else { return }
                guard let fallbackResult else {
                    previewFailed = true
                    previewRestoreRevision &+= 1
                    return
                }
                renderedCanvasKey = requestedCanvasKey
                rendered = fallbackResult
                #if DEBUG
                lifecycleObserver?("fallback.rendered")
                #endif
                renderedRequestKey = renderKeyWithRotation
                previewFailed = false
                return
            }
            showUnfiltered = false
            unfiltered = nil
            let metadata = await Self.resolvedPreviewMetadata(metadata, settings: settings)
            guard !Task.isCancelled else { return }
            let settings = settings
            let rotationQuarterTurns = rotationQuarterTurns
            guard let rotatedSource = try? await rotatedSourceCache.image(source, quarterTurns: rotationQuarterTurns),
                  !Task.isCancelled else { return }
            let result = try? await Self.cachedPreview(image: rotatedSource, sourceIdentity: source,
                settings: settings, metadata: metadata, originalMetadata: self.metadata,
                rotation: rotationQuarterTurns, placeContext: placeContextKey,
                cache: completeCache, intermediate: intermediateCache, sourceName: sourceName)
            guard !Task.isCancelled else { return }
            guard let result else {
                previewFailed = true
                previewRestoreRevision &+= 1
                return
            }
            renderedCanvasKey = requestedCanvasKey
            rendered = result
            #if DEBUG
            lifecycleObserver?("source.rendered")
            renderedImageObserver?(result)
            #endif
            renderedRequestKey = renderKeyWithRotation
            previewFailed = false
            guard (settings.photoFilterEnabled && settings.selectedFilter != nil) || settings.photoGrain.isEnabled else { return }

            // The comparison starts as soon as the current image is visible.
            // Neighbor warming is a separate task below so a favorite-order
            // change does not rebuild or animate the current frame.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let comparison = try? await Self.cachedPreview(image: rotatedSource, sourceIdentity: source,
                settings: settings, metadata: metadata, originalMetadata: self.metadata,
                rotation: rotationQuarterTurns, placeContext: placeContextKey,
                cache: comparisonCache, intermediate: nil, comparison: true, sourceName: sourceName)
            if let comparison, !Task.isCancelled {
                unfiltered = comparison
            }
        }
        .task(id: prefetchRequest) {
            guard prefetchRequest.enabled, let source else { return }
            if settings.photoGrain.isEnabled && !nextPhotoFilterSelections(for: settings).isEmpty {
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            }
            let rotation = rotationQuarterTurns
            guard let rotatedSource = try? await rotatedSourceCache.image(source, quarterTurns: rotation),
                  !Task.isCancelled else { return }
            await Self.prefetchedPreviews(
                image: rotatedSource, sourceIdentity: source, settings: settings,
                metadata: metadata, rotationQuarterTurns: rotation, placeContextKey: placeContextKey, cache: completeCache, sourceName: sourceName
            )

        }
    }

    private var previewUnavailableBadge: some View {
        Text(AppLocalized.resource("photo_frame_preview_unavailable"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ZTransferColors.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 6)
    }
}

private struct ConnectedPhotoEffectsPrefetchRequest: Equatable {
    let renderKey: String
    let orderedSelections: [String]
    let enabled: Bool
}

/// Android's expanded effects preview uses the same fitted image surface as
/// the photo viewer: a tap dismisses at 1x, a double tap toggles 2.5x, and a
/// pinch/drag pair keeps the image inside the viewport while zoomed.
struct PhotoEffectsExpandedPreview: View {
    let image: UIImage
    var comparison: UIImage? = nil
    let initialAnchor: CGRect
    let onDismiss: () -> Void
    @State private var interaction = PhotoEffectsExpandedInteraction()
    @State private var closeTask: Task<Void, Never>?
    @State private var presentationProgress: CGFloat = 0
    @State private var closing = false


    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black.opacity(0.74 * presentationProgress).ignoresSafeArea()
                PhotoEffectsExpandedImageSurface(image: image, comparison: comparison,
                    interaction: interaction, closing: closing, onClose: startClose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(PhotoPreviewAnchorTransform(
                    progress: presentationProgress,
                    anchor: initialAnchor == .zero ? nil : initialAnchor,
                    enabled: true,
                    closing: closing
                ))

                PreviewCircleButton(icon: .rotateLeft, accessibilityKey: "cd_rotate_photo") {
                    interaction.rotate()
                }
                .disabled(closing)
                .opacity(presentationProgress)
                .padding(.trailing, 20)
                .padding(.bottom, photoPreviewControlsBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Consume touches during collapse as well; never pass a drag to
            // the workbench pager or editor below the overlay.
            .background { PopupDragBoundary() }
        }
        .statusBarHidden(true)
        .onDisappear { closeTask?.cancel(); closeTask = nil }
        .onAppear {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.34)) {
                presentationProgress = 1
            }
        }
    }

    private func startClose() {
        guard !closing else { return }
        closing = true
        closeTask = Task { @MainActor in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) {
                presentationProgress = 0
            }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

}

private struct PhotoEffectsPreviewAnchorPreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Android's `nextPhotoFilterSelections`: preserve the catalog's favorite-first
/// order and warm only the two entries after the current selection.
/// Exact shape of Android's settings-page fallback source. It is only visible
/// after the grace period and disappears automatically when a real source key
/// arrives; it is never used for export or camera transfers.
private enum PhotoEffectsFallbackSource {
    static func make() -> UIImage {
        let size = CGSize(width: 1920, height: 1280)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let colors = [
                UIColor(red: 111 / 255, green: 169 / 255, blue: 181 / 255, alpha: 1).cgColor,
                UIColor(red: 214 / 255, green: 192 / 255, blue: 151 / 255, alpha: 1).cgColor,
            ] as CFArray
            context.drawLinearGradient(
                CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: [],
            )
            context.saveGState()
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: -.pi * 24 / 180)
            context.translateBy(x: -center.x, y: -center.y)
            context.setFillColor(UIColor(
                red: 47 / 255, green: 85 / 255, blue: 94 / 255, alpha: 1
            ).cgColor)
            context.fill(CGRect(x: -80, y: 215, width: 900, height: 115))
            context.restoreGState()
            context.setFillColor(UIColor(red: 244 / 255, green: 193 / 255, blue: 91 / 255, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: size.width * 0.72 - 42, y: size.height * 0.24 - 42, width: 84, height: 84))
        }
    }
}

/// One tick for 调整效果、边框设置 and the same disclosure buttons.
/// navigation's soft impact is too light to feel on these taps; use the
/// same selection tick as the surrounding wheels.
@MainActor
func playPhotoEffectDisclosureFeedback() {
    ZTransferHaptics.shared.play(.selection)
}

private struct PhotoEffectDisclosureHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Downward panel for those buttons. The controls keep their real height and
/// stay mounted; only the visible window and opacity follow `expanded`.
/// The height is applied directly from that flag so a parent transaction
/// cannot skip the transition and pop the full panel in.
struct PhotoEffectInlineDisclosure<Content: View>: View {
    let expanded: Bool
    let content: Content
    @State private var measured: CGFloat = 0

    init(expanded: Bool, @ViewBuilder content: () -> Content) {
        self.expanded = expanded
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PhotoEffectDisclosureHeightKey.self, value: proxy.size.height)
                }
            }
            .frame(height: expanded ? measured : 0, alignment: .top)
            .clipped()
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
            .animation(ZTransferMotion.inlineExpansion, value: expanded)
            .onPreferenceChange(PhotoEffectDisclosureHeightKey.self) { newValue in
                guard newValue > 0.5, abs(newValue - measured) > 0.5 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { measured = newValue }
            }
    }
}

/// Android PhotoLutEditor.PhotoColorEffectGroup: retain outgoing content,
/// expand/shrink towards the top in 240ms, fade in/out in 200ms. Spacing
/// belongs to the section so removing the last frame never drops a gap.
struct PhotoEffectModuleSection<Content: View>: View {
    let visible: Bool
    let spacing: CGFloat
    let content: Content
    @State private var retained = RetainedPhotoEffectModule<Content>()
    @State private var mounted: Bool
    @State private var progress: CGFloat
    @State private var opacity: Double

    init(visible: Bool, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.visible = visible
        self.spacing = spacing
        self.content = content()
        _mounted = State(initialValue: visible)
        _progress = State(initialValue: visible ? 1 : 0)
        _opacity = State(initialValue: visible ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if mounted || visible, let displayed = retained.resolve(content, visible: visible) {
                VStack(spacing: 0) { displayed }.padding(.bottom, spacing)
                    .modifier(PhotoEffectModuleReveal(progress: progress, retainingHeight: !visible))
                    .opacity(opacity)
            }
        }
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .onChange(of: visible) { value in
            if value { mounted = true }
            withAnimation(ZTransferMotion.inlineExpansion) { progress = value ? 1 : 0 }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)) { opacity = value ? 1 : 0 }
        }
        .task(id: visible) {
            guard !visible, mounted else { return }
            do { try await Task.sleep(for: .milliseconds(240)) } catch { return }
            guard !Task.isCancelled else { return }
            mounted = false
            retained.clear()
        }
    }
}

/// A rendering snapshot, not an observable/business state. Like Android's
/// retained composable, it records the last visible View value without
/// publishing a second editor update. Clearing after exit releases its binds.
private final class RetainedPhotoEffectModule<Content: View> {
    private var content: Content?
    func resolve(_ current: Content, visible: Bool) -> Content? {
        if visible { content = current }
        return content
    }
    func clear() { content = nil }
}

private struct PhotoEffectModuleReveal: AnimatableModifier {
    var progress: CGFloat
    let retainingHeight: Bool
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        PhotoEffectModuleRevealLayout(progress: progress, retainingHeight: retainingHeight) { content }
            .clipped()
            .transaction { transaction in
                // Only the section's own expand/collapse may freeze descendants.
                // An idle open section must keep button-driven disclosure animations.
                if progress > 0.001 && progress < 0.999 { transaction.animation = nil }
            }
    }
}

/// Only the layout interpolates each frame. No geometry state is written
/// back into the editor and no wheel is compressed into a shorter proposal.
struct PhotoEffectModuleRevealLayout: Layout {
    var progress: CGFloat
    var retainingHeight = false
    struct Cache { var fullSize: CGSize? }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let measured = subviews.first?.sizeThatFits(.init(width: proposal.width, height: nil)) ?? .zero
        // An observed LUT editor cancels immediately when hidden. Its own
        // expanded controls may disappear; that must not shorten this exit.
        if !retainingHeight || cache.fullSize == nil || cache.fullSize?.width != measured.width {
            cache.fullSize = measured
        }
        let fullSize = cache.fullSize ?? measured
        return CGSize(width: fullSize.width, height: fullSize.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: .init(width: bounds.width, height: nil))
    }
}

struct PhotoEffectsCard<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 8) { content }
            .padding(12)
            .background(ZTransferColors.primaryText.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .background(accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent.opacity(0.24), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// Android uses 3:2 for color controls and 4:3 for frame controls, after the
/// 50pt favorite button and the two 8pt gaps. All three are one 50pt row.
struct PhotoEffectControlRow: Layout {
    var primaryWeight: CGFloat = 4
    var secondaryWeight: CGFloat = 3
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? subviews.reduce(16) { $0 + $1.sizeThatFits(.unspecified).width }, height: PhotoEffectControlMetrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 || subviews.count == 3 else { return }
        let favoriteWidth = subviews.count == 3 ? PhotoEffectControlMetrics.height : 0
        let gaps = CGFloat(subviews.count - 1) * PhotoEffectControlMetrics.gap
        let available = max(0, bounds.width - favoriteWidth - gaps)
        let totalWeight = primaryWeight + secondaryWeight
        let widths = [available * primaryWeight / totalWeight,
                      available * secondaryWeight / totalWeight] + (subviews.count == 3 ? [favoriteWidth] : [])
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: widths[index], height: PhotoEffectControlMetrics.height))
            x += widths[index] + PhotoEffectControlMetrics.gap
        }
    }
}

/// Android watermark rows reserve 42% for names/positions and 29% for values.
struct PhotoEffectParameterRow: Layout {
    let weights: [CGFloat]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 300, height: 34)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == weights.count else { return }
        let available = max(0, bounds.width - CGFloat(max(0, weights.count - 1)) * 8)
        var x = bounds.minX
        for index in subviews.indices {
            let width = available * weights[index]
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: width, height: 34))
            x += width + 8
        }
    }
}

struct PhotoEffectFavoriteButton: View {
    let favorite: Bool
    let enabled: Bool
    var compact = false
    var compactSize: CGFloat = 28
    var description: String? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("skin_preset") private var skin = ZTransferButtonSkin.defaultPreset.rawValue

    private var markColor: Color {
        let dark = colorScheme == .dark
        switch skin {
        case "TITANIUM": return favorite ? hex(dark ? 0xFFE9C7 : 0x5A2800) : hex(dark ? 0xE4ECEF : 0x344149)
        case "WOOD": return favorite ? hex(dark ? 0xFFF0C7 : 0x4A210D) : hex(dark ? 0xF1D6A7 : 0x472A18)
        case "CAMERA_CONTROLS": return hex(favorite ? 0xFFE2A3 : 0xD5D8DA)
        default: return favorite ? ZTransferColors.accentOrange : ZTransferColors.secondaryText
        }
    }

    var body: some View {
        let size = compact ? compactSize : PhotoEffectControlMetrics.height
        Button {
            ZTransferHaptics.shared.play(.favorite)
            action()
        } label: {
            ZStack {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: compact ? max(16, compactSize - 10) : 22))
                    .id(favorite)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.55).animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.19))
                            .combined(with: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15))),
                        removal: .scale(scale: 0.72).animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.13))
                            .combined(with: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.11)))))
            }
            .foregroundStyle(markColor)
            .frame(width: size, height: size)
        }
        .buttonStyle(ZTransferGlassButtonStyle(
            tint: markColor,
            cornerRadius: compact ? 10 : 13,
            active: favorite,
            activeColor: ZTransferColors.accentOrange,
            activeOutline: true,
            materialContentColor: markColor
        ))
        .disabled(!enabled)
        .accessibilityLabel(description ?? AppLocalized.resource(favorite ? "photo_effect_favorite_remove" : "photo_effect_favorite_add"))
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18), value: favorite)
    }

    private func hex(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct PhotoEffectsHint: Equatable {
    let id = UUID()
    let resource: String
}

extension View {
    func photoEffectsHint(_ hint: Binding<PhotoEffectsHint?>, duration: Double,
                          multilineDuration: Double? = nil) -> some View {
        modifier(PhotoEffectsHintModifier(hint: hint, duration: duration, multilineDuration: multilineDuration))
    }
}

private struct PhotoEffectsHintModifier: ViewModifier {
    @Binding var hint: PhotoEffectsHint?
    let duration: Double
    let multilineDuration: Double?
    @State private var height: CGFloat = 40

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let hint {
                Text(AppLocalized.resource(hint.resource))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ZTransferColors.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(ZTransferHintSurface(cornerRadius: 18))
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { height = proxy.size.height }
                    })
                    .padding(.horizontal, 20).padding(.bottom, 28)
                    .transition(.opacity.combined(with: .offset(y: height / 2)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 1), value: hint != nil)
        .task(id: hint?.id) {
            guard let current = hint else { return }
            let text = AppLocalized.resource(current.resource)
            let delay = text.contains("\n") ? (multilineDuration ?? duration) : duration
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            hint = nil
        }
    }
}


private struct PhotoEffectModuleAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct PhotoEffectModuleMenuButton: View {
    @Binding var isPresented: Bool
    var size: CGFloat = 38
    var body: some View {
        Button { isPresented.toggle() } label: {
            RemoteEditorIcon(kind: .tune)
                .fill(ZTransferColors.primaryText)
                .frame(width: 19, height: 19)
                .frame(width: size, height: size)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 20))
        .frame(width: size, height: size)
        .accessibilityLabel(AppLocalized.resource("photo_effect_modules"))
        .accessibilityIdentifier("photo-effect-modules")
        .anchorPreference(key: PhotoEffectModuleAnchorKey.self, value: .bounds) { $0 }
        .onDisappear { isPresented = false }
    }
}

/// Android PhotoEffectModuleMenu uses non-dimming AnchorPopup, including its
/// 320/350ms Genie motion and retained close. Both effects entrypoints use this.
struct PhotoEffectModuleMenuOverlay: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    @Binding var draft: PhotoEffectsSettings
    let lutStore: PhotoLUTStore
    let isPro: Bool
    @State private var mounted = false

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PhotoEffectModuleAnchorKey.self) { anchor in
            if mounted, let anchor {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    let width = min(156, max(1, proxy.size.width - 36))
                    let left = max(0, proxy.size.width - width - 18)
                    let top = rect.maxY + 8
                    let source = GeniePopupMotion.attachmentAnchor(for: rect, cornerRadius: 20)
                    ZStack(alignment: .topLeading) {
                        Color.clear.ignoresSafeArea().contentShape(Rectangle())
                            .onTapGesture { isPresented = false }
                            .gesture(DragGesture(minimumDistance: 1).onChanged { _ in })
                        GeniePopupPanel(content: menu, trigger: .photoEffectModules,
                            targetProgress: isPresented ? 1 : 0,
                            anchorX: (source.midX - left) / width,
                            anchorWidth: source.width / width, anchorGap: top - source.maxY,
                            onSettled: { progress in
                                if progress == 0 && !isPresented { mounted = false }
                            })
                            .frame(width: width)
                            .offset(x: left, y: top)
                    }
                    .background(PopupDragBoundary())
                }
            }
        }
        .onAppear { if isPresented { mounted = true } }
        .onChange(of: isPresented) { if $0 { mounted = true } }
        .onChange(of: colorScheme) { _ in isPresented = false }
        .onDisappear { isPresented = false; mounted = false }
    }

    private var menu: some View {
        VStack(spacing: 8) {
            ForEach(PhotoEffectModule.allCases, id: \.self) { module in
                FilterChip(label: AppLocalized.resource(module.menuLabelKey),
                    selected: photoEffectModuleIsVisible(effectivePhotoEffectModules(
                        draft.photoEffectModules, isPro: isPro), module)) {
                    var value = draft
                    if togglePhotoEffectModuleDraft(module, draft: &value, lutStore: lutStore, isPro: isPro) {
                        ZTransferHaptics.shared.play(.toggle)
                        draft = value
                    }
                }
                .accessibilityIdentifier("photo-effect-module-\(module.rawValue)")
            }
        }
        .padding(12)
        .background { ZTransferGlassSurface(cornerRadius: 18, kind: .panel) }
        .onTapGesture { }
    }
}

extension PhotoEffectModule {
    var menuLabelKey: String {
        switch self {
        case .filter: "photo_effect_module_filter"
        case .lut: "photo_effect_module_lut"
        case .frame: "photo_effect_module_frame"
        case .watermark: "photo_effect_module_watermark"
        case .grain: "photo_grain"
        }
    }
}
