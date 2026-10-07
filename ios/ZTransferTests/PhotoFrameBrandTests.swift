import XCTest
@testable import ZTransfer

final class PhotoFrameBrandTests: XCTestCase {
    func testKnownBrandUsesLogoAndKeepsModel() {
        let identity = photoFrameBrandIdentity(make: "Nikon Corporation", model: "Z 8")
        XCTAssertEqual(identity.brand, .nikon); XCTAssertEqual(identity.remainingModel, "Z 8")
    }
    func testUnknownMakeFallsBackToText() {
        let identity = photoFrameBrandIdentity(make: "Acme", model: "X1")
        XCTAssertNil(identity.brand); XCTAssertEqual(identity.remainingModel, "Acme X1")
    }
}
