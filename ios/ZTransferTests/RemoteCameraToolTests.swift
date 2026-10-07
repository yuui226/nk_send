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

    func testZ30PhotoFocusAreaShortDynamicValuesAreNamed() {
        XCTAssertEqual(RemoteCameraTool.focusArea.labelResource(property: 0xD05D, value: 2,
                                                                model: "Z 30", dataType: 2),
                       "remote_af_dynamic_s")
        XCTAssertEqual(RemoteCameraTool.focusArea.labelResource(property: 0xD05D, value: 0x8013,
                                                                model: "Z 30", dataType: 2),
                       "remote_af_dynamic_m")
        XCTAssertEqual(RemoteCameraTool.focusArea.labelResource(property: 0xD05D, value: 0x8014,
                                                                model: "Z 30", dataType: 2),
                       "remote_af_dynamic_l")
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
        XCTAssertTrue(RemoteCameraTool.focusArea.hasTapMarker(descriptor, value: 0x8010, model: "Z 8"))
        XCTAssertFalse(RemoteCameraTool.whiteBalance.hasTapMarker(descriptor, value: 0x8011))
    }

    func testFocusModeLabelsManualRulesAndDescriptorTypesMatchAndroid() {
        XCTAssertEqual(RemoteFocusMode.label(property: .focusMode, value: 1), "MF")
        XCTAssertEqual(RemoteFocusMode.label(property: .focusMode, value: 2), "AF")
        XCTAssertEqual(RemoteFocusMode.label(property: .focusMode, value: 3), "AF Macro")
        XCTAssertEqual(RemoteFocusMode.label(property: .focusMode, value: 0x8010), "AF-S")
        XCTAssertEqual(RemoteFocusMode.label(property: .focusMode, value: 0x8011), "AF-C")
        XCTAssertEqual(RemoteFocusMode.label(property: .focusMode, value: 0x8012), "AF-A")
        XCTAssertEqual(RemoteFocusMode.label(property: .focusMode, value: 0x8013), "AF-F")
        XCTAssertEqual(RemoteFocusMode.label(property: .stillFocusMode, value: 3), "MF (fixed)")
        XCTAssertEqual(RemoteFocusMode.label(property: .stillFocusMode, value: 4), "MF")
        XCTAssertEqual(RemoteFocusMode.label(property: .nikonAFMode, value: 2), "AF-A")
        XCTAssertNil(RemoteFocusMode.label(property: .nikonAFMode, value: 3))
        XCTAssertTrue(RemoteFocusMode.manual(property: .focusMode, value: 1))
        XCTAssertTrue(RemoteFocusMode.manual(property: .stillFocusMode, value: 3))
        XCTAssertTrue(RemoteFocusMode.manual(property: .stillFocusMode, value: 4))
        XCTAssertFalse(RemoteFocusMode.manual(property: .nikonAFMode, value: 2))

        XCTAssertTrue(RemoteFocusMode.validDescriptor(.init(property: .focusMode, dataType: 4,
                                                            writable: true, current: 2, values: [1, 2])))
        XCTAssertTrue(RemoteFocusMode.validDescriptor(.init(property: .stillFocusMode, dataType: 2,
                                                            writable: true, current: 1, values: [0, 1])))
        XCTAssertTrue(RemoteFocusMode.validDescriptor(.init(property: .nikonAFMode, dataType: 2,
                                                            writable: true, current: 1, values: [0, 1])))
        XCTAssertFalse(RemoteFocusMode.validDescriptor(.init(property: .focusMode, dataType: 2,
                                                             writable: true, current: 2, values: [1, 2])))
        XCTAssertFalse(RemoteFocusMode.validDescriptor(.init(property: .stillFocusMode, dataType: 4,
                                                             writable: true, current: 1, values: [0, 1])))
    }

    func testFocusCoordinateAndTapPathMappingMatchAndroid() {
        XCTAssertEqual(rcNormalizedToFocusCoordinate(-1, size: 1000), 0)
        XCTAssertEqual(rcNormalizedToFocusCoordinate(0, size: 1000), 0)
        XCTAssertEqual(rcNormalizedToFocusCoordinate(0.5, size: 1000), 500)
        XCTAssertEqual(rcNormalizedToFocusCoordinate(1, size: 1000), 999)
        XCTAssertEqual(rcNormalizedToFocusCoordinate(2, size: 1000), 999)
        XCTAssertEqual(rcNormalizedToFocusCoordinate(0.5, size: 1), 0)

        func descriptor(_ property: RemoteProperty, _ current: UInt64) -> RemotePropertyDescriptor {
            .init(property: property, writable: true, current: current, values: [current])
        }
        for value: UInt64 in [0x8011, 0x8012, 0x8020, 0x8021] {
            XCTAssertEqual(rcTapFocusPath(descriptor(.focusArea, value), model: "Z 8"), .tracking)
        }
        for value: UInt64 in [0x8010, 0x8015, 0x8017, 0x8018, 0x8019, 0x801A, 0x801B,
                              0x801E, 0x801F, 2, 0x8013, 0x8014] {
            XCTAssertEqual(rcTapFocusPath(descriptor(.focusArea, value), model: "D850"), .moveArea)
        }
        XCTAssertEqual(rcTapFocusPath(descriptor(.focusArea, 0x801C), model: "Z 8"), .unsupported)
        XCTAssertEqual(rcTapFocusPath(descriptor(.focusArea, 0x801C), model: "D850"), .unknown)
        XCTAssertEqual(rcTapFocusPath(descriptor(.liveViewFocusArea, 0), model: "D750"), .tracking)
        XCTAssertEqual(rcTapFocusPath(descriptor(.liveViewFocusArea, 1), model: "D750"), .moveArea)
        XCTAssertEqual(rcTapFocusPath(descriptor(.liveViewFocusArea, 9), model: "D750"), .unknown)
        XCTAssertEqual(rcTapFocusPath(nil, model: "Z 8"), .unknown)
        XCTAssertEqual(rcTapFocusPath(descriptor(.focusMode, 1), model: "Z 8"), .unknown)
    }
}
