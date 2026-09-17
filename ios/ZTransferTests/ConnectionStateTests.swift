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
        XCTAssertEqual(state.usbPhase, .failed("未获得相机访问权限，请到系统设置允许访问"))
        XCTAssertEqual(state.errorMessage, "未获得相机访问权限，请到系统设置允许访问")
    }

    func testUSBReattachDoesNotClearPersistentIOSPermissionDenial() {
        var state = ConnectionState().applying(.authorization(.denied))
        let device = USBDeviceDescriptor(id: "camera", name: "Nikon", productKind: nil, transportType: "USB")
        state = state.applying(.deviceAdded(device))
        XCTAssertEqual(state.usbPhase, .failed("未获得相机访问权限，请到系统设置允许访问"))
        XCTAssertEqual(state.errorMessage, "未获得相机访问权限，请到系统设置允许访问")
        XCTAssertEqual(state.selectedDeviceID, device.id)
    }

    func testUSBDetachDoesNotClearPersistentIOSPermissionDenial() {
        let device = USBDeviceDescriptor(id: "camera", name: "Nikon", productKind: nil, transportType: "USB")
        var state = ConnectionState().applying(.deviceAdded(device))
        state = state.applying(.authorization(.denied))
        state = state.applying(.deviceRemoved(id: device.id))
        XCTAssertEqual(state.usbPhase, .failed("未获得相机访问权限，请到系统设置允许访问"))
        XCTAssertEqual(state.errorMessage, "未获得相机访问权限，请到系统设置允许访问")
        XCTAssertNil(state.selectedDeviceID)
    }

    func testGrantingUSBAuthorizationAfterDenialRestoresWaitingState() {
        var state = ConnectionState().applying(.authorization(.denied))
        state = state.applying(.authorization(.authorized))
        XCTAssertEqual(state.usbAuthorization, .authorized)
        XCTAssertEqual(state.usbPhase, .waitingForCamera)
        XCTAssertNil(state.errorMessage)
    }

    func testUSBFrameworkFailureWithoutDescriptionUsesLocalizedFallback() {
        var state = ConnectionState()
        let device = USBDeviceDescriptor(id: "camera", name: "Nikon", productKind: nil, transportType: "USB")
        state = state.applying(.deviceAdded(device))
        state = state.applying(.failed(id: device.id, message: ""))
        XCTAssertEqual(state.usbPhase, .failed(AppLocalized.resource("usb_unknown_error")))
        XCTAssertEqual(state.errorMessage, AppLocalized.resource("usb_unknown_error"))
    }

    func testConnectionCelebrationUsesAndroidTiming() {
        let beforeSuccess = ConnectionCelebrationValues(elapsedMilliseconds: 619)
        XCTAssertEqual(beforeSuccess.success, 0, accuracy: 0.0001)

        let successStart = ConnectionCelebrationValues(elapsedMilliseconds: 620)
        XCTAssertEqual(successStart.success, 0, accuracy: 0.0001)

        let heroFinished = ConnectionCelebrationValues(elapsedMilliseconds: 620)
        XCTAssertEqual(heroFinished.hero, 1, accuracy: 0.0001)

        let complete = ConnectionCelebrationValues(elapsedMilliseconds: 1_380)
        XCTAssertEqual(complete.hero, 1, accuracy: 0.0001)
        XCTAssertEqual(complete.success, 1, accuracy: 0.0001)
    }

    func testRemoteEntryIntroStopsAfterSixRecordedStarts() {
        XCTAssertTrue(isRemoteEntryIntroEligible(playCount: -1))
        XCTAssertTrue(isRemoteEntryIntroEligible(playCount: 0))
        XCTAssertTrue(isRemoteEntryIntroEligible(playCount: remoteEntryIntroMaxPlays - 1))
        XCTAssertFalse(isRemoteEntryIntroEligible(playCount: remoteEntryIntroMaxPlays))
        XCTAssertFalse(isRemoteEntryIntroEligible(playCount: remoteEntryIntroMaxPlays + 1))
    }

    func testUnreadTipUsesAndroidBreathingEndpoints() {
        let start = TipAttentionValues(elapsed: 0)
        XCTAssertEqual(start.buttonScale, 1)
        XCTAssertEqual(start.dotScale, 0.72)
        XCTAssertEqual(start.dotOpacity, 0.58)
        let peak = TipAttentionValues(elapsed: 0.9)
        XCTAssertEqual(peak.buttonScale, 1.09, accuracy: 0.000001)
        XCTAssertEqual(peak.dotScale, 1.12, accuracy: 0.000001)
        XCTAssertEqual(peak.dotOpacity, 1, accuracy: 0.000001)
        XCTAssertEqual(TipAttentionValues(elapsed: 1.8), start)
        XCTAssertEqual(TipAttentionValues.read.buttonScale, 1)
        XCTAssertEqual(TipAttentionValues.read.dotOpacity, 0)
    }

    func testUnreadTipReversesTheSameCurveRatherThanStartingANewEase() {
        // At half of the outward leg, FastOutSlowIn is ~0.77556, not 0.5.
        let outward = TipAttentionValues(elapsed: 0.45)
        XCTAssertEqual(outward.buttonScale, 1.06980052, accuracy: 0.000001)
        let returning = TipAttentionValues(elapsed: 1.35)
        XCTAssertEqual(returning.buttonScale, outward.buttonScale, accuracy: 0.000001)
        XCTAssertEqual(returning.dotScale, outward.dotScale, accuracy: 0.000001)
        XCTAssertEqual(returning.dotOpacity, outward.dotOpacity, accuracy: 0.000001)
        let nextCycle = TipAttentionValues(elapsed: 2.25)
        XCTAssertEqual(nextCycle.buttonScale, outward.buttonScale, accuracy: 0.000001)
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
