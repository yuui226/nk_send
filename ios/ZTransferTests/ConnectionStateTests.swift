import XCTest
@testable import ZTransfer

final class ConnectionStateTests: XCTestCase {
    func testUSBIsTheInitialConnectionMode() {
        let state = ConnectionState()
        XCTAssertEqual(state.selectedMode, .usb)
        XCTAssertEqual(state.usbPhase, .waitingForCamera)
    }

    func testConnectionModeSelectionIsStable() async {
        let model = await MainActor.run { ConnectionViewModel() }
        await MainActor.run {
            model.select(mode: .wifi)
            XCTAssertEqual(model.state.selectedMode, .wifi)
        }
    }

    func testUSBReducerKeepsDeviceAndSessionTransitionsPure() {
        let device = USBDeviceDescriptor(id: "camera", name: "Nikon", productKind: nil, transportType: "USB")
        var state = ConnectionState().applying(.deviceAdded(device))
        XCTAssertEqual(state.selectedDeviceID, "camera")
        XCTAssertEqual(state.discoveredDevices, [device])
        state = state.applying(.sessionOpened(id: "camera", token: UUID()))
        XCTAssertEqual(state.usbPhase, .connecting)
        state = state.applying(.failed(id: "camera", message: "断开"))
        XCTAssertEqual(state.usbPhase, .failed("断开"))
        state = state.applying(.deviceRemoved(id: "camera"))
        XCTAssertEqual(state.usbPhase, .waitingForCamera)
        XCTAssertNil(state.selectedDeviceID)
        XCTAssertTrue(state.discoveredDevices.isEmpty)
    }

    func testUSBPermissionDenialKeepsActionableErrorOnCard() {
        let state = ConnectionState().applying(.authorization(.denied))
        XCTAssertEqual(state.usbAuthorization, .denied)
        XCTAssertEqual(state.usbPhase, .failed("未获得 USB 权限，请重新插线并允许访问"))
        XCTAssertEqual(state.errorMessage, "未获得 USB 权限，请重新插线并允许访问")
    }

    func testUSBReattachClearsPreviousErrorAndWaitsForConnection() {
        var state = ConnectionState().applying(.authorization(.denied))
        let device = USBDeviceDescriptor(id: "camera", name: "Nikon", productKind: nil, transportType: "USB")
        state = state.applying(.deviceAdded(device))
        XCTAssertEqual(state.usbPhase, .waitingForCamera)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.selectedDeviceID, device.id)
    }

    func testConnectionCelebrationUsesAndroidTiming() {
        let beforeSuccess = ConnectionCelebrationValues(elapsedMilliseconds: 499)
        XCTAssertEqual(beforeSuccess.success, 0, accuracy: 0.0001)

        let successStart = ConnectionCelebrationValues(elapsedMilliseconds: 500)
        XCTAssertEqual(successStart.success, 0, accuracy: 0.0001)

        let heroFinished = ConnectionCelebrationValues(elapsedMilliseconds: 620)
        XCTAssertEqual(heroFinished.hero, 1, accuracy: 0.0001)

        let complete = ConnectionCelebrationValues(elapsedMilliseconds: 1_260)
        XCTAssertEqual(complete.hero, 1, accuracy: 0.0001)
        XCTAssertEqual(complete.success, 1, accuracy: 0.0001)
    }

    func testAPFailureClassificationMatchesAndroid() async {
        let refusal = await MainActor.run {
            ConnectionViewModel.wifiFailureKind(for: STAConnectionError.cameraRefused)
        }
        XCTAssertEqual(refusal, .refused)

        let timeout = await MainActor.run {
            ConnectionViewModel.wifiFailureKind(for: PTPSessionError.timeout)
        }
        XCTAssertEqual(timeout, .notFound)

        let protocolFailure = await MainActor.run {
            ConnectionViewModel.wifiFailureKind(for: PTPIPCodecError.malformedLength)
        }
        XCTAssertEqual(protocolFailure, .failed)
    }
}
