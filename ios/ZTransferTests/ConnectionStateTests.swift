import XCTest
import Combine
@testable import ZTransfer

final class ConnectionStateTests: XCTestCase {
    @MainActor
    func testUSBPermissionRecoveryUsesAuthorizationAcrossLanguageChanges() {
        let saved = UserDefaults.standard.object(forKey: "app_language")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "app_language") }
            else { UserDefaults.standard.removeObject(forKey: "app_language") }
        }
        for (before, after) in [("zh-Hans", "en"), ("en", "zh-Hans"), ("zh-Hant", "en"), ("en", "zh-Hant")] {
            for denied in [USBAuthorizationState.denied, .restricted] {
                UserDefaults.standard.set(before, forKey: "app_language")
                let model = ConnectionViewModel()
                model.apply(.authorization(denied))
                model.apply(.deviceAdded(USBDeviceDescriptor(id: "camera", name: "Nikon", productKind: nil, transportType: "USB")))
                let original = model.state.errorMessage
                UserDefaults.standard.set(after, forKey: "app_language")
                XCTAssertNotEqual(original, AppLocalized.resource("usb_permission_required"))
                model.apply(.authorization(.authorized))
                XCTAssertEqual(model.state.usbPhase, .waitingForCamera)
                XCTAssertNil(model.state.errorMessage)
                XCTAssertEqual(model.state.selectedDeviceID, "camera")
                // This synchronous replay ends before the queued physical USB
                // open; model teardown cancels it. No camera is contacted.
            }
        }
        var unrelated = ConnectionState()
        unrelated.usbAuthorization = .authorized
        unrelated.usbPhase = .failed("protocol failed")
        unrelated.errorMessage = "protocol failed"
        unrelated = unrelated.applying(.authorization(.authorized))
        XCTAssertEqual(unrelated.usbPhase, .failed("protocol failed"))
    }

    @MainActor
    func testUSBViewModelPreservesReducerFallbackAndPermissionError() {
        let device = USBDeviceDescriptor(id: "camera", name: "Nikon", productKind: nil, transportType: "USB")
        for status in [USBAuthorizationState.notDetermined, .denied, .restricted] {
            let model = ConnectionViewModel()
            model.apply(.authorization(status))
            model.apply(.deviceAdded(device))
            for message in ["", "framework failure"] {
                model.apply(.failed(id: device.id, message: message))
                let expected = status == .notDetermined
                    ? (message.isEmpty ? AppLocalized.resource("usb_unknown_error") : message)
                    : AppLocalized.resource("usb_permission_required")
                XCTAssertEqual(model.state.usbPhase, .failed(expected))
                XCTAssertEqual(model.state.errorMessage, expected)
                model.apply(.failed(id: "another camera", message: "unrelated"))
                XCTAssertEqual(model.state.usbPhase, .failed(expected))
            }
        }
    }
    @MainActor
    func testAPRetriesKeepFailureVisibleUntilSuccess() async {
        let preferences = UserDefaults(suiteName: "sta_connection")!
        let keys = ["wireless_mode", CameraPresentationMode.preferenceKey]
        let previous = keys.map { preferences.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        let service = APReplayService()
        let model = ConnectionViewModel(wifiService: service)
        model.setGPSConnectionPaused(false)
        model.select(wirelessMode: .ap)
        var observed: [ConnectionState] = []
        let observation = model.$state.sink { observed.append($0) }
        defer { observation.cancel() }
        let failures: [WiFiFailureKind] = [.notFound, .refused, .failed]
        for index in failures.indices {
            observed.removeAll()
            await model.connectSelectedWiFi()
            XCTAssertEqual(model.state.wifiFailureKind, failures[index])
            guard case .failed = model.state.wifiPhase else { return XCTFail("Expected AP failure") }
            XCTAssertEqual(observed.contains { $0.wifiPhase == .connecting }, index == 0)
            if index > 0 {
                XCTAssertFalse(observed.contains { $0.wifiFailureKind == nil })
            }
        }
        observed.removeAll()
        await model.connectSelectedWiFi()
        XCTAssertEqual(model.state.wifiPhase, .connected)
        XCTAssertNil(model.state.wifiFailureKind)
        XCTAssertNotNil(model.cameraSession)
        XCTAssertFalse(observed.contains { $0.wifiPhase == .connecting })
        let attempts = await service.attempts
        XCTAssertEqual(attempts, 4)
    }

    @MainActor
    func testAPCancellationRestartsBackoffAndReconnectingStaysVisible() async {
        let preferences = UserDefaults(suiteName: "sta_connection")!
        let keys = ["wireless_mode", CameraPresentationMode.preferenceKey]
        let previous = keys.map { preferences.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        let service = APReplayService(succeedsOnAttempt: 100)
        let model = ConnectionViewModel(wifiService: service)
        model.setGPSConnectionPaused(false)
        model.select(wirelessMode: .ap)
        await model.connectSelectedWiFi()
        XCTAssertEqual(model.apRetryDelayNanoseconds, 1_000_000_000)
        await model.connectSelectedWiFi()
        XCTAssertEqual(model.apRetryDelayNanoseconds, 3_000_000_000)
        model.cancelWiFiConnection()
        XCTAssertEqual(model.state.wifiPhase, .idle)
        XCTAssertNil(model.state.wifiFailureKind)
        var phases: [WiFiConnectionPhase] = []
        let observation = model.$state.sink { phases.append($0.wifiPhase) }
        defer { observation.cancel() }
        await model.connectSelectedWiFi()
        XCTAssertTrue(phases.contains(.connecting))
        XCTAssertEqual(model.apRetryDelayNanoseconds, 1_000_000_000)
        model.cancelWiFiConnection()
        for _ in 0..<3 {
            phases.removeAll()
            await model.connectSelectedWiFi(reconnect: true)
            XCTAssertEqual(model.state.wifiPhase, .reconnecting)
            XCTAssertNil(model.state.wifiFailureKind)
            XCTAssertEqual(model.apRetryDelayNanoseconds, 1_000_000_000)
            XCTAssertFalse(phases.contains(.connecting))
            XCTAssertFalse(phases.contains { if case .failed = $0 { return true }; return false })
        }
        model.cancelWiFiConnection()
        XCTAssertEqual(model.state.wifiPhase, .idle)
    }

    @MainActor
    func testWorkspaceReturnDefersDiscoverySnapshotAndTransportEventsUntilSettled() {
        let device = USBDeviceDescriptor(id: "workspace-replay", name: "Nikon", productKind: nil, transportType: "USB")
        let source = WorkspaceDiscoverySource(devices: [device])
        let model = ConnectionViewModel(discoverySource: source)
        var workspace = WorkspaceDiscoveryState()
        workspace.request(1)
        model.setConnectionDiscoveryPaused(workspace.shouldPause)
        workspace.begin(1)
        workspace.settle(1)
        workspace.request(0)
        workspace.begin(0)
        model.setConnectionDiscoveryPaused(workspace.shouldPause)
        // Framework events can already be queued when the workbench pauses.
        model.apply(.authorization(.authorized))
        model.apply(.deviceAdded(device))
        model.apply(.ready(id: device.id))
        model.apply(.sessionOpened(id: device.id, token: UUID()))
        XCTAssertNil(model.state.selectedDeviceID)
        XCTAssertTrue(model.state.discoveredDevices.isEmpty)
        XCTAssertEqual(model.state.usbPhase, .waitingForCamera)
        XCTAssertNil(model.cameraSession)
        XCTAssertEqual(source.calls, [])
        // Cancel return and retry it: neither path may resume early.
        workspace.request(1)
        workspace.settle(1)
        model.setConnectionDiscoveryPaused(workspace.shouldPause)
        workspace.request(0)
        workspace.begin(0)
        model.setConnectionDiscoveryPaused(workspace.shouldPause)
        XCTAssertEqual(source.calls, [])
        workspace.settle(0)
        model.setConnectionDiscoveryPaused(workspace.shouldPause)
        XCTAssertEqual(source.calls, ["authorization", "refresh", "devices"])
        XCTAssertEqual(model.state.usbAuthorization, .denied)
        XCTAssertEqual(model.state.discoveredDevices, [device])
        XCTAssertEqual(model.state.selectedDeviceID, device.id)
        // A repeated settled callback must not request permission/enumerate again.
        model.setConnectionDiscoveryPaused(workspace.shouldPause)
        XCTAssertEqual(source.calls, ["authorization", "refresh", "devices"])
    }

    #if DEBUG
    @MainActor
    func testWorkspacePauseAndResumePreserveAcceptedCameraSession() {
        let source = WorkspaceDiscoverySource(devices: [])
        let model = ConnectionViewModel(discoverySource: source)
        model.connectDebugSimulator()
        let accepted = model.cameraSession
        XCTAssertNotNil(accepted)
        model.setConnectionDiscoveryPaused(true)
        XCTAssertTrue(model.cameraSession === accepted)
        model.setConnectionDiscoveryPaused(false)
        XCTAssertTrue(model.cameraSession === accepted)
        XCTAssertTrue(source.calls.isEmpty)
    }
    #endif

    #if DEBUG
    @MainActor
    func testDebugPremiumPreviewIsSessionScopedAndDoesNotGrantAccess() {
        let accessBefore = PremiumAccess.shared.entitlement
        let now = Date()
        let usageBefore = FreeUsageStore.shared.snapshot(at: now)
        let model = ConnectionViewModel()
        XCTAssertFalse(model.previewsPremiumConnectionAnimation)
        model.connectDebugSimulator(previewPremiumAnimation: true)
        let session = model.cameraSession
        XCTAssertNotNil(session)
        XCTAssertTrue(model.previewsPremiumConnectionAnimation)
        // A release click following the recognized long press is a no-op.
        model.connectDebugSimulator()
        XCTAssertTrue(model.cameraSession === session)
        XCTAssertTrue(model.previewsPremiumConnectionAnimation)

        let nextWorkspace = ConnectionViewModel()
        nextWorkspace.connectDebugSimulator()
        XCTAssertFalse(nextWorkspace.previewsPremiumConnectionAnimation)
        XCTAssertEqual(PremiumAccess.shared.entitlement, accessBefore)
        XCTAssertEqual(FreeUsageStore.shared.snapshot(at: now), usageBefore)
    }
    #endif

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

    func testRemoteEntryIntroStopsAfterTwentyRecordedStarts() {
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


@MainActor
private final class WorkspaceDiscoverySource: ConnectionUSBDiscoverySource {
    let devices: [USBDeviceDescriptor]
    private(set) var calls: [String] = []
    init(devices: [USBDeviceDescriptor]) { self.devices = devices }
    func currentAuthorization() -> USBAuthorizationState {
        calls.append("authorization")
        // Keep this replay at the permission gate; no physical camera is opened.
        return .denied
    }
    func refreshAuthorization() { calls.append("refresh") }
    func attachedDevices() -> [USBDeviceDescriptor] { calls.append("devices"); return devices }
}


private actor APReplayService: WiFiConnectionServicing {
    nonisolated let profiles: STAProfileStore
    private(set) var attempts = 0
    private let succeedsOnAttempt: Int
    init(succeedsOnAttempt: Int = 4) {
        self.succeedsOnAttempt = succeedsOnAttempt
        let name = "APReplay-\(UUID())"
        profiles = STAProfileStore(preferences: UserDefaults(suiteName: name)!,
                                   pairing: UserDefaults(suiteName: name + ".pairing")!)
    }
    func connectAP(host: String) async throws -> CameraRepository {
        attempts += 1
        if attempts >= succeedsOnAttempt { return CameraRepository(debugData: .shared) }
        switch attempts % 3 {
        case 1: throw PTPSessionError.timeout
        case 2: throw STAConnectionError.cameraRefused
        default: throw PTPSessionError.invalidated
        }
    }
    func connectSTA(discovery: PTPIPDiscoveryService,
                    onStage: @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> CameraRepository {
        throw STAConnectionError.notFound
    }
    func startKeepalive(for repository: CameraRepository, onLost: @escaping @Sendable () async -> Void) {}
    func disconnect() {}
}
