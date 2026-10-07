import Foundation

@MainActor
final class PhotoLUTStore: ObservableObject {
    @Published private(set) var folderBookmark: Data?
    @Published private(set) var selectedIdentifier: String?
    @Published private(set) var intensityPercent: Int
    @Published private(set) var favorites: Set<String>
    @Published private(set) var favoriteOrder: [String]
    private let defaults: UserDefaults
    private let snapshotDirectory: URL

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        folderBookmark = defaults.data(forKey: "photo_lut_folder_bookmark")
        selectedIdentifier = defaults.string(forKey: "photo_lut_selected")
        intensityPercent = min(max(defaults.object(forKey: "photo_lut_intensity") as? Int ?? 80, 0), 100)
        let savedFavorites = Set(defaults.stringArray(forKey: "photo_lut_favorites") ?? [])
        favorites = savedFavorites
        favoriteOrder = defaults.stringArray(forKey: "photo_lut_favorite_order") ?? Array(savedFavorites)
        snapshotDirectory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-lut-snapshots", isDirectory: true)
    }

    func setFolderBookmark(_ data: Data?) { folderBookmark = data; defaults.set(data, forKey: "photo_lut_folder_bookmark") }
    func select(_ identifier: String?) { selectedIdentifier = identifier; defaults.set(identifier, forKey: "photo_lut_selected") }
    func setIntensity(_ value: Int) { intensityPercent = min(max(value, 0), 100); defaults.set(intensityPercent, forKey: "photo_lut_intensity") }
    func toggleFavorite(_ identifier: String) {
        if !favorites.insert(identifier).inserted { favorites.remove(identifier); favoriteOrder.removeAll { $0 == identifier } }
        else { favoriteOrder.append(identifier) }
        defaults.set(Array(favorites), forKey: "photo_lut_favorites"); defaults.set(favoriteOrder, forKey: "photo_lut_favorite_order")
    }

    func ordered(_ files: [RemoteLUTFile]) -> [RemoteLUTFile] {
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.identifier, $0) })
        let pinned = favoriteOrder.compactMap { byID[$0] }
        return pinned + files.filter { !favorites.contains($0.identifier) }
    }

    func saveSnapshot(_ lut: CubeLUT) throws -> URL {
        PhotoLUTRuntime.register(lut)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let url = snapshotDirectory.appendingPathComponent("\(lut.digest).bin")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        var data = Data(); data.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian, Array.init)); data.append(contentsOf: withUnsafeBytes(of: UInt32(lut.size).bigEndian, Array.init))
        for value in [lut.domainMin.x, lut.domainMin.y, lut.domainMin.z, lut.domainMax.x, lut.domainMax.y, lut.domainMax.z] { var bits = value.bitPattern.bigEndian; data.append(contentsOf: withUnsafeBytes(of: &bits, Array.init)) }
        for value in lut.rgb { var bits = value.bitPattern.bigEndian; data.append(contentsOf: withUnsafeBytes(of: &bits, Array.init)) }
        try data.write(to: url, options: .atomic); return url
    }

    func restoreSnapshot(digest: String) -> CubeLUT? {
        guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let url = snapshotDirectory.appendingPathComponent("\(digest).bin")
        guard let data = try? Data(contentsOf: url) else { return nil }
        var offset = 0
        func readUInt() -> UInt32? { guard offset + 4 <= data.count else { return nil }; defer { offset += 4 }; return data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        func readFloat() -> Float? { readUInt().map { Float(bitPattern: $0) } }
        guard readUInt() == 1, let rawSize = readUInt(), (2...65).contains(Int(rawSize)) else { return nil }
        let size = Int(rawSize)
        guard let a = readFloat(), let b = readFloat(), let c = readFloat(), let d = readFloat(), let e = readFloat(), let f = readFloat() else { return nil }
        var values: [Float] = []; values.reserveCapacity(size * size * size * 3)
        for _ in 0..<(size * size * size * 3) { guard let value = readFloat(), value.isFinite, (-65504...65504).contains(value) else { return nil }; values.append(value) }
        let lut = CubeLUT(size: size, domainMin: SIMD3(a,b,c), domainMax: SIMD3(d,e,f), rgb: values, digest: digest)
        PhotoLUTRuntime.register(lut); return lut
    }
}
