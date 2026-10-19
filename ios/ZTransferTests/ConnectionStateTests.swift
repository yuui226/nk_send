import XCTest
import Combine
import SwiftUI
import UIKit
@testable import ZTransfer

final class ConnectionStateTests: XCTestCase {
    @MainActor
    func testRepeatedDiscoveryKeepsCleanupButDoesNotRepublishUnchangedState() async throws {
        let service = APReplayService()
        let model = ConnectionViewModel(discoverySource: WorkspaceDiscoverySource(devices: []), wifiService: service)
        let device = USBDeviceDescriptor(id: "repeated", name: "Nikon", productKind: nil, transportType: "USB")
        model.apply(.authorization(.denied))
        model.apply(.deviceAdded(device))
        await model.refreshSTAProfiles()
        var updates = 0
        let token = model.objectWillChange.sink { updates += 1 }
        defer { token.cancel() }
        for _ in 0..<120 {
            model.apply(.authorization(.denied))
            model.apply(.deviceAdded(device))
            model.select(mode: model.state.selectedMode)
            await model.refreshSTAProfiles()
        }
        XCTAssertEqual(updates, 0)
        let deadline = ContinuousClock.now + .seconds(2)
        while await service.disconnects < 121, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 121, "Unchanged state must not suppress per-event cancellation/cleanup")
        XCTAssertEqual(model.state.selectedDeviceID, device.id)
        service.profiles.remember(guid: "00112233445566778899aabbccddeeff", ip: "192.168.1.2", identity: .pairedComputer, model: "Z30")
        service.profiles.confirmVerifiedPairing("00112233445566778899aabbccddeeff")
        await model.refreshSTAProfiles()
        XCTAssertEqual(model.pairedCameraCount, 1)
        XCTAssertEqual(model.pairedCameraModels, ["Z30"])
        let afterPairing = updates
        await model.refreshSTAProfiles()
        XCTAssertEqual(updates, afterPairing)
        service.profiles.resetPairing()
        await model.refreshSTAProfiles()
        XCTAssertEqual(model.pairedCameraCount, 0)
        XCTAssertEqual(model.pairedCameraModels, [])
        XCTAssertGreaterThan(updates, afterPairing)
    }

    @MainActor
    func testRepeatedWirelessSelectionStillPersistsItsPresentationMode() {
        let preferences = UserDefaults(suiteName: "sta_connection")!
        let keys = ["wireless_mode", CameraPresentationMode.preferenceKey]
        let previous = keys.map { preferences.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { preferences.set(value, forKey: key) } else { preferences.removeObject(forKey: key) }
            }
        }
        preferences.set("STA", forKey: "wireless_mode")
        preferences.set(CameraPresentationMode.sta.rawValue, forKey: CameraPresentationMode.preferenceKey)
        let model = ConnectionViewModel(discoverySource: WorkspaceDiscoverySource(devices: []), wifiService: APReplayService())
        var updates = 0
        let token = model.$state.dropFirst().sink { _ in updates += 1 }
        defer { token.cancel() }
        for _ in 0..<120 {
            preferences.removeObject(forKey: CameraPresentationMode.preferenceKey)
            model.select(wirelessMode: .sta)
            XCTAssertEqual(preferences.string(forKey: CameraPresentationMode.preferenceKey), CameraPresentationMode.sta.rawValue)
        }
        XCTAssertEqual(updates, 0)
    }

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
    func testAcceptedWirelessWorkspaceIgnoresUSBWhenDisconnected() async throws {
        let preferences = UserDefaults(suiteName: "sta_connection")!
        let keys = ["wireless_mode", CameraPresentationMode.preferenceKey]
        let saved = keys.map { preferences.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        for mode in [WirelessMode.ap, .sta] {
            let service = AcceptedWirelessReplayService()
            let model = ConnectionViewModel(wifiService: service)
            model.setGPSConnectionPaused(false); model.select(wirelessMode: mode)
            await model.connectSelectedWiFi()
            let session = try XCTUnwrap(model.cameraSession)
            let list = PhotoListViewModel.cached(session: session)
            await model.handleTransportLost(session)
            XCTAssertNil(model.cameraSession)
            XCTAssertFalse(list.transportAvailable, "Connection loss must stop cached work even without a mounted list")
            let device = USBDeviceDescriptor(id: "foreign-usb", name: "Nikon", productKind: nil, transportType: "USB")
            model.apply(.deviceAdded(device)); model.apply(.ready(id: device.id))
            model.apply(.deviceRemoved(id: device.id))
            XCTAssertNil(model.state.selectedDeviceID)
            XCTAssertTrue(model.state.discoveredDevices.isEmpty)
            XCTAssertEqual(model.establishedWorkspaceMode, mode == .sta ? .sta : .ap)
            model.setConnectionDiscoveryPaused(true)
            PhotoListViewModel.evict(session: session)
        }
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

    func testConnectionCelebrationUsesEstablishedIOSHandoffTiming() {
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
    private(set) var disconnects = 0
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
    func disconnect() { disconnects += 1 }
}

private actor AcceptedWirelessReplayService: WiFiConnectionServicing {
    nonisolated let profiles: STAProfileStore
    init() {
        let name = "AcceptedWirelessReplay-\(UUID())"
        profiles = STAProfileStore(preferences: UserDefaults(suiteName: name)!,
            pairing: UserDefaults(suiteName: name + ".pairing")!)
    }
    func connectAP(host: String) async throws -> CameraRepository { CameraRepository(debugData: .shared) }
    func connectSTA(discovery: PTPIPDiscoveryService,
        onStage: @escaping @Sendable (STAConnectionStage) async -> Void) async throws -> CameraRepository {
        CameraRepository(debugData: .shared)
    }
    func startKeepalive(for repository: CameraRepository, onLost: @escaping @Sendable () async -> Void) async {}
    func disconnect() async {}
}

@MainActor
final class PremiumConnectionArtworkTests: XCTestCase {
    private struct Render {
        let image: UIImage
        let bytes: [UInt8]
        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * 220 + x) * 4 + 3]) }
        var totalAlpha: Int { stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) } }
        var coreRadius: Int {
            (30...45).max { a, b in greenStrength(at: a) < greenStrength(at: b) }!
        }
        private func greenStrength(at radius: Int) -> Int {
            let i = (110 * 220 + 110 + radius) * 4
            return Int(bytes[i + 1]) - Int(bytes[i])
        }
    }
    private func render(_ progress: CGFloat, premium: Bool = true) throws -> Render {
        let renderer = ImageRenderer(content: ConnectionSuccessArtwork(progress: progress, goldBurst: premium)
            .frame(width: 220, height: 220).environment(\.colorScheme, .light))
        renderer.scale = 1; renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.uiImage)
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, 220); XCTAssertEqual(cg.height, 220)
        var bytes = [UInt8](repeating: 0, count: 220 * 220 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 220, height: 220,
            bitsPerComponent: 8, bytesPerRow: 220 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 220, height: 220))
        return Render(image: image, bytes: bytes)
    }

    func testAndroidPremiumTailEndpointsAndMonotonicFade() {
        XCTAssertEqual(premiumConnectionEffectFade(-1), 1)
        XCTAssertEqual(premiumConnectionEffectFade(0.5), 1)
        XCTAssertEqual(premiumConnectionEffectFade(0.62), 1)
        XCTAssertEqual(premiumConnectionEffectFade(0.81), 0.5, accuracy: 0.000001)
        XCTAssertGreaterThan(premiumConnectionEffectFade(0.8), premiumConnectionEffectFade(0.95))
        XCTAssertEqual(premiumConnectionEffectFade(1), 0)
        XCTAssertEqual(premiumConnectionEffectFade(2), 0)
        let samples = (0...100).map { premiumConnectionEffectFade(CGFloat($0) / 100) }
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }

    func testRealArtworkHasRadialGlowExpandingCoreAndNoResidualFinalPixels() throws {
        for progress: CGFloat in [-1, 0, 1, 2] {
            XCTAssertEqual(try render(progress).totalAlpha, 0, "Every premium layer must finish completely")
        }
        // At p=.5, all moving dots are outside radius 21. Sample inside that
        // region so a bright particle cannot be mistaken for the diffuse halo.
        let glow = try render(0.5)
        XCTAssertGreaterThan(glow.totalAlpha, 1_000, "A blank Canvas cannot pass the fade assertions")
        XCTAssertGreaterThan(glow.alpha(110, 110), glow.alpha(118, 110))
        XCTAssertGreaterThan(glow.alpha(118, 110), glow.alpha(126, 110), "Glow must soften radially, not form solid disks")
        let first = try render(0.6), later = try render(0.8), tail = try render(0.95)
        XCTAssertGreaterThan(later.coreRadius, first.coreRadius, "The confirmation ring expands; it must not contract into a badge")
        XCTAssertGreaterThan(later.totalAlpha, tail.totalAlpha)
        XCTAssertGreaterThan(tail.totalAlpha, 0)
    }

    func testFreePulsesRemainSeparateAndSaveActualStages() throws {
        XCTAssertEqual(try render(0, premium: false).totalAlpha, 0)
        XCTAssertEqual(try render(1, premium: false).totalAlpha, 0)
        let free = try render(0.3, premium: false)
        XCTAssertGreaterThan(free.totalAlpha, 1_000)
        XCTAssertEqual(free.alpha(110, 110), 0, "Free pulses cannot acquire the premium center glow")
        let stages: [CGFloat] = [0.05, 0.25, 0.5, 0.7, 0.85, 0.95, 1]
        let images = try stages.map { (try render($0).image, try render($0, premium: false).image) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 440, height: stages.count * 244), format: format).image { ctx in
            UIColor(white: 0.08, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 440, height: stages.count * 244))
            for (index, pair) in images.enumerated() {
                let y = index * 244
                pair.0.draw(at: CGPoint(x: 0, y: y + 24)); pair.1.draw(at: CGPoint(x: 220, y: y + 24))
                ("Pro / Free · p=\(stages[index])" as NSString).draw(at: CGPoint(x: 8, y: y + 4),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.white])
            }
        }
        try sheet.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1019-premium-connection.png"))
        let attachment = XCTAttachment(image: sheet); attachment.name = "Premium connection stages"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
