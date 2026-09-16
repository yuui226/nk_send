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
    private func isFavorite(_ preset: PhotoFilterPreset) -> Bool { draft.favoriteFilterIDs.contains(filterKey(preset.id)) }
    private func isFavoriteID(_ id: String) -> Bool { draft.favoriteFilterIDs.contains(filterKey(id)) }
    private var selectedFilterID: String? { draft.photoFilterEnabled ? draft.selectedFilter?.preset.id : nil }
    private var frameEnabled: Bool { draft.photoFrameEnabled && draft.photoFrameBorderEnabled }
    private var watermarkEnabled: Bool { draft.photoFrameEnabled && draft.watermark.enabled }
    private var activeMetadata: PhotoFrameMetadataSettings {
        draft.metadataByPreset[draft.photoFramePreset.rawValue] ?? PhotoFrameMetadataSettings.defaults(for: draft.photoFramePreset)
    }
    private var orderedFrameOptions: [PhotoFramePreset?] {
        // Android keeps the frame wheel in the fixed catalog order and only
        // decorates favorites with the star. Moving favorites to the front
        // changes the detent sequence, so a swipe/click can select a different
        // frame than the Android counterpart.
        return [nil] + PhotoFramePreset.allCases
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
                                onActivated: { withAnimation(ZTransferMotion.inlineExpansion) { metadataExpanded.toggle() } })
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
                                onActivated: { withAnimation(ZTransferMotion.inlineExpansion) { watermarkExpanded.toggle() } })
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
                                        set: { value in updateWatermark { $0.text = String(value.prefix(PhotoFrameWatermark.maxTextLength)) } }
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
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(selected ? .white : ZTransferColors.primaryText).frame(maxWidth: .infinity).frame(height: 48).background(selected ? ZTransferColors.accentBlue : ZTransferColors.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
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

/// Android keeps the last rendered effect visible while a new preview is
/// prepared. Rendering is detached from SwiftUI so wheel interaction remains
/// responsive and a cancelled generation cannot replace a newer one.
struct PhotoEffectsSettingsPreview: View {
    let source: UIImage?
    let metadata: PhotoFrameMetadata?
    let settings: PhotoEffectsSettings
    let onRequest: () -> Void
    @State private var rendered: UIImage?
    @State private var unfiltered: UIImage?
    @State private var showUnfiltered = false
    @State private var prefetched: [String: UIImage] = [:]
    @State private var rotationQuarterTurns = 0
    @State private var expanded = false

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
        let data = try? JSONEncoder().encode(settings)
        let settingsKey = String(data: data ?? Data(), encoding: .utf8) ?? ""
        let sourceKey: String
        if let source {
            sourceKey = "source:\(ObjectIdentifier(source)):\(source.size.width)x\(source.size.height)"
        } else {
            sourceKey = "source:none"
        }
        let metadataKey = metadata.map {
            "meta:\($0.make ?? "")|\($0.model ?? "")|\($0.aperture ?? "")|\($0.shutter ?? "")|\($0.iso ?? "")|\($0.focalLength ?? "")|\($0.lensModel ?? "")|\($0.dateTime ?? "")"
        } ?? "meta:none"
        return settingsKey + "|" + sourceKey + "|" + metadataKey
    }

    private var renderKeyWithRotation: String {
        "\(renderKey)|rotation:\(rotationQuarterTurns)"
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
            if let displayed = showUnfiltered ? (unfiltered ?? rendered) : rendered {
                Image(uiImage: displayed)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
            if !pressing { showUnfiltered = false }
        }, perform: {
            guard unfiltered != nil else { return }
            showUnfiltered = true
        })
        .onTapGesture(count: 2) {
            guard expanded == false else { return }
            rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
        }
        .onTapGesture {
            guard expandedImage != nil else { return }
            expanded = true
        }
        .fullScreenCover(isPresented: $expanded) {
            if let expandedImage {
                PhotoEffectsExpandedPreview(image: expandedImage) {
                    expanded = false
                }
            }
        }
        .task(id: renderKeyWithRotation) {
            // A rotated source is a different pixel canvas. Never promote a
            // prefetch rendered for the previous orientation into the new
            // frame, otherwise the border height briefly snaps back.
            prefetched.removeAll(keepingCapacity: true)
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
                            try PhotoEffectsRenderer.render(rotatedFallback, settings: fallbackSettings, metadata: nil)
                        }
                    }
                }.value
                guard !Task.isCancelled else { return }
                rendered = fallbackResult
                return
            }
            showUnfiltered = false
            unfiltered = nil
            let metadata = metadata
            let settings = settings
            let rotationQuarterTurns = rotationQuarterTurns
            let rotatedSource = Self.rotate(source, quarterTurns: rotationQuarterTurns)
            let result: UIImage?
            if let cached = prefetched.removeValue(forKey: renderKey) {
                result = cached
            } else {
                result = try? await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try await PhotoEffectsPreviewRenderGate.shared.withPermit {
                        try autoreleasepool {
                            try PhotoEffectsRenderer.render(rotatedSource, settings: settings, metadata: metadata)
                        }
                    }
                }.value
            }
            guard !Task.isCancelled else { return }
            rendered = result
            guard settings.photoFilterEnabled, settings.selectedFilter != nil else { return }
            // Android's comparison frame is deliberately delayed so the
            // filtered frame becomes visible first and rapid wheel changes
            // cancel obsolete comparison work.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let baseline: PhotoEffectsSettings = {
                var value = settings
                value.photoFilterEnabled = false
                return value
            }()
            let comparison = try? await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try await PhotoEffectsPreviewRenderGate.shared.withPermit {
                    try autoreleasepool {
                        try PhotoEffectsRenderer.render(rotatedSource, settings: baseline, metadata: metadata)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            unfiltered = comparison

            // Android warms the next two filters only after the current frame is
            // visible. Keep the complete result keyed by the same source,
            // metadata and decoration settings so a wheel step can promote it
            // without another full composition.
            for selection in nextPhotoFilterSelections(for: settings) {
                guard !Task.isCancelled else { return }
                let next: PhotoEffectsSettings = {
                    var value = settings
                    value.photoFilterEnabled = true
                    value.selectedFilter = selection
                    return value
                }()
                let key = Self.makeRenderKey(settings: next, source: source, metadata: metadata)
                guard prefetched[key] == nil else { continue }
                let nextResult = try? await Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try await PhotoEffectsPreviewRenderGate.shared.withPermit {
                        try autoreleasepool {
                            try PhotoEffectsRenderer.render(rotatedSource, settings: next, metadata: metadata)
                        }
                    }
                }.value
                guard !Task.isCancelled else { return }
                if let nextResult {
                    prefetched[key] = nextResult
                    if prefetched.count > 2, let oldest = prefetched.keys.first {
                        prefetched.removeValue(forKey: oldest)
                    }
                }
            }
        }
    }
}

/// Android's expanded effects preview uses the same fitted image surface as
/// the photo viewer: a tap dismisses at 1x, a double tap toggles 2.5x, and a
/// pinch/drag pair keeps the image inside the viewport while zoomed.
private struct PhotoEffectsExpandedPreview: View {
    let image: UIImage
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureStartScale: CGFloat = 1
    @State private var gestureStartOffset: CGSize = .zero

    private let maximumScale: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
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
                                if scale <= 1.01 {
                                    scale = 1
                                    offset = .zero
                                    gestureStartOffset = .zero
                                }
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
                                    viewport: proxy.size,
                                )
                            }
                            .onEnded { _ in
                                gestureStartOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        let target: CGFloat = scale > 1.01 ? 1 : 2.5
                        withAnimation(.easeInOut(duration: 0.24)) {
                            scale = target
                            offset = target > 1 ? .zero : .zero
                        }
                        gestureStartScale = target
                        gestureStartOffset = offset
                    }
                    .onTapGesture {
                        if scale <= 1.01 { onDismiss() }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .statusBarHidden(true)
    }

    private func clamped(_ proposed: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
        // Match Android's fitted-image bounds: only the part that grows past
        // the viewport can be panned, so a portrait image does not acquire a
        // loose horizontal drift when it is enlarged.
        let imageAspect = max(image.size.width, 1) / max(image.size.height, 1)
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
            context.translateBy(x: size.width * 0.5, y: size.height * 0.5)
            context.rotate(by: -.pi * 24 / 180)
            context.setFillColor(UIColor(red: 47 / 255, green: 85 / 255, blue: 94 / 255, alpha: 1).cgColor)
            context.fill(CGRect(x: -1040, y: -210, width: 1860, height: 170))
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
    @AppStorage("haptics_enabled") private var haptics = true

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
            if haptics { UISelectionFeedbackGenerator().selectionChanged() }
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
