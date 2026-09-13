import XCTest
@testable import ZTransfer

final class RemoteExposureParametersTests: XCTestCase {
    func testPhotoAndMoviePropertiesRemainSeparate() {
        XCTAssertEqual(RemoteExposureParameters.photoProperties, [.exposureCompensation, .iso, .fNumber, .nikonShutter])
        XCTAssertEqual(RemoteExposureParameters.movieProperties, [.movieExposureCompensation, .movieISO, .movieFNumber, .movieShutter])
        XCTAssertEqual(RemoteExposureParameters.compatibleProperties(for: .shutter), [.nikonShutter, .exposureTimeStandard])
        XCTAssertEqual(RemoteExposureParameters.compatibleProperties(for: .iso, movie: true), [.movieISO])
    }

    func testWritableSelectionPrefersWritableValueDomain() {
        let readable = RemotePropertyDescriptor(property: .iso, writable: false, current: 200, values: [100, 200])
        let writable = RemotePropertyDescriptor(property: .nikonISOEx, writable: true, current: 200, values: [100, 200])
        XCTAssertEqual(RemoteExposureParameters.selectWritable([readable, writable]), writable)
        XCTAssertEqual(RemoteExposureParameters.selectWritable([readable]), readable)
    }

    func testValueFormattingMatchesAndroidRemoteLab() {
        XCTAssertEqual(RemoteExposureParameters.format(.fNumber, raw: 280), "f/2.8")
        XCTAssertEqual(RemoteExposureParameters.format(.nikonShutter, raw: (1 << 16) | 250), "1/250s")
        XCTAssertEqual(RemoteExposureParameters.format(.nikonShutter, raw: (300 << 16) | 10), "30s")
        XCTAssertEqual(RemoteExposureParameters.format(.movieExposureCompensation, raw: UInt64(bitPattern: Int64(-500))), "-0.5EV")
        XCTAssertEqual(RemoteExposureParameters.format(.exposureProgram, raw: 0x8010), "AUTO")
    }
}
