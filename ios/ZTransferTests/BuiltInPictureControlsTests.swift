import XCTest
@testable import ZTransfer

final class BuiltInPictureControlsTests: XCTestCase {
    func testActualApplicationBundleContainsTwentyVerifiedWritablePresetsInCatalogOrder() throws {
        let entries = try builtInPictureControls()
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(entries.first?.name, "Kodak Ektar Green")
        XCTAssertEqual(entries.prefix(3).map(\.name), ["Kodak Ektar Green", "Kodak-Sun-Nature", "LINKS-Nature"])
        for entry in entries {
            let file = try entry.read()
            XCTAssertEqual(file.data.count, entry.sizeBytes)
            XCTAssertEqual(file.sha256, entry.sha256)
            XCTAssertEqual(try file.encodeClassicPictureControl().count, 614)
        }
        let bad = BuiltInPictureControl(name: entries[0].name, fileName: entries[0].fileName,
                                        sizeBytes: entries[0].sizeBytes, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try bad.read())
    }
}
