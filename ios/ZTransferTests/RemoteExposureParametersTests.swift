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

extension RemoteExposureParametersTests {
    func testAngleTypesAndWraparoundMatchAndroid() throws {
        func angle(_ raw: Int64, _ type: UInt16) -> Double? {
            RemotePropertyDescriptor(property: .angleLevel, dataType: type, writable: false,
                current: UInt64(bitPattern: raw), values: []).angleLevelRoll
        }
        XCTAssertEqual(try XCTUnwrap(angle(23_514_322, 5)), -1.2, accuracy: 0.001)
        XCTAssertEqual(angle(359, 4), -1)
        XCTAssertEqual(angle(-180, 3), 180)
        XCTAssertEqual(angle(-181, 3), 179)
        XCTAssertNil(angle(90, 8))
    }

    func testBatteryUnknownAndMalformedDescriptorsAreNotPercentages() {
        for value: UInt64 in [101, 255, UInt64.max] {
            let descriptor = RemotePropertyDescriptor(property: .batteryLevel, dataType: 2,
                writable: false, current: value, values: [])
            XCTAssertNil(descriptor.batteryPercentage)
        }
        XCTAssertNil(RemotePropertyDescriptor(property: .batteryLevel, dataType: 4,
            writable: false, current: 67, values: []).batteryPercentage)
    }

    func testAutoISOBinaryCapabilitiesMatchAndroid() {
        func toggle(_ type: UInt16, _ writable: Bool, _ current: UInt64, _ values: [UInt64]) -> Bool {
            RemotePropertyDescriptor(property: .nikonAutoISO, dataType: type,
                writable: writable, current: current, values: values).isBinaryToggle
        }
        XCTAssertTrue(toggle(2, true, 0, []))
        XCTAssertTrue(toggle(2, true, 1, [1, 0]))
        XCTAssertTrue(toggle(2, true, 2, [0, 2]))
        XCTAssertFalse(toggle(2, false, 0, [0, 1]))
        XCTAssertFalse(toggle(4, true, 0, []))
        XCTAssertFalse(toggle(2, true, 2, []))
    }
}
