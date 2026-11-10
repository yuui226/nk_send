import Combine
import Foundation

@MainActor
final class PhotoLUTStore: ObservableObject {
    enum Role {
        case camera, local

        // Keep the pre-existing camera keys; local recipes never inherit them.
        fileprivate var selectionKey: String {
            self == .camera ? "photo_lut_selected" : "photo_lut_local_selected"
        }
        fileprivate var intensityKey: String {
            self == .camera ? "photo_lut_intensity" : "photo_lut_local_intensity"
        }
        fileprivate var memoryRole: String { self == .camera ? "transfer" : "local" }
    }

    // All mutations are MainActor-isolated. The signal carries no preferences:
    // each live store rereads its own defaults, including isolated test suites.
    private static let sharedPreferencesChanged = PassthroughSubject<Void, Never>()
    private static let folderKey = "photo_lut_folder_identity"
    private static let folderRevisionKey = "photo_lut_folder_revision"
    let folderChanges = PassthroughSubject<Void, Never>()
    private var observedFolderRevision = 0
    var folderRevision: Int { defaults.integer(forKey: Self.folderRevisionKey) }
    private var sharedObservation: AnyCancellable?
    private var recipeKey: String { role.selectionKey + "_recipe" }
    private let role: Role
    private let savesOnCommit: Bool
    private var draftRecipe: [String: Any]?
    private var recipe: [String: Any]? {
        get { savesOnCommit ? draftRecipe : defaults.dictionary(forKey: recipeKey) }
        set {
            draftRecipe = newValue
            if !savesOnCommit { defaults.set(newValue, forKey: recipeKey) }
        }
    }
    // A transfer draft is not yet retained by saved preferences. Keep its
    // snapshot alive through cleanup until it is committed or discarded.
    private var recipeOwner: PhotoLUTSnapshotOwner?
    @Published private(set) var folderBookmark: Data?
    @Published private(set) var selectedIdentifier: String?
    /// Restored once per presentation, not by filesystem checks on each draw.
    /// Android's controls require a recipe, rather than only a saved source URI.
    @Published private(set) var hasSelection = false
    @Published private(set) var adjustments = LUTAdjustments()
    @Published private(set) var intensityPercent: Int
    @Published private(set) var favorites: Set<String>
    @Published private(set) var favoriteOrder: [String]
    private let defaults: UserDefaults
    let snapshotDirectory: URL
    private let legacySnapshotDirectory: URL?

    init(role: Role = .camera, defaults: UserDefaults = .standard, directory: URL? = nil,
         legacyDirectory: URL? = nil, savesOnCommit: Bool = false) {
        self.role = role
        self.defaults = defaults
        observedFolderRevision = defaults.integer(forKey: Self.folderRevisionKey)
        self.savesOnCommit = savesOnCommit
        draftRecipe = defaults.dictionary(forKey: role.selectionKey + "_recipe")
        folderBookmark = defaults.data(forKey: "photo_lut_folder_bookmark")
        selectedIdentifier = defaults.string(forKey: role.selectionKey)
        intensityPercent = Np3FilterEngine.normalizeIntensity(defaults.object(forKey: role.intensityKey) as? Int ?? 80)
        let savedFavorites = Set(defaults.stringArray(forKey: "photo_lut_favorites") ?? [])
        favorites = savedFavorites
        favoriteOrder = defaults.stringArray(forKey: "photo_lut_favorite_order") ?? Array(savedFavorites)
        snapshotDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-lut-snapshots", isDirectory: true)
        legacySnapshotDirectory = legacyDirectory ?? (directory == nil
            ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-lut-snapshots", isDirectory: true)
            : nil)
        if let recipe {
            adjustments = restoredAdjustments(recipe)
            intensityPercent = restoredIntensity(recipe)
        }
        hasSelection = restoreSelection() != nil
        sharedObservation = Self.sharedPreferencesChanged.sink { [weak self] in
            self?.reloadSharedPreferences()
        }
    }

    private func reloadSharedPreferences() {
        let bookmark = defaults.data(forKey: "photo_lut_folder_bookmark")
        let savedFavorites = Set(defaults.stringArray(forKey: "photo_lut_favorites") ?? [])
        let savedOrder = defaults.stringArray(forKey: "photo_lut_favorite_order") ?? Array(savedFavorites)
        if folderBookmark != bookmark { folderBookmark = bookmark }
        if favorites != savedFavorites { favorites = savedFavorites }
        if favoriteOrder != savedOrder { favoriteOrder = savedOrder }
        let revision = folderRevision
        if observedFolderRevision != revision {
            observedFolderRevision = revision
            draftRecipe = nil; recipeOwner = nil
            if selectedIdentifier != nil { selectedIdentifier = nil }
            if hasSelection { hasSelection = false }
            if intensityPercent != 80 { intensityPercent = 80 }
            if adjustments != .init() { adjustments = .init() }
            folderChanges.send()
        }
    }

    /// An editor can be reopened after another presenter changed the same role.
    func reloadRole() {
        reloadSharedPreferences()
        recipe = defaults.dictionary(forKey: recipeKey)
        recipeOwner = nil
        let available = restoreSelection() != nil
        if hasSelection != available { hasSelection = available }
        let selected = defaults.string(forKey: role.selectionKey)
        if selectedIdentifier != selected { selectedIdentifier = selected }
        if let recipe {
            let intensity = restoredIntensity(recipe), restored = restoredAdjustments(recipe)
            if intensityPercent != intensity { intensityPercent = intensity }
            if adjustments != restored { adjustments = restored }
        } else {
            let intensity = Np3FilterEngine.normalizeIntensity(defaults.object(forKey: role.intensityKey) as? Int ?? 80)
            if intensityPercent != intensity { intensityPercent = intensity }
            if adjustments != .init() { adjustments = .init() }
        }
    }

    func setFolderBookmark(_ data: Data?) {
        defaults.set(data, forKey: "photo_lut_folder_bookmark")
        Self.sharedPreferencesChanged.send()
    }

    /// A completed replacement invalidates both roles before publishing the new
    /// folder. Merely renewing its bookmark must not clear parameters or drafts.
    func acceptFolder(_ prepared: RemoteLUTFolderAccess.PreparedFolder, replacing: Bool, previous: URL?) {
        let next = prepared.root?.standardizedFileURL.path
        let old = defaults.string(forKey: Self.folderKey) ?? previous?.standardizedFileURL.path
        if replacing, let next, old != next {
            for key in defaults.dictionaryRepresentation().keys where
                key.hasPrefix("lut_adjustments_v1:") || key.hasPrefix("lut_adjustments_v2:") ||
                key.hasPrefix("strength:") || ["photo_lut_selected", "photo_lut_local_selected",
                    "photo_lut_selected_recipe", "photo_lut_local_selected_recipe",
                    "photo_lut_intensity", "photo_lut_local_intensity",
                    "photo_lut_favorites", "photo_lut_favorite_order"].contains(key) {
                defaults.removeObject(forKey: key)
            }
            defaults.set(folderRevision &+ 1, forKey: Self.folderRevisionKey)
        }
        if let next { defaults.set(next, forKey: Self.folderKey) }
        defaults.set(prepared.bookmark, forKey: "photo_lut_folder_bookmark")
        Self.sharedPreferencesChanged.send()
    }

    func isSourceCurrent(_ source: String?) -> Bool {
        guard let root = defaults.string(forKey: Self.folderKey), let source else { return true }
        let file: URL
        if source.hasPrefix("/") { file = URL(fileURLWithPath: source) }
        else if let url = URL(string: source), url.isFileURL { file = url }
        else { return true } // Unknown legacy identifiers cannot prove another folder.
        let a = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let b = file.standardizedFileURL.pathComponents
        return b.count > a.count && b.starts(with: a)
    }

    func canCommitSelection(_ selection: PhotoFilterSelection?) -> Bool {
        guard let selection, selection.preset.id.hasPrefix("cube:") else { return true }
        let digest = String(selection.preset.id.dropFirst(5))
        guard PhotoNp3RecipeKind.isDigest(digest), isSourceCurrent(selectedIdentifier) else { return false }
        return selectedIdentifier != nil || defaults.string(forKey: Self.folderKey) == nil ||
            defaults.dictionary(forKey: recipeKey)?["digest"] as? String == digest
    }
    func select(_ identifier: String?) {
        if identifier == nil || identifier != selectedIdentifier {
            retainSavedParameters()
            recipe = nil
            recipeOwner = nil
            if hasSelection { hasSelection = false }
        }
        if selectedIdentifier != identifier { selectedIdentifier = identifier }
        if !savesOnCommit { persistRole() }
    }

    /// SettingsScreen commits the transfer recipe on back/close. The workbench
    /// saves immediately; folder, favorites and per-LUT parameter memory do too.
    @discardableResult
    func commitDraft() -> Bool {
        guard isSourceCurrent(recipe?["source"] as? String) else { return false }
        retainSavedParameters()
        persistRole()
        recipeOwner = nil
        Task { await pruneSnapshots() }
        return true
    }

    private func persistRole() {
        defaults.set(selectedIdentifier, forKey: role.selectionKey)
        defaults.set(intensityPercent, forKey: role.intensityKey)
        defaults.set(recipe, forKey: recipeKey)
    }

    func setIntensity(_ value: Int) {
        guard isSourceCurrent(recipe?["source"] as? String) else { return }
        let intensity = Np3FilterEngine.normalizeIntensity(value)
        if intensityPercent != intensity { intensityPercent = intensity }
        if var recipe {
            if let digest = recipe["digest"] as? String, PhotoNp3RecipeKind.isDigest(digest) {
                _ = remembered(digest: digest, source: recipe["source"] as? String)
                defaults.set(intensity, forKey: memoryKey(digest) + ":intensity")
            }
            recipe["intensity"] = intensityPercent
            self.recipe = recipe
        }
        if !savesOnCommit { persistRole() }
    }

    /// Publish the role recipe only after its private table is safely written.
    /// Source identity remains a path/URI for the chooser; digest identifies pixels.
    @discardableResult
    func selectLUT(_ lut: CubeLUT, name: String, sourceIdentifier: String) throws -> PhotoFilterSelection {
        let prepared = try Self.prepareSelection(lut, directory: snapshotDirectory)
        return try acceptSelection(prepared, name: name, sourceIdentifier: sourceIdentifier)
    }

    struct PreparedSelection: Sendable {
        fileprivate let lut: CubeLUT
        fileprivate let owner: PhotoLUTSnapshotOwner
    }

    nonisolated static func prepareSelection(_ lut: CubeLUT, directory: URL,
                                            checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> PreparedSelection {
        let owner = PhotoLUTRuntime.snapshotOwner(digest: lut.digest,
            url: directory.appendingPathComponent("\(lut.digest).bin"))
        _ = try writeSnapshot(lut, directory: directory, checkCancelled: checkCancelled)
        try checkCancelled()
        return PreparedSelection(lut: lut, owner: owner)
    }

    func acceptSelection(_ prepared: PreparedSelection, name: String, sourceIdentifier: String) throws -> PhotoFilterSelection {
        guard isSourceCurrent(sourceIdentifier) else { throw CancellationError() }
        let lut = prepared.lut
        retainSavedParameters()
        PhotoLUTRuntime.register(lut, snapshot: snapshotDirectory.appendingPathComponent("\(lut.digest).bin"))
        let memory = remembered(digest: lut.digest, source: sourceIdentifier)
        intensityPercent = memory.intensity
        adjustments = memory.adjustments
        let selection = PhotoFilterSelection(preset: .init(id: "cube:\(lut.digest)", name: name),
                                             intensityPercent: intensityPercent, lutAdjustments: adjustments)
        recipe = ["digest": lut.digest, "name": name, "source": sourceIdentifier,
                  "intensity": selection.normalizedIntensityPercent,
                  "adjustments": Self.encodeAdjustments(adjustments)]
        recipeOwner = savesOnCommit ? prepared.owner : nil
        if !hasSelection { hasSelection = true }
        selectedIdentifier = sourceIdentifier
        if !savesOnCommit { persistRole() }
        Task { await pruneSnapshots() }
        return selection
    }

    var selectedName: String? { recipe?["name"] as? String }

    func restoreSelection() -> PhotoFilterSelection? {
        guard let recipe,
              isSourceCurrent(recipe["source"] as? String),
              let digest = recipe["digest"] as? String,
              let name = recipe["name"] as? String,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let url = snapshotDirectory.appendingPathComponent("\(digest).bin")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { return nil }
            // Android PhotoLutStore.restore checks file metadata only. Decode on
            // the render worker; a corrupt snapshot must fail there, not block UI.
            PhotoLUTRuntime.registerSnapshot(digest: digest, url: url)
        } else {
            guard let legacy = legacySnapshotDirectory?.appendingPathComponent("\(digest).bin"),
                  FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            PhotoLUTRuntime.registerSnapshot(digest: digest, url: url, legacyURL: legacy)
        }
        return PhotoFilterSelection(preset: .init(id: "cube:\(digest)", name: name),
                                    intensityPercent: restoredIntensity(recipe),
                                    lutAdjustments: restoredAdjustments(recipe))
    }

    // Android PhotoLutStore.restore: role values win; old recipes fall back
    // to digest memory. Use the same resolution for controls and rendering.
    private func restoredAdjustments(_ recipe: [String: Any]) -> LUTAdjustments {
        guard let digest = recipe["digest"] as? String, PhotoNp3RecipeKind.isDigest(digest) else { return .init() }
        let memory = remembered(digest: digest, source: recipe["source"] as? String)
        let fields = recipe["adjustments"] as? [String: Any] ?? [:]
        return PhotoLUTParameterMemory.hasAdjustments(fields) ? PhotoLUTParameterMemory.adjustments(fields) : memory.adjustments
    }

    private func restoredIntensity(_ recipe: [String: Any]) -> Int {
        guard let digest = recipe["digest"] as? String, PhotoNp3RecipeKind.isDigest(digest) else { return 80 }
        let memory = remembered(digest: digest, source: recipe["source"] as? String)
        return Np3FilterEngine.normalizeIntensity(PhotoLUTParameterMemory.integer(recipe["intensity"]) ?? memory.intensity)
    }

    func setAdjustments(_ value: LUTAdjustments) {
        guard isSourceCurrent(recipe?["source"] as? String) else { return }
        let normalized = value.normalized
        if adjustments != normalized { adjustments = normalized }
        guard var recipe,
              let digest = recipe["digest"] as? String, PhotoNp3RecipeKind.isDigest(digest) else { return }
        _ = remembered(digest: digest, source: nil, includeIntensity: false)
        let fields = Self.encodeAdjustments(adjustments)
        recipe["adjustments"] = fields
        self.recipe = recipe
        if !savesOnCommit { persistRole() }
        defaults.set(fields, forKey: memoryKey(digest))
    }

    private static func encodeAdjustments(_ value: LUTAdjustments) -> [String: Int] {
        ["contrast": value.contrast, "saturation": value.saturation,
         "highlights": value.highlights, "shadows": value.shadows]
    }

    private func memoryKey(_ digest: String) -> String {
        PhotoLUTParameterMemory.key(role: role.memoryRole, digest: digest)
    }

    private func remembered(digest: String, source: String?, includeIntensity: Bool = true) -> PhotoLUTParameterMemory {
        guard isSourceCurrent(source) else { return .init(intensity: 80, adjustments: .init()) }
        let key = memoryKey(digest), legacy = "lut_adjustments_v1:\(digest)"
        let applied = defaults.dictionary(forKey: recipeKey)
        let uri = source ?? (applied?["digest"] as? String == digest ? applied?["source"] as? String : nil)
        // Read only this file's keys, not the entire application defaults on every detent.
        var values: [String: Any] = [:]
        for name in [key, key + ":intensity", legacy, legacy + ":intensity"] + (uri.map { ["strength:" + $0] } ?? []) {
            values[name] = defaults.object(forKey: name)
        }
        let result = PhotoLUTParameterMemory.resolve(values: values, role: role.memoryRole,
            digest: digest, source: source, applied: applied)
        if includeIntensity && values[key + ":intensity"] == nil {
            defaults.set(result.intensity, forKey: key + ":intensity")
        }
        if !PhotoLUTParameterMemory.hasAdjustments(values[key] as? [String: Any] ?? [:]) {
            defaults.set(Self.encodeAdjustments(result.adjustments), forKey: key)
        }
        return result
    }

    private func retainSavedParameters() {
        guard let saved = defaults.dictionary(forKey: recipeKey),
              isSourceCurrent(saved["source"] as? String),
              let digest = saved["digest"] as? String, PhotoNp3RecipeKind.isDigest(digest) else { return }
        _ = remembered(digest: digest, source: saved["source"] as? String)
    }

    func toggleFavorite(_ identifier: String) {
        guard isSourceCurrent(identifier) else { return }
        reloadSharedPreferences()
        if !favorites.insert(identifier).inserted { favorites.remove(identifier); favoriteOrder.removeAll { $0 == identifier } }
        else { favoriteOrder.append(identifier) }
        defaults.set(Array(favorites), forKey: "photo_lut_favorites"); defaults.set(favoriteOrder, forKey: "photo_lut_favorite_order")
        Self.sharedPreferencesChanged.send()
    }

    func ordered(_ files: [RemoteLUTFile]) -> [RemoteLUTFile] {
        // PhotoLutEditor.kt uses a stable partition: favorites first, while
        // preserving the catalog order within both groups (not tap order).
        files.filter { favorites.contains($0.identifier) } + files.filter { !favorites.contains($0.identifier) }
    }

    // UserDefaults supports concurrent reads. Read roles at deletion time rather
    // than capturing an obsolete set before this serial cleanup worker runs.
    private final class SnapshotPreferences: @unchecked Sendable {
        let defaults: UserDefaults
        let directory: URL
        init(defaults: UserDefaults, directory: URL) {
            self.defaults = defaults; self.directory = directory
        }
        func retainedURLs() -> Set<URL> {
            Set(["photo_lut_selected_recipe", "photo_lut_local_selected_recipe"].compactMap { key in
                guard let digest = defaults.dictionary(forKey: key)?["digest"] as? String,
                      digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
                return directory.appendingPathComponent("\(digest).bin")
            })
        }
    }

    nonisolated private static let cleanupQueue = DispatchQueue(label: "photo-lut-snapshot-cleanup", qos: .utility)

    func pruneSnapshots() async {
        let preferences = SnapshotPreferences(defaults: defaults, directory: snapshotDirectory)
        await withCheckedContinuation { continuation in
            Self.cleanupQueue.async {
                PhotoLUTRuntime.pruneSnapshots(in: preferences.directory, retained: preferences.retainedURLs)
                continuation.resume()
            }
        }
    }

    func saveSnapshot(_ lut: CubeLUT) throws -> URL {
        let owner = PhotoLUTRuntime.snapshotOwner(digest: lut.digest,
            url: snapshotDirectory.appendingPathComponent("\(lut.digest).bin"))
        defer { withExtendedLifetime(owner) {} }
        let url = try Self.writeSnapshot(lut, directory: snapshotDirectory)
        PhotoLUTRuntime.register(lut, snapshot: snapshotDirectory.appendingPathComponent("\(lut.digest).bin"))
        return url
    }

    nonisolated private static func writeSnapshot(_ lut: CubeLUT, directory: URL,
                                                  checkCancelled: () throws -> Void = { try Task.checkCancellation() }) throws -> URL {
        try checkCancelled()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(lut.digest).bin")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        var data = Data(); data.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian, Array.init)); data.append(contentsOf: withUnsafeBytes(of: UInt32(lut.size).bigEndian, Array.init))
        for value in [lut.domainMin.x, lut.domainMin.y, lut.domainMin.z, lut.domainMax.x, lut.domainMax.y, lut.domainMax.z] { var bits = value.bitPattern.bigEndian; data.append(contentsOf: withUnsafeBytes(of: &bits, Array.init)) }
        for (index, value) in lut.rgb.enumerated() {
            if index % 1024 == 0 { try checkCancelled() }
            var bits = value.bitPattern.bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &bits, Array.init))
        }
        try checkCancelled()
        try data.write(to: url, options: .atomic); return url
    }

    func restoreSnapshot(digest: String) -> CubeLUT? {
        guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let url = snapshotDirectory.appendingPathComponent("\(digest).bin")
        let owner = PhotoLUTRuntime.snapshotOwner(digest: digest, url: url)
        defer { withExtendedLifetime(owner) {} }
        let source: URL
        if FileManager.default.fileExists(atPath: url.path) { source = url }
        else { source = legacySnapshotDirectory?.appendingPathComponent("\(digest).bin") ?? url }
        guard let lut = Self.readSnapshot(at: source, digest: digest) else { return nil }
        if source != url {
            guard (try? Self.writeSnapshot(lut, directory: snapshotDirectory)) != nil else { return nil }
        }
        PhotoLUTRuntime.register(lut, snapshot: snapshotDirectory.appendingPathComponent("\(lut.digest).bin"))
        return lut
    }

    /// Legacy compatibility follows the same lazy worker path as normal loads.
    nonisolated static func migrateSnapshot(from legacy: URL, to destination: URL, digest: String) -> CubeLUT? {
        if FileManager.default.fileExists(atPath: destination.path) {
            return readSnapshot(at: destination, digest: digest)
        }
        guard let table = readSnapshot(at: legacy, digest: digest),
              (try? writeSnapshot(table, directory: destination.deletingLastPathComponent())) != nil else { return nil }
        return table
    }

    /// Worker-safe decoding for later cache misses; never publishes into runtime.
    nonisolated static func readSnapshot(at url: URL, digest: String) -> CubeLUT? {
        guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let maximumBytes = 32 + CubeLUTParser.maxSize * CubeLUTParser.maxSize * CubeLUTParser.maxSize * 12
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else { return nil }
        var offset = 0
        func readUInt() -> UInt32? { guard offset + 4 <= data.count else { return nil }; defer { offset += 4 }; return data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        func readFloat() -> Float? { readUInt().map { Float(bitPattern: $0) } }
        guard readUInt() == 1, let rawSize = readUInt(), (2...65).contains(Int(rawSize)) else { return nil }
        let size = Int(rawSize)
        guard data.count == 32 + size * size * size * 3 * 4 else { return nil }
        guard let a = readFloat(), let b = readFloat(), let c = readFloat(), let d = readFloat(), let e = readFloat(), let f = readFloat() else { return nil }
        guard CubeLUT.validDomain(SIMD3(a, b, c), SIMD3(d, e, f)) else { return nil }
        var values: [Float] = []; values.reserveCapacity(size * size * size * 3)
        for _ in 0..<(size * size * size * 3) { guard let value = readFloat(), value.isFinite, (-65504...65504).contains(value) else { return nil }; values.append(value) }
        return CubeLUT(size: size, domainMin: SIMD3(a,b,c), domainMax: SIMD3(d,e,f), rgb: values, digest: digest)
    }
}
