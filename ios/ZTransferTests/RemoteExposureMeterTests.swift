import XCTest
@testable import ZTransfer

final class RemoteExposureMeterTests: XCTestCase {
    func testPropertyCodesMatchNikonProtocol() {
        XCTAssertEqual(RemoteProperty.nikonLightMeter.rawValue, 0xD10A)
        XCTAssertEqual(RemoteProperty.nikonExposureIndicate.rawValue, 0xD1B1)
    }

    func testD10AAndD1B1ConversionAndRanges() {
        XCTAssertEqual(RemoteExposureMeter.ev(property: 0xD10A, dataType: 1, writable: false, current: 12), 1)
        XCTAssertEqual(RemoteExposureMeter.ev(property: 0xD1B1, dataType: 1, writable: false, current: -3), -1)
        XCTAssertNil(RemoteExposureMeter.ev(property: 0xD10A, dataType: 1, writable: false, current: 61))
        XCTAssertNil(RemoteExposureMeter.ev(property: 0xD1B1, dataType: 1, writable: true, current: 0))
    }

    func testDecodeRequiresExactSingleSignedByteResponse() {
        XCTAssertEqual(RemoteExposureMeter.decode(property: 0xD1B1, dataType: 1, writable: false,
                                                   responseOK: true, data: Data([0xFD])), -3)
        XCTAssertNil(RemoteExposureMeter.decode(property: 0xD1B1, dataType: 1, writable: false,
                                                 responseOK: true, data: Data()))
        XCTAssertNil(RemoteExposureMeter.decode(property: 0xD1B1, dataType: 1, writable: false,
                                                 responseOK: true, data: Data([1, 2])))
    }

    func testFreshWindowIsStrictlyLessThan1500Milliseconds() {
        XCTAssertTrue(RemoteExposureMeter.isFresh(startedAt: 100, now: 1599))
        XCTAssertFalse(RemoteExposureMeter.isFresh(startedAt: 100, now: 1600))
        XCTAssertFalse(RemoteExposureMeter.isFresh(startedAt: 100, now: 99))
    }
}
