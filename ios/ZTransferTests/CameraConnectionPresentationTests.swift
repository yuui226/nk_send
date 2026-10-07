import XCTest
@testable import ZTransfer

/// Android DisconnectedCameraPresentationTest.kt; protocol state remains separate.
final class CameraConnectionPresentationTests: XCTestCase {
    func testEveryDisconnectedTransportKeepsItsHintAndAction() {
        let expected: [(CameraPresentationMode, String, String, String?)] = [
            (.usb, "usb_connection_lost", "reconnect_camera_usb", nil),
            (.ap, "connection_lost", "connect_camera_wifi", "open_wifi_settings"),
            (.sta, "connection_lost", "reconnect_camera_sta", "reconnect_camera")
        ]
        for (mode, title, hint, action) in expected {
            XCTAssertEqual(mode.disconnectedTitle, title)
            XCTAssertEqual(mode.disconnectedHint, hint)
            XCTAssertEqual(mode.disconnectedAction, action)
            XCTAssertEqual(mode.canRetrySTA(connected: false), mode == .sta)
            XCTAssertFalse(mode.canRetrySTA(connected: true))
        }
    }

    func testRestorationDoesNotInventConnectedState() {
        for mode in CameraPresentationMode.allCases {
            var state = ConnectionState()
            state.rememberedPresentationMode = CameraPresentationMode(rawValue: mode.rawValue)
            state.wirelessMode = .sta
            XCTAssertEqual(state.presentationMode(transport: nil, isSTA: false), mode)
            XCTAssertEqual(state.usbPhase, .waitingForCamera)
            XCTAssertEqual(state.wifiPhase, .idle)
            XCTAssertNil(state.selectedDeviceID)
        }
    }

    func testInvalidOrAbsentHistoryFallsBackToWirelessPreference() {
        for raw in ["invalid", "", "sta"] {
            XCTAssertNil(CameraPresentationMode(rawValue: raw))
        }
        for wireless in WirelessMode.allCases {
            XCTAssertEqual(CameraPresentationMode.resolve(transport: nil, isSTA: false,
                remembered: nil, wireless: wireless), wireless == .sta ? .sta : .ap)
        }
    }

    func testActualTransportWinsHistoryAndUSBWinsStaleSTAFlag() {
        XCTAssertEqual(CameraPresentationMode.resolve(transport: .usb, isSTA: true,
            remembered: .sta, wireless: .sta), .usb)
        XCTAssertEqual(CameraPresentationMode.resolve(transport: .wifi, isSTA: false,
            remembered: .usb, wireless: .sta), .ap)
        XCTAssertEqual(CameraPresentationMode.resolve(transport: .wifi, isSTA: true,
            remembered: .usb, wireless: .ap), .sta)
    }

    func testRetryDoesNotChangePresentationBeforeSuccess() {
        var state = ConnectionState()
        state.rememberedPresentationMode = .sta
        state.wifiPhase = .reconnecting
        let mode = state.presentationMode(transport: nil, isSTA: false)
        XCTAssertEqual(mode, .sta)
        XCTAssertTrue(mode.canRetrySTA(connected: false))
        XCTAssertFalse(mode.canRetrySTA(connected: true))
    }
}
