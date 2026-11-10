import Combine
import Foundation

/// Android PhotoNp3Source, using the existing shared preset reader and native
/// bookmark leases. Scan results contain metadata only; every selection opens
/// the file again, even when its URI already has an identity hint.
struct PhotoNp3Source: Sendable {
    struct ScanRequest: Sendable {
        let folder: URL
        let previousFolder: URL?
        let bookmark: Data?
        let replacing: Bool
    }
    var scan: @Sendable (ScanRequest, PresetIOQueue.Ticket) throws -> RemoteLUTFolderAccess.PreparedFolder
    var read: @Sendable (PresetFile, Data?, PresetIOQueue.Ticket) throws -> ParsedPhotoNp3

    static func fileProvider(operations: DirectoryAccessOperations = .system) -> Self {
        .init(scan: { request, ticket in
            try ticket.checkCancellation()
            let prepared: RemoteLUTFolderAccess.PreparedFolder
            let identity: URL
            if request.replacing {
                let previous = RemoteLUTFolderAccess.resolveBookmark(request.bookmark)
                prepared = try RemoteLUTFolderAccess.prepareFolder(request.folder, fileExtension: "np3",
                    operations: operations, checkCancelled: ticket.checkCancellation)
                // A bookmark can resolve after a provider/container path moves.
                // Keep document identities stable when reselecting that folder.
                identity = previous?.standardizedFileURL.path == request.folder.standardizedFileURL.path
                    ? request.previousFolder ?? request.folder : request.folder
            } else {
                prepared = try RemoteLUTFolderAccess.prepareBookmark(request.bookmark, fileExtension: "np3",
                    operations: operations, checkCancelled: ticket.checkCancellation)
                identity = request.folder
            }
            let root = URL(fileURLWithPath: identity.standardizedFileURL.path, isDirectory: true)
            let files = try prepared.files.map { file in
                try ticket.checkCancellation()
                // PresetFile.identifier is opaque. NP3 uses file-URL identities;
                // actual access always resolves the bookmark + relative path.
                return PresetFile(identifier: root.appendingPathComponent(file.relativePath).absoluteString,
                    name: file.name, relativePath: file.relativePath, size: file.size, modified: file.modified)
            }
            // URI escaping can change the final duplicate-name tie order.
            // Number source labels only after assigning the final identities.
            return .init(bookmark: prepared.bookmark, files: RemoteLUTCatalog.sortedFiles(files), root: root)
        }, read: { file, bookmark, ticket in
            try RemoteLUTFolderAccess.withScopedFile(bookmark, file: file, operations: operations,
                checkCancelled: ticket.checkCancellation) { url in
                try ticket.checkCancellation()
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try PhotoNp3Parser.read(from: handle, checkpoint: ticket.checkCancellation)
            }
        })
    }
}

/// Android PhotoNp3EditorState: source/directory draft only. The owner decides
/// when to commit the effect, whether it is enabled and which strength to use.
/// Both entries share the folder, but never share this draft or its request.
@MainActor
final class PhotoNp3EditorState: ObservableObject {
    struct Notice: Equatable {
        let id = UUID()
        let resource: String
    }
    let store: PhotoNp3Store
    let request: LUTRequestController
    private let source: PhotoNp3Source
    private let timeout: Duration
    private let onSelected: (PhotoNp3Recipe, Bool) -> Void
    private let onUnavailable: () -> Void
    private let selectionAllowed: () -> Bool
    private var observations = Set<AnyCancellable>()
    private var closed = false

    @Published private(set) var folder: URL?
    @Published private(set) var files: [PresetFile] = [] { didSet { catalogCache = nil } }
    @Published private(set) var failure: RemoteLUTFolderAccessError? { didSet { catalogCache = nil } }
    @Published private(set) var selectedRecipe: PhotoNp3Recipe? { didSet { catalogCache = nil } }
    @Published private(set) var selectedSource: String? { didSet { catalogCache = nil } }
    @Published private(set) var selectedSourceLabel: PhotoNp3SourceLabel? { didSet { catalogCache = nil } }
    @Published private(set) var sourcePresetIDs: [String: String] = [:] { didSet { catalogCache = nil } }
    @Published private(set) var notice: Notice?
    @Published private(set) var loadingOrigin = Date()
    private var catalogCache: (selected: PhotoFilterPreset?, favorites: [String], index: PhotoFilterCatalogIndex)?

    func catalog(selected: PhotoFilterPreset?, favorites: [String]) -> PhotoFilterCatalogIndex {
        if let catalogCache, catalogCache.selected == selected, catalogCache.favorites == favorites {
            return catalogCache.index
        }
        let index = PhotoFilterCatalogIndex(files: files, failure: failure, hints: sourcePresetIDs,
            sourceRecipe: selectedRecipe, source: selectedSource, sourceLabel: selectedSourceLabel,
            selected: selected, favorites: favorites)
        catalogCache = (selected, favorites, index)
        return index
    }

    init(store: PhotoNp3Store, role: PhotoNp3Store.Role, initialRecipe: PhotoNp3Recipe?,
         source: PhotoNp3Source = .fileProvider(), request: LUTRequestController = LUTRequestController(),
         timeout: Duration = .seconds(10), onSelected: @escaping (PhotoNp3Recipe, Bool) -> Void,
         onUnavailable: @escaping () -> Void, selectionAllowed: @escaping () -> Bool = { true }) {
        self.store = store; self.source = source; self.request = request; self.timeout = timeout
        self.onSelected = onSelected; self.onUnavailable = onUnavailable; self.selectionAllowed = selectionAllowed
        folder = store.folder; selectedRecipe = initialRecipe
        let uri = initialRecipe != nil && store.savedID(role) == initialRecipe?.preset.id ? store.source(role) : nil
        selectedSource = uri; selectedSourceLabel = uri.flatMap(store.sourceLabel)
        store.observeFolderChanges { [weak self] in self?.folderChanged() }.store(in: &observations)
        request.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    var loading: Bool { request.loading }
    var loadingSelection: Bool { request.pendingIdentifier != nil }
    var pendingSource: String? { request.pendingIdentifier }
    /// PhotoLutEditor empty-state precedence, adapted to user-supplied NP3.
    /// Callers only use this when neither files nor a saved recipe is selectable.
    var emptyLabelKey: String {
        if folder == nil { return "photo_filter_set_folder" }
        if let failure {
            switch failure {
            case .missing: return "lut_folder_missing"
            case .denied: return "lut_folder_denied"
            case .read: return "lut_folder_read_failed"
            case .tooMany: return "lut_folder_too_many"
            }
        }
        return loading ? "lut_reading_folder" : "photo_filter_folder_empty"
    }
    func knownPresetID(_ source: String) -> String? { sourcePresetIDs[source] }
    func source(for presetID: String?) -> String? {
        presetID != nil && selectedRecipe?.preset.id == presetID ? selectedSource : nil
    }

    private func folderChanged() {
        guard !closed, folder != store.folder else { return }
        let replaced = folder != nil
        cancelPending(); folder = store.folder
        if !files.isEmpty { files = [] }
        if !sourcePresetIDs.isEmpty { sourcePresetIDs = [:] }
        failure = nil
        if replaced {
            selectedSource = nil; selectedSourceLabel = nil
            if selectedRecipe.map({ PhotoNp3RecipeKind.from(id: $0.preset.id) != nil }) == true {
                selectedRecipe = nil
                onUnavailable()
            }
        }
    }

    func resetSelection(_ recipe: PhotoNp3Recipe?, source explicitSource: String? = nil) {
        guard !closed else { return }
        let retained = explicitSource ?? (recipe?.preset.id == selectedRecipe?.preset.id ? selectedSource : nil)
        cancelPending(); selectedRecipe = recipe
        selectedSource = recipe == nil ? nil : retained
        selectedSourceLabel = selectedSource.flatMap(store.sourceLabel)
    }
    func off() { resetSelection(nil) }
    func cancelPending() { request.cancel() }
    func close() {
        guard !closed else { return }
        closed = true; observations.removeAll(); cancelPending()
    }
    func refresh() {
        guard !closed, !loading, let folder = store.folder else { return }
        scan(folder, replacing: false)
    }
    func folderPicked(_ url: URL) {
        guard !closed else { return }
        scan(url, replacing: true)
    }
    func choose(_ identifier: String) {
        guard !closed, let file = files.first(where: { $0.identifier == identifier }) else { return }
        read(file, refreshed: false)
    }

    private struct ScanResult: Sendable {
        let folder: RemoteLUTFolderAccess.PreparedFolder
        let hints: [String: String]
        let selectedLabel: PhotoNp3SourceLabel?
    }
    private func scan(_ url: URL, replacing: Bool) {
        let scan = source.scan, hints = store.sourceHints(), selected = selectedSource
        let input = PhotoNp3Source.ScanRequest(folder: url, previousFolder: store.folder,
            bookmark: store.folderBookmark, replacing: replacing)
        request.submit(timeout: timeout, action: { ticket in
            let result = try scan(input, ticket)
            let known = try hints.knownPresetIDs(result.files.map(\.identifier), checkpoint: ticket.checkCancellation)
            let label = selected.flatMap { PhotoNp3SourceLabel.forSource($0, in: result.files) }
            try ticket.checkCancellation()
            return ScanResult(folder: result, hints: known, selectedLabel: label)
        }, onTimeout: { [weak self] in
            guard let self else { return }
            if !replacing { self.failure = .read }
            self.notice = .init(resource: "photo_np3_read_timeout")
        }, deliver: { [weak self] result in
            guard let self, !self.closed, self.selectionAllowed() else { return }
            switch result {
            case .success(let scanned):
                guard let root = scanned.folder.root else { return }
                let previous = self.store.folder
                // Native scope leases already ended on the worker. Only an
                // accepted complete scan may publish its prepared bookmark.
                self.store.replaceFolder(root, bookmark: scanned.folder.bookmark)
                guard !self.closed, self.store.folder == root else { return }
                self.folder = root
                if self.files != scanned.folder.files { self.files = scanned.folder.files }
                let known = replacing && previous != nil && previous != root ? [:] : scanned.hints
                if self.sourcePresetIDs != known { self.sourcePresetIDs = known }
                self.failure = nil
                if let selected = self.selectedSource {
                    if let file = self.files.first(where: { $0.identifier == selected }) {
                        self.selectedSourceLabel = scanned.selectedLabel
                        if let label = scanned.selectedLabel { self.store.rememberSourceLabel(selected, label: label) }
                        self.read(file, refreshed: true)
                    } else {
                        self.off(); self.onUnavailable()
                    }
                }
            case .failure(let error):
                let reason = error as? RemoteLUTFolderAccessError ?? .read
                if !replacing { self.failure = reason }
                self.notice = .init(resource: Self.folderMessage(reason))
            }
        })
    }

    private struct ReadResult: Sendable {
        let parsed: ParsedPhotoNp3
        let label: PhotoNp3SourceLabel?
    }
    private func read(_ file: PresetFile, refreshed: Bool) {
        let read = source.read, bookmark = store.folderBookmark, directory = files
        let listedLabel = refreshed && selectedSource == file.identifier ? selectedSourceLabel : nil
        if !refreshed { loadingOrigin = Date() }
        request.submit(timeout: timeout, selectionIdentifier: refreshed ? nil : file.identifier, action: { ticket in
            let parsed = try read(file, bookmark, ticket)
            let label = listedLabel ?? PhotoNp3SourceLabel.forSource(file.identifier, in: directory)
            try ticket.checkCancellation()
            return ReadResult(parsed: parsed, label: label)
        }, onTimeout: { [weak self] in
            self?.notice = .init(resource: "photo_np3_read_timeout")
        }, deliver: { [weak self] result in
            guard let self, !self.closed, self.selectionAllowed() else { return }
            do {
                let result = try result.get(), parsed = result.parsed
                let unchanged = self.selectedRecipe?.preset.id == parsed.recipe.preset.id && self.selectedSource == file.identifier
                try self.store.rememberSource(file.identifier, sha256: parsed.sourceSha256, presetID: parsed.recipe.preset.id)
                if self.sourcePresetIDs[file.identifier] != parsed.recipe.preset.id { self.sourcePresetIDs[file.identifier] = parsed.recipe.preset.id }
                if !unchanged { self.selectedRecipe = parsed.recipe }
                self.selectedSource = file.identifier; self.selectedSourceLabel = result.label
                if let label = result.label { self.store.rememberSourceLabel(file.identifier, label: label) }
                if !refreshed || !unchanged { self.onSelected(self.selectedRecipe ?? parsed.recipe, !refreshed) }
            } catch {
                let resource: String
                switch (error as? PhotoNp3Error)?.reason {
                case .invalid: resource = "photo_np3_invalid"
                case .unsupported: resource = "photo_np3_unsupported"
                case .tooLarge: resource = "photo_np3_too_large"
                case nil: resource = "photo_np3_read_failed"
                }
                self.notice = .init(resource: resource)
            }
        })
    }

    private static func folderMessage(_ failure: RemoteLUTFolderAccessError) -> String {
        switch failure {
        case .missing: "lut_folder_missing"
        case .denied: "lut_folder_denied"
        case .read: "lut_folder_read_failed"
        case .tooMany: "lut_folder_too_many"
        }
    }
}
