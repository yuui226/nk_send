import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferRemote
#else
@testable import ZTransfer
#endif

final class RemoteExposureTests: XCTestCase {
    func testPhotoAndMoviePropertiesRemainSeparate() {
        XCTAssertEqual(RemoteExposureParameters.photoProperties,
                       [.exposureCompensation, .iso, .fNumber, .nikonShutter])
        XCTAssertEqual(RemoteExposureParameters.movieProperties,
                       [.movieExposureCompensation, .movieISO, .movieFNumber, .movieShutter])
        XCTAssertEqual(RemoteExposureParameters.compatibleProperties(for: .shutter),
                       [.nikonShutter, .exposureTimeStandard])
        XCTAssertEqual(RemoteExposureParameters.compatibleProperties(for: .iso, movie: true), [.movieISO])
    }

    func testWritableSelectionAndFormatting() {
        let readable = RemotePropertyDescriptor(property: .iso, writable: false, current: 200, values: [100, 200])
        let writable = RemotePropertyDescriptor(property: .nikonISOEx, writable: true, current: 200, values: [100, 200])
        XCTAssertEqual(RemoteExposureParameters.selectWritable([readable, writable]), writable)
        XCTAssertEqual(RemoteExposureParameters.format(.fNumber, raw: 280), "f/2.8")
        XCTAssertEqual(RemoteExposureParameters.format(.nikonShutter, raw: (1 << 16) | 250), "1/250s")
        XCTAssertEqual(RemoteExposureParameters.format(.movieExposureCompensation, raw: UInt64(bitPattern: Int64(-500))), "-0.5EV")
        XCTAssertEqual(RemoteExposureParameters.format(.exposureProgram, raw: 0x8010), "AUTO")
    }

    func testDownStepSignFollowsPhysicalValueDirection() {
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .iso, values: [100, 200, 400]), 1)
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .fNumber, values: [180, 280, 400]), -1)
    }

    func testAutoISOProbeOrderMatchesAndroid() {
        XCTAssertEqual(RemoteExposureParameters.autoISOProperties(movie: false), [.nikonAutoISO, .nikonAutoISOAlternate])
        XCTAssertEqual(RemoteExposureParameters.autoISOProperties(movie: true), [.movieAutoISO, .nikonAutoISOAlternate, .nikonAutoISO])
    }

    func testDesqueezeCyclesThroughAndroidOptions() {
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 1), 1.33, accuracy: 0.001)
        XCTAssertEqual(RemoteDisplayOptions.nextDesqueeze(after: 2), 1, accuracy: 0.001)
        XCTAssertEqual(RemoteDisplayOptions.label(for: 1), "1.0")
    }
}
