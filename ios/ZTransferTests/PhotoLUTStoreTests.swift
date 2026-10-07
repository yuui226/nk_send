import XCTest
@testable import ZTransfer

@MainActor final class PhotoLUTStoreTests: XCTestCase {
    func testSelectionStrengthAndFavoritesRestoreAcrossInstances() {
        let suite = "photo-lut-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PhotoLUTStore(defaults: defaults, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        first.select("cube-a"); first.setIntensity(140); first.toggleFavorite("cube-a")
        let second = PhotoLUTStore(defaults: defaults, directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(second.selectedIdentifier, "cube-a")
        XCTAssertEqual(second.intensityPercent, 100)
        XCTAssertTrue(second.favorites.contains("cube-a"))
    }

    func testFavoriteToggleIsIdempotent() {
        let suite = "photo-lut-toggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoLUTStore(defaults: defaults)
        store.toggleFavorite("cube-a"); XCTAssertTrue(store.favorites.contains("cube-a"))
        store.toggleFavorite("cube-a"); XCTAssertFalse(store.favorites.contains("cube-a"))
    }
}
