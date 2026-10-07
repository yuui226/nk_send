import XCTest
@testable import ZTransfer

final class RemoteDispModeTests: XCTestCase {
    func testDispCyclesCameraExposureClean() {
        XCTAssertEqual(RemoteDispMode.camera.next, .exposure)
        XCTAssertEqual(RemoteDispMode.exposure.next, .clean)
        XCTAssertEqual(RemoteDispMode.clean.next, .camera)
    }

    func testDispInformationVisibility() {
        XCTAssertTrue(RemoteDispMode.camera.showsCameraInformation)
        XCTAssertTrue(RemoteDispMode.camera.showsExposureInformation)
        XCTAssertFalse(RemoteDispMode.exposure.showsCameraInformation)
        XCTAssertTrue(RemoteDispMode.exposure.showsExposureInformation)
        XCTAssertFalse(RemoteDispMode.clean.showsCameraInformation)
        XCTAssertFalse(RemoteDispMode.clean.showsExposureInformation)
    }
}
