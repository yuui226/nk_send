import Foundation
import Combine
import ZTransferShared

/// The iOS adapter for the shared filter catalog. It owns only presentation state and persistence;
/// filter classification, names and stable catalog identities still come from commonMain.
enum IOSPhotoFilterCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case favorites = "收藏"
    case landscape = "风景"
    case portrait = "人像"
    case monochrome = "黑白"
    case film = "胶片"
    case cinematic = "电影感"
    case color = "色彩"

    var id: String { rawValue }

    static func fromSharedTitle(_ title: String) -> IOSPhotoFilterCategory {
        allCases.first { $0.rawValue == title } ?? .color
    }
}

struct IOSPhotoFilterEntry: Identifiable, Equatable {
    let index: Int32
    let filterID: String
    let name: String
    let category: IOSPhotoFilterCategory
    let catalogKey: String

    var id: String { catalogKey }
}

/// The small value passed back to either filter-wheel host. Keeping the index and intensity
/// together prevents the picker from updating its own label while the preview still renders an
/// older preset.
struct IOSPhotoFilterSelection: Equatable, Sendable {
    let index: Int32
    let filterID: String
    let catalogKey: String
    let intensityPercent: Int
}

@MainActor
final class PhotoFilterCatalogStore: ObservableObject {
    static let favoritesKey = "ztransfer.ios.photo-filter.favorite-keys.v1"
    static let intensitiesKey = "ztransfer.ios.photo-filter.intensities.v1"

    @Published private(set) var entries: [IOSPhotoFilterEntry]
    @Published private(set) var favoriteKeys: [String]
    @Published private(set) var intensities: [String: Int]
    @Published var category: IOSPhotoFilterCategory = .all
    @Published var selectedKey: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let catalog = NativePhotoFilterCatalog.shared
        let count = Int(catalog.count())
        var loaded: [IOSPhotoFilterEntry] = []
        loaded.reserveCapacity(count)
        for rawIndex in 0..<count {
            let index = Int32(rawIndex)
            guard let filterID = catalog.id(index: index),
                  let name = catalog.name(index: index) else { continue }
            let key = catalog.catalogKey(index: index) ?? filterID
            let title = catalog.categoryTitle(index: index) ?? IOSPhotoFilterCategory.color.rawValue
            loaded.append(IOSPhotoFilterEntry(index: index, filterID: filterID, name: name,
                                              category: IOSPhotoFilterCategory.fromSharedTitle(title),
                                              catalogKey: key))
        }
        self.entries = loaded
        self.favoriteKeys = Self.restoreFavorites(defaults: defaults, validKeys: Set(loaded.map(\.catalogKey)))
        self.intensities = Self.restoreIntensities(defaults: defaults, validKeys: Set(loaded.map(\.catalogKey)))
        self.selectedKey = loaded.first?.catalogKey
    }

    /// Injectable initializer keeps sorting and persistence tests independent of the generated
    /// Kotlin framework while the product initializer above remains the single catalog source.
    init(entries: [IOSPhotoFilterEntry], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = entries
        self.favoriteKeys = Self.restoreFavorites(defaults: defaults, validKeys: Set(entries.map(\.catalogKey)))
        self.intensities = Self.restoreIntensities(defaults: defaults, validKeys: Set(entries.map(\.catalogKey)))
        self.selectedKey = entries.first?.catalogKey
    }

    var visibleEntries: [IOSPhotoFilterEntry] {
        let candidates: [IOSPhotoFilterEntry]
        switch category {
        case .all: candidates = entries
        case .favorites: candidates = entries.filter { favoriteKeys.contains($0.catalogKey) }
        default: candidates = entries.filter { $0.category == category }
        }
        let favoriteSet = Set(favoriteKeys)
        let favorites = favoriteKeys.compactMap { key in candidates.first { $0.catalogKey == key } }
        return favorites + candidates.filter { !favoriteSet.contains($0.catalogKey) }
    }

    func toggleFavorite(_ entry: IOSPhotoFilterEntry) {
        if let index = favoriteKeys.firstIndex(of: entry.catalogKey) {
            favoriteKeys.remove(at: index)
        } else {
            favoriteKeys.append(entry.catalogKey)
        }
        defaults.set(favoriteKeys, forKey: Self.favoritesKey)
    }

    func select(_ entry: IOSPhotoFilterEntry) {
        selectedKey = entry.catalogKey
    }

    func selection(for entry: IOSPhotoFilterEntry) -> IOSPhotoFilterSelection {
        select(entry)
        return IOSPhotoFilterSelection(index: entry.index, filterID: entry.filterID,
                                       catalogKey: entry.catalogKey, intensityPercent: intensity(for: entry))
    }

    func intensity(for entry: IOSPhotoFilterEntry) -> Int {
        intensities[entry.catalogKey] ?? 80
    }

    func setIntensity(_ value: Int, for entry: IOSPhotoFilterEntry) {
        let clamped = min(100, max(2, value))
        intensities[entry.catalogKey] = min(100, ((clamped + 1) / 2) * 2)
        defaults.set(intensities, forKey: Self.intensitiesKey)
    }

    private static func restoreFavorites(defaults: UserDefaults, validKeys: Set<String>) -> [String] {
        (defaults.stringArray(forKey: favoritesKey) ?? []).filter { validKeys.contains($0) }
    }

    private static func restoreIntensities(defaults: UserDefaults, validKeys: Set<String>) -> [String: Int] {
        let raw = defaults.dictionary(forKey: intensitiesKey) as? [String: Int] ?? [:]
        return raw.reduce(into: [:]) { result, item in
            guard validKeys.contains(item.key) else { return }
            let clamped = min(100, max(2, item.value))
            result[item.key] = min(100, ((clamped + 1) / 2) * 2)
        }
    }
}
