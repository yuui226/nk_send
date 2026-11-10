import Combine
import XCTest
@testable import ZTransfer

final class PhotoFilterFavoritesCodecTests: XCTestCase {
    private let builtIns: Set<String> = ["cinema_blue", "soft_portrait", "warm_film"]
    func testMergePreservesTransferOrderAndAppendsLocalOnlyFavorites() {
        XCTAssertEqual(PhotoFilterFavorites.merge("soft_portrait;cinema_blue;soft_portrait",
            "cinema_blue;warm_film;soft_portrait;warm_film", validKeys: builtIns),
            ["soft_portrait", "cinema_blue", "warm_film"])
    }
    func testEmptySidesDoNotInventOrDiscardFavorites() {
        XCTAssertEqual(PhotoFilterFavorites.merge(nil, nil, validKeys: builtIns), [])
        XCTAssertEqual(PhotoFilterFavorites.merge("", " ", validKeys: builtIns), [])
        XCTAssertEqual(PhotoFilterFavorites.merge(nil, "cinema_blue;soft_portrait", validKeys: builtIns), ["cinema_blue", "soft_portrait"])
        XCTAssertEqual(PhotoFilterFavorites.merge("soft_portrait;cinema_blue", "", validKeys: builtIns), ["soft_portrait", "cinema_blue"])
    }
    func testLegacyStrengthSuffixesAreIgnoredAndInvalidEntriesDiscarded() {
        XCTAssertEqual(PhotoFilterFavorites.merge("cinema_blue,42;missing;np3:broken;soft_portrait,80;cinema_blue,95",
            "warm_film,60;missing,20;bad key;soft_portrait,12;np3:broken", validKeys: builtIns),
            ["cinema_blue", "soft_portrait", "warm_film"])
    }
    func testDetachedCustomKeysRemainValidAndDeduplicateAcrossRoles() {
        let a = "np3:" + String(repeating: "a", count: 64), b = "np3:" + String(repeating: "b", count: 64)
        XCTAssertEqual(PhotoFilterFavorites.merge("\(a),24;cinema_blue;\(a)",
            "\(b);\(a),90;\(b);np3:short", validKeys: builtIns), [a, "cinema_blue", b])
    }
}

@MainActor
final class SharedPhotoFilterFavoritesTests: XCTestCase {
    @MainActor private final class Fixture {
        let sharedName = "shared-filter-favorites-\(UUID())"
        let localName = "local-filter-favorites-\(UUID())"
        let shared: UserDefaults
        let local: UserDefaults
        init() {
            shared = UserDefaults(suiteName: sharedName)!
            local = UserDefaults(suiteName: localName)!
        }
        func store() -> SharedPhotoFilterFavorites {
            // Distinct UserDefaults instances deliberately model separate pages.
            SharedPhotoFilterFavorites(defaults: UserDefaults(suiteName: sharedName)!, legacyLocal: local)
        }
        func clean() {
            shared.removePersistentDomain(forName: sharedName)
            local.removePersistentDomain(forName: localName)
        }
    }
    private let a = TestPhotoFilterCatalog.presets[0]
    private let b = TestPhotoFilterCatalog.presets[1]
    private var aKey: String { PhotoEffectsSettings.filterKey(a.id) }
    private var bKey: String { PhotoEffectsSettings.filterKey(b.id) }

    func testMigrationRetainsLegacyLocalKeyAndNeverResurrectsRemovedFavorite() {
        let f = Fixture(); defer { f.clean() }
        f.shared.set(aKey + ",42", forKey: PhotoFilterFavorites.key)
        let oldLocal = bKey + ";" + aKey + ",60"
        f.local.set(oldLocal, forKey: PhotoFilterFavorites.key)
        f.shared.set("unchanged", forKey: "photo_lut_favorites")
        let first = f.store()
        XCTAssertEqual(first.values, [aKey, bKey])
        XCTAssertTrue(f.shared.bool(forKey: PhotoFilterFavorites.migrationKey))
        first.toggle(bKey)
        XCTAssertEqual(f.store().values, [aKey])
        XCTAssertEqual(f.local.string(forKey: PhotoFilterFavorites.key), oldLocal)
        XCTAssertEqual(f.shared.string(forKey: "photo_lut_favorites"), "unchanged")
    }

    func testLiveStoresPublishOneChangePerToggleAndDoNotAffectOtherSuites() {
        let f = Fixture(), other = Fixture(); defer { f.clean(); other.clean() }
        let first = f.store(), second = f.store(), unrelated = other.store()
        var changes: [[String]] = []
        let observation = second.changes.dropFirst().sink { changes.append($0) }
        first.toggle(aKey); second.toggle(bKey); first.toggle(aKey); second.toggle(aKey)
        first.toggle("invalid"); first.removeCustom()
        XCTAssertEqual(first.values, []); XCTAssertEqual(second.values, first.values)
        XCTAssertEqual(changes, [[aKey], [aKey, bKey], [bKey], [bKey, aKey], []])
        XCTAssertTrue(unrelated.values.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testOnlyBooleanTrueCompletesMigration() {
        for malformed: Any in [1, "true", false] {
            let f = Fixture(); defer { f.clean() }
            f.shared.set(malformed, forKey: PhotoFilterFavorites.migrationKey)
            f.local.set(aKey, forKey: PhotoFilterFavorites.key)
            XCTAssertEqual(f.store().values, [aKey])
            XCTAssertTrue(PhotoFilterFavorites.hasMigrated(f.shared), "Invalid marker: \(malformed)")
            let reopened = f.store()
            reopened.toggle(aKey)
            XCTAssertTrue(f.store().values.isEmpty, "Removing a migrated favorite must not import it again")
        }
    }

    func testMigrationFromOriginalIOSJSONPreservesBothOrders() throws {
        let f = Fixture(); defer { f.clean() }
        var transfer = PhotoEffectsSettings(), local = PhotoEffectsSettings()
        transfer.favoriteFilterIDs = [a.id]; local.favoriteFilterIDs = [b.id, a.id]
        f.shared.set(try JSONEncoder().encode(transfer), forKey: "photoEffectsSettings.v1")
        f.local.set(try JSONEncoder().encode(local), forKey: "localPhotoEffectsSettings.v1")
        let savedLocal = f.local.data(forKey: "localPhotoEffectsSettings.v1")
        let values = f.store()
        XCTAssertEqual(values.values, [aKey, bKey])
        XCTAssertNil(f.local.object(forKey: PhotoFilterFavorites.key))
        XCTAssertEqual(f.local.data(forKey: "localPhotoEffectsSettings.v1"), savedLocal)
        values.toggle(aKey); values.toggle(bKey)
        XCTAssertTrue(f.store().values.isEmpty)
    }

    func testFavoritesFirstInitializationDoesNotHideLegacyCameraConfiguration() throws {
        let f = Fixture(); defer { f.clean() }
        var original = PhotoEffectsSettings()
        original.photoFrameEnabled = true; original.photoFramePreset = .cinema
        original.selectTestFilter(b.id); original.favoriteFilterIDs = [aKey]
        f.shared.set(try JSONEncoder().encode(original), forKey: "photoEffectsSettings.v1")
        let favorites = f.store()
        let owner = PhotoEffectsStore(defaults: f.shared, filterFavorites: favorites)
        XCTAssertEqual(owner.settings.photoFramePreset, .cinema)
        XCTAssertTrue(owner.settings.photoFrameEnabled)
        XCTAssertEqual(owner.settings.selectedFilter?.preset.id, b.id)
        XCTAssertEqual(owner.settings.favoriteFilterIDs, [aKey])
    }

    func testBothOwnersShareOnlyFavoritesAndStaleDraftCannotOverwriteThem() throws {
        let f = Fixture(); defer { f.clean() }
        let transfer = PhotoEffectsStore(defaults: f.shared, filterFavorites: f.store())
        let local = PhotoEffectsStore(defaults: f.local, scope: .localPhotos, filterFavorites: f.store())
        var left = transfer.beginDraft(), right = local.beginDraft()
        left.selectTestFilter(a.id); left.photoFramePreset = .cinema
        left.selectedFilter?.intensityPercent = 42
        left.selectedFilter?.lutAdjustments = .init(contrast: 19)
        right.selectTestFilter(b.id); right.photoFramePreset = .mist
        right.selectedFilter?.intensityPercent = 88
        right.selectedFilter?.lutAdjustments = .init(shadows: -23)
        transfer.update(left); local.update(right)
        let stale = transfer.beginDraft()
        let transferPixels = photoEffectsPreviewPixelSettings(transfer.settings)
        let localPixels = photoEffectsPreviewPixelSettings(local.settings)
        local.toggleFilterFavorite(try XCTUnwrap(local.settings.selectedFilter))
        transfer.toggleFilterFavorite(try XCTUnwrap(transfer.settings.selectedFilter))
        XCTAssertEqual(transfer.settings.favoriteFilterIDs, [bKey, aKey])
        XCTAssertEqual(local.settings.favoriteFilterIDs, [bKey, aKey])
        transfer.persistEditorPreferences(from: stale)
        XCTAssertTrue(transfer.commitFromEditor(stale, np3Source: nil))
        local.updateFromEditor(right)
        XCTAssertEqual(transfer.settings.favoriteFilterIDs, [bKey, aKey])
        XCTAssertEqual(local.settings.favoriteFilterIDs, [bKey, aKey])
        XCTAssertEqual(photoEffectsPreviewPixelSettings(transfer.settings), transferPixels)
        XCTAssertEqual(photoEffectsPreviewPixelSettings(local.settings), localPixels)
        XCTAssertEqual(transfer.settings.filterAdjustments, left.filterAdjustments)
        XCTAssertEqual(local.settings.filterAdjustments, right.filterAdjustments)
        XCTAssertNil(f.local.object(forKey: PhotoFilterFavorites.key))
    }

    func testFolderReplacementClearsCustomFavoritesOnceWithoutResurrectionOrRecipeMutation() throws {
        let f = Fixture(); defer { f.clean() }
        let recipe = try photoNp3SnapshotFixture(), customKey = PhotoEffectsSettings.filterKey(recipe.preset.id)
        f.local.set(customKey + ";" + aKey, forKey: PhotoFilterFavorites.key)
        let first = f.store(), second = f.store(), np3 = PhotoNp3Store(defaults: f.shared)
        let root = URL(fileURLWithPath: "/shared-favorites/a/", isDirectory: true)
        np3.replaceFolder(root, bookmark: Data([1]))
        let transfer = PhotoEffectsStore(defaults: f.shared, np3Store: np3, filterFavorites: first)
        let local = PhotoEffectsStore(defaults: f.local, scope: .localPhotos, np3Store: np3, filterFavorites: second)
        var draft = transfer.beginDraft()
        XCTAssertTrue(draft.selectPhotoFilter(recipe, explicit: true))
        XCTAssertTrue(transfer.commitFromEditor(draft, np3Source: root.appendingPathComponent("a.NP3").absoluteString))
        let queued = transfer.settings
        np3.replaceFolder(root, bookmark: Data([2]))
        XCTAssertEqual(first.values, [customKey, aKey])
        np3.replaceFolder(URL(fileURLWithPath: "/shared-favorites/b/", isDirectory: true), bookmark: Data([3]))
        XCTAssertEqual(first.values, []); XCTAssertEqual(second.values, [])
        XCTAssertEqual(local.settings.favoriteFilterIDs, [])
        XCTAssertEqual(queued.selectedFilter?.np3Recipe, recipe)
        XCTAssertEqual(queued.favoriteFilterIDs, [customKey, aKey])
        XCTAssertFalse(transfer.commitFromEditor(queued, np3Source: root.appendingPathComponent("a.NP3").absoluteString))
        XCTAssertEqual(f.store().values, [])
        XCTAssertEqual(f.local.string(forKey: PhotoFilterFavorites.key), customKey + ";" + aKey)
    }

    func testObserversDoNotRetainEitherOwnerOrFavoritesStore() {
        let f = Fixture(); defer { f.clean() }
        var favorites: SharedPhotoFilterFavorites? = f.store()
        var owner: PhotoEffectsStore? = PhotoEffectsStore(defaults: f.shared, filterFavorites: favorites)
        weak var weakFavorites = favorites; weak var weakOwner = owner
        favorites = nil; owner = nil
        XCTAssertNil(weakOwner); XCTAssertNil(weakFavorites)
    }
}
