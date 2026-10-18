import SwiftUI
import UniformTypeIdentifiers

/// Shared by transfer settings and the local workbench. Android PhotoLutEditor:
/// a 3:2 name/settings row, favorite action, and compact release-commit wheels.
struct PhotoLUTChooser: View {
    @ObservedObject var editor: PhotoLUTEditorState
    @Binding var draft: PhotoEffectsSettings
    @Environment(\.scenePhase) private var scenePhase

    private var store: PhotoLUTStore { editor.store }
    private var accent: Color { ZTransferColors.photoLUTAccent }
    var body: some View {
        let options = editor.selectionOptions
        let labels = editor.catalog.labels(uncategorized: AppLocalized.resource("lut_uncategorized"))
        let off = AppLocalized.resource("lut_off")
        let empty = AppLocalized.resource(options.count == 1 ? editor.emptyLabelKey : "lut_off")
        let selectedName = store.selectedName
        let optionLabel: (String?) -> String = { identifier in
            guard let identifier else { return empty }
            return labels[identifier] ?? selectedName ?? off
        }
        PhotoEffectsCard(accent: accent) {
            PhotoEffectControlRow(primaryWeight: 3, secondaryWeight: 2) {
                DetentWheel(label: "LUT", options: options,
                    selected: editor.request.pendingIdentifier ?? store.selectedIdentifier,
                    optionLabel: optionLabel,
                    onCommit: choose,
                    rowHeight: 30, wheelHeight: PhotoEffectControlMetrics.height,
                    readOnly: editor.loading, optionMaxLines: 2, optionFontSize: 13,
                    optionFontSizeFor: { optionLabel($0).utf16.count > 24 ? 11 : 13 },
                    accentColor: accent,
                    onActivated: options.count == 1 ? {
                        ZTransferHaptics.shared.tick(); editor.openFolder()
                    } : nil,
                    onLongClick: { editor.openChooser(onDisable: disable) },
                    ambientEffectColor: accent,
                    ambientEffectPulse: editor.loadingSelection ? NativeAmbientPulse(
                        origin: editor.loadingOrigin, minimum: 0.04, maximum: 0.14, halfPeriod: 0.6,
                        restingOpacity: 0, breathing: true, paused: scenePhase != .active) : nil)
                DetentWheel(label: "", options: [false], selected: false,
                    optionLabel: { _ in AppLocalized.resource("photo_lut_settings") }, onCommit: { _ in },
                    enabled: editor.active, accentColor: accent,
                    emphasized: editor.settingsExpanded, showDragHint: false,
                    onActivated: {
                        ZTransferHaptics.shared.tick()
                        withAnimation(ZTransferMotion.inlineExpansion) { editor.settingsExpanded.toggle() }
                    })
                PhotoEffectFavoriteButton(
                    favorite: store.selectedIdentifier.map { store.favorites.contains($0) } == true,
                    enabled: editor.active
                ) {
                    if let identifier = store.selectedIdentifier { store.toggleFavorite(identifier) }
                }
            }
            if editor.settingsExpanded && store.selectedIdentifier != nil {
                VStack(spacing: 8) {
                    DetentWheel(label: AppLocalized.resource("photo_lut_concentration"),
                        options: Array(stride(from: 100, through: 2, by: -2)), selected: store.intensityPercent,
                        optionLabel: { "\($0)%" }, onCommit: setIntensity,
                        sizing: PhotoEffectControlMetrics.lutParameterWheel, enabled: editor.active,
                        accentColor: accent)
                    HStack(spacing: 6) {
                        adjustment("photo_lut_contrast", keyPath: \.contrast)
                        adjustment("photo_lut_saturation", keyPath: \.saturation)
                    }
                    HStack(spacing: 6) {
                        adjustment("photo_lut_highlights", keyPath: \.highlights)
                        adjustment("photo_lut_shadows", keyPath: \.shadows)
                    }
                }
                .id(store.selectedIdentifier)
                .transition(.opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)))
            }
        }
        .fileImporter(isPresented: $editor.showingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                editor.refresh(onDisable: disable); return
            }
            editor.scanFolder(url, onDisable: disable)
        }
        .onAppear { editor.refresh(onDisable: disable) }
        .onDisappear { editor.close() }
    }

    private func disable() { disablePhotoLUTDraft(&draft, lutStore: store) }
    private func choose(_ identifier: String?) {
        editor.choose(identifier, onDisable: disable, shouldAccept: canAcceptSelection) { selection in
            var value = draft
            value.selectedFilter = selection
            value.photoFilterEnabled = true
            draft = value
        }
    }
    private func canAcceptSelection() -> Bool {
        PhotoColorEffectEditorVisibility(settings: draft, isPro: PremiumEntitlementStore.shared.access.isPro).lut
    }
    private func setIntensity(_ intensity: Int) {
        guard editor.active, var selection = draft.selectedFilter, selection.preset.id.hasPrefix("cube:") else { return }
        store.setIntensity(intensity)
        selection.intensityPercent = store.intensityPercent
        draft.selectedFilter = selection
    }
    private func adjustment(_ label: String, keyPath: WritableKeyPath<LUTAdjustments, Int>) -> some View {
        DetentWheel(label: AppLocalized.resource(label), options: Array(stride(from: -100, through: 100, by: 5)),
            selected: store.adjustments[keyPath: keyPath], optionLabel: String.init,
            onCommit: { value in
                guard editor.active, var selection = draft.selectedFilter, selection.preset.id.hasPrefix("cube:") else { return }
                var adjustments = store.adjustments
                adjustments[keyPath: keyPath] = value
                store.setAdjustments(adjustments)
                selection.lutAdjustments = store.adjustments
                draft.selectedFilter = selection
            }, sizing: PhotoEffectControlMetrics.lutParameterWheel, enabled: editor.active,
            accentColor: accent)
    }
}

/// Hosted beside the entire page/popup, never inside the scrolling card. Both
/// columns scroll independently; category changes reset only the right list.
struct PhotoLUTChooserPresentation: View {
    @ObservedObject var editor: PhotoLUTEditorState
    @Binding var draft: PhotoEffectsSettings
    var body: some View {
        if editor.showingChooser { PhotoLUTChooserOverlay(editor: editor, draft: $draft) }
    }
}

struct PhotoLUTChooserOverlay: View {
    @ObservedObject var editor: PhotoLUTEditorState
    @Binding var draft: PhotoEffectsSettings
    private var store: PhotoLUTStore { editor.store }
    private func categoryLabel(_ category: String?) -> String { category ?? AppLocalized.resource("lut_uncategorized") }

    var body: some View {
        let catalog = editor.catalog
        let categories = catalog.categories
        let visible = catalog.filesByCategory[editor.categorySelection.category] ?? []
        let initialID = store.selectedIdentifier.flatMap { catalog.filesByIdentifier[$0] }.flatMap {
            $0.category == editor.categorySelection.category ? $0.identifier : nil
        } ?? visible.first?.identifier
        PhotoEffectChooserDialog(categoryLabels: categories.map(categoryLabel),
            optionLabels: catalog.labelsByCategory[editor.categorySelection.category] ?? [],
            onDismiss: { editor.showingChooser = false }) {
            HStack(spacing: 8) {
                PhotoEffectChooserAction(label: AppLocalized.resource("lut_turn_off"), selected: store.selectedIdentifier == nil) {
                    ZTransferHaptics.shared.tick()
                    editor.off { disablePhotoLUTDraft(&draft, lutStore: store) }
                    editor.showingChooser = false
                }
                PhotoEffectChooserAction(label: AppLocalized.resource("lut_folder")) {
                    ZTransferHaptics.shared.tick(); editor.openFolder()
                }
            }
        } content: { width in
            HStack(spacing: 6) {
                PhotoEffectChooserList(items: categories, id: \.self,
                    initialID: .some(editor.categorySelection.category)) { category in
                    PhotoEffectChooserRow(label: categoryLabel(category),
                        selected: editor.categorySelection.category == category, category: true) {
                        editor.categorySelection.category = category
                    }
                }.frame(width: max(0, width - 6) * 0.36)
                PhotoEffectChooserList(items: visible, id: \.identifier,
                    initialID: initialID) { file in
                    PhotoEffectChooserRow(label: file.label,
                        selected: store.selectedIdentifier == file.identifier,
                        favorite: store.favorites.contains(file.identifier),
                        accent: ZTransferColors.photoLUTAccent) {
                        ZTransferHaptics.shared.tick()
                        editor.choose(file.identifier,
                            onDisable: { disablePhotoLUTDraft(&draft, lutStore: store) },
                            shouldAccept: { PhotoColorEffectEditorVisibility(settings: draft, isPro: PremiumEntitlementStore.shared.access.isPro).lut }) { selection in
                                var value = draft
                                value.selectedFilter = selection
                                value.photoFilterEnabled = true
                                draft = value
                            }
                        editor.showingChooser = false
                    }
                }.id(editor.categorySelection.category)
            }
        }
    }
}
