import Foundation
import ZTransferShared

/// Independent app-private options; never stores a provider URL/bookmark or camera/queue identity.
@MainActor
final class TransferPreferencesStore {
    static let key = "ztransfer.transfer.preferences"
    private let defaults: UserDefaults
    private struct Document: Codable {
        let version: Int
        let organizeByDate: Bool
        let deferStart: Bool
        // Optional v1 extension: Android's original automatic-transfer default is false.
        let autoTransferNewMedia: Bool?
    }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func read() -> NativeTransferPreferences? {
        guard let raw = defaults.object(forKey: Self.key) else { return NativeTransferPreferences.companion.defaults() }
        guard let data = raw as? Data, data.count <= 4096,
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return nil }
        return NativeTransferPreferences(organizeByDate: document.organizeByDate, deferStart: document.deferStart)
    }
    @discardableResult
    func save(_ value: NativeTransferPreferences) -> Bool {
        guard let automatic = readAutomatic() else { return false } // Preserve corrupt/future bytes across downgrades.
        let document = Document(version: 1, organizeByDate: value.organizeByDate, deferStart: value.deferStart,
                                autoTransferNewMedia: automatic)
        return write(document)
    }

    func readAutomatic() -> Bool? {
        guard let raw = defaults.object(forKey: Self.key) else { return false }
        guard let data = raw as? Data, data.count <= 4096,
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return nil }
        return document.autoTransferNewMedia ?? false
    }

    @discardableResult
    func saveAutomatic(_ enabled: Bool) -> Bool {
        guard let value = read() else { return false }
        return write(Document(version: 1, organizeByDate: value.organizeByDate, deferStart: value.deferStart,
                              autoTransferNewMedia: enabled))
    }

    /// The UI must obtain explicit confirmation. Ordinary reads/writes never erase unknown data.
    @discardableResult
    func resetAfterUserConfirmation() -> Bool {
        if let raw = defaults.object(forKey: Self.key) { defaults.set(raw, forKey: Self.key + ".recoveryBackup") }
        return write(Document(version: 1, organizeByDate: false, deferStart: false, autoTransferNewMedia: false))
    }

    private func write(_ document: Document) -> Bool {
        guard let data = try? JSONEncoder().encode(document), data.count <= 4096 else { return false }
        defaults.set(data, forKey: Self.key)
        return defaults.data(forKey: Self.key) == data // Store acknowledgement, not fsync.
    }
}

/// One app-private, versioned value. No camera IDs, credentials, bookmarks or task state.
/// MainActor serialization matches the shared UI boundary; UserDefaults handles disk scheduling.
@MainActor
final class BrowsePreferencesStore {
    static let key = "ztransfer.browse.preferences"
    private static var updateRevision: UInt64 = 0
    /// Process-local ordering for asynchronous live settings relays, not persisted user data.
    static func nextUpdateRevision() -> UInt64 { updateRevision &+= 1; return updateRevision }
    private let defaults: UserDefaults
    private struct Document: Codable {
        var version: Int
        var columns: Int32
        var collapseBursts: Bool
        var extensions: [String]?
        var protectedOnly: Bool
        var burstOnly: Bool
        var untransferredOnly: Bool
        var startDay: Int32
        var endDay: Int32
        // Optional additions to v1: existing installs restore the original 0 / false values.
        var previewRotationQuarterTurns: Int32?
        var previewHistogramEnabled: Bool?
        var tapToPreview: Bool?
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func resetAfterUserConfirmation() -> Bool {
        if let raw = defaults.object(forKey: Self.key) { defaults.set(raw, forKey: Self.key + ".recoveryBackup") }
        defaults.removeObject(forKey: Self.key)
        return save(NativeBrowsePreferences.companion.defaults())
    }

    func read() -> NativeBrowsePreferences? {
        guard let raw = defaults.object(forKey: Self.key) else { return NativeBrowsePreferences.companion.defaults() }
        guard let data = raw as? Data, data.count <= 64 * 1024,
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return nil }
        // Normalization/date validation live in shared; slot selection is deliberately absent.
        return NativeBrowsePreferences(columns: document.columns, collapseBursts: document.collapseBursts,
            extensions: document.extensions, protectedOnly: document.protectedOnly, burstOnly: document.burstOnly,
            untransferredOnly: document.untransferredOnly, startDay: document.startDay, endDay: document.endDay,
            previewRotationQuarterTurns: document.previewRotationQuarterTurns ?? 0,
            previewHistogramEnabled: document.previewHistogramEnabled ?? false, tapToPreview: document.tapToPreview ?? false)
    }

    @discardableResult
    func save(_ value: NativeBrowsePreferences) -> Bool {
        // Preserve unknown future versions/corrupt data for diagnosis, including after a downgrade.
        guard read() != nil else { return false }
        let document = Document(version: 1, columns: value.columns, collapseBursts: value.collapseBursts,
            extensions: value.extensions, protectedOnly: value.protectedOnly, burstOnly: value.burstOnly,
            untransferredOnly: value.untransferredOnly, startDay: value.startDay, endDay: value.endDay,
            previewRotationQuarterTurns: value.previewRotationQuarterTurns, previewHistogramEnabled: value.previewHistogramEnabled, tapToPreview: value.tapToPreview)
        guard let data = try? JSONEncoder().encode(document), data.count <= 64 * 1024 else { return false }
        defaults.set(data, forKey: Self.key)
        return defaults.data(forKey: Self.key) == data // Acknowledges the defaults store, not a disk fsync.
    }
}
