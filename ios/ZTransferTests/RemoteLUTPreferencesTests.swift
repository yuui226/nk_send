import XCTest
@testable import ZTransfer

@MainActor
final class RemoteLUTPreferencesTests: XCTestCase {
    func testPhotoAndMovieSelectionsAreIndependentAndSameFileTogglesOff() {
        let defaults = UserDefaults(suiteName: "RemoteLUTPreferencesTests")!
        defaults.removePersistentDomain(forName: "RemoteLUTPreferencesTests")
        let prefs = RemoteLUTPreferences(defaults: defaults)
        prefs.setFolder("folder")
        prefs.toggleSelection("a.cube", movie: false)
        prefs.toggleSelection("b.cube", movie: true)
        XCTAssertEqual(prefs.folder, "folder")
        XCTAssertEqual(prefs.selection(movie: false), "a.cube")
        XCTAssertEqual(prefs.selection(movie: true), "b.cube")
        prefs.toggleSelection("a.cube", movie: false)
        XCTAssertNil(prefs.selection(movie: false))
        XCTAssertEqual(prefs.selection(movie: true), "b.cube")
    }
}
