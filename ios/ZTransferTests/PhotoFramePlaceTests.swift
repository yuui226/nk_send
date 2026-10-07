import XCTest
@testable import ZTransfer

final class PhotoFramePlaceTests: XCTestCase {
    func testChineseDistrictDoesNotBecomeCity() {
        XCTAssertEqual(photoFramePlace(city: "西湖区", district: "西湖区", subAdmin: "杭州市", admin: "浙江省", countryCode: "CN"), PhotoFramePlace(city: "杭州市", region: "西湖区"))
    }
    func testRejectsZeroPlaceholderButAllowsEquatorOnly() {
        XCTAssertFalse(validPhotoFrameCoordinates(0, 0)); XCTAssertTrue(validPhotoFrameCoordinates(0, 120)); XCTAssertFalse(validPhotoFrameCoordinates(91, 0))
    }
}
