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
    }

    // All mutations are MainActor-isolated. The signal carries no preferences:
    // each live store rereads its own defaults, including isolated test suites.
    private static let sharedPreferencesChanged = PassthroughSubject<Void, Never>()
    private var sharedObservation: AnyCancellable?
    private var recipeKey: String { role.selectionKey + "_recipe" }
    private let role: Role
    @Published private(set) var folderBookmark: Data?
    @Published private(set) var selectedIdentifier: String?
    @Published private(set) var adjustments = LUTAdjustments()
    @Published private(set) var intensityPercent: Int
    @Published private(set) var favorites: Set<String>
    @Published private(set) var favoriteOrder: [String]
    private let defaults: UserDefaults
    let snapshotDirectory: URL
    private let legacySnapshotDirectory: URL?

    init(role: Role = .camera, defaults: UserDefaults = .standard, directory: URL? = nil, legacyDirectory: URL? = nil) {
        self.role = role
        self.defaults = defaults
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
        if let recipe = defaults.dictionary(forKey: recipeKey) {
            adjustments = restoredAdjustments(recipe)
            intensityPercent = restoredIntensity(recipe)
        }
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
    }

    /// An editor can be reopened after another presenter changed the same role.
    func reloadRole() {
        reloadSharedPreferences()
        let selected = defaults.string(forKey: role.selectionKey)
        if selectedIdentifier != selected { selectedIdentifier = selected }
        if let recipe = defaults.dictionary(forKey: recipeKey) {
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
    func select(_ identifier: String?) {
        if identifier == nil || identifier != selectedIdentifier { defaults.removeObject(forKey: recipeKey) }
        if selectedIdentifier != identifier { selectedIdentifier = identifier }
        defaults.set(identifier, forKey: role.selectionKey)
    }

    func setIntensity(_ value: Int) {
        let intensity = Np3FilterEngine.normalizeIntensity(value)
        if intensityPercent != intensity { intensityPercent = intensity }
        defaults.set(intensityPercent, forKey: role.intensityKey)
        if var recipe = defaults.dictionary(forKey: recipeKey) {
            recipe["intensity"] = intensityPercent
            defaults.set(recipe, forKey: recipeKey)
            if let digest = recipe["digest"] as? String {
                defaults.set(intensityPercent, forKey: "lut_adjustments_v1:\(digest):intensity")
            }
            if let source = recipe["source"] as? String {
                defaults.set(intensityPercent, forKey: "strength:\(source)")
            }
        }
    }

    /// Publish the role recipe only after its private table is safely written.
    /// Source identity remains a path/URI for the chooser; digest identifies pixels.
    @discardableResult
    func selectLUT(_ lut: CubeLUT, name: String, sourceIdentifier: String) throws -> PhotoFilterSelection {
        let prepared = try Self.prepareSelection(lut, directory: snapshotDirectory)
        return acceptSelection(prepared, name: name, sourceIdentifier: sourceIdentifier)
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

    func acceptSelection(_ prepared: PreparedSelection, name: String, sourceIdentifier: String) -> PhotoFilterSelection {
        let lut = prepared.lut
        PhotoLUTRuntime.register(lut, snapshot: snapshotDirectory.appendingPathComponent("\(lut.digest).bin"))
        let intensityKey = "lut_adjustments_v1:\(lut.digest):intensity"
        let remembered = defaults.object(forKey: intensityKey) as? Int
            ?? defaults.object(forKey: "strength:\(sourceIdentifier)") as? Int ?? 80
        intensityPercent = Np3FilterEngine.normalizeIntensity(remembered)
        defaults.set(intensityPercent, forKey: intensityKey)
        defaults.set(intensityPercent, forKey: "strength:\(sourceIdentifier)")
        defaults.set(intensityPercent, forKey: role.intensityKey)
        adjustments = Self.decodeAdjustments(defaults.dictionary(forKey: "lut_adjustments_v1:\(lut.digest)") as? [String: Int])
        let selection = PhotoFilterSelection(preset: .init(id: "cube:\(lut.digest)", name: name),
                                             intensityPercent: intensityPercent, lutAdjustments: adjustments)
        defaults.set(["digest": lut.digest, "name": name, "source": sourceIdentifier,
                      "intensity": selection.normalizedIntensityPercent,
                      "adjustments": Self.encodeAdjustments(adjustments)], forKey: recipeKey)
        selectedIdentifier = sourceIdentifier
        defaults.set(sourceIdentifier, forKey: role.selectionKey)
        Task { await pruneSnapshots() }
        return selection
    }

    var selectedName: String? { defaults.dictionary(forKey: recipeKey)?["name"] as? String }

    func restoreSelection() -> PhotoFilterSelection? {
        guard let recipe = defaults.dictionary(forKey: recipeKey),
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
        if let fields = recipe["adjustments"] as? [String: Int], fields["contrast"] != nil {
            return Self.decodeAdjustments(fields)
        }
        guard let digest = recipe["digest"] as? String else { return .init() }
        return Self.decodeAdjustments(defaults.dictionary(forKey: "lut_adjustments_v1:\(digest)") as? [String: Int])
    }

    private func restoredIntensity(_ recipe: [String: Any]) -> Int {
        let digestValue = (recipe["digest"] as? String).flatMap {
            defaults.object(forKey: "lut_adjustments_v1:\($0):intensity") as? Int
        }
        return Np3FilterEngine.normalizeIntensity(recipe["intensity"] as? Int ?? digestValue ?? 80)
    }

    func setAdjustments(_ value: LUTAdjustments) {
        let normalized = value.normalized
        if adjustments != normalized { adjustments = normalized }
        guard var recipe = defaults.dictionary(forKey: recipeKey),
              let digest = recipe["digest"] as? String else { return }
        let fields = Self.encodeAdjustments(adjustments)
        recipe["adjustments"] = fields
        defaults.set(recipe, forKey: recipeKey)
        defaults.set(fields, forKey: "lut_adjustments_v1:\(digest)")
    }

    private static func encodeAdjustments(_ value: LUTAdjustments) -> [String: Int] {
        ["contrast": value.contrast, "saturation": value.saturation,
         "highlights": value.highlights, "shadows": value.shadows]
    }

    private static func decodeAdjustments(_ fields: [String: Int]?) -> LUTAdjustments {
        LUTAdjustments(contrast: fields?["contrast"] ?? 0, saturation: fields?["saturation"] ?? 0,
                       highlights: fields?["highlights"] ?? 0, shadows: fields?["shadows"] ?? 0).normalized
    }

    func toggleFavorite(_ identifier: String) {
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
