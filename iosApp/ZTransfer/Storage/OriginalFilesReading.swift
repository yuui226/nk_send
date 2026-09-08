import Foundation
import ZTransferShared

/// A page binds one existing owner for BOTH its index and local preview reads.
/// This is read-only: selecting a browse source cannot redirect the camera's download queue.
protocol OriginalFilesReading: Actor {
    func originals(since revision: Int64, rescan: Bool) async throws -> OriginalIndexUpdate
    func originalData(locator: String) async throws -> Data
    func originalRawPreviewData(locator: String) async throws -> Data?
    func originalExif(locator: String) async throws -> PhotoExif?
}

extension CameraOriginalQueue: OriginalFilesReading {}
extension CameraOriginalStore: OriginalFilesReading {}

/// Frozen lookup metadata, not an escaping security-scoped URL or an authority to read it.
struct ExistingOriginalReference: Sendable, Equatable {
    let name: String
    let size: Int64
    let locator: String
}

protocol OriginalFilesReusing: OriginalFilesReading {
    func copyOriginal(_ reference: ExistingOriginalReference, to output: SandboxTransferFile) async throws -> Int64
}

extension CameraOriginalStore: OriginalFilesReusing {}
extension CameraOriginalQueue: OriginalFilesReusing {}

/// One operation owns only private export copies; no scoped provider URL escapes its reader.
actor OriginalActionCopies {
    private let source: OriginalFilesReusing
    private let root: URL
    init(source: OriginalFilesReusing, root: URL = FileManager.default.temporaryDirectory) {
        self.source = source
        self.root = root.appendingPathComponent("ZTransfer-export-" + UUID().uuidString, isDirectory: true)
    }
    func prepare(_ reference: ExistingOriginalReference) async throws -> SavedCameraFile {
        try Task.checkCancellation()
        let output = try SandboxTransferFile(directory: root, name: reference.name,
            declaredSize: reference.size, captureDate: nil)
        do {
            let count = try await source.copyOriginal(reference, to: output)
            try Task.checkCancellation()
            guard count == reference.size else { throw OriginalIndexError.incompleteMetadata }
            return try output.commit(expectedBytes: count)
        } catch { output.discard(); throw error }
    }
    /// Called only after this operation's reader/PhotoKit commit/system sheet has finished.
    func release() {
        try? FileManager.default.removeItem(at: root)
    }
}
/// Publication is optional for a queue run; platform grants and byte verification remain in its owner.
protocol OriginalFilesDestination: OriginalFilesReusing {
    func validateSelection() async throws
    func publish(_ saved: SavedCameraFile, originalName: String?, folder: String?) async throws -> SavedCameraFile
}

extension ProviderOriginalStore: OriginalFilesDestination {}

/// Commit must throw before publication or return normally after it; no fallible post-commit work.
protocol OriginalDestinationChange: Sendable {
    var destination: OriginalFilesDestination { get }
    func commit() async throws
}

struct ProviderDirectoryChange: OriginalDestinationChange {
    let provider: ProviderOriginalStore
    var destination: OriginalFilesDestination { provider }
    let displayName: String
    private let directory: ScopedDirectoryStore
    private let prepared: PreparedExportDirectorySelection

    static func prepare(_ url: URL, directory: ScopedDirectoryStore) async throws -> ProviderDirectoryChange {
        let prepared = try await directory.prepareSelection(url)
        let destination = ProviderOriginalStore(directory: directory, selection: prepared.selection)
        return ProviderDirectoryChange(provider: destination, displayName: prepared.displayName, directory: directory, prepared: prepared)
    }

    func commit() async throws { try await directory.commitSelection(prepared) }
}
