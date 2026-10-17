import Foundation

enum RemoteLUTFolderFailure: Equatable { case missing, denied, read, tooMany }

struct RemoteLUTLayer: Identifiable {
    struct ID: Hashable { let request: UInt64; let retry: Int }
    var id: ID { ID(request: request, retry: retry) }
    let request: UInt64
    let file: RemoteLUTFile
    let lut: CubeLUT
    var retry = 0
}

enum RemoteLUTRenderFailure { case gpu, inputColor }

/// Main-thread coordinator matching Android's LutMonitorState commit rules.
/// File-system and renderer adapters call `loaded` only after the candidate is ready;
/// `presented` is the only operation that replaces the displayed LUT.
@MainActor
final class RemoteLUTMonitorState: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var files: [RemoteLUTFile] = []
    @Published private(set) var folderFailure: RemoteLUTFolderFailure?
    @Published private(set) var scanning = false
    @Published private(set) var loadingIdentifier: String?
    @Published private(set) var active: RemoteLUTLayer?
    @Published private(set) var candidate: RemoteLUTLayer?
    @Published private(set) var failure: String?
    @Published private(set) var noticeResource: String?
    /// Resource-key notification, routed to RemoteScreen's shared hint host.
    /// Keeping the callback in the accepted-result path also rejects stale IO.
    var onNotice: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCloseMenu: (() -> Void)?
    private var manualRequest = false

    private var generation: UInt64 = 0
    private var movie: Bool?
    private var available = false
    private var disposed = false
    private var gpuRetryUsed = false
    private var suppressedSelections: [Bool: String] = [:]
    private let preferences: RemoteLUTPreferences
    private let access: RemoteLUTFolderAccess
    private let queue: LUTIOQueue
    private let timeout: Duration
    private let scan: @Sendable (URL?, Data?, LUTIOQueue.Ticket) throws -> (URL, RemoteLUTFolderAccess.PreparedFolder)
    private let read: @Sendable (Data?, RemoteLUTFile, LUTIOQueue.Ticket) throws -> CubeLUT
    private var ticket: LUTIOQueue.Ticket?
    private var deadline: Task<Void, Never>?

    init(preferences: RemoteLUTPreferences = RemoteLUTPreferences(),
         access: RemoteLUTFolderAccess = RemoteLUTFolderAccess(),
         queue: LUTIOQueue = .shared, timeout: Duration = .seconds(10),
         scan: @escaping @Sendable (URL?, Data?, LUTIOQueue.Ticket) throws -> (URL, RemoteLUTFolderAccess.PreparedFolder) = { replacement, bookmark, ticket in
             if let replacement {
                 return (replacement, try RemoteLUTFolderAccess.prepareFolder(replacement, checkCancelled: ticket.checkCancellation))
             }
             let prepared = try RemoteLUTFolderAccess.prepareBookmark(bookmark, checkCancelled: ticket.checkCancellation)
             guard let root = RemoteLUTFolderAccess.resolveBookmark(prepared.bookmark) else { throw RemoteLUTFolderAccessError.missing }
             return (root, prepared)
         },
         read: @escaping @Sendable (Data?, RemoteLUTFile, LUTIOQueue.Ticket) throws -> CubeLUT = { bookmark, file, ticket in
             try RemoteLUTFolderAccess.parseBookmark(bookmark, file: file,
                                                    checkCancelled: ticket.checkCancellation)
         }) {
        self.preferences = preferences
        self.access = access
        self.queue = queue
        self.timeout = timeout
        self.read = read
        self.scan = scan
    }

    deinit { ticket?.cancel(); deadline?.cancel() }

    func environment(movie: Bool, available: Bool, visible: Bool) {
        guard !disposed else { return }
        let changed = self.movie != movie || self.available != available
        self.movie = movie
        self.available = available
        // Android clears only this mode's saved choice when its LUT tool is hidden.
        guard visible else { turnOff(); return }
        guard changed else { return }
        invalidate()
        active = nil
        guard available else { return }
        if files.isEmpty, access.bookmarkData != nil { refreshFolder() }
        else { restoreSelection() }
    }

    /// Backgrounding releases rendering but preserves the mode's saved choice.
    func suspendRendering() {
        available = false
        invalidate()
        active = nil
    }

    func refreshFolder(replacing replacement: URL? = nil) {
        guard !disposed, replacement != nil || access.bookmarkData != nil else { return }
        invalidate()
        let id = generation
        scanning = true
        let bookmark = access.bookmarkData
        let scan = scan
        ticket = queue.submit(action: { ticket in try scan(replacement, bookmark, ticket) }) { [weak self] result in
            guard let self, self.generation == id, !self.disposed else { return }
            self.ticket = nil
            self.deadline?.cancel(); self.deadline = nil
            self.scanning = false
            switch result {
            case .success(let (root, prepared)):
                let changedFolder = replacement != nil && root != self.folder
                self.access.commit(prepared)
                self.folder = root
                self.preferences.setFolder(root.absoluteString)
                self.files = RemoteLUTCatalog.visibleFiles(prepared.files)
                self.folderFailure = nil
                self.failure = nil
                if changedFolder {
                    self.active = nil
                    self.suppressedSelections.removeAll()
                    self.preferences.setSelection(nil, movie: false)
                    self.preferences.setSelection(nil, movie: true)
                } else {
                    for mode in [false, true] {
                        if let selected = self.preferences.selection(movie: mode),
                           !self.files.contains(where: { $0.identifier == selected }) {
                            self.preferences.setSelection(nil, movie: mode)
                            if mode == self.movie { self.active = nil; self.notify("lut_file_missing") }
                        }
                    }
                    if self.active == nil { self.restoreSelection() }
                    else if let current = self.active,
                            let updated = self.files.first(where: { $0.identifier == current.file.identifier }),
                            (updated.modified != nil && updated.modified != current.file.modified) ||
                            (updated.size != nil && updated.size != current.file.size) {
                        self.select(updated, manual: false)
                    }
                }
            case .failure(let error):
                let reason: RemoteLUTFolderFailure
                switch error as? RemoteLUTFolderAccessError {
                case .missing: reason = .missing
                case .denied: reason = .denied
                case .tooMany: reason = .tooMany
                default: reason = .read
                }
                if replacement != nil {
                    self.notify(Self.folderNotice(reason))
                } else {
                    self.scanFailed(reason)
                    if reason == .missing || reason == .denied {
                        self.preferences.setSelection(nil, movie: false)
                        self.preferences.setSelection(nil, movie: true)
                    }
                }
            }
        }
        startDeadline(id: id, marksFolderReadFailure: replacement == nil)
    }

    private func restoreSelection() {
        guard available, let movie, let id = preferences.selection(movie: movie),
              id != suppressedSelections[movie], let file = files.first(where: { $0.identifier == id }) else { return }
        select(file, manual: false)
    }

    private static func folderNotice(_ reason: RemoteLUTFolderFailure) -> String {
        switch reason {
        case .missing: "lut_folder_missing"
        case .denied: "lut_folder_denied"
        case .read: "lut_folder_read_failed"
        case .tooMany: "lut_folder_too_many"
        }
    }

    func scanFailed(_ reason: RemoteLUTFolderFailure) {
        scanning = false; failure = String(describing: reason); folderFailure = reason
        if reason == .missing || reason == .denied { active = nil; candidate = nil }
        // Current native caller is the explicit replacement-folder picker.
        notify(Self.folderNotice(reason))
    }

    private func notify(_ resource: String) {
        noticeResource = resource
        onNotice?(resource)
    }

    func openMenu() { noticeResource = nil; refreshFolder() }

    func chooseOff() { turnOff(); onCloseMenu?() }

    func dismissMenu() { if manualRequest { invalidate() } }

    func prepareFolderPicker() { invalidate() }

    func select(_ file: RemoteLUTFile, manual: Bool = true) {
        if manual, available, !disposed, active?.file == file {
            invalidate()
            onCloseMenu?()
            return
        }
        guard let id = beginSelection(file, manual: manual) else { return }
        let bookmark = access.bookmarkData
        let read = read
        ticket = queue.submit(action: { ticket in try read(bookmark, file, ticket) }) { [weak self] result in
            guard let self, self.generation == id, !self.disposed else { return }
            self.ticket = nil
            switch result {
            case .success(let lut): self.loaded(file, lut: lut, generation: id)
            case .failure(let error):
                let reason: String
                switch error as? CubeLUTFailure {
                case .invalid: reason = "invalid"
                case .unsupported: reason = "unsupported"
                case .tooLarge: reason = "tooLarge"
                default: reason = "read"
                }
                self.failed(generation: id, reason: reason)
            }
        }
        startDeadline(id: id)
    }

    // Android's deadline includes first GPU presentation, not just parsing.
    private func startDeadline(id: UInt64, marksFolderReadFailure: Bool = false) {
        deadline = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == id, !self.disposed else { return }
            self.invalidate()
            if marksFolderReadFailure { self.folderFailure = .read }
            self.failure = "timeout"
            self.notify("lut_read_timeout")
        }
    }

    func beginSelection(_ file: RemoteLUTFile, manual: Bool = true) -> UInt64? {
        guard !disposed else { return nil }
        guard available else { notify("lut_frame_unavailable"); return nil }
        if manual, let movie { suppressedSelections.removeValue(forKey: movie) }
        invalidate()
        manualRequest = manual
        noticeResource = nil
        loadingIdentifier = file.identifier
        return generation
    }

    func loaded(_ file: RemoteLUTFile, lut: CubeLUT, generation id: UInt64) {
        guard id == generation, !disposed else { return }
        candidate = RemoteLUTLayer(request: id, file: file, lut: lut)
    }

    func presented(_ layer: RemoteLUTLayer) {
        guard candidate?.id == layer.id else { return }
        presented(generation: layer.request)
    }

    func presented(generation id: UInt64) {
        guard id == generation, !disposed, let candidate else { return }
        deadline?.cancel(); deadline = nil
        ticket = nil
        active = candidate; self.candidate = nil; loadingIdentifier = nil
        if let movie { preferences.setSelection(candidate.file.identifier, movie: movie) }
        onCommit?()
        if manualRequest { onCloseMenu?() }
        manualRequest = false
    }

    func failed(generation id: UInt64, reason: String) {
        guard id == generation, !disposed else { return }
        invalidate(); failure = reason
        // The current LUT remains active exactly as on Android.
        let key: String = switch reason {
        case "invalid": "lut_invalid"
        case "unsupported": "lut_unsupported"
        case "tooLarge": "lut_too_large"
        default: "lut_read_failed"
        }
        notify(key)
    }

    /// A retry has its own surface identity; stale callbacks from its predecessor
    /// cannot consume the retry or discard the current visible layer.
    func renderFailed(_ layer: RemoteLUTLayer, reason: RemoteLUTRenderFailure) {
        guard !disposed else { return }
        let isCandidate = candidate?.request == layer.request && candidate?.retry == layer.retry
        let isActive = active?.request == layer.request && active?.retry == layer.retry
        guard isCandidate || isActive else { return }
        if !gpuRetryUsed, reason == .gpu {
            gpuRetryUsed = true
            var retry = layer
            retry.retry += 1
            if isCandidate { candidate = retry } else { active = retry }
            return
        }
        if let movie { suppressedSelections[movie] = layer.file.identifier }
        invalidate()
        if isActive { active = nil }
        failure = reason == .inputColor ? "inputColor" : "gpu"
        notify(reason == .inputColor ? "lut_input_color_unsupported" : "lut_gpu_failed")
    }

    func turnOff() {
        invalidate(); active = nil
        if let movie { preferences.setSelection(nil, movie: movie) }
    }

    func close() { disposed = true; invalidate(); active = nil; candidate = nil }

    private func invalidate() {
        ticket?.cancel(); ticket = nil
        deadline?.cancel(); deadline = nil
        generation &+= 1; scanning = false; loadingIdentifier = nil; candidate = nil
        manualRequest = false
    }
}

/// Joins GPU completion and drawable presentation without depending on callback order.
/// Surface loss invalidates outstanding frames, allowing a new surface to recover.
struct RemoteLUTPresentationGate {
    private var serial: UInt64 = 0
    private var pending: UInt64?
    private var completed = false
    private var displayed = false
    private var acknowledged = false
    var inFlight: Bool { pending != nil }
    var isPresented: Bool { acknowledged }
    func accepts(_ id: UInt64) -> Bool { pending == id }

    mutating func begin() -> UInt64? {
        guard pending == nil else { return nil }
        serial &+= 1
        pending = serial
        completed = false
        displayed = false
        return serial
    }
    mutating func complete(_ id: UInt64) -> Bool {
        guard pending == id else { return false }
        completed = true
        return confirm()
    }
    mutating func present(_ id: UInt64) -> Bool {
        guard pending == id else { return false }
        displayed = true
        return confirm()
    }
    mutating func invalidate() {
        pending = nil
        acknowledged = false
    }
    private mutating func confirm() -> Bool {
        guard completed, displayed else { return false }
        pending = nil
        guard !acknowledged else { return false }
        acknowledged = true
        return true
    }
}

struct RemoteLUTPanelStatus: Equatable {
    let folderAction: String
    let guidance: String?
    let accessible: Bool
    let showMonitorOnly: Bool

    init(hasFolder: Bool, failure: RemoteLUTFolderFailure?, scanning: Bool, empty: Bool) {
        accessible = failure != .missing && failure != .denied
        folderAction = "lut_folder"
        showMonitorOnly = !hasFolder
        if !hasFolder { guidance = "lut_choose_hint" }
        else if let failure {
            guidance = switch failure {
            case .missing: "lut_folder_missing"
            case .denied: "lut_folder_denied"
            case .read: "lut_folder_read_failed"
            case .tooMany: "lut_folder_too_many"
            }
        } else if scanning && empty { guidance = "lut_reading_folder" }
        else if empty { guidance = "lut_folder_empty" }
        else { guidance = nil }
    }
}
