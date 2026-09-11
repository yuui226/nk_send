import XCTest
@testable import ZTransfer

final class PhotoEffectsPresentationTests: XCTestCase {
    @MainActor
    func testPresentationRouteOpensAndDismisses() {
        let route = PhotoEffectsPresentation()
        XCTAssertFalse(route.isPresented)
        route.present()
        XCTAssertTrue(route.isPresented)
        route.dismiss()
        XCTAssertFalse(route.isPresented)
    }
}
