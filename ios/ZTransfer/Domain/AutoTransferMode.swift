import Foundation

/// Android 617082c3: AutoTransferMode + TransferViewModel.setAutoTransferMode.
/// Applies only when a newly discovered file is admitted, never to the catalog,
/// manual transfers or tasks that are already in the queue.
enum AutoTransferMode: String, CaseIterable, Sendable {
    case off = "OFF", all = "ALL", jpg = "JPG", raw = "RAW", video = "VIDEO"

    static let preferenceKey = "auto_transfer_mode"
    static let legacyPreferenceKey = "auto_transfer_new_media"

    func accepts(_ fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: ".") else { return false }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        switch self {
        case .off: return false
        case .all: return ["jpg", "jpeg", "nef", "mov", "mp4"].contains(ext)
        case .jpg: return ext == "jpg" || ext == "jpeg"
        case .raw: return ext == "nef"
        case .video: return ext == "mov" || ext == "mp4"
        }
    }

    static func restored(_ value: String?, legacyEnabled: Bool) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? (legacyEnabled ? .all : .off)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        restored(defaults.string(forKey: preferenceKey),
                 legacyEnabled: defaults.bool(forKey: legacyPreferenceKey))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        defaults.set(self != .off, forKey: Self.legacyPreferenceKey)
    }
}
