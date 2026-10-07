import XCTest
@testable import ZTransfer

final class CropPreparationTests: XCTestCase {
    func testOnlyPreviewReadAndConnectionAreRetryable() {
        XCTAssertFalse(cropPreparationCanRetry(.orientation(detail: "bad exif")))
        XCTAssertTrue(cropPreparationCanRetry(.previewRead(detail: "timeout")))
        XCTAssertTrue(cropPreparationCanRetry(.connection(detail: "offline")))
    }
}
