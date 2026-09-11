import XCTest
@testable import ZTransfer

final class DesqueezeControlTests: XCTestCase {
    @MainActor
    func testControlFollowsSharedCycleAndCompactLabelPolicy() {
        let model = IOSDesqueezeControlModel()
        XCTAssertNil(model.displayLabel)
        XCTAssertFalse(model.isActive)

        model.advance()
        XCTAssertEqual(model.displayLabel, "1.3")
        XCTAssertTrue(model.isActive)
        model.advance()
        XCTAssertEqual(model.displayLabel, "1.5")
        model.setMultiplier(1.31)
        XCTAssertEqual(model.displayLabel, "1.3")
        model.setMultiplier(2.0)
        model.advance()
        XCTAssertNil(model.displayLabel)
    }
}
