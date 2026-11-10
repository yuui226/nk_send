import Combine
import SwiftUI

/// The page owns this lifetime without observing every IO/control update.
@MainActor
final class PhotoFilterEditorLifetime: ObservableObject {
    let session: PhotoFilterEditorSession
    init(store: PhotoNp3Store = PhotoNp3Store(), role: PhotoNp3Store.Role) {
        session = PhotoFilterEditorSession(store: store, role: role)
    }
    init(_ session: PhotoFilterEditorSession) { self.session = session }
}

/// Native counterpart of rememberPhotoNp3Draft and PhotoFilterEditor. Each
/// presentation gets a fresh source state; transfer commits at its existing
/// boundary, while local selection/source changes save their role immediately.
@MainActor
final class PhotoFilterEditorSession: ObservableObject {
    private final class Relay { weak var owner: PhotoFilterEditorSession? }
    private let relay: Relay
    private let store: PhotoNp3Store
    private let role: PhotoNp3Store.Role
    private let source: PhotoNp3Source
    private var draft: Binding<PhotoEffectsSettings>?
    private var observations = Set<AnyCancellable>()
    private var onExplicitSelection: () -> Void = {}
    private var ended = true
    private var sceneActive = true
    private var suppressResume = false
    private var previousEnabled: Bool?
    private(set) var lifetimeID = UUID()
    @Published private(set) var editor: PhotoNp3EditorState
    @Published private(set) var active = false
    @Published var showingChooser = false
    @Published var showingFolderHint = false
    @Published var showingFolder = false
    @Published var settingsExpanded = false
    @Published var category = PhotoFilterCategorySelection()
    @Published private(set) var notice: PhotoNp3EditorState.Notice?

    init(store: PhotoNp3Store, role: PhotoNp3Store.Role, source: PhotoNp3Source = .fileProvider()) {
        self.store = store; self.role = role; self.source = source
        let relay = Relay(); self.relay = relay
        editor = Self.makeEditor(store: store, role: role, source: source, recipe: store.restore(role), relay: relay)
        relay.owner = self
    }
    private static func makeEditor(store: PhotoNp3Store, role: PhotoNp3Store.Role, source: PhotoNp3Source,
                                   recipe: PhotoNp3Recipe?, relay: Relay) -> PhotoNp3EditorState {
        PhotoNp3EditorState(store: store, role: role, initialRecipe: recipe, source: source,
            onSelected: { [weak relay] in relay?.owner?.accepted($0, explicit: $1) },
            onUnavailable: { [weak relay] in relay?.owner?.unavailable() },
            selectionAllowed: { [weak relay] in relay?.owner?.active == true })
    }

    func begin(draft: Binding<PhotoEffectsSettings>, active: Bool,
               onExplicitSelection: @escaping () -> Void) {
        end()
        self.draft = draft; self.onExplicitSelection = onExplicitSelection; ended = false
        previousEnabled = draft.wrappedValue.photoFilterEnabled && draft.wrappedValue.colorEffectModule == .filter
        editor = Self.makeEditor(store: store, role: role, source: source,
            recipe: draft.wrappedValue.builtinFilterSelection?.photoRecipe, relay: relay)
        editor.$notice.compactMap { $0 }.sink { [weak self] in self?.notice = $0 }.store(in: &observations)
        var previousFolder = store.folder
        store.observeFolderChanges { [weak self] in
            guard let self, let draft = self.draft else { return }
            let replaced = previousFolder != nil && previousFolder != self.store.folder
            previousFolder = self.store.folder
            if replaced {
                var value = draft.wrappedValue
                value.clearNP3DirectorySettings()
                self.draftChanged(value)
                if value != draft.wrappedValue { draft.wrappedValue = value }
                self.saveLocalSource()
            }
        }.store(in: &observations)
        notice = nil; settingsExpanded = false; category = .init()
        setActive(active)
        saveLocalSource()
    }

    func end() {
        saveLocalSource()
        active = false; ended = true
        lifetimeID = UUID()
        showingChooser = false; showingFolderHint = false; showingFolder = false
        editor.close(); observations.removeAll()
        draft = nil; onExplicitSelection = {}; suppressResume = false
        previousEnabled = nil
    }
    func setActive(_ value: Bool) {
        guard !ended else { return }
        guard active != value else { return }
        active = value
        if value { if sceneActive { editor.refresh() } }
        else {
            editor.cancelPending(); showingChooser = false; showingFolderHint = false
        }
    }
    func setSceneActive(_ value: Bool) {
        guard sceneActive != value else { return }
        sceneActive = value
        guard value else { return }
        if showingFolder || suppressResume { suppressResume = false; return }
        if active { editor.refresh() }
    }
    func source(for settings: PhotoEffectsSettings) -> String? {
        editor.source(for: settings.builtinFilterSelection?.preset.id)
    }
    func draftChanged(_ value: PhotoEffectsSettings) {
        let enabled = value.photoFilterEnabled && value.colorEffectModule == .filter
        guard previousEnabled != enabled else { return }
        previousEnabled = enabled; settingsExpanded = false
        if !enabled { editor.cancelPending() }
    }
    func openChooser() {
        guard active else { return }
        category = .init(); showingFolderHint = false; showingChooser = true; editor.refresh()
    }
    func closeChooser() { showingChooser = false; showingFolderHint = false }
    func requestFolder() {
        guard active else { return }
        editor.cancelPending()
        if editor.folder == nil { showingFolderHint = true }
        else { launchFolderPicker() }
    }
    func launchFolderPicker() {
        guard active else { return }
        editor.cancelPending(); showingFolderHint = false; showingChooser = false; showingFolder = true
    }
    func folderPickerCompleted(_ result: Result<[URL], Error>, lifetimeID: UUID) {
        guard lifetimeID == self.lifetimeID, !ended else { return }
        // A native modal may leave the scene active throughout. Skip a resume
        // only if it actually became inactive; never skip a later real resume.
        suppressResume = !sceneActive
        showingFolder = false
        guard active else { return }
        switch result {
        case .success(let urls): if let url = urls.first { editor.folderPicked(url) }
        case .failure(let error):
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || error.code != NSUserCancelledError {
                notice = .init(resource: "lut_folder_denied")
            }
        }
    }
    func disable() {
        guard active, let draft else { return }
        editor.cancelPending()
        var value = draft.wrappedValue
        if value.colorEffectModule == .filter { value.photoFilterEnabled = false }
        draftChanged(value)
        draft.wrappedValue = value; settingsExpanded = false
    }
    func choose(_ choice: PhotoFilterChoice?) {
        guard active, let draft else { return }
        guard let choice else { disable(); return }
        switch choice {
        case .document(let file, _):
            guard !editor.loading else { return }
            editor.choose(file.identifier)
        case .preset(let preset, let source):
            let recipe = Np3FilterCatalog.preset(id: preset.id).map {
                PhotoNp3Recipe(preset: preset, parameters: .flexible($0.parameters))
            } ?? (editor.selectedRecipe?.preset.id == preset.id ? editor.selectedRecipe : nil)
                ?? draft.wrappedValue.builtinFilterSelection?.photoRecipe.flatMap { $0.preset.id == preset.id ? $0 : nil }
            guard let recipe else { return }
            if source == nil, Np3FilterCatalog.preset(id: preset.id) != nil { editor.off() }
            editor.resetSelection(recipe, source: source)
            accepted(recipe, explicit: true)
        }
    }
    private func accepted(_ recipe: PhotoNp3Recipe, explicit: Bool) {
        guard active, let draft else { return }
        var value = draft.wrappedValue
        guard value.selectPhotoFilter(recipe, explicit: explicit) else { return }
        if explicit { onExplicitSelection() }
        draftChanged(value)
        draft.wrappedValue = value
        saveLocalSource()
    }
    private func unavailable() {
        guard let draft else { return }
        var value = draft.wrappedValue
        value.rememberedBuiltinFilter = nil
        if value.colorEffectModule == .filter { value.selectedFilter = nil; value.photoFilterEnabled = false }
        draftChanged(value)
        draft.wrappedValue = value; settingsExpanded = false
        saveLocalSource()
    }
    private func saveLocalSource() {
        guard role == .local, let value = draft?.wrappedValue else { return }
        _ = try? store.save(role, recipe: value.builtinFilterSelection?.photoRecipe, source: source(for: value))
    }
}
