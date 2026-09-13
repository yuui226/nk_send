import SwiftUI

/// Android-equivalent draft editor.  All mutations stay in a local draft until
/// 完成; cancelling the sheet never changes the persisted effect configuration.
struct PhotoEffectsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let initial: PhotoEffectsSettings
    let onSave: (PhotoEffectsSettings) -> Void
    @State private var draft: PhotoEffectsSettings

    init(initial: PhotoEffectsSettings, onSave: @escaping (PhotoEffectsSettings) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                PhotoEffectsControls(draft: $draft)
                .padding(.horizontal, ZTransferMetrics.pageHorizontal)
                .padding(.vertical, 12)
            }
            .background(ZTransferColors.background.ignoresSafeArea())
            .navigationTitle(AppLocalized.resource("photo_effects"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(AppLocalized.resource("cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(AppLocalized.resource("done")) { onSave(draft); dismiss() } }
            }
        }
    }
}

/// Shared controls for transfer settings and the inline local workbench. The
/// caller owns whether edits are a cancellable draft or immediately persisted.
struct PhotoEffectsControls: View {
    @Binding var draft: PhotoEffectsSettings
    var showLocationFields = true

    var body: some View {
        VStack(spacing: 10) {
            filterCard
            frameCard
            watermarkCard
            metadataCard
        }
    }

    private var filterCard: some View {
        EditorCard(title: AppLocalized.resource("photo_filter")) {
            EffectToggle(label: AppLocalized.resource("photo_frame_on"), isOn: binding(\.photoFilterEnabled))
            if draft.photoFilterEnabled {
                let ids: [String?] = [nil] + PhotoFilterCatalog.presets.map(\.id)
                DetentWheel(label: AppLocalized.resource("photo_filter"), options: ids,
                            selected: draft.selectedFilter?.preset.id,
                            optionLabel: { id in
                                guard let id else { return AppLocalized.resource("photo_filter_off_option") }
                                guard let preset = Np3FilterCatalog.preset(id: id) else { return AppLocalized.resource("photo_filter_off_option") }
                                return AppLocalized.resource("photo_filter_builtin_\(preset.legacyID)")
                            }, onCommit: { id in
                                guard let id, let preset = PhotoFilterCatalog.presets.first(where: { $0.id == id }) else {
                                    draft.selectedFilter = nil
                                    draft.photoFilterEnabled = false
                                    return
                                }
                                draft.selectedFilter = PhotoFilterSelection(
                                    preset: preset,
                                    intensityPercent: draft.selectedFilter?.intensityPercent ?? 80
                                )
                            })
                DetentWheel(label: AppLocalized.resource("photo_filter_intensity"), options: Array(stride(from: 100, through: 2, by: -2)),
                            selected: draft.selectedFilter?.intensityPercent ?? 80,
                            optionLabel: { "\($0)%" }, onCommit: { value in
                                guard let selected = draft.selectedFilter else { return }
                                draft.selectedFilter = PhotoFilterSelection(preset: selected.preset, intensityPercent: value)
                            }, rowHeight: 26, enabled: draft.selectedFilter != nil)
            }
        }
    }

    private var frameCard: some View {
        EditorCard(title: AppLocalized.resource("photo_frame_and_watermark_short")) {
            EffectToggle(label: AppLocalized.resource("photo_frame_on"), isOn: binding(\.photoFrameEnabled))
            EffectToggle(label: AppLocalized.resource("photo_frame_style_short"), isOn: binding(\.photoFrameBorderEnabled), enabled: draft.photoFrameEnabled)
            if draft.photoFrameEnabled {
                DetentWheel(label: AppLocalized.resource("photo_frame_style_short"), options: PhotoFramePreset.allCases,
                            selected: draft.photoFramePreset,
                            optionLabel: { frameName($0) }, onCommit: { draft.photoFramePreset = $0 }, rowHeight: 28)
            }
        }
    }

    private var watermarkCard: some View {
        EditorCard(title: AppLocalized.resource("photo_frame_watermark_short")) {
            EffectToggle(label: AppLocalized.resource("photo_frame_on"), isOn: binding(\.watermark.enabled), enabled: draft.photoFrameEnabled)
            TextField("", text: Binding(get: { draft.watermark.text }, set: { draft.watermark.text = String($0.prefix(PhotoFrameWatermark.maxTextLength)) }))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).frame(height: 42)
                .background(ZTransferColors.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!draft.photoFrameEnabled || !draft.watermark.enabled)
            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_font"), options: PhotoFrameWatermarkFont.allCases, selected: draft.watermark.font,
                        optionLabel: fontName, onCommit: { draft.watermark.font = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_size"), options: Array(stride(from: 100, through: 1, by: -1)), selected: min(max(draft.watermark.sizePercent, 1), 100),
                        optionLabel: { "\($0)%" }, onCommit: { draft.watermark.sizePercent = $0 }, rowHeight: 26,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_position"), options: PhotoFrameWatermarkPosition.allCases, selected: draft.watermark.position,
                        optionLabel: positionName, onCommit: { draft.watermark.position = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_color"), options: PhotoFrameWatermarkColor.allCases, selected: draft.watermark.color,
                        optionLabel: colorName, onCommit: { draft.watermark.color = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_opacity"), options: Array(stride(from: 100, through: 1, by: -1)), selected: min(max(draft.watermark.opacityPercent, 1), 100),
                        optionLabel: { "\($0)%" }, onCommit: { draft.watermark.opacityPercent = $0 }, rowHeight: 26,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
            DetentWheel(label: AppLocalized.resource("photo_frame_watermark_effect"), options: PhotoFrameWatermarkEffect.allCases, selected: draft.watermark.effect,
                        optionLabel: effectName, onCommit: { draft.watermark.effect = $0 }, rowHeight: 28,
                        enabled: draft.photoFrameEnabled && draft.watermark.enabled)
        }
    }

    private var metadataCard: some View {
        EditorCard(title: AppLocalized.resource("photo_frame_metadata_button")) {
            EffectToggle(label: AppLocalized.resource("photo_frame_metadata_date_format"), isOn: binding(\.metadata.showDate))
            EffectToggle(label: AppLocalized.resource("photo_frame_metadata_time_format"), isOn: binding(\.metadata.showTime))
            EffectToggle(label: AppLocalized.resource("photo_frame_metadata_focal_length"), isOn: binding(\.metadata.showFocalLength))
            EffectToggle(label: AppLocalized.resource("photo_frame_metadata_exposure"), isOn: binding(\.metadata.showExposure))
            EffectToggle(label: AppLocalized.resource("photo_frame_metadata_brand"), isOn: binding(\.metadata.showBrand))
            EffectToggle(label: AppLocalized.resource("photo_frame_metadata_model"), isOn: binding(\.metadata.showModel))
            EffectToggle(label: AppLocalized.resource("photo_frame_metadata_lens_model"), isOn: binding(\.metadata.showLensModel))
            if showLocationFields {
                EffectToggle(label: AppLocalized.resource("photo_frame_metadata_coordinates"), isOn: binding(\.metadata.showCoordinates))
                EffectToggle(label: AppLocalized.resource("photo_frame_metadata_altitude"), isOn: binding(\.metadata.showAltitude))
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PhotoEffectsSettings, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }
    private func frameName(_ value: PhotoFramePreset) -> String {
        switch value {
        case .mist: return AppLocalized.resource("photo_frame_mist"); case .cinema: return AppLocalized.resource("photo_frame_cinema"); case .minimal: return AppLocalized.resource("photo_frame_minimal"); case .frosted: return AppLocalized.resource("photo_frame_frosted")
        case .plaque: return AppLocalized.resource("photo_frame_plaque"); case .immersive: return AppLocalized.resource("photo_frame_immersive"); case .brandInset: return AppLocalized.resource("photo_frame_brand_inset"); case .brandGallery: return AppLocalized.resource("photo_frame_brand_gallery")
        case .classicSignature: return AppLocalized.resource("photo_frame_classic_signature"); case .galleryMat: return AppLocalized.resource("photo_frame_gallery_mat"); case .colorArchive: return AppLocalized.resource("photo_frame_color_archive"); case .filmGallery: return AppLocalized.resource("photo_frame_film_gallery"); case .filmEdge: return AppLocalized.resource("photo_frame_film_edge")
        }
    }
    private func fontName(_ value: PhotoFrameWatermarkFont) -> String {
        switch value { case .signature: return AppLocalized.resource("photo_frame_font_signature"); case .elegant: return AppLocalized.resource("photo_frame_font_elegant"); case .calligraphy: return AppLocalized.resource("photo_frame_font_calligraphy"); case .simple: return AppLocalized.resource("photo_frame_font_simple"); case .bold: return AppLocalized.resource("photo_frame_font_bold") }
    }
    private func positionName(_ value: PhotoFrameWatermarkPosition) -> String {
        switch value {
        case .auto: return AppLocalized.resource("photo_frame_position_auto"); case .left: return AppLocalized.resource("photo_frame_position_left"); case .center: return AppLocalized.resource("photo_frame_position_center"); case .right: return AppLocalized.resource("photo_frame_position_right")
        case .photoTopLeft: return AppLocalized.resource("photo_frame_position_photo_top_left"); case .photoTopCenter: return AppLocalized.resource("photo_frame_position_photo_top_center"); case .photoTopRight: return AppLocalized.resource("photo_frame_position_photo_top_right"); case .photoCenter: return AppLocalized.resource("photo_frame_position_photo_center")
        case .photoBottomLeft: return AppLocalized.resource("photo_frame_position_photo_bottom_left"); case .photoBottomCenter: return AppLocalized.resource("photo_frame_position_photo_bottom_center"); case .photoBottomRight: return AppLocalized.resource("photo_frame_position_photo_bottom_right")
        }
    }
    private func colorName(_ value: PhotoFrameWatermarkColor) -> String {
        switch value { case .adaptive: return AppLocalized.resource("photo_frame_color_adaptive"); case .white: return AppLocalized.resource("photo_frame_color_white"); case .black: return AppLocalized.resource("photo_frame_color_black"); case .gold: return AppLocalized.resource("photo_frame_color_gold"); case .mistBlue: return AppLocalized.resource("photo_frame_color_mist_blue"); case .roseGold: return AppLocalized.resource("photo_frame_color_rose_gold") }
    }
    private func effectName(_ value: PhotoFrameWatermarkEffect) -> String {
        switch value { case .auto: return AppLocalized.resource("photo_frame_effect_auto"); case .none: return AppLocalized.resource("photo_frame_effect_none"); case .shadow: return AppLocalized.resource("photo_frame_effect_shadow"); case .outline: return AppLocalized.resource("photo_frame_effect_outline") }
    }
}

private struct EditorCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).zTransferText(size: ZTransferMetrics.body, weight: .semibold)
            Divider().opacity(0.35)
            content
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 1))
    }
}

private struct EffectToggle: View {
    let label: String
    @Binding var isOn: Bool
    var enabled = true
    var body: some View {
        Button { if enabled { isOn.toggle() } } label: {
            HStack {
                Text(label).zTransferText(size: ZTransferMetrics.body)
                Spacer()
                Text(AppLocalized.settingState(isOn)).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
            }
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
