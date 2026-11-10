import Combine
import Foundation

@main struct Check {
    @MainActor static func main() throws {
        let sharedName = "native-shared-favorites-\(UUID())", localName = "native-local-favorites-\(UUID())"
        let shared = UserDefaults(suiteName: sharedName)!, local = UserDefaults(suiteName: localName)!
        defer { shared.removePersistentDomain(forName: sharedName); local.removePersistentDomain(forName: localName) }
        let a = Np3FilterCatalog.presets[0], b = Np3FilterCatalog.presets[1]
        let custom = "np3:" + String(repeating: "c", count: 64)
        let localLegacy = "\(b.catalogKey),90;\(custom);\(a.catalogKey)"
        shared.set("\(a.catalogKey),42;invalid;\(a.catalogKey);np3:bad", forKey: PhotoFilterFavorites.key)
        local.set(localLegacy, forKey: PhotoFilterFavorites.key)
        let first = SharedPhotoFilterFavorites(defaults: shared, legacyLocal: local)
        precondition(first.values == [a.catalogKey, b.catalogKey, custom])
        precondition(PhotoFilterFavorites.hasMigrated(shared))
        let second = SharedPhotoFilterFavorites(defaults: UserDefaults(suiteName: sharedName)!, legacyLocal: local)
        var events: [[String]] = []
        let observation = second.changes.dropFirst().sink { events.append($0) }
        first.toggle(b.catalogKey); second.toggle(a.catalogKey); first.removeCustom(); first.removeCustom()
        precondition(first.values.isEmpty && second.values.isEmpty && events.count == 3)
        precondition(SharedPhotoFilterFavorites(defaults: shared, legacyLocal: local).values.isEmpty)
        precondition(local.string(forKey: PhotoFilterFavorites.key) == localLegacy)
        withExtendedLifetime(observation) {}
        print("PASS: migration order, detached NP3, malformed rejection, cross-instance publication, removal and folder-clear non-resurrection")

        for malformed: Any in [1, "true", false] {
            shared.removePersistentDomain(forName: sharedName)
            shared.set(malformed, forKey: PhotoFilterFavorites.migrationKey)
            precondition(!PhotoFilterFavorites.hasMigrated(shared))
            precondition(SharedPhotoFilterFavorites(defaults: shared, legacyLocal: local).values == [b.catalogKey, custom, a.catalogKey])
        }
        print("PASS: migration flag requires a real boolean true")
        shared.removePersistentDomain(forName: sharedName); local.removePersistentDomain(forName: localName)
        shared.set(try JSONSerialization.data(withJSONObject: ["favoriteFilterIDs": [a.id]]), forKey: "photoEffectsSettings.v1")
        local.set(try JSONSerialization.data(withJSONObject: ["favoriteFilterIDs": [b.legacyID, a.id]]), forKey: "localPhotoEffectsSettings.v1")
        let migratedJSON = SharedPhotoFilterFavorites(defaults: shared, legacyLocal: local)
        precondition(migratedJSON.values == [a.catalogKey, b.catalogKey])
        migratedJSON.toggle(a.catalogKey); migratedJSON.toggle(b.catalogKey)
        precondition(SharedPhotoFilterFavorites(defaults: shared, legacyLocal: local).values.isEmpty)
        print("PASS: actual catalog normalizes original iOS JSON IDs without reimport")
        weak var released: SharedPhotoFilterFavorites?
        do { let temporary = SharedPhotoFilterFavorites(defaults: shared, legacyLocal: local); released = temporary }
        precondition(released == nil)
        print("PASS: global invalidations do not retain the store")
    }
}
