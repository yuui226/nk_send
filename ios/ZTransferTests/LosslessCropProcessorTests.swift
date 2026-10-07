import XCTest
@testable import ZTransfer

final class LosslessCropProcessorTests: XCTestCase {
    func testOutputNameMatchesAndroidConvention() {
        let source = URL(fileURLWithPath: "/tmp/IMG_0001.JPG")
        XCTAssertEqual(LosslessCropProcessor.outputURL(for: source, in: URL(fileURLWithPath: "/tmp")).lastPathComponent, "IMG_0001_crop.jpg")
    }
}
