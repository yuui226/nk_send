import XCTest
@testable import ZTransfer

final class RemoteCameraToolTests: XCTestCase {
    // Android RemoteCameraToolLabelTest: all four tests, plus ordering and WB.
    func testReportedNikonOptionsAcrossPhotoFallbackAndMovieProperties() {
        let expected: [UInt64: String] = [32784: "single", 32785: "auto", 32791: "pinpoint",
            32792: "wide_s", 32793: "wide_l", 32794: "wide_people", 32795: "wide_animals",
            32800: "auto_people", 32801: "auto_animals"]
        for property: UInt32 in [0x501C, 0xD05D, 0xD1F8] {
            for (value, name) in expected {
                XCTAssertEqual(RemoteCameraTool.focusArea.labelResource(property: property, value: value), "remote_af_" + name)
            }
        }
    }

    func testUnrelatedAndUnknownCodesKeepNumericFallback() {
        XCTAssertNil(RemoteCameraTool.focusArea.labelResource(property: 0xD05D, value: 2))
        XCTAssertNil(RemoteCameraTool.focusArea.labelResource(property: 0x1234, value: 32784))
        XCTAssertNil(RemoteCameraTool.focusArea.labelResource(property: 0x501C, value: 99999))
        XCTAssertNil(RemoteCameraTool.whiteBalance.labelResource(property: 0x5005, value: 99999))
    }

    func testModelSpecificPointCountsDoNotLeakToOtherBodies() {
        func label(_ model: String?, _ value: UInt64) -> String? {
            RemoteCameraTool.focusArea.labelResource(property: 0x501C, value: value, model: model)
        }
        XCTAssertEqual(label("NIKON D7100", 0x8013), "remote_af_dynamic_21")
        XCTAssertEqual(label("D850", 0x8013), "remote_af_dynamic_72")
        XCTAssertEqual(label("D7100", 2), "remote_af_dynamic_9")
        XCTAssertEqual(label("D850", 2), "remote_af_dynamic_25")
        XCTAssertNil(label("Z 8", 0x8013))
        XCTAssertNil(label(nil, 0x8012))
        XCTAssertNil(label("Z 8", 0x801C))
        XCTAssertNil(label("Z 8", 0x801D))
        XCTAssertEqual(label(" nikon z 8 ", 2), "remote_af_dynamic")
    }

    func testLegacyLiveViewRequiresCorrectPropertyAndByteType() {
        func label(_ prop: UInt32, _ type: UInt16) -> String? {
            RemoteCameraTool.focusArea.labelResource(property: prop, value: 2, model: "D850", dataType: type)
        }
        XCTAssertEqual(label(0xD05D, 2), "remote_af_normal")
        XCTAssertEqual(label(0xD05D, 1), "remote_af_normal")
        XCTAssertNil(label(0xD05D, 4))
        XCTAssertNil(label(0xD1F8, 2))
    }

    func testWhiteBalanceNamesAndRowsPreserveCameraOrderIncludingCurrentValue() {
        let expected: [UInt64: String] = [1: "manual", 2: "auto", 3: "one_push", 4: "daylight",
            5: "fluorescent", 6: "incandescent", 7: "flash", 0x8010: "cloudy", 0x8011: "shade",
            0x8012: "kelvin", 0x8013: "preset", 0x8014: "off", 0x8015: "flash", 0x8016: "natural"]
        for (value, name) in expected {
            let key = RemoteCameraTool.whiteBalance.labelResource(property: 0xD23A, value: value)
            XCTAssertEqual(key, "remote_wb_" + name)
            for language in ["en", "zh", "hant"] { XCTAssertNotNil(AndroidLocalization.byResource[key!]?[language]) }
        }
        let descriptor = RemotePropertyDescriptor(property: .whiteBalance, writable: true, current: 99, values: [4, 2, 4, 1])
        XCTAssertEqual(RemoteCameraTool.whiteBalance.orderedValues(descriptor, model: nil), [4, 2, 1, 99])
    }

    func testFocusNamesControlOrderAndUnknownCurrentRemainsVisible() {
        let descriptor = RemotePropertyDescriptor(property: .focusArea, writable: true, current: 90000,
            values: [0x8011, 0x8019, 80000, 0x8017, 0x8010, 0x8019, 2])
        XCTAssertEqual(RemoteCameraTool.focusArea.orderedValues(descriptor, model: "Z 8"),
                       [0x8017, 0x8010, 2, 0x8019, 0x8011, 80000, 90000])
        XCTAssertTrue(RemoteCameraTool.focusArea.hasTapMarker(descriptor, value: 0x8011))
        XCTAssertFalse(RemoteCameraTool.focusArea.hasTapMarker(descriptor, value: 0x8010))
        XCTAssertFalse(RemoteCameraTool.whiteBalance.hasTapMarker(descriptor, value: 0x8011))
    }
}
