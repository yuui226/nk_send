import SwiftUI
import UIKit

private enum PhotoEffectControlMetrics {
    static let height: CGFloat = 50
    static let gap: CGFloat = 8
    static let primaryWeight: CGFloat = 4
    static let secondaryWeight: CGFloat = 3
}

/// Android SettingsScreen.PhotoFilterEditor / PhotoFrameWatermarkEditor are
/// shared by transfer settings and LocalPhotoEffectsPage. The caller owns the
/// draft, persistence scope, keyboard focus, and image picker lifecycle.
struct PhotoEffectsControls: View {
    @Binding var draft: PhotoEffectsSettings
    @Binding var showingWatermarkPicker: Bool
    @FocusState.Binding var textFieldFocused: Bool
    var showLocationFields = false
    @State private var metadataExpanded = false
    @State private var watermarkExpanded = false
    @Binding var filterChooser: PhotoFilterChooserState
    var onWatermarkTextCommitted: (String) -> Void = { _ in }
    var onFavoriteImageMissing: () -> Void = {}

    private var filterOptions: [String?] { [nil] + draft.orderedFilters.map(\.id) }
    private func filterKey(_ id: String) -> String {
        PhotoEffectsSettings.filterKey(id)
    }
    private func isFavoriteID(_ id: String) -> Bool { draft.favoriteFilterIDs.contains(filterKey(id)) }
    private var selectedFilterID: String? { draft.photoFilterEnabled ? draft.selectedFilter?.preset.id : nil }
    private var frameEnabled: Bool { draft.photoFrameEnabled && draft.photoFrameBorderEnabled }
    private var watermarkEnabled: Bool { draft.photoFrameEnabled && draft.watermark.enabled }
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
        draft = value
    }
    private func updateWatermark(_ update: (inout PhotoFrameWatermark) -> Void) {
        var value = draft
        update(&value.watermark)
        if frameEnabled, let index = value.favoriteFrameEffects.firstIndex(where: { $0.preset == value.photoFramePreset }) {
            value.favoriteFrameEffects[index].watermark = value.watermark
        }
        draft = value
    }

    var body: some View {
        VStack(spacing: 10) {
            filterCard
            frameCard
        }
        .onChange(of: textFieldFocused) { focused in
            guard !focused else { return }
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

    private var filterCard: some View {
            PhotoEffectsCard(accent: ZTransferColors.accentBlue) {
                PhotoEffectControlRow {
                    DetentWheel(label: AppLocalized.resource("photo_filter"), options: filterOptions, selected: selectedFilterID,
                                optionLabel: { id in
                                    guard let id, let preset = Np3FilterCatalog.preset(id: id) else { return AppLocalized.resource("photo_filter_off_option") }
                                    return AppLocalized.resource("photo_filter_builtin_\(preset.legacyID)")
                                },
                                onCommit: { id in
                                    var value = draft
                                    value.selectFilter(id)
                                    draft = value
                                }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height,
                                onLongClick: { filterChooser.isPresented = true },
                                favoriteOption: { id in id.map(isFavoriteID) ?? false },
                                favoriteIconColor: ZTransferColors.accentOrange)
                    .frame(maxWidth: .infinity)
                    DetentWheel(label: AppLocalized.resource("photo_filter_intensity"), options: Array(stride(from: 100, through: 2, by: -2)),
                                selected: draft.selectedFilter?.intensityPercent ?? 80,
                                optionLabel: { "\($0)%" }, onCommit: { value in
                                    guard let selected = draft.selectedFilter else { return }
                                    var updated = draft
                                    updated.filterIntensities[filterKey(selected.preset.id)] = value
                                    updated.selectedFilter = .init(preset: selected.preset, intensityPercent: value)
                                    draft = updated
                                }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, enabled: selectedFilterID != nil)
                    .frame(maxWidth: .infinity)
                    PhotoEffectFavoriteButton(
                        favorite: selectedFilterID.map(isFavoriteID) == true,
                        enabled: selectedFilterID != nil
                    ) {
                        guard let id = selectedFilterID else { return }
                        var value = draft
                        value.toggleFilterFavorite(id)
                        draft = value
                    }
                }
            }
    }

    private var frameCard: some View {
            PhotoEffectsCard(accent: ZTransferColors.accentOrange) {
                PhotoEffectControlRow {
                    DetentWheel(label: AppLocalized.resource("photo_frame_style_short"), options: orderedFrameOptions,
                                selected: frameEnabled ? draft.photoFramePreset : nil,
                                optionLabel: { $0.map(frameName) ?? AppLocalized.resource("photo_frame_off") }, onCommit: { value in
                                    textFieldFocused = false
                                    var updated = draft
                                    guard let value else {
                                        updated.photoFrameBorderEnabled = false
                                        updated.photoFrameEnabled = updated.watermark.enabled
                                        draft = updated
                                        return
                                    }
                                    if let favorite = updated.favoriteFrameEffects.first(where: { $0.preset == value }) {
                                        guard let watermark = favorite.applying(to: updated.watermark) else {
                                            onFavoriteImageMissing()
                                            return
                                        }
                                        updated.watermark = watermark
                                    }
                                    updated.photoFramePreset = value
                                    updated.photoFrameEnabled = true
                                    updated.photoFrameBorderEnabled = true
                                    updated.metadata = updated.metadataByPreset[value.rawValue] ?? PhotoFrameMetadataSettings.defaults(for: value)
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
                                    ZTransferHaptics.shared.tick()
                                    withAnimation(ZTransferMotion.inlineExpansion) { metadataExpanded.toggle() }
                                })
                    .frame(maxWidth: .infinity)
                    PhotoEffectFavoriteButton(
                        favorite: frameEnabled && draft.favoriteFrameEffects.contains { $0.preset == draft.photoFramePreset },
                        enabled: frameEnabled,
                        action: toggleFrameFavorite
                    )
                }
                if frameEnabled && metadataExpanded {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            metadataButton(AppLocalized.resource("photo_frame_metadata_focal_length"), activeMetadata.showFocalLength) { updateMetadata { $0.showFocalLength.toggle() } }
                            metadataButton(AppLocalized.resource("photo_frame_metadata_exposure"), activeMetadata.showExposure) { updateMetadata { $0.showExposure.toggle() } }
                            metadataButton(AppLocalized.resource("photo_frame_metadata_lens_model"), activeMetadata.showLensModel) { updateMetadata { $0.showLensModel.toggle() } }
                        }
                        HStack(spacing: 8) {
                            metadataButton(AppLocalized.resource("photo_frame_metadata_brand"), activeMetadata.showBrand) { updateMetadata { $0.showBrand.toggle() } }
                            metadataButton(AppLocalized.resource("photo_frame_metadata_model"), activeMetadata.showModel) { updateMetadata { $0.showModel.toggle() } }
                            if showLocationFields {
                                metadataButton(AppLocalized.resource("photo_frame_metadata_coordinates"), activeMetadata.showCoordinates) { updateMetadata { $0.showCoordinates.toggle() } }
                            }
                        }
                        if showLocationFields {
                            metadataButton(AppLocalized.resource("photo_frame_metadata_altitude"), activeMetadata.showAltitude) { updateMetadata { $0.showAltitude.toggle() } }
                        }
                        HStack(spacing: 8) {
                            let datePatterns: [String?] = [nil, "yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "MM-dd-yyyy"]
                            let timePatterns: [String?] = [nil, "HH:mm", "HH:mm:ss", "HH.mm", "HH.mm.ss"]
                            DetentWheel(label: AppLocalized.resource("photo_frame_metadata_date_format"), options: datePatterns, selected: activeMetadata.showDate ? activeMetadata.datePattern : nil,
                                        optionLabel: { value in
                                            guard let value else { return AppLocalized.resource("photo_frame_off") }
                                            switch value { case "yyyy-MM-dd": return "2026-08-17"; case "yyyy/MM/dd": return "2026/08/17"; case "yyyy.MM.dd": return "2026.08.17"; default: return "08-17-2026" }
                                        }, onCommit: { value in updateMetadata { $0.showDate = value != nil; if let value { $0.datePattern = value } } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentOrange)
                            DetentWheel(label: AppLocalized.resource("photo_frame_metadata_time_format"), options: timePatterns, selected: activeMetadata.showTime ? activeMetadata.timePattern : nil,
                                        optionLabel: { value in
                                            guard let value else { return AppLocalized.resource("photo_frame_off") }
                                            switch value { case "HH:mm": return "14:32"; case "HH:mm:ss": return "14:32:08"; case "HH.mm": return "14.32"; default: return "14.32.08" }
                                        }, onCommit: { value in updateMetadata { $0.showTime = value != nil; if let value { $0.timePattern = value } } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentOrange)
                        }
                    }
                    .padding(8)
                    .background(.thinMaterial.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZTransferColors.secondaryText.opacity(0.18)))
                    .padding(.top, 4)
                    .transition(.opacity)
                }
                VStack(spacing: 0) {
                HStack(spacing: 8) {
                    DetentWheel(label: AppLocalized.resource("photo_frame_watermark_short"), options: [false, true], selected: watermarkEnabled,
                                optionLabel: { $0 ? AppLocalized.resource("photo_frame_on") : AppLocalized.resource("photo_frame_off") }, onCommit: { value in
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
                                }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, enabled: true, accentColor: ZTransferColors.accentPurple)
                    DetentWheel(label: "", options: [false], selected: false,
                                optionLabel: { _ in AppLocalized.resource("photo_frame_watermark_settings_button") }, onCommit: { _ in }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height,
                                enabled: watermarkEnabled, accentColor: ZTransferColors.accentPurple,
                                emphasized: watermarkExpanded, showDragHint: false,
                                onActivated: {
                                    ZTransferHaptics.shared.tick()
                                    withAnimation(ZTransferMotion.inlineExpansion) { watermarkExpanded.toggle() }
                                })
                }
                if watermarkExpanded && watermarkEnabled {
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
                                            selected: draft.watermark.content,
                                            optionLabel: { $0 == .text ? AppLocalized.resource("photo_frame_content_text") : AppLocalized.resource("photo_frame_content_image") },
                                            onCommit: { value in
                                                if value == .image && draft.watermark.imageHash == nil {
                                                    showingWatermarkPicker = true
                                                } else {
                                                    updateWatermark { $0.content = value }
                                                }
                                            }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height,
                                            accentColor: ZTransferColors.accentPurple)
                                .frame(width: typeWidth)
                                if draft.watermark.content == .text {
                                    TextField("", text: Binding(
                                        get: { draft.watermark.text },
                                        set: { value in
                                            updateWatermark {
                                                $0.text = PhotoFrameWatermark.limitText(value)
                                            }
                                        }
                                    ))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.center)
                                    .focused($textFieldFocused)
                                    .submitLabel(.done)
                                    .onSubmit { textFieldFocused = false }
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: PhotoEffectControlMetrics.height)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(ZTransferColors.secondaryText.opacity(0.15)))
                                } else {
                                    Button { showingWatermarkPicker = true } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "photo").font(.system(size: 16, weight: .medium))
                                            Text(AppLocalized.resource("photo_frame_replace_image")).font(.system(size: 14, weight: .medium))
                                        }
                                        .foregroundStyle(ZTransferColors.primaryText)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: PhotoEffectControlMetrics.height)
                                    }
                                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 13))
                                }
                            }
                        }
                        .frame(height: PhotoEffectControlMetrics.height)
                        if draft.watermark.content == .text {
                            HStack(spacing: 8) {
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_font"), options: PhotoFrameWatermarkFont.allCases, selected: draft.watermark.font, optionLabel: fontName, onCommit: { value in updateWatermark { $0.font = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_size"), options: Array(PhotoFrameWatermark.sizeRange.reversed()), selected: draft.watermark.sizePercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.sizePercent = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_opacity"), options: Array(PhotoFrameWatermark.opacityRange.reversed()), selected: draft.watermark.opacityPercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.opacityPercent = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                            }
                            HStack(spacing: 8) {
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_position"), options: textWatermarkPositions, selected: textWatermarkPositions.contains(draft.watermark.position) ? draft.watermark.position : .photoBottomCenter, optionLabel: positionName, onCommit: { value in updateWatermark { $0.position = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_color"), options: PhotoFrameWatermarkColor.allCases, selected: draft.watermark.color, optionLabel: colorName, onCommit: { value in updateWatermark { $0.color = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_effect"), options: PhotoFrameWatermarkEffect.allCases, selected: draft.watermark.effect, optionLabel: effectName, onCommit: { value in updateWatermark { $0.effect = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                            }
                        } else {
                            HStack(spacing: 8) {
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_size"), options: Array(PhotoFrameWatermark.sizeRange.reversed()), selected: draft.watermark.sizePercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.sizePercent = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_opacity"), options: Array(PhotoFrameWatermark.opacityRange.reversed()), selected: draft.watermark.opacityPercent, optionLabel: { "\($0)%" }, onCommit: { value in updateWatermark { $0.opacityPercent = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                                DetentWheel(label: AppLocalized.resource("photo_frame_watermark_position"), options: photoWatermarkPositions, selected: photoWatermarkPositions.contains(draft.watermark.position) ? draft.watermark.position : .photoBottomCenter, optionLabel: positionName, onCommit: { value in updateWatermark { $0.position = value } }, rowHeight: 18, wheelHeight: PhotoEffectControlMetrics.height, accentColor: ZTransferColors.accentPurple)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .transition(.opacity)
                }
                }
                .padding(8)
                .background(ZTransferColors.accentPurple.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZTransferColors.accentPurple.opacity(0.18)))
                .padding(.top, 8)
            }
    }

    private func metadataButton(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ZTransferHaptics.shared.tick()
            action()
        } label: {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(selected ? .white : ZTransferColors.primaryText).frame(maxWidth: .infinity).frame(height: 48).background(selected ? ZTransferColors.accentBlue : ZTransferColors.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private func toggleFrameFavorite() {
        guard frameEnabled else { return }
        var value = draft
        let preset = value.photoFramePreset
        if let index = value.favoriteFrameEffects.firstIndex(where: { $0.preset == preset }) {
            value.favoriteFrameEffects.remove(at: index)
            value.favoriteFramePresets.remove(preset)
        } else {
            value.favoriteFrameEffects.append(.init(preset: preset, watermark: value.watermark))
            value.favoriteFramePresets.insert(preset)
        }
        draft = value
    }
    private func frameName(_ value: PhotoFramePreset) -> String {
        switch value {
        case .mist: return AppLocalized.resource("photo_frame_mist"); case .cinema: return AppLocalized.resource("photo_frame_cinema"); case .minimal: return AppLocalized.resource("photo_frame_minimal"); case .frosted: return AppLocalized.resource("photo_frame_frosted"); case .plaque: return AppLocalized.resource("photo_frame_plaque"); case .immersive: return AppLocalized.resource("photo_frame_immersive"); case .brandInset: return AppLocalized.resource("photo_frame_brand_inset"); case .brandGallery: return AppLocalized.resource("photo_frame_brand_gallery"); case .classicSignature: return AppLocalized.resource("photo_frame_classic_signature"); case .galleryMat: return AppLocalized.resource("photo_frame_gallery_mat"); case .colorArchive: return AppLocalized.resource("photo_frame_color_archive"); case .filmGallery: return AppLocalized.resource("photo_frame_film_gallery"); case .filmEdge: return AppLocalized.resource("photo_frame_film_edge")
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

private struct PhotoEffectsPreviewFrameKey: Hashable {
    let image: ObjectIdentifier
    let canvas: String
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
    var cornerRadius: CGFloat = 0
    var restoreRevision = 0

    @State private var visible: PhotoEffectsPreviewFrame
    @State private var outgoing: PhotoEffectsPreviewFrame?
    @State private var incomingOpacity: CGFloat = 1
    @State private var replacementOpacity: CGFloat = 1

    init(
        frame: PhotoEffectsPreviewFrame,
        requestedCanvasKey: String,
        showComparison: Bool,
        cornerRadius: CGFloat = 0,
        restoreRevision: Int = 0
    ) {
        self.frame = frame
        self.requestedCanvasKey = requestedCanvasKey
        self.showComparison = showComparison
        self.cornerRadius = cornerRadius
        self.restoreRevision = restoreRevision
        _visible = State(initialValue: frame)
    }

    private var frameKey: PhotoEffectsPreviewFrameKey {
        .init(image: ObjectIdentifier(frame.image), canvas: frame.canvasKey)
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
            layer(
                visible,
                opacity: replacementOpacity * (outgoing == nil ? 1 : incomingOpacity)
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: requestedCanvasKey) {
            if visible.canvasKey != requestedCanvasKey {
                withAnimation(.linear(duration: 0.11)) { replacementOpacity = 0 }
            } else {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.19)) {
                    replacementOpacity = 1
                }
            }
        }
        .task(id: frameKey) {
            let next = frame
            guard ObjectIdentifier(next.image) != ObjectIdentifier(visible.image) else {
                visible = next
                if next.canvasKey == requestedCanvasKey {
                    withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.19)) {
                        replacementOpacity = 1
                    }
                }
                return
            }
            if next.canvasKey != visible.canvasKey {
                withAnimation(.linear(duration: 0.11)) { replacementOpacity = 0 }
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                outgoing = nil
                visible = next
                incomingOpacity = 1
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.19)) {
                    replacementOpacity = 1
                }
            } else {
                outgoing = visible
                visible = next
                replacementOpacity = 1
                incomingOpacity = 0
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)) {
                    incomingOpacity = 1
                }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled,
                      ObjectIdentifier(visible.image) == ObjectIdentifier(next.image) else { return }
                outgoing = nil
            }
        }
        .task(id: restoreRevision) {
            guard restoreRevision > 0 else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.19)) {
                replacementOpacity = 1
            }
        }
    }
}

func photoEffectsPreviewCanvasKey(_ settings: PhotoEffectsSettings, rotationQuarterTurns: Int = 0) -> String {
    let border = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
        ? settings.photoFramePreset.rawValue
        : "none"
    return "rotation:\(rotationQuarterTurns)|frame:\(border)"
}

/// Android keeps the last rendered effect visible while a new preview is
/// prepared. Rendering is detached from SwiftUI so wheel interaction remains
/// responsive and a cancelled generation cannot replace a newer one.
struct PhotoEffectsSettingsPreview: View {
    let source: UIImage?
    let metadata: PhotoFrameMetadata?
    let settings: PhotoEffectsSettings
    let onRequest: () -> Void
    @State private var rendered: UIImage?
    @State private var renderedRequestKey = ""
    @State private var renderedCanvasKey = ""
    @State private var unfiltered: UIImage?
    @State private var previewRestoreRevision = 0
    @State private var previewFailed = false
    @State private var showUnfiltered = false
    @State private var prefetched: [String: UIImage] = [:]
    @State private var filteredSource: UIImage?
    @State private var filteredSourceKey: PhotoFilterSelection?
    @State private var lastPreviewSettings: PhotoEffectsSettings?
    @State private var cachedContextKey = ""
    @State private var rotationQuarterTurns = 0
    @State private var expanded = false
    @State private var previewAnchor: CGRect = .zero

    private var sourceIsPortrait: Bool {
        let portrait = source.map { $0.size.height > $0.size.width } ?? false
        return rotationQuarterTurns.isMultiple(of: 2) ? portrait : !portrait
    }

    private var renderKey: String {
        Self.makeRenderKey(settings: settings, source: source, metadata: metadata)
    }

    private static func makeRenderKey(
        settings: PhotoEffectsSettings,
        source: UIImage?,
        metadata: PhotoFrameMetadata?,
    ) -> String {
        let data = try? JSONEncoder().encode(photoEffectsPreviewPixelSettings(settings))
        let settingsKey = String(data: data ?? Data(), encoding: .utf8) ?? ""
        let sourceKey: String
        if let source {
            sourceKey = "source:\(ObjectIdentifier(source)):\(source.size.width)x\(source.size.height)"
        } else {
            sourceKey = "source:none"
        }
        let metadataKey = Self.metadataKey(metadata)
        return settingsKey + "|" + sourceKey + "|" + metadataKey
    }

    private static func metadataKey(_ metadata: PhotoFrameMetadata?) -> String {
        guard let metadata else { return "meta:none" }
        let fields = [
            metadata.make ?? "", metadata.model ?? "", metadata.aperture ?? "",
            metadata.shutter ?? "", metadata.iso ?? "", metadata.focalLength ?? "",
            metadata.lensModel ?? "", metadata.dateTime ?? "",
            metadata.latitude.map { String($0) } ?? "",
            metadata.longitude.map { String($0) } ?? "",
            metadata.altitude.map { String($0) } ?? "",
        ]
        return "meta:" + fields.joined(separator: "|")
    }

    private var renderKeyWithRotation: String {
        "\(renderKey)|rotation:\(rotationQuarterTurns)"
    }

    private var requestedCanvasKey: String {
        photoEffectsPreviewCanvasKey(settings, rotationQuarterTurns: rotationQuarterTurns)
    }

    private var sourceContextKey: String {
        Self.makeSourceContextKey(source: source, metadata: metadata,
                                  rotationQuarterTurns: rotationQuarterTurns)
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

    private static func comparisonPreview(
        image: UIImage, settings: PhotoEffectsSettings, metadata: PhotoFrameMetadata?
    ) async -> UIImage? {
        do {
            try await Task.sleep(for: .milliseconds(500))
            return try await LocalPhotoOutput.unfilteredPreview(
                image: image, settings: settings, metadata: metadata
            )
        } catch { return nil }
    }

    private static func prefetchedPreviews(
        image: UIImage, sourceIdentity: UIImage, settings: PhotoEffectsSettings,
        metadata: PhotoFrameMetadata?, rotationQuarterTurns: Int
    ) async -> [(String, UIImage)] {
        var results: [(String, UIImage)] = []
        do {
            for selection in nextPhotoFilterSelections(for: settings) {
                try Task.checkCancellation()
                var next = settings
                next.photoFilterEnabled = true
                next.selectedFilter = selection
                let nextFiltered = try await LocalPhotoOutput.filteredSource(
                    image: image, selection: selection
                )
                let preview = try await LocalPhotoOutput.preview(
                    image: image, settings: next, metadata: metadata,
                    filteredSource: nextFiltered
                )
                let base = makeRenderKey(settings: next, source: sourceIdentity, metadata: metadata)
                results.append(("\(base)|rotation:\(rotationQuarterTurns)", preview.filtered))
            }
        } catch {}
        return results
    }

    private static func rotate(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let sourceSize = image.size
        let rotatedSize = turns.isMultiple(of: 2)
            ? sourceSize
            : CGSize(width: sourceSize.height, height: sourceSize.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = image.cgImage != nil
        return UIGraphicsImageRenderer(size: rotatedSize, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            context.rotate(by: -.pi / 2 * CGFloat(turns))
            context.translateBy(x: -sourceSize.width / 2, y: -sourceSize.height / 2)
            image.draw(in: CGRect(origin: .zero, size: sourceSize))
        }
    }

    private var expandedImage: UIImage? { rendered ?? source }

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
                    restoreRevision: previewRestoreRevision
                )
                .overlay(alignment: .bottom) {
                    if previewFailed { previewUnavailableBadge }
                }
            } else if previewFailed, let source {
                Image(uiImage: source)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottom) { previewUnavailableBadge }
            } else if source != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ZTransferColors.primaryText.opacity(0.045))
                    .overlay { ProgressView().tint(ZTransferColors.secondaryText) }
            } else {
                // Keep a real 4:3 preview surface while the connected list is
                // still resolving its latest file. An EmptyView collapses the
                // aspect-ratio proposal to zero, which prevents the fallback
                // render task from ever producing a visible preview in the
                // settings page.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ZTransferColors.primaryText.opacity(0.045))
                    .overlay { ProgressView().tint(ZTransferColors.secondaryText) }
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
                Color.clear.preference(
                    key: PhotoEffectsPreviewAnchorPreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        }
        .onPreferenceChange(PhotoEffectsPreviewAnchorPreferenceKey.self) { previewAnchor = $0 }
        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
            if !pressing { showUnfiltered = false }
        }, perform: {
            guard unfiltered != nil else { return }
            showUnfiltered = true
        })
        .simultaneousGesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { gesture in
                    switch gesture {
                    case .first:
                        guard expanded == false else { return }
                        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
                    case .second:
                        guard expandedImage != nil else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { expanded = true }
                    }
                }
        )
        .fullScreenCover(isPresented: $expanded) {
            if let expandedImage {
                PhotoEffectsExpandedPreview(image: expandedImage, initialAnchor: previewAnchor) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { expanded = false }
                }
            }
        }
        .task(id: renderKeyWithRotation) {
            let pixelSettings = photoEffectsPreviewPixelSettings(settings)
            if let previous = lastPreviewSettings,
               Self.differsOnlyInWatermarkText(previous, pixelSettings) {
                // Android delays only text-only edits. Each new keystroke
                // cancels this task before any pixel work begins.
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }
            lastPreviewSettings = pixelSettings
            previewFailed = false
            if cachedContextKey != sourceContextKey {
                // Rotation/source/EXIF changes invalidate every pixel cache;
                // border and watermark edits deliberately do not.
                cachedContextKey = sourceContextKey
                prefetched.removeAll(keepingCapacity: true)
                filteredSource = nil
                filteredSourceKey = nil
            }
            guard let source else {
                onRequest()
                // Android gives the real thumbnail/FHD request a 2200 ms
                // grace period before showing its deterministic demo source.
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                let fallback = PhotoEffectsFallbackSource.make()
                let rotatedFallback = Self.rotate(fallback, quarterTurns: rotationQuarterTurns)
                let fallbackSettings = settings
                let fallbackResult = try? await Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try await PhotoEffectsPreviewRenderGate.shared.withPermit {
                        try autoreleasepool {
                            try PhotoEffectsRenderer.render(
                                rotatedFallback, settings: fallbackSettings, metadata: nil,
                                previewPlaceholders: true, previewLongEdge: 1_920
                            )
                        }
                    }
                }.value
                guard !Task.isCancelled else { return }
                guard let fallbackResult else {
                    previewFailed = true
                    previewRestoreRevision &+= 1
                    return
                }
                renderedCanvasKey = requestedCanvasKey
                rendered = fallbackResult
                renderedRequestKey = renderKeyWithRotation
                previewFailed = false
                return
            }
            showUnfiltered = false
            unfiltered = nil
            let metadata = metadata
            let settings = settings
            let rotationQuarterTurns = rotationQuarterTurns
            let rotatedSource = Self.rotate(source, quarterTurns: rotationQuarterTurns)
            let result: UIImage?
            if let cached = prefetched.removeValue(forKey: renderKeyWithRotation) {
                result = cached
            } else {
                let filterKey = settings.photoFilterEnabled ? settings.selectedFilter : nil
                let preparedSource: UIImage?
                if let filterKey {
                    if filteredSourceKey == filterKey, let filteredSource {
                        preparedSource = filteredSource
                    } else {
                        let next = try? await LocalPhotoOutput.filteredSource(
                            image: rotatedSource, selection: filterKey
                        )
                        guard !Task.isCancelled else { return }
                        filteredSource = next
                        filteredSourceKey = filterKey
                        preparedSource = next
                    }
                } else {
                    filteredSource = nil
                    filteredSourceKey = nil
                    preparedSource = nil
                }
                result = try? await LocalPhotoOutput.preview(
                    image: rotatedSource, settings: settings, metadata: metadata,
                    filteredSource: preparedSource
                ).filtered
            }
            guard !Task.isCancelled else { return }
            guard let result else {
                previewFailed = true
                previewRestoreRevision &+= 1
                return
            }
            renderedCanvasKey = requestedCanvasKey
            rendered = result
            renderedRequestKey = renderKeyWithRotation
            previewFailed = false
            guard settings.photoFilterEnabled, settings.selectedFilter != nil else { return }

            // The comparison starts as soon as the current image is visible.
            // Neighbor warming is a separate task below so a favorite-order
            // change does not rebuild or animate the current frame.
            let comparison = await Self.comparisonPreview(
                image: rotatedSource, settings: settings, metadata: metadata
            )
            if let comparison, !Task.isCancelled {
                unfiltered = comparison
            }
        }
        .task(id: prefetchRequest) {
            guard prefetchRequest.enabled, let source else { return }
            let rotation = rotationQuarterTurns
            let rotatedSource = Self.rotate(source, quarterTurns: rotation)
            let warmedResults = await Self.prefetchedPreviews(
                image: rotatedSource, sourceIdentity: source, settings: settings,
                metadata: metadata, rotationQuarterTurns: rotation
            )
            guard !Task.isCancelled else { return }
            for (key, image) in warmedResults where prefetched[key] == nil {
                prefetched[key] = image
                if prefetched.count > 2, let oldest = prefetched.keys.first {
                    prefetched.removeValue(forKey: oldest)
                }
            }
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
private struct PhotoEffectsExpandedPreview: View {
    let image: UIImage
    let initialAnchor: CGRect
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureStartScale: CGFloat = 1
    @State private var gestureStartOffset: CGSize = .zero
    @State private var rotationDegrees: Double = 0
    @State private var presentationProgress: CGFloat = 0
    @State private var closing = false

    private let maximumScale: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.74 * presentationProgress).ignoresSafeArea()
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .rotationEffect(.degrees(rotationDegrees))
                        .contentShape(Rectangle())
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let next = min(max(gestureStartScale * value, 1), maximumScale)
                                    scale = next
                                    offset = clamped(offset, scale: next, viewport: proxy.size)
                                }
                                .onEnded { _ in
                                    gestureStartScale = scale
                                    gestureStartOffset = offset
                                    if scale <= 1.01 { resetZoom() }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard scale > 1.01 else { return }
                                    offset = clamped(
                                        CGSize(width: gestureStartOffset.width + value.translation.width,
                                               height: gestureStartOffset.height + value.translation.height),
                                        scale: scale,
                                        viewport: proxy.size
                                    )
                                }
                                .onEnded { _ in gestureStartOffset = offset }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .exclusively(before: TapGesture(count: 1))
                                .onEnded { gesture in
                                    switch gesture {
                                    case .first:
                                        let target: CGFloat = scale > 1.01 ? 1 : 2.5
                                        withAnimation(.easeInOut(duration: 0.24)) {
                                            scale = target
                                            offset = .zero
                                        }
                                        gestureStartScale = target
                                        gestureStartOffset = .zero
                                    case .second:
                                        if scale <= 1.01 { startClose() }
                                    }
                                }
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(PhotoPreviewAnchorTransform(
                    progress: presentationProgress,
                    anchor: initialAnchor == .zero ? nil : initialAnchor,
                    enabled: true,
                    closing: closing
                ))

                Text(AppLocalized.resource("photo_effects"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85 * presentationProgress))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 52)
                    .padding(.top, proxy.safeAreaInsets.top + 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Button {
                    rotationDegrees -= 90
                    resetZoom()
                } label: {
                    Image(systemName: "rotate.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalized.resource("cd_rotate_photo"))
                .opacity(presentationProgress)
                .padding(.trailing, 20)
                .padding(.bottom, proxy.safeAreaInsets.bottom + 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .allowsHitTesting(!closing)
        }
        .statusBarHidden(true)
        .onAppear {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.34)) {
                presentationProgress = 1
            }
        }
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
        gestureStartScale = 1
        gestureStartOffset = .zero
    }

    private func startClose() {
        guard !closing else { return }
        closing = true
        Task { @MainActor in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) {
                presentationProgress = 0
            }
            try? await Task.sleep(for: .milliseconds(260))
            onDismiss()
        }
    }

    private func clamped(_ proposed: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
        // Match Android's fitted-image bounds: only the part that grows past
        // the viewport can be panned, so a portrait image does not acquire a
        // loose horizontal drift when it is enlarged.
        let turns = ((Int(-rotationDegrees / 90) % 4) + 4) % 4
        let size = turns.isMultiple(of: 2)
            ? image.size
            : CGSize(width: image.size.height, height: image.size.width)
        let imageAspect = max(size.width, 1) / max(size.height, 1)
        let viewportAspect = max(viewport.width, 1) / max(viewport.height, 1)
        let fittedWidth = imageAspect > viewportAspect
            ? viewport.width
            : viewport.height * imageAspect
        let fittedHeight = imageAspect > viewportAspect
            ? viewport.width / imageAspect
            : viewport.height
        let maxX = max(0, (fittedWidth * scale - viewport.width) / 2)
        let maxY = max(0, (fittedHeight * scale - viewport.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }
}

private struct PhotoEffectsPreviewAnchorPreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Android's `nextPhotoFilterSelections`: preserve the catalog's favorite-first
/// order and warm only the two entries after the current selection.
func nextPhotoFilterSelections(for settings: PhotoEffectsSettings) -> [PhotoFilterSelection] {
    guard settings.photoFilterEnabled, let selected = settings.selectedFilter else { return [] }
    let ordered = settings.orderedFilters
    guard let index = ordered.firstIndex(where: { $0.id == selected.preset.id }),
          index < ordered.index(before: ordered.endIndex) else { return [] }
    return ordered.dropFirst(index + 1).prefix(2).map { preset in
        let key = PhotoEffectsSettings.filterKey(preset.id)
        return PhotoFilterSelection(
            preset: preset,
            intensityPercent: settings.filterIntensities[key] ?? 80,
        )
    }
}

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

private struct PhotoEffectsCard<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 8) { content }
            .padding(12)
            .background(ZTransferColors.primaryText.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .background(accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.24), lineWidth: 1))
    }
}

enum PhotoEffectFilterCategory: String, CaseIterable, Identifiable {
    case all, favorites, landscape, portrait, monochrome, film, cinematic, color
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"; case .favorites: return "收藏"; case .landscape: return "风景"; case .portrait: return "人像"
        case .monochrome: return "黑白"; case .film: return "胶片"; case .cinematic: return "电影感"; case .color: return "色彩"
        }
    }
}

private extension PhotoFilterPreset {
    var category: PhotoEffectFilterCategory {
        let value = name
        if value.range(of: "黑白|单色|Mono", options: [.regularExpression, .caseInsensitive]) != nil { return .monochrome }
        if value.range(of: "人像|Portrait|Skin|Love Glow|Warm Portrait|Soft Portrait", options: [.regularExpression, .caseInsensitive]) != nil { return .portrait }
        if value.range(of: "风景|Landscape|Nature|Forest|Fern|Moss|Urban Green|Blue Hour|Sunset", options: [.regularExpression, .caseInsensitive]) != nil { return .landscape }
        if value.range(of: "电影|Cine|Cinema|Teal and Orange|Dusk", options: [.regularExpression, .caseInsensitive]) != nil { return .cinematic }
        if value.range(of: "胶片|Film|Vintage|Darkroom", options: [.regularExpression, .caseInsensitive]) != nil { return .film }
        return .color
    }
}


struct PhotoFilterChooserState {
    var isPresented = false
    var category: PhotoEffectFilterCategory = .all
}

/// Hosted above the page/popup, outside its ScrollView and clipping bounds.
struct PhotoFilterChooserOverlay: View {
    @Binding var draft: PhotoEffectsSettings
    @Binding var state: PhotoFilterChooserState

    private var items: [PhotoFilterPreset] {
        draft.orderedFilters.filter { preset in
            switch state.category {
            case .all: return true
            case .favorites: return draft.favoriteFilterIDs.contains(PhotoEffectsSettings.filterKey(preset.id))
            default: return preset.category == state.category
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let maximumHeight = min(max(proxy.size.height - 160, 360), 440)
            let contentHeight = min(max(334, CGFloat(items.count * 44 - 4)), maximumHeight)
            ZStack {
                Color.black.opacity(0.32).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { state.isPresented = false }
                HStack(spacing: 8) {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(PhotoEffectFilterCategory.allCases) { category in
                                Button { state.category = category } label: {
                                    Text(category.title)
                                        .font(.system(size: 14, weight: state.category == category ? .semibold : .regular))
                                        .foregroundStyle(state.category == category ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                        .background(state.category == category ? ZTransferColors.accentBlue.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(width: 84)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(items) { preset in
                                Button {
                                    var updated = draft
                                    updated.selectFilter(preset.id)
                                    draft = updated
                                    state.isPresented = false
                                } label: {
                                    HStack(spacing: 8) {
                                        if draft.favoriteFilterIDs.contains(PhotoEffectsSettings.filterKey(preset.id)) {
                                            Image(systemName: "star.fill").font(.system(size: 18))
                                                .foregroundStyle(ZTransferColors.accentYellow)
                                        }
                                        Text(AppLocalized.resource("photo_filter_builtin_\(Np3FilterCatalog.preset(id: preset.id)?.legacyID ?? preset.id)"))
                                            .font(.system(size: 14)).foregroundStyle(ZTransferColors.primaryText)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                    .background(draft.photoFilterEnabled && draft.selectedFilter?.preset.id == preset.id ? ZTransferColors.accentBlue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(width: min(280, proxy.size.width - 48), height: contentHeight + 20)
                .background(ZTransferGlassSurface(cornerRadius: 18, kind: .panel))
                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .zIndex(200)
    }
}

/// Android gives the primary/secondary wheels 4:3 of the width left after the
/// 50pt favorite button and the two 8pt gaps. All three are one 50pt row.
private struct PhotoEffectControlRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? subviews.reduce(16) { $0 + $1.sizeThatFits(.unspecified).width }, height: PhotoEffectControlMetrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let available = max(0, bounds.width - PhotoEffectControlMetrics.height - 2 * PhotoEffectControlMetrics.gap)
        let totalWeight = PhotoEffectControlMetrics.primaryWeight + PhotoEffectControlMetrics.secondaryWeight
        let widths = [available * PhotoEffectControlMetrics.primaryWeight / totalWeight,
                      available * PhotoEffectControlMetrics.secondaryWeight / totalWeight,
                      PhotoEffectControlMetrics.height]
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: widths[index], height: PhotoEffectControlMetrics.height))
            x += widths[index] + PhotoEffectControlMetrics.gap
        }
    }
}

private struct PhotoEffectFavoriteButton: View {
    let favorite: Bool
    let enabled: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("skin_preset") private var skin = "FROSTED_GLASS"

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
        Button {
            ZTransferHaptics.shared.tick()
            action()
        } label: {
            ZStack {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 22))
                    .id(favorite)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.55).animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.19))
                            .combined(with: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15))),
                        removal: .scale(scale: 0.72).animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.13))
                            .combined(with: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.11)))))
            }
            .foregroundStyle(markColor)
            .frame(width: PhotoEffectControlMetrics.height, height: PhotoEffectControlMetrics.height)
        }
        .buttonStyle(ZTransferGlassButtonStyle(tint: markColor, cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ZTransferColors.accentOrange.opacity(favorite ? 0.75 : 0), lineWidth: 1))
        .disabled(!enabled).opacity(enabled ? 1 : 0.48)
        .accessibilityLabel(AppLocalized.resource(favorite ? "photo_effect_favorite_remove" : "photo_effect_favorite_add"))
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
    func photoEffectsHint(_ hint: Binding<PhotoEffectsHint?>, duration: Double) -> some View {
        modifier(PhotoEffectsHintModifier(hint: hint, duration: duration))
    }
}

private struct PhotoEffectsHintModifier: ViewModifier {
    @Binding var hint: PhotoEffectsHint?
    let duration: Double
    @State private var height: CGFloat = 40

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let hint {
                Text(AppLocalized.resource(hint.resource))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ZTransferColors.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(ZTransferGlassSurface(cornerRadius: 18, kind: .panel))
                    .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
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
            guard hint != nil else { return }
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            hint = nil
        }
    }
}
