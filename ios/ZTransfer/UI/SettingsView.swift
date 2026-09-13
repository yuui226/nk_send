import SwiftUI
import UIKit
import PhotosUI

struct SettingsView: View {
    @ObservedObject private var directory: DirectoryAccessStore
    @ObservedObject private var effectsStore: PhotoEffectsStore
    @State private var showingPicker = false
    @State private var feedbackHint = false
    @State private var settingsPage: SettingsPage = .main
    @Binding private var effectsDraft: PhotoEffectsSettings
    @Binding private var filterChooser: PhotoFilterChooserState
    @Binding private var effectsHint: PhotoEffectsHint?
    @State private var showingWatermarkPicker = false
    @State private var watermarkPickerItems: [PhotosPickerItem] = []
    @FocusState private var watermarkTextFocused: Bool
    @State private var showingHelp = false
    @State private var showingEffectsHelp = false
    @State private var helpAnchor: CGRect = .zero
    @State private var helpAttentionScale: CGFloat = 1
    @AppStorage("organize_transfers_by_date") private var organizeByDate = false
    @AppStorage("auto_transfer_new_media") private var autoTransfer = false
    @AppStorage("defer_transfer_start") private var deferStart = false
    @AppStorage("thumbnail_columns") private var columns = 3
    @AppStorage("collapse_burst_photos") private var collapseBurst = true
    @AppStorage("tap_to_preview") private var tapToPreview = false
    @AppStorage("haptics_enabled") private var haptics = true
    @AppStorage("keep_screen_on") private var keepScreenOn = true
    @AppStorage("theme_mode") private var themeMode = "SYSTEM"
    @AppStorage("app_language") private var appLanguage = "system"
    @AppStorage("skin_preset") private var skinPreset = "FROSTED_GLASS"
    @AppStorage("main_settings_help_viewed") private var mainSettingsHelpViewed = false
    @AppStorage("photo_effects_help_viewed") private var photoEffectsHelpViewed = false

    var showPhotoEffectsEntry: Bool = true
    var onClose: (() -> Void)? = nil
    var dismissalRequested = false
    let effectPreviewSource: UIImage?
    let effectPreviewExif: PhotoExif?
    let onEffectPreviewRequested: () -> Void

    private enum SettingsPage {
        case main
        case effects
    }

    init(showPhotoEffectsEntry: Bool, effectsStore: PhotoEffectsStore, directory: DirectoryAccessStore,
         effectsDraft: Binding<PhotoEffectsSettings>, filterChooser: Binding<PhotoFilterChooserState>,
         effectsHint: Binding<PhotoEffectsHint?>, dismissalRequested: Bool,
         effectPreviewSource: UIImage? = nil, effectPreviewExif: PhotoExif? = nil,
         onEffectPreviewRequested: @escaping () -> Void = {}, onClose: (() -> Void)? = nil) {
        self.showPhotoEffectsEntry = showPhotoEffectsEntry
        self.onClose = onClose
        _effectsStore = ObservedObject(wrappedValue: effectsStore)
        _directory = ObservedObject(wrappedValue: directory)
        _effectsDraft = effectsDraft
        _filterChooser = filterChooser
        _effectsHint = effectsHint
        self.dismissalRequested = dismissalRequested
        self.effectPreviewSource = effectPreviewSource
        self.effectPreviewExif = effectPreviewExif
        self.onEffectPreviewRequested = onEffectPreviewRequested
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if settingsPage == .main {
                    VStack(spacing: 0) {
                        header
                        ScrollView { mainSettingsContent }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                } else {
                    VStack(spacing: 0) {
                        effectsHeader
                        ScrollView {
                            PhotoEffectsSettingsPreview(source: effectPreviewSource,
                                metadata: effectPreviewExif.map(PhotoFrameMetadata.init),
                                settings: effectsDraft,
                                onRequest: onEffectPreviewRequested)
                                .padding(.horizontal, 16).padding(.top, 10)
                            PhotoEffectsControls(draft: $effectsDraft,
                                showingWatermarkPicker: $showingWatermarkPicker,
                                textFieldFocused: $watermarkTextFocused,
                                showLocationFields: true,
                                filterChooser: $filterChooser,
                                onWatermarkTextCommitted: { _ in commitFrameDraft() },
                                onFavoriteImageMissing: { effectsHint = .init(resource: "photo_effect_favorite_image_missing") })
                                .padding(.horizontal, 16)
                                .padding(.bottom, 14)
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }

            if showingHelp && settingsPage == .main {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissHelp() }
                    .zIndex(1)
                SettingsHelpBubble()
                    .offset(x: max(12, helpAnchor.minX - 10), y: helpAnchor.maxY + 8)
                    .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
                    .zIndex(2)
            }
            if showingEffectsHelp && settingsPage == .effects {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissEffectsHelp() }
                    .zIndex(1)
                PhotoEffectsHelpBubble()
                    .offset(x: max(12, helpAnchor.minX - 10), y: helpAnchor.maxY + 8)
                    .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        // Android AnchorPopup uses glassSurfaceHeavy (0.92/0.95 alpha). A
        // connection-card wash is intentionally translucent and lets the
        // underlying USB/Wi‑Fi labels bleed through the settings panel.
        .background(ZTransferGlassSurface(cornerRadius: 26, kind: .panel))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(ZTransferColors.primaryText.opacity(0.16), lineWidth: 1))
        .sheet(isPresented: $showingPicker) { DirectoryPicker { url in directory.setDirectory(url); showingPicker = false } }
        .photosPicker(isPresented: $showingWatermarkPicker, selection: $watermarkPickerItems,
                      maxSelectionCount: 1, matching: .images, preferredItemEncoding: .current)
        .task(id: watermarkPickerItems) {
            guard let item = watermarkPickerItems.last else { return }
            guard let data = try? await item.loadTransferable(type: Data.self), !Task.isCancelled,
                  let image = UIImage(data: data), let hash = effectsStore.importWatermarkImage(image) else {
                if !Task.isCancelled { effectsHint = .init(resource: "photo_frame_image_import_failed"); watermarkPickerItems = [] }
                return
            }
            effectsDraft.watermark.content = .image
            effectsDraft.watermark.imageHash = hash
            if effectsDraft.photoFrameBorderEnabled,
               let index = effectsDraft.favoriteFrameEffects.firstIndex(where: { $0.preset == effectsDraft.photoFramePreset }) {
                effectsDraft.favoriteFrameEffects[index].watermark = effectsDraft.watermark
            }
            commitFrameDraft()
            watermarkPickerItems = []
        }
        .onChange(of: dismissalRequested) { closing in
            if closing && settingsPage == .effects { commitEffectsDraft() }
        }
        .coordinateSpace(name: "settings-panel")
        .onPreferenceChange(SettingsHelpAnchorPreferenceKey.self) { helpAnchor = $0 }
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24), value: showingHelp)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24), value: showingEffectsHelp)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24), value: settingsPage)
        .onAppear {
            // Migrate the early preview value ("自动") to the same BCP-47
            // tags used by Android so the selection actually changes the app
            // locale instead of only changing the wheel label.
            if !["system", "en", "zh-Hans", "zh-Hant"].contains(appLanguage) {
                appLanguage = "system"
            }
            if !mainSettingsHelpViewed {
                helpAttentionScale = 1.09
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    helpAttentionScale = 1
                }
            }
        }
    }

    private var mainSettingsContent: some View {
        VStack(spacing: 10) {
            directoryCard
            listCard
            if showPhotoEffectsEntry { photoEffectsCard }
            appearanceCard
            footer
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var effectsHeader: some View {
        HStack(spacing: 8) {
            Button(action: showMainSettings) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ZTransferColors.primaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 12))
            Text(AppLocalized.resource("photo_effects"))
                .zTransferText(size: ZTransferMetrics.title, weight: .bold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Button {
                photoEffectsHelpViewed = true
                showingEffectsHelp.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ZTransferColors.accentOrange)
                    if !photoEffectsHelpViewed {
                        Circle()
                            .fill(Color(red: 1, green: 0.30, blue: 0.24))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 12))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsHelpAnchorPreferenceKey.self,
                        value: proxy.frame(in: .named("settings-panel"))
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func showEffectsSettings() {
        effectsDraft = effectsStore.beginDraft()
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) {
            showingHelp = false
            settingsPage = .effects
        }
    }

    private func showMainSettings() {
        commitEffectsDraft()
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)) {
            showingEffectsHelp = false
            settingsPage = .main
        }
    }

    private func closeSettings() {
        if settingsPage == .effects {
            commitEffectsDraft()
        }
        onClose?()
    }

    private func commitFrameDraft() {
        var persisted = effectsStore.settings.persistingEditorPreferences(from: effectsDraft)
        persisted.photoFrameEnabled = effectsDraft.photoFrameEnabled
        persisted.photoFrameBorderEnabled = effectsDraft.photoFrameBorderEnabled
        persisted.photoFramePreset = effectsDraft.photoFramePreset
        persisted.metadata = effectsDraft.metadata
        persisted.watermark = effectsDraft.watermark
        effectsStore.update(persisted)
    }

    private func commitEffectsDraft() {
        watermarkTextFocused = false
        if effectsDraft.watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectsDraft.watermark.text = PhotoFrameWatermark.defaultText
        }
        effectsStore.update(effectsDraft)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Keep the title in one line.  The Android title occupies a single
            // titleLarge slot; allowing SwiftUI to compress it produces the
            // two-character vertical title seen in the old iOS panel.
            Text(AppLocalized.resource("settings"))
                .zTransferText(size: ZTransferMetrics.title, weight: .bold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                showingHelp.toggle()
                // Android persists this exact preference when the guide is opened;
                // the attention marker must not reappear on the next visit.
                mainSettingsHelpViewed = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ZTransferColors.accentOrange)
                    if !mainSettingsHelpViewed {
                        Circle()
                            .fill(Color(red: 1, green: 0.30, blue: 0.24))
                            .frame(width: 7, height: 7)
                            .scaleEffect(helpAttentionScale)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 12))
            .scaleEffect(mainSettingsHelpViewed ? 1 : helpAttentionScale)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsHelpAnchorPreferenceKey.self,
                        value: proxy.frame(in: .named("settings-panel"))
                    )
                }
            }
            Spacer()
            Button { onClose?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ZTransferColors.secondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var directoryCard: some View {
        SettingsCard {
            HStack(spacing: 10) {
                Image(systemName: "location.fill").foregroundStyle(directory.directoryURL == nil ? ZTransferColors.accentOrange : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalized.resource("transfer_directory")).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                    Text(directory.directoryURL?.lastPathComponent ?? AppLocalized.resource("dir_not_set")).zTransferText(size: ZTransferMetrics.caption).lineLimit(1)
                }
                Spacer()
                Button { showingPicker = true } label: {
                    Text(directory.directoryURL == nil ? AppLocalized.resource("choose_directory") : AppLocalized.resource("change_directory"))
                        .zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 12))
            }
            SettingsDivider()
            HStack(spacing: 8) {
                ToggleWheel(label: AppLocalized.resource("organize_transfers_by_date"), isOn: $organizeByDate, disabled: directory.directoryURL == nil)
                ToggleWheel(label: AppLocalized.resource("auto_transfer_new_media"), isOn: $autoTransfer, disabled: directory.directoryURL == nil)
                ToggleWheel(label: AppLocalized.resource("defer_transfer_start"), isOn: $deferStart, disabled: directory.directoryURL == nil)
            }
        }
    }

    private var listCard: some View {
        SettingsCard {
            HStack(spacing: 8) {
                DetentWheel(label: AppLocalized.resource("columns"), options: [2, 3, 4], selected: columns, optionLabel: String.init, onCommit: { columns = $0 }, rowHeight: 18, wheelHeight: 50).frame(maxWidth: .infinity)
                ToggleWheel(label: AppLocalized.resource("collapse_burst_photos"), isOn: $collapseBurst).frame(maxWidth: .infinity)
            }
            SettingsDivider()
                DetentWheel(label: AppLocalized.resource("photo_interaction"), options: [false, true], selected: tapToPreview, optionLabel: { $0 ? AppLocalized.resource("tap_preview_hold_transfer") : AppLocalized.resource("tap_transfer_hold_preview") }, onCommit: { tapToPreview = $0 }, rowHeight: 32, wheelHeight: 56, optionMaxLines: 2, optionFontSize: 13)
        }
    }

    private var appearanceCard: some View {
        SettingsCard {
            HStack(spacing: 8) {
                DetentWheel(label: AppLocalized.resource("light_dark_mode"), options: ["SYSTEM", "DARK", "LIGHT"], selected: themeMode, optionLabel: {
                    switch $0 {
                    case "DARK": return AppLocalized.resource("theme_dark")
                    case "LIGHT": return AppLocalized.resource("theme_light")
                    default: return AppLocalized.resource("theme_system")
                    }
                }, onCommit: { themeMode = $0 }, rowHeight: 16, wheelHeight: 42, optionFontSize: 13).frame(maxWidth: .infinity)
                DetentWheel(label: AppLocalized.resource("language"), options: ["system", "en", "zh-Hans", "zh-Hant"], selected: appLanguage, optionLabel: { language in
                    switch language {
                    case "en": return "English"
                    case "zh-Hans": return AppLocalized.text("简体中文")
                    case "zh-Hant": return AppLocalized.text("繁體中文")
                    default: return AppLocalized.resource("language_system")
                    }
                }, onCommit: { appLanguage = $0; onClose?() }, rowHeight: 16, wheelHeight: 42, optionFontSize: 13).frame(maxWidth: .infinity)
                DetentWheel(label: AppLocalized.resource("button_style"), options: ["FROSTED_GLASS", "WOOD", "CAMERA_CONTROLS", "TITANIUM"], selected: skinPreset, optionLabel: {
                    switch $0 {
                    case "WOOD": return AppLocalized.resource("skin_wood")
                    case "CAMERA_CONTROLS": return AppLocalized.resource("skin_camera_controls")
                    case "TITANIUM": return AppLocalized.resource("skin_titanium")
                    default: return AppLocalized.resource("skin_frosted_glass")
                    }
                }, onCommit: { skinPreset = $0 }, rowHeight: 16, wheelHeight: 42, optionFontSize: 13).frame(maxWidth: .infinity)
            }
            SettingsDivider()
            HStack(spacing: 8) { ToggleWheel(label: AppLocalized.resource("haptic_feedback"), isOn: $haptics); ToggleWheel(label: AppLocalized.resource("keep_screen_on"), isOn: $keepScreenOn) }
        }
    }

    @ViewBuilder
    private var photoEffectsCard: some View {
        let settings = effectsStore.settings
        let filterSummary: String = {
            guard settings.photoFilterEnabled, let selection = settings.selectedFilter else {
                return AppLocalized.resource("photo_filter_off_option")
            }
            let name = Np3FilterCatalog.preset(id: selection.preset.id).map { AppLocalized.resource("photo_filter_builtin_\($0.legacyID)") } ?? selection.preset.name
            return "\(name)\n\(AppLocalized.formattedResource("photo_filter_intensity_summary", ["%1$d": "\(selection.intensityPercent)"]))"
        }()
        let frameSummary = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
            ? settings.photoFramePreset.displayName : AppLocalized.resource("photo_frame_off")
        let watermarkSummary: String = {
            guard settings.photoFrameEnabled, settings.watermark.enabled else { return AppLocalized.resource("photo_frame_no_watermark") }
            switch settings.watermark.content {
            case .text: return settings.watermark.displayText
            case .image: return AppLocalized.resource("photo_frame_image_watermark")
            }
        }()
        Button(action: showEffectsSettings) {
            SettingsCard {
                HStack { Text(AppLocalized.resource("photo_effects")).zTransferText(size: ZTransferMetrics.body, weight: .semibold); Spacer(); Image(systemName: "chevron.right").foregroundStyle(ZTransferColors.secondaryText) }
                Divider().opacity(0.35)
                HStack(spacing: 8) {
                    Text(AppLocalized.resource("photo_filter")).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                    Text(filterSummary).zTransferText(size: ZTransferMetrics.caption).multilineTextAlignment(.leading)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(AppLocalized.resource("photo_frame_and_watermark_short")).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                        Text(AppLocalized.formattedResource("photo_frame_summary_line", ["%1$s": frameSummary])).zTransferText(size: ZTransferMetrics.caption)
                        Text(AppLocalized.formattedResource("photo_watermark_summary_line", ["%1$s": watermarkSummary])).zTransferText(size: ZTransferMetrics.caption)
                    }
                }
            }
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VersionPlaque(text: AppLocalized.versionText(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.82"))
            Spacer()
            SettingsFooterButton(AppLocalized.resource("feedback")) { UIPasteboard.general.string = "953000922"; feedbackHint = true }
        }
        .alert(AppLocalized.formattedResource("feedback_qq_copied", ["%1$s": "953000922"]), isPresented: $feedbackHint) { Button(AppLocalized.resource("cd_close"), role: .cancel) {} }
    }

    private func dismissHelp() {
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.18)) {
            showingHelp = false
        }
    }

    private func dismissEffectsHelp() {
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.18)) {
            showingEffectsHelp = false
        }
    }
}

private struct SettingsHelpAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Android MainSettingsInfoBubble equivalent. The four label/summary pairs
/// and their order are copied from SettingsScreen; no iOS-only help text is
/// introduced here.
private struct SettingsHelpBubble: View {
    private let items = [
        ("organize_transfers_by_date", "organize_transfers_by_date_summary"),
        ("auto_transfer_new_media", "auto_transfer_new_media_summary"),
        ("defer_transfer_start", "defer_transfer_start_summary"),
        ("collapse_burst_photos", "collapse_burst_photos_summary"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized.resource("settings_help_title"))
                .zTransferTypography(.titleMedium, weight: .bold)
            ForEach(items, id: \.0) { label, summary in
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalized.resource(label))
                        .zTransferTypography(.labelMedium, weight: .bold)
                        .foregroundStyle(ZTransferColors.accentOrange)
                    Text(AppLocalized.resource(summary))
                        .zTransferTypography(.bodySmall)
                        .foregroundStyle(ZTransferColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(ZTransferColors.primaryText)
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(ZTransferGlassSurface(cornerRadius: 18, kind: .panel))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
    }
}

/// Android PhotoEffectsInfoBubble equivalent. The strings and ordering are
/// sourced from the same Android resource keys used by the detail page.
private struct PhotoEffectsHelpBubble: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(AppLocalized.resource("photo_effects_info_title"))
                .zTransferTypography(.titleMedium, weight: .bold)
            Text(AppLocalized.resource("photo_effects_info_description"))
                .zTransferTypography(.bodySmall)
            Text(AppLocalized.resource("photo_effects_gesture_hint"))
                .zTransferTypography(.bodySmall)
                .fontWeight(.semibold)
            Text(AppLocalized.resource("photo_effects_wheel_hint"))
                .zTransferTypography(.bodySmall)
                .fontWeight(.semibold)
        }
        .foregroundStyle(ZTransferColors.primaryText)
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(ZTransferGlassSurface(cornerRadius: 18, kind: .panel))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
    }
}

extension PhotoFramePreset {
    var displayName: String {
        switch self {
        case .mist: return AppLocalized.resource("photo_frame_mist"); case .cinema: return AppLocalized.resource("photo_frame_cinema"); case .minimal: return AppLocalized.resource("photo_frame_minimal"); case .frosted: return AppLocalized.resource("photo_frame_frosted"); case .plaque: return AppLocalized.resource("photo_frame_plaque"); case .immersive: return AppLocalized.resource("photo_frame_immersive"); case .brandInset: return AppLocalized.resource("photo_frame_brand_inset"); case .brandGallery: return AppLocalized.resource("photo_frame_brand_gallery"); case .classicSignature: return AppLocalized.resource("photo_frame_classic_signature"); case .galleryMat: return AppLocalized.resource("photo_frame_gallery_mat"); case .colorArchive: return AppLocalized.resource("photo_frame_color_archive"); case .filmGallery: return AppLocalized.resource("photo_frame_film_gallery"); case .filmEdge: return AppLocalized.resource("photo_frame_film_edge")
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // Materialize the builder as one vertical group before applying the
        // surface. Without this wrapper SwiftUI can propagate the background
        // proposal to tuple children, making each divider look like a second
        // empty rounded card in the popup.
        VStack(spacing: 0) { content }
            .padding(12)
            .background(ZTransferGlassSurface(cornerRadius: 14, kind: .button))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ZTransferColors.primaryText.opacity(0.10), lineWidth: 1))
    }
}

private struct ToggleWheel: View {
    let label: String
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        DetentWheel(
            label: label,
            options: [false, true],
            selected: isOn,
            optionLabel: { AppLocalized.settingState($0) },
            onCommit: { isOn = $0 },
            rowHeight: 18,
            wheelHeight: 50,
            enabled: !disabled,
            accentColor: isOn ? ZTransferColors.accentBlue : ZTransferColors.secondaryText,
            emphasized: isOn,
        )
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(ZTransferColors.primaryText.opacity(0.10))
            .padding(.vertical, 8)
    }
}

private struct SettingsFooterButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(ZTransferGlassSurface(cornerRadius: 12, kind: .button))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ZTransferColors.primaryText.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct VersionPlaque: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ZTransferColors.secondaryText.opacity(0.42)).frame(width: 3, height: 3)
            Text(text).zTransferTypography(.labelSmall, weight: .medium)
                .foregroundStyle(ZTransferColors.secondaryText.opacity(0.82))
                .lineLimit(1)
            Circle().fill(ZTransferColors.secondaryText.opacity(0.42)).frame(width: 3, height: 3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(ZTransferColors.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(ZTransferColors.primaryText.opacity(0.10), lineWidth: 1))
    }
}
