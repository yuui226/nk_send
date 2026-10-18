import Combine
import Foundation

/// Owns the lazily created editor without forwarding its control/IO updates
/// into the entire page. LUT controls and the chooser observe the editor;
/// notices are delivered separately, while the page retains its lifetime.
@MainActor
final class PhotoLUTEditorLifetime: ObservableObject {
    let editor: PhotoLUTEditorState
    init(_ editor: PhotoLUTEditorState) { self.editor = editor }
    convenience init(role: PhotoLUTStore.Role) { self.init(PhotoLUTEditorState(role: role)) }
}

/// PhotoLutEditorState.kt: one editor lifetime, shared folder/favorites, and a
/// role-specific recipe. The presenter owns its draft and accepts callbacks.
@MainActor
final class PhotoLUTEditorState: ObservableObject {
    struct Notice: Equatable {
        let id = UUID()
        let resource: String
    }

    let store: PhotoLUTStore
    let request: LUTRequestController
    private var access: RemoteLUTFolderAccess
    private var observations = Set<AnyCancellable>()
    @Published private(set) var files: [RemoteLUTFile] = [] {
        didSet { catalogCache = nil }
    }
    private var catalogCache: PresetCatalogIndex?
    @Published private(set) var folderFailure: String?
    @Published private(set) var notice: Notice?
    @Published var categorySelection = PhotoLUTCategorySelection()
    @Published var showingChooser = false
    @Published var showingFolder = false
    @Published var settingsExpanded = false
    @Published private(set) var loadingOrigin = Date()

    init(role: PhotoLUTStore.Role, defaults: UserDefaults = .standard,
         directory: URL? = nil, request: LUTRequestController = LUTRequestController()) {
        store = PhotoLUTStore(role: role, defaults: defaults, directory: directory)
        access = RemoteLUTFolderAccess(defaults: defaults, scope: .photo)
        self.request = request
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        store.$favorites.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.catalogCache = nil
        }.store(in: &observations)
        request.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    var loading: Bool { request.loading }
    var loadingSelection: Bool { request.pendingIdentifier != nil }
    var active: Bool { store.selectedIdentifier != nil && !loading }
    /// Android remembers files/favorites separately from recipe and loading
    /// state. Keep one index per editor so wheel labels are O(1), not O(N) each.
    var catalog: PresetCatalogIndex {
        if let catalogCache { return catalogCache }
        let result = PresetCatalogIndex(files: files, orderedFiles: store.ordered(files))
        catalogCache = result
        return result
    }
    var orderedFiles: [RemoteLUTFile] { catalog.orderedFiles }
    var selectionOptions: [String?] { catalog.selectionOptions(current: store.selectedIdentifier) }
    var emptyLabelKey: String {
        RemoteLUTCatalog.photoFolderStatus(hasFolder: store.folderBookmark != nil,
            loading: loading && files.isEmpty, failure: folderFailure)
    }

    func openChooser(onDisable: @escaping () -> Void) {
        categorySelection = PhotoLUTCategorySelection()
        reconcileCategory()
        showingChooser = true
        refresh(onDisable: onDisable)
    }

    func openFolder() {
        cancelPending()
        showingChooser = false
        showingFolder = true
    }

    func resetForPresentation() {
        close()
        store.reloadRole()
        files = []
        folderFailure = nil
        notice = nil
        categorySelection = PhotoLUTCategorySelection()
    }

    func cancelPending() { request.cancel() }
    func close() {
        cancelPending()
        showingChooser = false
        showingFolder = false
        settingsExpanded = false
    }
    func off(onDisable: () -> Void) {
        cancelPending()
        onDisable()
        reconcileCategory()
    }

    func refresh(onDisable: @escaping () -> Void) { scanFolder(nil, onDisable: onDisable) }

    func scanFolder(_ replacement: URL?, onDisable: @escaping () -> Void) {
        let bookmark = access.bookmarkData
        guard replacement != nil || bookmark != nil else {
            cancelPending()
            replaceFiles([])
            folderFailure = nil
            reconcileCategory()
            return
        }
        request.submit(action: { ticket in
            if let replacement {
                let previous = RemoteLUTFolderAccess.resolveBookmark(bookmark)
                let prepared = try RemoteLUTFolderAccess.prepareFolder(replacement, checkCancelled: ticket.checkCancellation)
                return (prepared, previous)
            }
            return (try RemoteLUTFolderAccess.prepareBookmark(bookmark, checkCancelled: ticket.checkCancellation), nil as URL?)
        }, onTimeout: { [weak self] in
            guard let self else { return }
            if replacement == nil { self.folderFailure = "lut_folder_read_failed" }
            self.notice = Notice(resource: "lut_read_timeout")
        }, deliver: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (prepared, previous)):
                self.access.commit(prepared)
                self.store.setFolderBookmark(self.access.bookmarkData)
                self.replaceFiles(prepared.files)
                self.folderFailure = nil
                if (replacement != nil && previous?.standardizedFileURL != replacement?.standardizedFileURL)
                    || !self.files.contains(where: { $0.identifier == self.store.selectedIdentifier }) { onDisable() }
                self.reconcileCategory()
            case .failure(let error):
                let message = Self.folderMessage(error)
                // A failed replacement never changes the current folder or its status.
                if replacement == nil {
                    self.folderFailure = message
                    if let failure = error as? RemoteLUTFolderAccessError, failure == .missing || failure == .denied {
                        self.replaceFiles([])
                        onDisable()
                        self.reconcileCategory()
                    }
                }
                self.notice = Notice(resource: message)
            }
        })
    }

    func choose(_ identifier: String?, onDisable: () -> Void,
                shouldAccept: @escaping () -> Bool = { true },
                onSelect: @escaping (PhotoFilterSelection) -> Void) {
        guard let identifier else { off(onDisable: onDisable); return }
        guard let file = catalog.filesByIdentifier[identifier] else { return }
        let bookmark = access.bookmarkData
        let directory = store.snapshotDirectory
        loadingOrigin = Date()
        request.submit(selectionIdentifier: identifier, action: { ticket in
            let lut = try RemoteLUTFolderAccess.parseBookmark(bookmark, file: file, checkCancelled: ticket.checkCancellation)
            return try PhotoLUTStore.prepareSelection(lut, directory: directory, checkCancelled: ticket.checkCancellation)
        }, onTimeout: { [weak self] in
            self?.notice = Notice(resource: "lut_read_timeout")
        }, deliver: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let prepared):
                guard shouldAccept() else { return }
                let selection = self.store.acceptSelection(prepared,
                    name: file.label.isEmpty ? file.name : file.label, sourceIdentifier: file.identifier)
                onSelect(selection)
                self.reconcileCategory()
            case .failure(let error):
                let message: String
                switch error as? CubeLUTFailure {
                case .invalid: message = "lut_invalid"
                case .unsupported: message = "lut_unsupported"
                case .tooLarge: message = "lut_too_large"
                default: message = "lut_read_failed"
                }
                // A bad candidate is a transient notice, never a folder failure.
                self.notice = Notice(resource: message)
            }
        })
    }

    private func reconcileCategory() {
        categorySelection.reconcile(files: files, selected: store.selectedIdentifier)
    }
    private func replaceFiles(_ next: [RemoteLUTFile]) {
        if files != next { files = next }
    }
    private static func folderMessage(_ error: Error) -> String {
        switch error as? RemoteLUTFolderAccessError {
        case .missing: return "lut_folder_missing"
        case .denied: return "lut_folder_denied"
        case .tooMany: return "lut_folder_too_many"
        default: return "lut_folder_read_failed"
        }
    }
}
