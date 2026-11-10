import Combine
import CryptoKit
import Foundation

struct PhotoNp3SourceLabel: Equatable, Sendable {
    let name: String
    let category: String?
    let showCategory: Bool
    let ordinal: Int?

    func displayName(uncategorized: String) -> String {
        guard showCategory else { return name }
        return [name, category ?? uncategorized, ordinal.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func forSource(_ identifier: String, in files: [PresetFile]) -> Self? {
        guard let selected = files.first(where: { $0.identifier == identifier }) else { return nil }
        let group = Data(selected.label.lowercased().utf8)
        var total = 0, categoryCount = 0, ordinal = 0
        for file in files where Data(file.label.lowercased().utf8) == group {
            total += 1
            if file.category.presetCategoryBytes == selected.category.presetCategoryBytes { categoryCount += 1 }
            if file.identifier == identifier { ordinal = total }
        }
        return .init(name: String(decoding: (selected.label.isEmpty ? selected.name : selected.label).utf16.prefix(256), as: UTF16.self),
                     category: selected.category, showCategory: total > 1,
                     ordinal: total > 1 && categoryCount > 1 ? ordinal : nil)
    }
}

/// Android PhotoNp3Store. One shared source directory and source hints; two
/// independently committed recipes. Tiny snapshots live in preferences, not
/// a purgeable source-file cache. The iOS grant is a security-scoped bookmark;
/// each actual I/O operation owns its own balanced DirectoryAccessLease.
@MainActor
final class PhotoNp3Store {
    enum Role: String { case transfer, local }
    static let preferencesKey = "photo_np3"
    private static let changes = PassthroughSubject<Void, Never>()
    private let defaults: UserDefaults
    private var values: [String: Any] { defaults.dictionary(forKey: Self.preferencesKey) ?? [:] }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var folder: URL? { (values["folder"] as? String).flatMap(URL.init(string:)) }
    var folderBookmark: Data? { values["bookmark"] as? Data }

    func observeFolderChanges(_ onChanged: @escaping @MainActor () -> Void) -> AnyCancellable {
        var previous = values["folder"] as? String
        return Self.changes.sink { [weak self] _ in
            guard let self else { return }
            let current = self.values["folder"] as? String
            guard current != previous else { return }
            previous = current
            onChanged()
        }
    }

    private func write(_ values: [String: Any], folderChanged: Bool = false) {
        defaults.set(values, forKey: Self.preferencesKey)
        if folderChanged { Self.changes.send() }
    }

    /// Commit only after a complete scan. Replacing an existing directory clears
    /// its custom selections/hints atomically, while preserving built-in choices.
    func replaceFolder(_ url: URL, bookmark: Data) {
        var current = values
        // File URLs with/without a trailing slash identify the same directory.
        // Authorization remains in the original bookmark, not this display key.
        let identifier = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true).absoluteString
        let changed = current["folder"] as? String != identifier
        if let previous = current["folder"] as? String, previous != identifier {
            for key in Array(current.keys) where key.hasPrefix("source:") { current.removeValue(forKey: key) }
            for role in [Role.transfer, .local] {
                let key = role.rawValue
                let id = current[key + ":id"] as? String
                if id.flatMap({ Np3FilterCatalog.preset(id: $0) }) == nil { current.removeValue(forKey: key + ":id") }
                current.removeValue(forKey: key + ":uri"); current.removeValue(forKey: key + ":snapshot")
            }
        }
        current["folder"] = identifier; current["bookmark"] = bookmark
        write(current, folderChanged: changed)
    }

    func savedID(_ role: Role) -> String? { values[role.rawValue + ":id"] as? String }
    func source(_ role: Role) -> String? {
        let current = values
        guard let uri = current[role.rawValue + ":uri"] as? String, Self.validSource(uri),
              Self.sourceMatchesFolder(uri, values: current) else { return nil }
        return uri
    }

    func restore(_ role: Role) -> PhotoNp3Recipe? {
        let current = values, key = role.rawValue
        guard let id = current[key + ":id"] as? String else { return nil }
        if let builtin = Np3FilterCatalog.presets.first(where: { $0.id == id }) {
            return .init(preset: .init(id: builtin.id, name: builtin.name), parameters: .flexible(builtin.parameters))
        }
        guard PhotoNp3RecipeKind.from(id: id) != nil,
              Self.sourceMatchesFolder(current[key + ":uri"] as? String, values: current),
              let encoded = current[key + ":snapshot"] as? String,
              encoded.utf8.count <= PhotoNp3SnapshotCodec.maximumBase64Length,
              let bytes = Data(base64Encoded: encoded), let recipe = try? PhotoNp3SnapshotCodec.decode(bytes),
              recipe.preset.id == id else { return nil }
        return recipe
    }

    func isSelectionCurrent(_ role: Role, preset: PhotoFilterPreset?, source: String?) -> Bool {
        Self.isSelectionCurrent(role, preset: preset, source: source, values: values)
    }
    private static func isSelectionCurrent(_ role: Role, preset: PhotoFilterPreset?, source: String?, values: [String: Any]) -> Bool {
        guard let preset, PhotoNp3RecipeKind.from(id: preset.id) != nil else { return true }
        guard sourceMatchesFolder(source, values: values) else { return false }
        return source != nil || values["folder"] == nil ||
            values[role.rawValue + ":id"] as? String == preset.id &&
            sourceMatchesFolder(values[role.rawValue + ":uri"] as? String, values: values)
    }

    /// A late outgoing draft from another entry must not resurrect its old
    /// directory. Disabling a recipe leaves its per-source identity hints intact.
    @discardableResult
    func save(_ role: Role, recipe: PhotoNp3Recipe?, source: String?) throws -> Bool {
        let current = values
        guard Self.isSelectionCurrent(role, preset: recipe?.preset, source: source, values: current) else { return false }
        let encoded: String?
        if let recipe {
            if PhotoNp3RecipeKind.from(id: recipe.preset.id) != nil {
                encoded = try PhotoNp3SnapshotCodec.encode(recipe).base64EncodedString()
            } else {
                guard Np3FilterCatalog.preset(id: recipe.preset.id) != nil else { throw PhotoNp3SnapshotError.invalid }
                encoded = nil
            }
        } else { encoded = nil }
        var next = current
        let key = role.rawValue
        next[key + ":id"] = recipe?.preset.id
        next[key + ":snapshot"] = encoded
        next[key + ":uri"] = recipe == nil ? nil : source.flatMap {
            Self.validSource($0) && Self.sourceMatchesFolder($0, values: current) ? $0 : nil
        }
        write(next)
        return true
    }

    func rememberSource(_ uri: String, sha256: String, presetID: String) throws {
        guard Self.validSource(uri), PhotoNp3RecipeKind.isDigest(sha256),
              PhotoNp3RecipeKind.sourceDigest(presetID) == sha256 || Np3FilterCatalog.preset(id: presetID)?.catalogKey == sha256
        else { throw PhotoNp3SnapshotError.invalid }
        var next = values
        guard Self.sourceMatchesFolder(uri, values: next) else { return }
        next[Self.sourceKey(uri)] = sha256 + "|" + presetID
        write(next)
    }

    /// Capture once per directory scan, then resolve labels/IDs on the I/O
    /// worker. A hint is never authority to skip reading a selected file again.
    struct SourceHints: Sendable {
        fileprivate let values: [String: String]
        func knownPresetID(_ uri: String) -> String? {
            guard let text = values[PhotoNp3Store.sourceKey(uri)] else { return nil }
            let parts = text.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, PhotoNp3RecipeKind.isDigest(parts[0]) else { return nil }
            let id = String(parts[1]), digest = String(parts[0])
            return PhotoNp3RecipeKind.sourceDigest(id) == digest || Np3FilterCatalog.preset(id: id)?.catalogKey == digest ? id : nil
        }
        func knownPresetIDs(_ uris: [String], checkpoint: () throws -> Void = {}) rethrows -> [String: String] {
            var result: [String: String] = [:]
            for uri in uris {
                try checkpoint()
                if let id = knownPresetID(uri) { result[uri] = id }
            }
            return result
        }
    }

    func sourceHints() -> SourceHints {
        .init(values: values.reduce(into: [:]) { result, entry in
            if entry.key.hasPrefix("source:"), let text = entry.value as? String { result[entry.key] = text }
        })
    }

    func sourceLabel(_ uri: String) -> PhotoNp3SourceLabel? {
        let current = values
        guard Self.validSource(uri), Self.sourceMatchesFolder(uri, values: current),
              let encoded = current[Self.sourceKey(uri) + ":label"] as? String else { return nil }
        return Self.decodeLabel(encoded)
    }

    func rememberSourceLabel(_ uri: String, label: PhotoNp3SourceLabel) {
        var next = values
        guard Self.validSource(uri), Self.sourceMatchesFolder(uri, values: next), let encoded = Self.encodeLabel(label) else { return }
        let key = Self.sourceKey(uri) + ":label"
        guard next[key] as? String != encoded else { return }
        next[key] = encoded; write(next)
    }

    nonisolated private static func sourceKey(_ uri: String) -> String {
        "source:" + SHA256.hash(data: Data(uri.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func validSource(_ uri: String) -> Bool {
        (1...16384).contains(uri.utf16.count) && uri.hasPrefix("file://") && URL(string: uri)?.isFileURL == true
    }
    private static func sourceMatchesFolder(_ source: String?, values: [String: Any]) -> Bool {
        guard let folder = values["folder"] as? String, let source else { return true }
        guard validSource(source), let root = URL(string: folder), let file = URL(string: source) else { return false }
        let a = root.standardizedFileURL.pathComponents, b = file.standardizedFileURL.pathComponents
        return b.count > a.count && b.starts(with: a)
    }
    private static func encodeLabel(_ label: PhotoNp3SourceLabel) -> String? {
        guard (1...256).contains(label.name.utf16.count), (label.category?.utf16.count ?? 0) <= 1024,
              label.ordinal == nil || (label.showCategory && (1...Int(Int32.max)).contains(label.ordinal!)) else { return nil }
        return ["1", Data(label.name.utf8).base64EncodedString(), label.category.map { Data($0.utf8).base64EncodedString() } ?? "-",
                label.showCategory ? "1" : "0", String(label.ordinal ?? 0)].joined(separator: "|")
    }
    private static func decodeLabel(_ encoded: String) -> PhotoNp3SourceLabel? {
        guard encoded.utf16.count <= 8192 else { return nil }
        let p = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 5, p[0] == "1", p[3] == "0" || p[3] == "1", let ordinal = Int32(p[4]), ordinal >= 0,
              let nameBytes = Data(base64Encoded: p[1]) else { return nil }
        let category: String?
        if p[2] == "-" { category = nil }
        else {
            guard let bytes = Data(base64Encoded: p[2]) else { return nil }
            category = String(decoding: bytes, as: UTF8.self)
        }
        let result = PhotoNp3SourceLabel(name: String(decoding: nameBytes, as: UTF8.self), category: category,
            showCategory: p[3] == "1", ordinal: ordinal == 0 ? nil : Int(ordinal))
        return encodeLabel(result) == nil ? nil : result
    }
}
