import Foundation

enum RemoteLUTFolderFailure: Equatable { case missing, denied, read, tooMany }

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
    @Published private(set) var active: (file: RemoteLUTFile, lut: CubeLUT)?
    @Published private(set) var candidate: (file: RemoteLUTFile, lut: CubeLUT)?
    @Published private(set) var failure: String?

    private var generation: UInt64 = 0
    private var movie: Bool?
    private var available = false
    private var disposed = false
    private let preferences: RemoteLUTPreferences

    init(preferences: RemoteLUTPreferences = RemoteLUTPreferences()) { self.preferences = preferences }

    func environment(movie: Bool, available: Bool, visible: Bool) {
        self.movie = movie; self.available = available
        guard visible && available else { invalidate(); active = nil; return }
        let id = preferences.selection(movie: movie)
        if let file = files.first(where: { $0.identifier == id }) { loadingIdentifier = file.identifier }
    }

    func beginScan(_ replacingFolder: URL? = nil) {
        generation &+= 1; scanning = true; folderFailure = nil
        if let replacingFolder { folder = replacingFolder }
    }

    func scanned(_ list: [RemoteLUTFile], acquiredFolder: URL? = nil) {
        guard !disposed else { return }
        scanning = false; failure = nil; files = RemoteLUTCatalog.visibleFiles(list)
        if let acquiredFolder { folder = acquiredFolder }
        folderFailure = nil
    }

    func scanFailed(_ reason: RemoteLUTFolderFailure) {
        scanning = false; failure = String(describing: reason); folderFailure = reason
        if reason == .missing || reason == .denied { active = nil; candidate = nil }
    }

    func beginSelection(_ file: RemoteLUTFile) -> UInt64? {
        guard available, !disposed else { return nil }
        generation &+= 1; loadingIdentifier = file.identifier; candidate = nil
        return generation
    }

    func loaded(_ file: RemoteLUTFile, lut: CubeLUT, generation id: UInt64) {
        guard id == generation, !disposed else { return }
        candidate = (file, lut); loadingIdentifier = nil
    }

    func presented(generation id: UInt64) {
        guard id == generation, let candidate else { return }
        active = candidate; self.candidate = nil; loadingIdentifier = nil
        if let movie { preferences.setSelection(candidate.file.identifier, movie: movie) }
    }

    func failed(generation id: UInt64, reason: String) {
        guard id == generation, !disposed else { return }
        candidate = nil; loadingIdentifier = nil; failure = reason
        // The current LUT remains active exactly as on Android.
        _ = reason
    }

    func turnOff() {
        invalidate(); active = nil
        if let movie { preferences.setSelection(nil, movie: movie) }
    }

    func close() { disposed = true; invalidate(); active = nil; candidate = nil }

    private func invalidate() {
        generation &+= 1; scanning = false; loadingIdentifier = nil; candidate = nil
    }
}
