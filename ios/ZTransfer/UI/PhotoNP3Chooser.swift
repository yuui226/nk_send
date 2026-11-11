import SwiftUI
import UniformTypeIdentifiers

struct PhotoNP3Chooser: View {
    @ObservedObject var session: PhotoFilterEditorSession
    @Binding var draft: PhotoEffectsSettings
    let onFavorite: (PhotoFilterSelection) -> Void
    var body: some View { PhotoNP3Card(session: session, editor: session.editor, draft: $draft, onFavorite: onFavorite) }
}

private struct PhotoNP3Card: View {
    @ObservedObject var session: PhotoFilterEditorSession
    @ObservedObject var editor: PhotoNp3EditorState
    @Binding var draft: PhotoEffectsSettings
    let onFavorite: (PhotoFilterSelection) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @AppStorage("app_language") private var language = "system"
    private var selection: PhotoFilterSelection? { draft.builtinFilterSelection }
    private var enabled: Bool { draft.photoFilterEnabled && draft.colorEffectModule == .filter }
    private var controlsEnabled: Bool { session.active && enabled && selection != nil }

    var body: some View {
        let catalog = editor.catalog(selected: selection?.preset, favorites: draft.favoriteFilterIDs)
        let labels = catalog.labels(locale: locale.identifier + language,
            uncategorized: AppLocalized.resource("lut_uncategorized"),
            restoredSourceFallback: AppLocalized.resource("photo_np3_selected_source"),
            builtInLabel: photoFilterBuiltInLabel)
        // No built-in catalog on iOS. Match PhotoLutEditor's empty-folder
        // action while retaining Off beside real files or a restored snapshot.
        let empty = catalog.selectionOptions.count == 1
        let off = AppLocalized.resource(empty ? editor.emptyLabelKey : "photo_filter_off_option")
        let label: (String?) -> String = { $0.flatMap { labels[$0] } ?? off }
        PhotoEffectsCard(accent: ZTransferColors.accentBlue) {
            VStack(spacing: 0) {
            PhotoEffectControlRow(primaryWeight: 3, secondaryWeight: 2) {
                DetentWheel(label: AppLocalized.resource("photo_filter"), options: catalog.selectionOptions,
                    selected: catalog.pendingKey(source: editor.pendingSource) ?? catalog.currentKey(enabled: enabled),
                    optionLabel: label, onCommit: { session.choose($0.flatMap { catalog.byKey[$0] }) },
                    rowHeight: 30, wheelHeight: PhotoEffectControlMetrics.height,
                    readOnly: !session.active || editor.loading, optionMaxLines: 2, optionFontSize: 13,
                    optionFontSizeFor: { label($0).utf16.count > 24 ? 11 : 13 },
                    onActivated: empty ? {
                        ZTransferHaptics.shared.play(.navigation)
                        session.launchFolderPicker()
                    } : nil,
                    onLongClick: { session.openChooser() },
                    favoriteOption: { $0.flatMap { catalog.byKey[$0]?.catalogKey }.map(catalog.favoriteKeys.contains) == true },
                    favoriteIconColor: ZTransferColors.accentOrange, ambientEffectColor: ZTransferColors.accentBlue,
                    ambientEffectPulse: editor.loadingSelection ? NativeAmbientPulse(origin: editor.loadingOrigin,
                        minimum: 0.04, maximum: 0.14, halfPeriod: 0.6, restingOpacity: 0,
                        breathing: true, paused: scenePhase != .active) : nil)
                    .accessibilityIdentifier("photo-np3-name")
                DetentWheel(label: "", options: [0], selected: 0,
                    optionLabel: { _ in AppLocalized.resource("photo_filter_settings") }, onCommit: { _ in },
                    enabled: controlsEnabled, readOnly: editor.loading, emphasized: session.settingsExpanded && enabled,
                    showDragHint: false, onActivated: {
                        playPhotoEffectDisclosureFeedback()
                        withAnimation(ZTransferMotion.inlineExpansion) { session.settingsExpanded.toggle() }
                    }).accessibilityIdentifier("photo-np3-adjust")
                PhotoEffectFavoriteButton(favorite: enabled && selection.map {
                    catalog.favoriteKeys.contains(PhotoEffectsSettings.filterKey($0.preset.id))
                } == true, enabled: controlsEnabled) {
                    guard controlsEnabled, !editor.loading, let selection else { return }
                    onFavorite(selection)
                }.allowsHitTesting(!editor.loading)
            }
            PhotoEffectInlineDisclosure(expanded: session.settingsExpanded && enabled && selection != nil) {
                if let selection {
                    PhotoColorAdjustmentControls(selection: selection, intensityLabel: "photo_filter_intensity",
                        accent: ZTransferColors.accentBlue, enabled: controlsEnabled, readOnly: editor.loading) { intensity, adjustments in
                        guard session.active, !editor.loading, session.settingsExpanded, enabled,
                              let current = draft.selectedFilter,
                              PhotoColorControlIdentity(current) == PhotoColorControlIdentity(selection) else { return }
                        var value = draft
                        var changed = current
                        changed.intensityPercent = intensity; changed.lutAdjustments = adjustments
                        value.selectedFilter = changed
                        let key = PhotoEffectsSettings.filterKey(current.preset.id)
                        value.filterIntensities[key] = intensity; value.filterAdjustments[key] = adjustments
                        draft = value
                    }
                    .padding(.top, 8)
                }
            }
            }
        }
        .onChange(of: enabled) { _ in session.draftChanged(draft) }
    }
}

struct PhotoColorControlIdentity: Hashable {
    let id: String
    let intensity: Int
    let contrast: Int
    let saturation: Int
    let highlights: Int
    let shadows: Int
    init(_ selection: PhotoFilterSelection) {
        id = selection.preset.id; intensity = selection.normalizedIntensityPercent
        contrast = selection.lutAdjustments.contrast; saturation = selection.lutAdjustments.saturation
        highlights = selection.lutAdjustments.highlights; shadows = selection.lutAdjustments.shadows
    }
}

/// Android's five compact wheels. Preserve valid restored values between the
/// five-step detents and cancel every old gesture when any control is reset.
struct PhotoColorAdjustmentControls: View {
    let selection: PhotoFilterSelection
    let intensityLabel: String
    let accent: Color
    let enabled: Bool
    let readOnly: Bool
    let onChange: (Int, LUTAdjustments) -> Void
    private var identity: PhotoColorControlIdentity { .init(selection) }
    private var sizing: DetentWheelSizing { .init(height: 34, rowHeight: 16, cornerRadius: 10, fontSize: 13) }
    static func options(_ selected: Int) -> [Int] {
        let values = Array(stride(from: 100, through: -100, by: -5))
        return values.contains(selected) ? values : (values + [selected]).sorted(by: >)
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                DetentWheel(label: AppLocalized.resource(intensityLabel), options: Array(stride(from: 100, through: 2, by: -2)),
                    selected: selection.normalizedIntensityPercent, optionLabel: { "\($0)%" },
                    onCommit: { onChange($0, selection.lutAdjustments) }, sizing: sizing,
                    enabled: enabled, readOnly: readOnly, accentColor: accent, gestureIdentity: identity)
                    .frame(maxWidth: .infinity)
                DetentWheel(label: "", options: [0], selected: 0, optionLabel: { _ in "" }, onCommit: { _ in },
                    sizing: sizing, enabled: enabled, readOnly: readOnly, accentColor: accent,
                    showDragHint: false, onActivated: {
                        ZTransferHaptics.shared.play(.selection); onChange(80, .init())
                    }, centerIcon: { color in
                        AnyView(RemoteToolMark(tool: .rotate).environment(\.remoteToolTint, color).scaleEffect(x: -1, y: 1))
                    }, gestureIdentity: identity)
                    .frame(width: sizing.height, height: sizing.height)
                    .accessibilityLabel(AppLocalized.resource("photo_color_reset"))
                    .accessibilityIdentifier("photo-color-reset")
            }
            HStack(spacing: 6) {
                adjustment("photo_lut_contrast", keyPath: \.contrast)
                adjustment("photo_lut_saturation", keyPath: \.saturation)
            }
            HStack(spacing: 6) {
                adjustment("photo_lut_highlights", keyPath: \.highlights)
                adjustment("photo_lut_shadows", keyPath: \.shadows)
            }
        }
    }
    private func adjustment(_ label: String, keyPath: WritableKeyPath<LUTAdjustments, Int>) -> some View {
        let current = selection.lutAdjustments[keyPath: keyPath]
        return DetentWheel(label: AppLocalized.resource(label), options: Self.options(current), selected: current,
            optionLabel: String.init, onCommit: { value in
                var changed = selection.lutAdjustments; changed[keyPath: keyPath] = value
                onChange(selection.normalizedIntensityPercent, changed)
            }, sizing: sizing, enabled: enabled, readOnly: readOnly, accentColor: accent, gestureIdentity: identity)
    }
}

private func photoFilterBuiltInLabel(_ preset: PhotoFilterPreset) -> String {
    Np3FilterCatalog.preset(id: preset.id).map { AppLocalized.resource("photo_filter_builtin_" + $0.legacyID) } ?? preset.name
}

/// Host above the whole page, outside the scrolling card and Genie clipping.
struct PhotoNP3ChooserPresentation: View {
    @ObservedObject var session: PhotoFilterEditorSession
    @Binding var draft: PhotoEffectsSettings
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        AndroidDialogPresentation(isPresented: session.showingChooser) {
            PhotoNP3ChooserOverlay(session: session, editor: session.editor, draft: $draft)
        }
        .background {
            PhotoNP3FolderPicker(session: session, lifetimeID: session.lifetimeID).id(session.lifetimeID)
        }
        .onChange(of: scenePhase) { session.setSceneActive($0 == .active) }
    }
}

/// Give the native delegate an immutable presentation identity, including its
/// isPresented binding. An old picker cannot dismiss or update a newer one.
private struct PhotoNP3FolderPicker: View {
    @ObservedObject var session: PhotoFilterEditorSession
    let lifetimeID: UUID
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .fileImporter(isPresented: Binding(get: {
                lifetimeID == session.lifetimeID && session.showingFolder
            }, set: {
                if lifetimeID == session.lifetimeID { session.showingFolder = $0 }
            }), allowedContentTypes: [.folder], allowsMultipleSelection: false) {
                session.folderPickerCompleted($0, lifetimeID: lifetimeID)
            }
    }
}

private struct PhotoNP3ChooserOverlay: View {
    @ObservedObject var session: PhotoFilterEditorSession
    @ObservedObject var editor: PhotoNp3EditorState
    @Binding var draft: PhotoEffectsSettings
    @Environment(\.locale) private var locale
    @AppStorage("app_language") private var language = "system"
    private var enabled: Bool { draft.photoFilterEnabled && draft.colorEffectModule == .filter }
    private var guidance: String? {
        if editor.loading { return AppLocalized.resource("lut_reading_folder") }
        if let failure = editor.failure {
            let key: String
            switch failure {
            case .missing: key = "lut_folder_missing"
            case .denied: key = "lut_folder_denied"
            case .read: key = "lut_folder_read_failed"
            case .tooMany: key = "lut_folder_too_many"
            }
            return AppLocalized.resource(key)
        }
        return editor.folder != nil && editor.files.isEmpty ? AppLocalized.resource("photo_filter_folder_empty") : nil
    }
    private func categoryLabel(_ category: PhotoFilterCatalogIndex.Category) -> String {
        category.builtIn.map { AppLocalized.resource("photo_filter_category_" + $0.rawValue) }
            ?? category.directory ?? AppLocalized.resource("lut_uncategorized")
    }
    var body: some View {
        let catalog = editor.catalog(selected: draft.builtinFilterSelection?.preset, favorites: draft.favoriteFilterIDs)
        let current = catalog.currentKey(enabled: enabled)
        let selected = catalog.pendingKey(source: editor.pendingSource) ?? current
        let labels = catalog.labels(locale: locale.identifier + language,
            uncategorized: AppLocalized.resource("lut_uncategorized"),
            restoredSourceFallback: AppLocalized.resource("photo_np3_selected_source"), builtInLabel: photoFilterBuiltInLabel)
        let category = catalog.categories.first { $0.key == session.category.key } ?? catalog.categories.first!
        PhotoEffectChooserDialog(categoryLabels: catalog.categories.map(categoryLabel),
            optionLabels: category.choices.map { labels[$0.key] ?? "" }, maximumHeight: 560,
            guidance: guidance, hint: session.showingFolderHint ? AppLocalized.resource("photo_filter_folder_hint") : nil,
            onDismiss: session.closeChooser) {
            HStack(spacing: 8) {
                if session.showingFolderHint {
                    PhotoEffectChooserAction(label: AppLocalized.resource("cancel")) {
                        ZTransferHaptics.shared.play(.selection); session.showingFolderHint = false
                    }
                    PhotoEffectChooserAction(label: AppLocalized.resource("photo_filter_folder")) {
                        ZTransferHaptics.shared.play(.navigation); session.launchFolderPicker()
                    }
                } else {
                    PhotoEffectChooserAction(label: AppLocalized.resource("photo_filter_turn_off"), selected: !enabled) {
                        ZTransferHaptics.shared.play(.selection); session.disable(); session.closeChooser()
                    }
                    PhotoEffectChooserAction(label: AppLocalized.resource("photo_filter_folder")) {
                        ZTransferHaptics.shared.play(.navigation); session.requestFolder()
                    }
                }
            }
        } content: { width in
            HStack(spacing: 6) {
                PhotoEffectChooserList(items: catalog.categories, id: \.key, initialID: category.key) { item in
                    PhotoEffectChooserRow(label: categoryLabel(item), selected: category.key == item.key, category: true) {
                        session.category.select(item.key)
                    }
                }.frame(width: max(0, width - 6) * 0.36)
                PhotoEffectChooserList(items: category.choices, id: \.key,
                    initialID: category.choices.contains { $0.key == selected } ? selected : category.choices.first?.key) { choice in
                    PhotoEffectChooserRow(label: labels[choice.key] ?? "", selected: choice.key == current,
                        favorite: choice.catalogKey.map(catalog.favoriteKeys.contains) == true) {
                        ZTransferHaptics.shared.play(.selection); session.choose(choice); session.closeChooser()
                    }.disabled(isReadOnly(choice))
                }.id(category.key)
            }
        }
        .onAppear { session.category.reconcile(catalog: catalog, selected: selected) }
        .onChange(of: selected) { session.category.reconcile(catalog: catalog, selected: $0) }
        .onChange(of: ObjectIdentifier(catalog)) { _ in session.category.reconcile(catalog: catalog, selected: selected) }
    }
    private func isReadOnly(_ choice: PhotoFilterChoice) -> Bool {
        if case .document = choice { return editor.loading }
        return false
    }
}
