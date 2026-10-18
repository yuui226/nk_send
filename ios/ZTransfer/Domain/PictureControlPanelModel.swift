import Foundation
import Combine

enum PictureControlPresetChoice: Identifiable, Sendable {
    case builtIn(BuiltInPictureControl), document(PresetFile)
    var id: String { switch self { case .builtIn(let value): value.id; case .document(let value): value.identifier } }
}

/// Business state for Android RemotePictureControlPanel. A destination is always explicit.
@MainActor
final class PictureControlPanelModel: ObservableObject {
    enum Action: Sendable { case write(Int, PictureControlPresetChoice), activate(Int), clear(Int)
        var slot: Int { switch self { case .write(let slot, _), .activate(let slot), .clear(let slot): slot } }
    }
    @Published private(set) var overview: PictureControlOverview?
    @Published private(set) var loading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var initialLoadFinished = false
    @Published private(set) var loadFailureResource = "picture_control_slots_read_failed"
    @Published private(set) var pending: Action?
    @Published var editingSlot: Int?
    @Published private(set) var closeRequested = false
    @Published var interactionAllowed = true
    @Published private(set) var presets: [BuiltInPictureControl] = []
    @Published private(set) var presetsFailed = false
    @Published private(set) var report = ""
    let folders: PictureControlFolderState
    var notice: (String) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var onReport: (String) -> Void = { _ in }
    var feedback: () -> Void = {}
    var movie = false
    private let readOverview: ((@Sendable (String) -> Void)?) async throws -> PictureControlOverview
    private let reports: PictureControlReportHistory
    private let change: (Int, PictureControlChange, (@Sendable (String) -> Void)?) async throws -> Void
    private let current: () -> Bool
    private let allowed: () -> Bool
    private let busy: (Bool) -> Bool
    private let closesFolders: Bool
    private var task: Task<Void, Never>?
    private var closed = false
    private var opened = false

    init(folders: PictureControlFolderState,
         current: @escaping () -> Bool, allowed: @escaping () -> Bool, busy: @escaping (Bool) -> Bool,
         readOverview: @escaping ((@Sendable (String) -> Void)?) async throws -> PictureControlOverview,
         change: @escaping (Int, PictureControlChange, (@Sendable (String) -> Void)?) async throws -> Void,
         closesFolders: Bool = true, reports: PictureControlReportHistory? = nil) {
        self.folders = folders; self.current = current; self.allowed = allowed; self.busy = busy
        self.readOverview = readOverview; self.change = change
        self.closesFolders = closesFolders
        self.reports = reports ?? PictureControlReportHistory()
    }
    func open() {
        guard task == nil, !closed, !opened else { return }
        opened = true
        if !loading { loading = true }
        #if DEBUG
        let ticket = reports.begin(.overview)
        #endif
        task = Task { [self] in
            defer { initialLoadFinished = true; task = nil }
            let result = await Task.detached { Result { try builtInPictureControls() } }.value
            guard !Task.isCancelled, !closed else { return }
            switch result {
            case .success(let entries): if presets != entries { presets = entries }
            case .failure: if !presetsFailed { presetsFailed = true }
            }
            #if DEBUG
            let saved = await Task.detached { (try? PictureControlReportJournal.latestByKind()) ?? [:] }.value
            reports.restore(saved)
            let journal = await Task.detached { PictureControlReportJournal(kind: .overview) }.value
            let header = "Picture Control overview v1 \(Date()) app=\(Self.version) movie=\(movie)"
            await Task.detached { journal.append(header) }.value
            await refresh(notifyFailure: false, log: journal.append)
            if closed || Task.isCancelled {
                await Task.detached { journal.append("READ CANCELLED: panel closed or camera changed") }.value
            }
            finishReport(ticket, journal.text)
            #else
            await refresh()
            if !closed, !Task.isCancelled, loadFailed { dismiss() }
            #endif
        }
    }
    private static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version)(\(build))"
    }
    private func finishReport(_ ticket: PictureControlReportHistory.Ticket, _ text: String) {
        reports.finish(ticket, text: text)
        if report != reports.text { report = reports.text }
        onReport(reports.text)
    }
    func refresh(notifyFailure: Bool = true, log: (@Sendable (String) -> Void)? = nil) async {
        if !loading { loading = true }
        defer { if loading { loading = false } }
        do {
            guard !closed else { throw CancellationError() }
            guard current() else { throw PTPSessionError.invalidResponse }
            let fresh = try await readOverview(log)
            guard current(), !closed, !Task.isCancelled else { throw CancellationError() }
            if overview != fresh { overview = fresh }
            if loadFailed { loadFailed = false }
        } catch is CancellationError { return }
        catch {
            guard !closed, !Task.isCancelled, current() else { return }
            if !loadFailed { loadFailed = true }
            loadFailureResource = error as? NikonPictureControlError == .movieBankUnsupported ?
                "picture_control_movie_bank_unsupported" : "picture_control_slots_read_failed"
            let message = "READ FAILED: \(type(of: error)): \(error.localizedDescription)"
            await Task.detached { log?(message) }.value
        }
        if loadFailed && notifyFailure { notice(AppLocalized.resource(loadFailureResource)) }
    }
    var canBrowse: Bool { pending == nil && !loading && !closed && !closeRequested }
    var opening: Bool { !initialLoadFinished }
    func requestClose() {
        guard !closed, !closeRequested else { return }
        closeRequested = true
        // Like Android, an opening spinner has no recorded popup to collapse.
        if opening { dismiss() }
    }
    func canEdit(_ slot: PictureControlSlotInfo) -> Bool {
        canBrowse && interactionAllowed && allowed() && current() && !loadFailed && overview?.canEdit == true && slot.readable
    }
    func act(_ action: Action) {
        guard canBrowse, interactionAllowed, allowed(), current(), !loadFailed,
              let state = overview, let target = state.slots.first(where: { $0.slot == action.slot }) else { return }
        let permitted: Bool
        switch action {
        case .activate: permitted = state.canActivate && target.availability == .occupied
        case .write: permitted = state.canEdit && target.readable
        case .clear: permitted = state.canEdit && target.availability == .occupied
        }
        guard permitted, busy(true) else { return }
        feedback()
        pending = action
        let ticket = reports.begin(.operation)
        task = Task { [self] in
            defer { pending = nil; _ = busy(false); task = nil }
            let journal = await Task.detached { PictureControlReportJournal(kind: .operation) }.value
            #if DEBUG
            let log: (@Sendable (String) -> Void)? = journal.append
            #else
            let log: (@Sendable (String) -> Void)? = nil
            #endif
            var operationFailed = false
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            await journal.appendAsync("Picture Control slots v6 \(Date()) app=\(version)(\(build)) movie=\(movie) target=C\(action.slot - 200)")
            do {
                let operation: PictureControlChange
                switch action {
                case .activate: operation = .activate; await journal.appendAsync("action=activate")
                case .clear: operation = .clear; await journal.appendAsync("action=clear")
                case .write(_, let choice):
                    let file: NikonPictureControlFile
                    switch choice {
                    case .builtIn(let preset): file = try await Task.detached { try preset.read() }.value
                    case .document(let item): file = try await folders.read(item)
                    }
                    try Task.checkCancellation()
                    await journal.appendAsync("action=write preset=\(file.name) NP3=\(file.version) sha256=\(file.sha256)")
                    operation = .write(file)
                }
                try Task.checkCancellation()
                try await change(action.slot, operation, log)
                await refresh(log: log)
                if !closed { editingSlot = nil }
            } catch is CancellationError { await journal.appendAsync("UI cancelled; accepted mutation drains verification/rollback") }
            catch {
                operationFailed = true
                await journal.appendAsync("FAILED: \(error)")
                await refresh(notifyFailure: false, log: log)
                if !closed { notice(Self.message(error, slot: action.slot)) }
            }
            finishReport(ticket, journal.text)
            if journal.failed && !closed && !operationFailed { notice(AppLocalized.resource("picture_control_report_save_failed")) }
        }
    }
    func close() {
        closed = true; task?.cancel()
        if closesFolders { folders.close() }
    }
    static func message(_ error: Error, slot: Int) -> String {
        let key: String
        switch error {
        case NikonPictureControlError.presetUnsupported: key = "picture_control_camera_preset_unsupported"
        case NikonPictureControlError.movieBankUnsupported: key = "picture_control_movie_bank_unsupported"
        case is PictureControlExposureModeError: key = "picture_control_exposure_mode_required"
        case let failure as PictureControlReplacementError:
            key = failure.originalRestored ? "picture_control_failed_restored" : "picture_control_check_slot"
        case let failure as PictureControlImportFailure:
            key = switch failure {
            case .read: "picture_control_file_read_failed"
            case .invalid: "picture_control_file_invalid"
            case .flexibleColor: "picture_control_flexible_color_unsupported"
            case .unsupported: "picture_control_file_unsupported"
            case .timeout: "picture_control_read_timeout"
            }
        default: key = "picture_control_write_failed"
        }
        return String(format: AppLocalized.resource(key), slot - 200)
    }
}

/// The folder catalog/grant outlives individual popup reads, as on Android.
/// Only the popup observes scanning/file changes; the live monitor does not.
@MainActor final class PictureControlFolderLifetime: ObservableObject {
    let folders: PictureControlFolderState
    let reports = PictureControlReportHistory()
    init(defaults: UserDefaults) { folders = PictureControlFolderState(defaults: defaults) }
}

/// Owned by the monitor, never by a transient/rotated popup. A cancelled
/// picker still returns to its explicit slot; background results wait for resume.
struct PictureControlFolderPickerState {
    struct Return { let slot: Int; let folder: URL? }
    var active = false
    private(set) var didReturn = false
    private var target: Int?
    private var folder: URL?
    mutating func begin(slot: Int) {
        target = slot; folder = nil; didReturn = false; active = true
    }
    mutating func complete(folder: URL?) {
        self.folder = folder; active = false; didReturn = true
    }
    mutating func consume(resumed: Bool) -> Return? {
        guard resumed, didReturn, let target else { return nil }
        let result = Return(slot: target, folder: folder)
        self = Self()
        return result
    }
}

/// Append-only per-run debug journal; shared snapshots have a separate immutable file.
final class PictureControlReportJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var contents = ""
    private var failure = false
    private let url: URL?
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("picture_control_reports", isDirectory: true)
    }
    init(kind: PictureControlReportHistory.Kind = .operation, directory: URL = PictureControlReportJournal.directory) {
        #if DEBUG
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("PictureControl-\(Int64(Date().timeIntervalSince1970 * 1000))-\(kind.rawValue)-\(UUID().uuidString).txt")
            try Data().write(to: file, options: .withoutOverwriting); url = file
        } catch { url = nil; failure = true }
        #else
        url = nil
        #endif
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return contents }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure }
    func appendAsync(_ line: String) async { await Task.detached { self.append(line) }.value }
    func append(_ line: String) {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        contents += line + "\n"
        guard let url else { return }
        do {
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch { failure = true }
        #endif
    }
    static func latestByKind(directory: URL = PictureControlReportJournal.directory) throws -> [PictureControlReportHistory.Kind: String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("PictureControl-") && $0.pathExtension == "txt" &&
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var result: [PictureControlReportHistory.Kind: String] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let kind: PictureControlReportHistory.Kind = file.lastPathComponent.contains("-overview-") || text.hasPrefix("Picture Control overview ") ? .overview : .operation
            if result[kind] == nil { result[kind] = text }
            if result.count == 2 { break }
        }
        return result
    }
    static func share(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Shared-PictureControl-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}

/// Independent generations: a late cancelled read cannot replace a new read,
/// and reopening can never erase the latest failed mutation/rollback report.
@MainActor final class PictureControlReportHistory {
    enum Kind: String, Sendable { case overview, operation }
    struct Ticket { let kind: Kind; let generation: UInt64 }
    private var generations: [Kind: UInt64] = [:]
    private var reports: [Kind: String] = [:]
    func begin(_ kind: Kind) -> Ticket {
        let next = (generations[kind] ?? 0) &+ 1; generations[kind] = next
        return Ticket(kind: kind, generation: next)
    }
    func finish(_ ticket: Ticket, text: String) {
        guard generations[ticket.kind] == ticket.generation, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        reports[ticket.kind] = text
    }
    func restore(_ saved: [Kind: String]) {
        for (kind, text) in saved where generations[kind] == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reports[kind] = text }
    }
    var text: String { [reports[.operation], reports[.overview]].compactMap { $0 }.joined(separator: "\n\n") }
}
