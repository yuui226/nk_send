import XCTest
@testable import ZTransfer

final class PhotoFilterCatalogTests: XCTestCase {
    @MainActor
    private func store(_ defaults: UserDefaults = UserDefaults(suiteName: "PhotoFilterCatalogTests")!) -> PhotoFilterCatalogStore {
        defaults.removePersistentDomain(forName: "PhotoFilterCatalogTests")
        let entries = [
            IOSPhotoFilterEntry(index: 0, filterID: "a", name: "A", category: .color, catalogKey: "a"),
            IOSPhotoFilterEntry(index: 1, filterID: "b", name: "B", category: .portrait, catalogKey: "b"),
            IOSPhotoFilterEntry(index: 2, filterID: "c", name: "C", category: .portrait, catalogKey: "c"),
        ]
        return PhotoFilterCatalogStore(entries: entries, defaults: defaults)
    }

    @MainActor func testFavoritesArePinnedInAllAndWithinCategory() {
        let store = store()
        store.toggleFavorite(store.entries[2])
        store.toggleFavorite(store.entries[0])
        XCTAssertEqual(store.visibleEntries.map(\.catalogKey), ["c", "a", "b"])
        store.category = .portrait
        XCTAssertEqual(store.visibleEntries.map(\.catalogKey), ["c", "b"])
        store.category = .favorites
        XCTAssertEqual(store.visibleEntries.map(\.catalogKey), ["c", "a"])
    }

    @MainActor func testFavoriteOrderAndIntensitySurviveReload() {
        let defaults = UserDefaults(suiteName: "PhotoFilterCatalogTests")!
        let first = store(defaults)
        first.toggleFavorite(first.entries[1])
        first.setIntensity(81, for: first.entries[1])
        let second = PhotoFilterCatalogStore(entries: first.entries, defaults: defaults)
        XCTAssertEqual(second.favoriteKeys, ["b"])
        XCTAssertEqual(second.intensity(for: second.entries[1]), 82)
    }
}
