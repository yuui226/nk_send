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
            VStack(spacing: 0) {
            PhotoEffectControlRow(primaryWeight: 3, secondaryWeight: 2) {
                DetentWheel(label: "LUT", options: options,
                    selected: editor.request.pendingIdentifier ?? editor.currentIdentifier,
                    optionLabel: optionLabel,
                    onCommit: choose,
                    rowHeight: 30, wheelHeight: PhotoEffectControlMetrics.height,
                    readOnly: editor.loading, optionMaxLines: 2, optionFontSize: 13,
                    optionFontSizeFor: { optionLabel($0).utf16.count > 24 ? 11 : 13 },
                    accentColor: accent,
                    onActivated: options.count == 1 ? {
                        ZTransferHaptics.shared.play(.navigation); editor.openFolder()
                    } : nil,
                    onLongClick: { editor.openChooser(onDisable: disable) },
                    ambientEffectColor: accent,
                    ambientEffectPulse: editor.loadingSelection ? NativeAmbientPulse(
                        origin: editor.loadingOrigin, minimum: 0.04, maximum: 0.14, halfPeriod: 0.6,
                        restingOpacity: 0, breathing: true, paused: scenePhase != .active) : nil)
                DetentWheel(label: "", options: [false], selected: false,
                    optionLabel: { _ in AppLocalized.resource("photo_lut_settings") }, onCommit: { _ in },
                    enabled: store.hasSelection, readOnly: editor.loading, accentColor: accent,
                    emphasized: editor.settingsExpanded, showDragHint: false,
                    onActivated: {
                        playPhotoEffectDisclosureFeedback()
                        withAnimation(ZTransferMotion.inlineExpansion) { editor.settingsExpanded.toggle() }
                    })
                PhotoEffectFavoriteButton(
                    favorite: editor.currentIdentifier.map { store.favorites.contains($0) } == true,
                    enabled: store.hasSelection
                ) {
                    guard !editor.loading else { return }
                    if let identifier = store.selectedIdentifier { store.toggleFavorite(identifier) }
                }.allowsHitTesting(!editor.loading)
            }
            PhotoEffectInlineDisclosure(expanded: editor.settingsExpanded && store.hasSelection
                && draft.selectedFilter?.preset.id.hasPrefix("cube:") == true) {
                if let selection = draft.selectedFilter, selection.preset.id.hasPrefix("cube:") {
                    PhotoColorAdjustmentControls(selection: selection, intensityLabel: "photo_lut_concentration",
                        accent: accent, enabled: store.hasSelection, readOnly: editor.loading) { intensity, adjustments in
                        guard editor.active, editor.settingsExpanded, let current = draft.selectedFilter,
                              PhotoColorControlIdentity(current) == PhotoColorControlIdentity(selection) else { return }
                        if store.intensityPercent != intensity { store.setIntensity(intensity) }
                        if store.adjustments != adjustments { store.setAdjustments(adjustments) }
                        var changed = current
                        changed.intensityPercent = store.intensityPercent
                        changed.lutAdjustments = store.adjustments
                        draft.selectedFilter = changed
                    }
                    .padding(.top, 8)
                }
            }
            }
        }
        .onChange(of: store.hasSelection) { _ in editor.settingsExpanded = false }
        .fileImporter(isPresented: $editor.showingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            editor.folderPickerCompleted(result, onDisable: disable)
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
}

/// Hosted beside the entire page/popup, never inside the scrolling card. Both
/// columns scroll independently; category changes reset only the right list.
struct PhotoLUTChooserPresentation: View {
    @ObservedObject var editor: PhotoLUTEditorState
    @Binding var draft: PhotoEffectsSettings
    var body: some View {
        AndroidDialogPresentation(isPresented: editor.showingChooser) {
            PhotoLUTChooserOverlay(editor: editor, draft: $draft)
        }
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
        let visible = catalog.files(in: editor.categorySelection.category) ?? []
        let initialID = editor.currentIdentifier.flatMap { catalog.filesByIdentifier[$0] }.flatMap {
            $0.category.presetCategoryBytes == editor.categorySelection.category.presetCategoryBytes ? $0.identifier : nil
        } ?? visible.first?.identifier
        PhotoEffectChooserDialog(categoryLabels: categories.map(categoryLabel),
            optionLabels: catalog.labels(in: editor.categorySelection.category) ?? [],
            onDismiss: { editor.showingChooser = false }) {
            HStack(spacing: 8) {
                PhotoEffectChooserAction(label: AppLocalized.resource("lut_turn_off"), selected: editor.currentIdentifier == nil) {
                    ZTransferHaptics.shared.play(.selection)
                    editor.off { disablePhotoLUTDraft(&draft, lutStore: store) }
                    editor.showingChooser = false
                }
                PhotoEffectChooserAction(label: AppLocalized.resource("lut_folder")) {
                    ZTransferHaptics.shared.play(.navigation); editor.openFolder()
                }
            }
        } content: { width in
            HStack(spacing: 6) {
                PhotoEffectChooserList(items: categories, id: \.presetCategoryBytes,
                    initialID: .some(editor.categorySelection.category.presetCategoryBytes)) { category in
                    PhotoEffectChooserRow(label: categoryLabel(category),
                        selected: editor.categorySelection.category.presetCategoryBytes == category.presetCategoryBytes, category: true) {
                        editor.categorySelection.category = category
                    }
                }.frame(width: max(0, width - 6) * 0.36)
                PhotoEffectChooserList(items: visible, id: \.identifier,
                    initialID: initialID) { file in
                    PhotoEffectChooserRow(label: file.label,
                        selected: editor.currentIdentifier == file.identifier,
                        favorite: store.favorites.contains(file.identifier),
                        accent: ZTransferColors.photoLUTAccent) {
                        ZTransferHaptics.shared.play(.selection)
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
                }.id(editor.categorySelection.category.presetCategoryBytes)
            }
        }
    }
}
