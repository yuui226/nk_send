import XCTest
@testable import ZTransfer

final class PhotoFrameCoordinateFormatTests: XCTestCase {
    func testLocationRowUsesDegreeMinuteSecondAndAltitude() {
        let metadata = PhotoFrameMetadata(make: nil, model: nil, lensModel: nil, focalLength: nil, aperture: nil, shutter: nil, iso: nil, exposureCompensation: nil, dateTime: nil, latitude: 30.25, longitude: -120.15, altitude: 520)
        XCTAssertEqual(metadata.locationRow, "30°15′00.00″N, 120°09′00.00″W  520m")
    }
}
