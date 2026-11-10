import Combine
import Foundation

/// Android SharedPhotoFilterFavorites.kt: camera order, then local-only keys.
/// Favorites never carry intensity, adjustments or an applied recipe.
enum PhotoFilterFavorites {
    static let key = "favorite_photo_filters_v1"
    static let migrationKey = "photo_filter_favorites_shared_v1"

    static func hasMigrated(_ defaults: UserDefaults) -> Bool {
        guard let value = defaults.object(forKey: migrationKey) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    static func merge(_ shared: String?, _ local: String?,
                      validKeys: Set<String> = PhotoFilterPreferences.builtInKeys) -> [String] {
        var seen = Set<String>()
        return [shared, local].flatMap { ($0 ?? "").split(separator: ";") }.compactMap { entry in
            let key = String(entry.prefix { $0 != "," })
            guard PhotoFilterPreferences.accepts(key, validKeys: validKeys), seen.insert(key).inserted else { return nil }
            return key
        }
    }
}

/// One durable favorites list across both editors, independent of their drafts.
/// Instances can use separate UserDefaults objects for the same suite. Changes
/// refresh only this small list; there is no polling or per-detent disk scan.
@MainActor
final class SharedPhotoFilterFavorites {
    private static let invalidations = PassthroughSubject<Void, Never>()
    private let defaults: UserDefaults
    private let state: CurrentValueSubject<[String], Never>
    private var observation: AnyCancellable?
    var values: [String] { state.value }
    var changes: AnyPublisher<[String], Never> { state.eraseToAnyPublisher() }

    init(defaults: UserDefaults, legacyLocal: UserDefaults) {
        self.defaults = defaults
        let migrated = PhotoFilterFavorites.hasMigrated(defaults)
        let encoded = defaults.string(forKey: PhotoFilterFavorites.key)
        let shared = migrated ? encoded : Self.legacyFavorites(defaults, snapshotKey: "photoEffectsSettings.v1")
        let local = migrated ? nil : Self.legacyFavorites(legacyLocal, snapshotKey: "localPhotoEffectsSettings.v1")
        let restored = PhotoFilterFavorites.merge(shared, local)
        state = .init(restored)
        let normalized = restored.joined(separator: ";")
        if !migrated || normalized != encoded {
            // Preserve the old local key. Future removal or folder replacement
            // must never import it again. Both writes run on the main actor.
            defaults.set(normalized, forKey: PhotoFilterFavorites.key)
            // CFPreferences can treat numeric 1 and Boolean true as equal and
            // retain the old numeric type. Force a typed replacement so the
            // strict Android migration flag cannot import old favorites again.
            if !migrated { defaults.removeObject(forKey: PhotoFilterFavorites.migrationKey) }
            defaults.set(true, forKey: PhotoFilterFavorites.migrationKey)
            Self.invalidations.send()
        }
        observation = Self.invalidations.sink { [weak self] in self?.reload() }
    }

    func toggle(_ key: String) {
        guard PhotoFilterPreferences.accepts(key) else { return }
        var next = values
        if let index = next.firstIndex(of: key) { next.remove(at: index) }
        else { next.append(key) }
        persist(next)
    }

    func removeCustom() {
        persist(values.filter { !PhotoFilterPreferences.isCustomKey($0) })
    }

    private func persist(_ next: [String]) {
        guard next != values else { return }
        defaults.set(next.joined(separator: ";"), forKey: PhotoFilterFavorites.key)
        Self.invalidations.send()
    }

    private func reload() {
        let next = PhotoFilterFavorites.merge(defaults.string(forKey: PhotoFilterFavorites.key), nil)
        if next != values { state.send(next) }
    }

    private static func legacyFavorites(_ defaults: UserDefaults, snapshotKey: String) -> String? {
        if let encoded = defaults.string(forKey: PhotoFilterFavorites.key) { return encoded }
        // Preserve upgrades from the original iOS JSON storage without loading
        // or applying either entry's rendering configuration.
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = snapshot["favoriteFilterIDs"] as? [String] else { return nil }
        return ids.map { PhotoFilterPreferences.catalogKey($0) ?? $0 }.joined(separator: ";")
    }
}
