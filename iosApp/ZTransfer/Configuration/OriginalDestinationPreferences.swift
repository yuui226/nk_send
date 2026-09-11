import Foundation
import ZTransferShared

enum OriginalDestinationPreference: String, Codable { case sandbox, provider }

struct RestoredOriginalDestination {
    let destination: OriginalFilesDestination?
    let provider: ProviderOriginalStore?
    let selected: OriginalDestinationPreference?
    let failure: String?
    var displayName: String? = nil
}

/// Explicit target choice, separate from a grant that may only have been used for browsing/export.
/// The caller records a choice only after queue configuration commits. A failed save is reported;
/// UserDefaults acknowledgement is not an atomic transaction with the bookmark or a disk fsync.
@MainActor
final class OriginalDestinationPreferences {
    static let key = "ztransfer.original.destination"
    private let defaults: UserDefaults
    private struct Document: Codable {
        let version: Int
        let target: OriginalDestinationPreference
    }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    /// Called only after explicit sandbox confirmation and a successful queue target commit.
    func resetToSandboxAfterUserConfirmation() -> Bool {
        if let raw = defaults.object(forKey: Self.key) { defaults.set(raw, forKey: Self.key + ".recoveryBackup") }
        defaults.removeObject(forKey: Self.key)
        return save(.sandbox)
    }

    func read() -> OriginalDestinationPreference? {
        guard let raw = defaults.object(forKey: Self.key) else { return .sandbox }
        guard let data = raw as? Data, data.count <= 1024,
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return nil }
        return document.target
    }

    @discardableResult
    func save(_ target: OriginalDestinationPreference) -> Bool {
        guard read() != nil else { return false } // Do not destroy a future/corrupt document during a downgrade.
        guard let data = try? JSONEncoder().encode(Document(version: 1, target: target)), data.count <= 1024 else { return false }
        defaults.set(data, forKey: Self.key)
        return defaults.data(forKey: Self.key) == data
    }

    func restore(directory: () throws -> ScopedDirectoryStore = { try ScopedDirectoryStore.applicationStore() }) async throws -> RestoredOriginalDestination {
        try Task.checkCancellation()
        let selected = read()
        if selected == .sandbox {
            return RestoredOriginalDestination(destination: nil, provider: nil, selected: selected, failure: nil)
        }
        do {
            guard selected == .provider else {
                throw OriginalDestinationUnavailable(message: "@ztr|destination_unknown")
            }
            let store = try directory()
            // Bind this connection before it is exposed to admissions; never reuse the last connection's actor.
            let provider = ProviderOriginalStore(directory: store, selection: try await store.selection())
            try await provider.validateSelection()
            try Task.checkCancellation()
            let name = try await store.displayName()
            try Task.checkCancellation()
            return RestoredOriginalDestination(destination: provider, provider: provider, selected: selected, failure: nil, displayName: name)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation() // Cancellation aborts restoration, not a recoverable target error.
            let message = "@ztr|destination_repair"
            return RestoredOriginalDestination(destination: UnavailableOriginalDestination(message: message),
                provider: nil, selected: selected, failure: message)
        }
    }
}

private struct OriginalDestinationUnavailable: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Fail closed for every index/read/publication entry, not an empty index or a sandbox fallback.
/// Replacing it requires the same explicit, idle queue configuration as a normal destination.
private actor UnavailableOriginalDestination: OriginalFilesDestination {
    private let failure: OriginalDestinationUnavailable
    init(message: String) { failure = OriginalDestinationUnavailable(message: message) }
    func validateSelection() throws { throw failure }
    func originals(since revision: Int64, rescan: Bool) throws -> OriginalIndexUpdate { throw failure }
    func originalData(locator: String) throws -> Data { throw failure }
    func originalRawPreviewData(locator: String) throws -> Data? { throw failure }
    func originalExif(locator: String) throws -> PhotoExif? { throw failure }
    func copyOriginal(_ reference: ExistingOriginalReference, to output: SandboxTransferFile) throws -> Int64 { throw failure }
    func publish(_ saved: SavedCameraFile, originalName: String?, folder: String?) throws -> SavedCameraFile { throw failure }
}
