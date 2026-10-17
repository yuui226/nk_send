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
    @Published private(set) var pending: Action?
    @Published var editingSlot: Int?
    @Published private(set) var presets: [BuiltInPictureControl] = []
    @Published private(set) var presetsFailed = false
    @Published private(set) var report = ""
    let folders: PictureControlFolderState
    var notice: (String) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var onReport: (String) -> Void = { _ in }
    var movie = false
    private let readOverview: () async throws -> PictureControlOverview
    private let change: (Int, PictureControlChange, (@Sendable (String) -> Void)?) async throws -> Void
    private let current: () -> Bool
    private let allowed: () -> Bool
    private let busy: (Bool) -> Bool
    private var task: Task<Void, Never>?
    private var closed = false

    init(folders: PictureControlFolderState,
         current: @escaping () -> Bool, allowed: @escaping () -> Bool, busy: @escaping (Bool) -> Bool,
         readOverview: @escaping () async throws -> PictureControlOverview,
         change: @escaping (Int, PictureControlChange, (@Sendable (String) -> Void)?) async throws -> Void) {
        self.folders = folders; self.current = current; self.allowed = allowed; self.busy = busy
        self.readOverview = readOverview; self.change = change
    }
    func open() {
        guard task == nil, !closed else { return }
        loading = true
        task = Task { [self] in
            let result = await Task.detached { Result { try builtInPictureControls() } }.value
            guard !Task.isCancelled, !closed else { return }
            switch result { case .success(let entries): presets = entries; case .failure: presetsFailed = true }
            #if DEBUG
            if report.isEmpty {
                let saved = await Task.detached { (try? PictureControlReportJournal.latest()) ?? "" }.value
                guard !closed, !Task.isCancelled else { return }
                report = saved
            }
            onReport(report)
            #endif
            await refresh()
            if !closed, !Task.isCancelled, loadFailed { dismiss() }
            task = nil
        }
    }
    func refresh(notifyFailure: Bool = true) async {
        loading = true
        defer { loading = false }
        do {
            guard !closed else { throw CancellationError() }
            guard current() else { throw PTPSessionError.invalidResponse }
            let fresh = try await readOverview()
            guard current(), !closed, !Task.isCancelled else { throw CancellationError() }
            overview = fresh; loadFailed = false
        } catch is CancellationError { return }
        catch {
            guard !closed, !Task.isCancelled, current() else { return }
            loadFailed = true
        }
        if loadFailed && notifyFailure { notice(AppLocalized.resource("picture_control_slots_read_failed")) }
    }
    var canBrowse: Bool { pending == nil && !loading && !closed }
    func canEdit(_ slot: PictureControlSlotInfo) -> Bool {
        canBrowse && allowed() && current() && !loadFailed && overview?.canEdit == true && slot.readable
    }
    func act(_ action: Action) {
        guard canBrowse, allowed(), current(), !loadFailed,
              let state = overview, let target = state.slots.first(where: { $0.slot == action.slot }) else { return }
        let permitted: Bool
        switch action {
        case .activate: permitted = state.canActivate && target.availability == .occupied
        case .write: permitted = state.canEdit && target.readable
        case .clear: permitted = state.canEdit && target.availability == .occupied
        }
        guard permitted, busy(true) else { return }
        pending = action
        task = Task { [self] in
            defer { pending = nil; _ = busy(false); task = nil }
            let journal = await Task.detached { PictureControlReportJournal() }.value
            var operationFailed = false
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            journal.append("Picture Control slots v6 \(Date()) app=\(version)(\(build)) movie=\(movie) target=C\(action.slot - 200)")
            do {
                let operation: PictureControlChange
                switch action {
                case .activate: operation = .activate; journal.append("action=activate")
                case .clear: operation = .clear; journal.append("action=clear")
                case .write(_, let choice):
                    let file: NikonPictureControlFile
                    switch choice {
                    case .builtIn(let preset): file = try await Task.detached { try preset.read() }.value
                    case .document(let item): file = try await folders.read(item)
                    }
                    try Task.checkCancellation()
                    journal.append("action=write preset=\(file.name) NP3=\(file.version) sha256=\(file.sha256)")
                    operation = .write(file)
                }
                try Task.checkCancellation()
                try await change(action.slot, operation, journal.append)
                await refresh()
                if !closed { editingSlot = nil }
            } catch is CancellationError { journal.append("UI cancelled; accepted mutation drains verification/rollback") }
            catch {
                operationFailed = true
                journal.append("FAILED: \(error)")
                await refresh(notifyFailure: false)
                if !closed { notice(Self.message(error, slot: action.slot)) }
            }
            report = journal.text
            onReport(report)
            if journal.failed && !closed && !operationFailed { notice(AppLocalized.resource("picture_control_report_save_failed")) }
        }
    }
    func close() { closed = true; task?.cancel(); folders.close() }
    static func message(_ error: Error, slot: Int) -> String {
        let key: String
        switch error {
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
    init() {
        #if DEBUG
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let file = Self.directory.appendingPathComponent("PictureControl-\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).txt")
            try Data().write(to: file, options: .withoutOverwriting); url = file
        } catch { url = nil; failure = true }
        #else
        url = nil
        #endif
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return contents }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure }
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
    static func latest() throws -> String? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("PictureControl-") && $0.pathExtension == "txt" &&
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
        guard let file = files.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }
    static func share(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Shared-PictureControl-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}
