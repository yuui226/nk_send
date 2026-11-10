import Foundation
import CoreLocation
import XCTest
#if !SWIFT_PACKAGE
import CoreBluetooth
import ExternalAccessory
import Combine
import SwiftUI
import UIKit
#endif
#if SWIFT_PACKAGE
@testable import ZTransferGPS
#else
@testable import ZTransfer
#endif

final class GPSProtocolTests: XCTestCase {
    func testCameraCoordinateFormatAndClipboardMatchAndroid() {
        let cases: [(Double, Double, String)] = [
            (31.2304, 121.4737, "N 31°13.824', E 121°28.422'"),
            (-33.8688, 151.2093, "S 33°52.128', E 151°12.558'"),
            (40.7128, -74.006, "N 40°42.768', W 74°00.360'"),
            (0, -0.0, "N 0°00.000', E 0°00.000'"),
            (-90, -180, "S 90°00.000', W 180°00.000'")
        ]
        for (latitude, longitude, expected) in cases {
            XCTAssertEqual(GPSCoordinateFormat.coordinates(latitude: latitude, longitude: longitude), expected)
            XCTAssertEqual(GPSCoordinateFormat.clipboard(latitude: latitude, longitude: longitude), expected)
            XCTAssertEqual(GPSCoordinateFormat.clipboard(latitude: latitude, longitude: longitude,
                                                        placeName: "地点"), "地点\n" + expected)
        }
        XCTAssertEqual(GPSCoordinateFormat.value(24 + 59.9996 / 60, latitude: true), "N 25°00.000'")
        XCTAssertEqual(GPSCoordinateFormat.value(-(24 + 59.9996 / 60), latitude: true), "S 25°00.000'")
        XCTAssertEqual(GPSCoordinateFormat.value(179.99999999, latitude: false), "E 180°00.000'")
        XCTAssertEqual(GPSCoordinateFormat.value(90, latitude: true), "N 90°00.000'")
        XCTAssertEqual(GPSCoordinateFormat.value(24 + 29.369 / 60, latitude: true), "N 24°29.369'")
        for value in [91.0, -91, .nan, .infinity] {
            XCTAssertNil(GPSCoordinateFormat.value(value, latitude: true))
        }
        for value in [181.0, -181, .nan, -.infinity] {
            XCTAssertNil(GPSCoordinateFormat.value(value, latitude: false))
        }
        XCTAssertNil(GPSCoordinateFormat.value(nil, latitude: true))
        XCTAssertNil(GPSCoordinateFormat.clipboard(latitude: .nan, longitude: 0))
    }

    #if !SWIFT_PACKAGE
    @MainActor
    func testFreshHandshakeDoesNotPersistIdentityBeforeSystemPairingConfirmation() {
        let suite = "GPSUnconfirmedIdentity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = NikonGPSBluetoothClient(defaults: defaults)
        _ = client.preparePairingIdentity()
        XCTAssertFalse(client.hasSavedPairing)
        XCTAssertNil(defaults.object(forKey: GPSPreferences.deviceID))
        XCTAssertNil(defaults.object(forKey: GPSPreferences.nonce))
        client.stop()
        XCTAssertFalse(NikonGPSBluetoothClient(defaults: defaults).hasSavedPairing)
    }

    @MainActor
    func testFreshIDACKRequiresSystemPairingThenNewBLEHandshakeBeforeReady() throws {
        for result: NikonGPSSystemPairingResult in [.paired, .alreadyConnected, .notFound, .failed] {
            let suite = "GPSSystemPairingSuccess-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let pairing = GPSControlledSystemPairing()
            let client = NikonGPSBluetoothClient(defaults: defaults,
                centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
            defer { client.stop() }
            var events: [NikonGPSBluetoothState] = []
            let observation = client.statePublisher.sink { events.append($0) }
            defer { observation.cancel() }
            client.start()
            let packet = client.preparePairingIdentity()
            XCTAssertNotNil(client.takeControllerIDPayload())
            var closes = 0
            client.controllerIDDidWrite(cameraName: "Z30_123") { closes += 1 }
            client.controllerIDDidWrite(cameraName: "Z30_123") { XCTFail("Duplicate ID ACK") }
            XCTAssertEqual(closes, 1)
            XCTAssertEqual(pairing.names, ["Z30_123"])
            XCTAssertEqual(client.state, .cameraConfirm)
            XCTAssertTrue(client.isRunning)
            XCTAssertFalse(client.hasSavedPairing)
            XCTAssertFalse(events.contains(.ready("Z30_123")))
            var geoAccepted: Bool?
            client.writeGeo(Data(repeating: 0, count: 41)) { geoAccepted = $0 }
            XCTAssertEqual(geoAccepted, false)
            pairing.complete(0, result)
            XCTAssertEqual(Array(events.suffix(2)), [.verifyingPairing("Z30_123"), .disconnected])
            XCTAssertTrue(client.hasPairingIdentity)
            XCTAssertFalse(client.hasSavedPairing)
            XCTAssertFalse(defaults.bool(forKey: GPSPreferences.pairingConfirmed))
            XCTAssertTrue(defaults.bool(forKey: GPSPreferences.pairingVerificationPending))
            XCTAssertEqual(defaults.integer(forKey: GPSPreferences.deviceID), Int(packet.device))
            XCTAssertEqual(defaults.integer(forKey: GPSPreferences.nonce), Int(packet.nonce))
            XCTAssertNil(defaults.string(forKey: GPSPreferences.bleAddress))
            let afterPair = events
            pairing.complete(0, result)
            XCTAssertEqual(events, afterPair)
            client.stop(); client.start()
            let reconnect = client.preparePairingIdentity()
            XCTAssertEqual(reconnect.device, packet.device)
            XCTAssertEqual(reconnect.nonce, packet.nonce)
            XCTAssertNotNil(client.takeControllerIDPayload())
            client.controllerIDDidWrite(cameraName: "Z30_123") { XCTFail("Paired reconnect must retain BLE") }
            XCTAssertEqual(client.state, .ready("Z30_123"))
            XCTAssertEqual(pairing.names.count, 1)
            XCTAssertFalse(client.hasSavedPairing)
            client.confirmIdentityAfterGeoWrite()
            XCTAssertTrue(client.hasSavedPairing)
            XCTAssertTrue(defaults.bool(forKey: GPSPreferences.pairingConfirmed))
            XCTAssertNil(defaults.object(forKey: GPSPreferences.pairingVerificationPending))
        }
    }

    @MainActor
    func testFreshClientCannotExposePhoneCoordinatesBeforeCameraReconnect() {
        for result: NikonGPSSystemPairingResult in [.paired, .notFound, .cancelled] {
            let suite = "GPSClientPresentationGate-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let pairing = GPSControlledSystemPairing(), manager = GPSControlledLocationManager()
            let client = NikonGPSBluetoothClient(defaults: defaults,
                centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: client, locationManager: manager,
                bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
            defer { coordinator.setEnabled(false) }
            coordinator.setEnabled(true)
            _ = client.preparePairingIdentity(); _ = client.takeControllerIDPayload()
            var closes = 0
            client.controllerIDDidWrite(cameraName: "Nikon test") { closes += 1 }
            XCTAssertEqual(closes, 1)
            XCTAssertEqual(pairing.names, ["Nikon test"])
            XCTAssertEqual(coordinator.state.status, .cameraConfirm)
            XCTAssertFalse(manager.updating)
            let fix = CLLocation(coordinate: .init(latitude: 31, longitude: 121), altitude: 10,
                horizontalAccuracy: 5, verticalAccuracy: 2, timestamp: Date())
            coordinator.locationManager(manager, didUpdateLocations: [fix])
            XCTAssertNil(coordinator.state.latitude, "A phone fix is not a camera connection")
            XCTAssertNil(coordinator.state.longitude)
            XCTAssertFalse(coordinator.state.canSyncNow)
            pairing.complete(0, result)
            coordinator.locationManager(manager, didUpdateLocations: [fix])
            XCTAssertFalse(manager.updating, "Picker result alone cannot start the coordinate panel")
            XCTAssertNil(coordinator.state.latitude)
            XCTAssertNil(coordinator.state.longitude)
            XCTAssertNil(coordinator.state.lastSentAt)
            XCTAssertFalse(coordinator.state.canSyncNow)
            XCTAssertFalse(client.hasSavedPairing)
            let connectedStates: Set<GPSStatus> = [.connected, .pairingSuccess, .waitingFix, .writing, .ready]
            XCTAssertFalse(connectedStates.contains(coordinator.state.status))
        }
    }

    @MainActor
    func testSystemPairingFailureNeverCommitsIdentityOrReportsReady() {
        for result: NikonGPSSystemPairingResult in [.cancelled, .timedOut] {
            let suite = "GPSSystemPairingFailure-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let pairing = GPSControlledSystemPairing()
            let client = NikonGPSBluetoothClient(defaults: defaults,
                centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
            defer { client.stop() }
            client.start(); _ = client.preparePairingIdentity(); _ = client.takeControllerIDPayload()
            client.controllerIDDidWrite(cameraName: "Nikon") {}
            pairing.complete(0, result)
            XCTAssertEqual(client.state, .failed(result.failureMessage))
            XCTAssertFalse(client.hasSavedPairing)
            XCTAssertNil(defaults.object(forKey: GPSPreferences.deviceID))
            XCTAssertNil(defaults.object(forKey: GPSPreferences.pairingConfirmed))
            pairing.complete(0, .paired)
            XCTAssertFalse(client.hasSavedPairing)
            XCTAssertEqual(client.state, .failed(result.failureMessage))
        }
    }

    @MainActor
    func testSystemPairingCancellationAndTimeoutRejectLateConfirmation() async throws {
        for action in ["stop", "clear", "adapter", "timeout", "replacement"] {
            let suite = "GPSSystemPairingCancel-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let pairing = GPSControlledSystemPairing(), clock = GPSDeferredClock()
            let client = NikonGPSBluetoothClient(defaults: defaults, sleep: { await clock.wait($0) },
                centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
            defer { client.stop() }
            client.start(); _ = client.preparePairingIdentity(); _ = client.takeControllerIDPayload()
            client.controllerIDDidWrite(cameraName: "Nikon") {}
            for _ in 0..<100 where await clock.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
            let delays = await clock.delays
            XCTAssertEqual(delays, [30_000_000_000])
            switch action {
            case "clear": client.clearPairing()
            case "adapter": client.invalidateAdapterConnection()
            case "timeout": break
            case "replacement":
                client.stop(); client.start()
                _ = client.preparePairingIdentity(); _ = client.takeControllerIDPayload()
                client.controllerIDDidWrite(cameraName: "Other Nikon") {}
            default: client.stop()
            }
            await clock.release(0)
            for _ in 0..<20 { await Task.yield() }
            pairing.complete(0, .paired)
            XCTAssertFalse(client.hasSavedPairing, action)
            XCTAssertNil(defaults.object(forKey: GPSPreferences.pairingConfirmed), action)
            if action == "timeout" { XCTAssertEqual(client.state, .failed("请确认蓝牙配对")) }
            if action == "replacement" {
                XCTAssertEqual(client.state, .cameraConfirm)
                pairing.complete(1, .paired)
                XCTAssertTrue(client.hasPairingIdentity)
                XCTAssertFalse(client.hasSavedPairing)
                for _ in 0..<100 where await clock.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
                await clock.release(1)
            }
        }
    }

    @MainActor
    func testSystemPairingHandlesSynchronousObserverCancellation() {
        for cancellation in ["beforePicker", "afterPair"] {
            let suite = "GPSSystemPairingReentrant-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let pairing = GPSControlledSystemPairing()
            let client = NikonGPSBluetoothClient(defaults: defaults,
                centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
            let subscription = client.statePublisher.sink { state in
                if (cancellation == "beforePicker" && state == .cameraConfirm) ||
                   (cancellation == "afterPair" && state == .verifyingPairing("Nikon")) { client.clearPairing() }
            }
            defer { subscription.cancel(); client.stop() }
            client.start(); _ = client.preparePairingIdentity(); _ = client.takeControllerIDPayload()
            client.controllerIDDidWrite(cameraName: "Nikon") {}
            if cancellation == "beforePicker" { XCTAssertTrue(pairing.names.isEmpty) }
            else { pairing.complete(0, .paired) }
            XCTAssertEqual(client.state, .disconnected)
            XCTAssertFalse(client.hasSavedPairing)
        }
    }

    @MainActor
    func testOnlyConfirmedCompleteIdentitySurvivesClientRecreation() {
        for confirmed in [false, true] {
            let suite = "GPSPairingMigration-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(123, forKey: GPSPreferences.deviceID)
            defaults.set(456, forKey: GPSPreferences.nonce)
            defaults.set(UUID().uuidString, forKey: GPSPreferences.bleAddress)
            defaults.set(confirmed, forKey: GPSPreferences.pairingConfirmed)
            let client = NikonGPSBluetoothClient(defaults: defaults)
            XCTAssertEqual(client.hasSavedPairing, confirmed)
            XCTAssertEqual(defaults.object(forKey: GPSPreferences.deviceID) != nil, confirmed)
            XCTAssertEqual(defaults.object(forKey: GPSPreferences.bleAddress) != nil, confirmed)
            client.clearPairing()
            XCTAssertNil(defaults.object(forKey: GPSPreferences.pairingConfirmed))
        }
    }

    @MainActor
    func testProvisionalPairingSurvivesRestartAndTransportTimeoutWithoutClaimingSuccess() async throws {
        let suite = "GPSPendingIdentity-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairing = GPSControlledSystemPairing()
        let first = NikonGPSBluetoothClient(defaults: defaults,
            centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
        first.start()
        let packet = first.preparePairingIdentity()
        _ = first.takeControllerIDPayload()
        first.controllerIDDidWrite(cameraName: "Z50_2_123") {}
        pairing.complete(0, .notFound) // Actual device trace: camera paired, picker failed its connection.
        XCTAssertTrue(first.hasPairingIdentity)
        XCTAssertFalse(first.hasSavedPairing)
        first.confirmIdentityAfterGeoWrite()
        XCTAssertFalse(first.hasSavedPairing, "Picker completion is not GEO acknowledgement")
        first.stop()
        let clock = GPSDeferredClock()
        let restored = NikonGPSBluetoothClient(defaults: defaults, sleep: { await clock.wait($0) },
            centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
        defer { restored.stop() }
        XCTAssertTrue(restored.hasPairingIdentity)
        XCTAssertFalse(restored.hasSavedPairing)
        XCTAssertFalse(restored.isRunning, "Pending credentials must never auto-enable GPS")
        restored.start()
        let retry = restored.preparePairingIdentity()
        XCTAssertEqual(retry.device, packet.device)
        XCTAssertEqual(retry.nonce, packet.nonce)
        restored.beginPairingDeadline(restoringIdentity: true)
        for _ in 0..<100 where await clock.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let delays = await clock.delays
        XCTAssertEqual(delays, [7_000_000_000])
        await clock.release(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(restored.state, .failed("GPS connection confirmation timeout"))
        XCTAssertFalse(GPSBluetoothFailurePolicy("GPS connection confirmation timeout").invalidatesIdentity)
        XCTAssertTrue(defaults.bool(forKey: GPSPreferences.pairingVerificationPending))
        restored.clearPairing()
        for key in [GPSPreferences.deviceID, GPSPreferences.nonce, GPSPreferences.pairingConfirmed,
                    GPSPreferences.pairingVerificationPending, GPSPreferences.cameraName, GPSPreferences.bleAddress] {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    @MainActor
    func testProvisionalPairingCannotBeConfirmedByFailedWriteOrAfterStop() {
        let suite = "GPSPendingACK-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairing = GPSControlledSystemPairing()
        let client = NikonGPSBluetoothClient(defaults: defaults,
            centralFactory: { _, _ in CBCentralManager(delegate: nil, queue: .main) }, systemPairing: pairing)
        client.start(); _ = client.preparePairingIdentity(); _ = client.takeControllerIDPayload()
        client.controllerIDDidWrite(cameraName: "Z50_2_123") {}
        pairing.complete(0, .notFound)
        client.stop(); client.start()
        _ = client.preparePairingIdentity(); _ = client.takeControllerIDPayload()
        client.controllerIDDidWrite(cameraName: "Z50_2_123") {}
        XCTAssertEqual(client.state, .ready("Z50_2_123"))
        var success: Bool?
        client.writeGeo(Data(repeating: 0, count: 41)) { success = $0 }
        XCTAssertEqual(success, false, "No real peripheral exists in this unit test")
        XCTAssertFalse(client.hasSavedPairing)
        client.stop()
        client.confirmIdentityAfterGeoWrite()
        XCTAssertFalse(client.hasSavedPairing)
        XCTAssertTrue(defaults.bool(forKey: GPSPreferences.pairingVerificationPending))
        client.clearPairing()
    }

    @MainActor
    func testConnectedCameraSelectionUsesKnownIDOrUnambiguousName() {
        let a = UUID(), b = UUID(), other = UUID()
        let candidates: [(id: UUID, name: String?)] = [(a, "Z50_2_123"), (b, "Z30_456"), (other, nil)]
        XCTAssertEqual(NikonGPSBluetoothClient.connectedPeripheralID(candidates, savedID: other, cameraName: nil), other)
        XCTAssertEqual(NikonGPSBluetoothClient.connectedPeripheralID(candidates, savedID: UUID(), cameraName: "z50_2_123"), a)
        XCTAssertNil(NikonGPSBluetoothClient.connectedPeripheralID(candidates, savedID: nil, cameraName: "Nikon"))
        XCTAssertNil(NikonGPSBluetoothClient.connectedPeripheralID(candidates, savedID: nil, cameraName: "Z6_987"))
        XCTAssertEqual(NikonGPSBluetoothClient.connectedPeripheralID([(a, "Z50_")], savedID: nil, cameraName: "Z50_2_123"), a)
        XCTAssertNil(NikonGPSBluetoothClient.connectedPeripheralID([(a, "Z50_"), (b, "Z50_")], savedID: nil, cameraName: "Z50_2_123"))
        XCTAssertEqual(NikonGPSBluetoothClient.connectedPeripheralID([(a, "Z50_"), (b, "Z50_2_123")], savedID: nil, cameraName: "Z50_2_123"), b)
    }

    @MainActor
    func testSystemPairingNameFilterAndErrorsMatchAndroidCameraScope() {
        let filter = NikonGPSAccessoryPairing.nameFilter("Z30_123456")
        for name in ["Z30_123456", "z30_123456", "Z30_123456_extra", "Z30_123"] { XCTAssertTrue(filter.evaluate(with: name), name) }
        for name in ["Other Camera", "Z30", "Z30_999999", "Headphones"] { XCTAssertFalse(filter.evaluate(with: name), name) }
        XCTAssertTrue(NikonGPSAccessoryPairing.nameFilter("Nikon").evaluate(with: "NIKON Z30"))
        XCTAssertEqual(NikonGPSSystemPairingResult(error: nil), .paired)
        for (code, result) in [(EABluetoothAccessoryPickerError.Code.alreadyConnected, NikonGPSSystemPairingResult.alreadyConnected),
                              (.resultCancelled, .cancelled), (.resultNotFound, .notFound), (.resultFailed, .failed)] {
            XCTAssertEqual(NikonGPSSystemPairingResult(error: NSError(domain: EABluetoothAccessoryPickerErrorDomain,
                                                                     code: code.rawValue)), result)
        }
        XCTAssertEqual(NikonGPSSystemPairingResult(error: NSError(domain: "Other", code: 0)), .failed)
    }

    @MainActor
    func testAccessoryPickerWaitsForForegroundAndDoesNotReopenAfterCancel() async {
        var active = false
        var presentations = 0
        var completions: [@MainActor (NikonGPSSystemPairingResult) -> Void] = []
        let picker = NikonGPSAccessoryPairing(applicationIsActive: { active }, presentPicker: { filter, completion in
            XCTAssertTrue(filter.evaluate(with: "Z30_123"))
            presentations += 1
            completions.append(completion)
        })
        var results: [NikonGPSSystemPairingResult] = []
        picker.pair(cameraName: "Z30_123") { results.append($0) }
        XCTAssertEqual(presentations, 0)
        picker.cancel()
        active = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(results.isEmpty)
        active = false
        picker.pair(cameraName: "Z30_123") { results.append($0) }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presentations, 0)
        active = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presentations, 1)
        completions[0](.paired)
        XCTAssertEqual(results, [.paired])
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presentations, 1)
    }

    @MainActor
    func testAccessoryPickerOwnsVisibleWindowAndRejectsOldOrDuplicateResults() {
        var completions: [@MainActor (NikonGPSSystemPairingResult) -> Void] = []
        let picker = NikonGPSAccessoryPairing(applicationIsActive: { true }, presentPicker: { _, completion in
            completions.append(completion)
        })
        var first: [NikonGPSSystemPairingResult] = [], replacement: [NikonGPSSystemPairingResult] = []
        picker.pair(cameraName: "Z30") { first.append($0) }
        picker.cancel()
        // The OS window is still visible. Never open another or accept its result.
        picker.pair(cameraName: "Z30") { replacement.append($0) }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(replacement, [.failed])
        completions[0](.paired)
        XCTAssertTrue(first.isEmpty)
        picker.pair(cameraName: "Z30") { replacement.append($0) }
        XCTAssertEqual(completions.count, 2)
        completions[0](.paired)
        picker.pair(cameraName: "Z30") { replacement.append($0) }
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(replacement, [.failed, .failed])
        completions[1](.paired)
        completions[1](.paired)
        XCTAssertEqual(replacement, [.failed, .failed, .paired])
    }

    func testPairingGuidanceOnlyAppearsForActiveSystemPairingOrItsRecovery() {
        var state = GPSState(enabled: true, status: .cameraConfirm)
        XCTAssertEqual(state.pairingGuidance, AppLocalized.resource("gps_ios_system_pairing"))
        state.status = .needsCamera
        state.message = "请确认蓝牙配对"
        XCTAssertEqual(state.pairingGuidance, AppLocalized.resource("gps_ios_confirm_pairing"))
        state.message = "请在系统蓝牙中删除相机配对后重试"
        XCTAssertEqual(state.pairingGuidance, AppLocalized.resource("gps_ios_forget_pairing"))
        state.permissionIssue = .bluetoothDenied
        XCTAssertNil(state.pairingGuidance)
        state.permissionIssue = nil
        state.status = .connecting
        XCTAssertNil(state.pairingGuidance)
        state.status = .needsCamera; state.enabled = false
        XCTAssertNil(state.pairingGuidance)
        for key in ["gps_ios_system_pairing", "gps_ios_confirm_pairing", "gps_ios_forget_pairing"] {
            for language in ["zh", "en", "hant"] {
                XCTAssertNotEqual(AppLocalized.resource(key, language: language), key)
            }
        }
    }

    @MainActor
    func testColdLaunchIgnoresLegacyEnabledWithoutRequestingPermissionsOrStartingGPS() async throws {
        for authorization: CLAuthorizationStatus in [.notDetermined, .denied, .authorizedWhenInUse] {
            let suite = "GPSColdLaunch-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: GPSPreferences.legacyEnabled)
            defaults.set(120, forKey: GPSPreferences.updateFrequencySeconds)
            defaults.set(true, forKey: GPSPreferences.connectionHelpViewed)
            defaults.set(123, forKey: GPSPreferences.deviceID)
            defaults.set(456, forKey: GPSPreferences.nonce)
            let manager = GPSControlledLocationManager(), transport = GPSControlledTransport()
            manager.authorization = authorization
            var queries = 0
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport,
                locationManager: manager, locationServicesQuery: { queries += 1; $0(true) },
                bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
            defer { coordinator.setEnabled(false) }
            coordinator.resumeAuthorizationIfNeeded()
            coordinator.locationManagerDidChangeAuthorization(manager)
            transport.emit(.ready("old camera"))
            coordinator.syncNow()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(coordinator.state.enabled)
            XCTAssertEqual(coordinator.state.status, .off)
            XCTAssertNil(coordinator.state.permissionIssue)
            XCTAssertEqual(queries, 0)
            XCTAssertEqual(manager.foregroundRequests, 0)
            XCTAssertEqual(manager.starts, 0)
            XCTAssertEqual(transport.starts, 0)
            XCTAssertTrue(transport.payloads.isEmpty)
            XCTAssertNil(defaults.object(forKey: GPSPreferences.legacyEnabled))
            XCTAssertEqual(coordinator.frequency.rawValue, 120)
            XCTAssertTrue(coordinator.connectionHelpViewed)
            XCTAssertEqual(defaults.integer(forKey: GPSPreferences.deviceID), 123)
            XCTAssertEqual(defaults.integer(forKey: GPSPreferences.nonce), 456)
        }
    }

    func testBuiltAppDeclaresBothLocationAndCentralBluetoothBackgroundModes() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertTrue(modes.contains("location"))
        XCTAssertTrue(modes.contains("bluetooth-central"))
    }

    @MainActor
    func testDelayedSystemSwitchCheckCannotOutliveGrantOffAPOrOwner() {
        for action in ["grant", "off", "ap", "replace", "destroy", "background"] {
            let suite = "GPSDelayedSwitch-\(UUID())", manager = GPSControlledLocationManager()
            let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.authorization = .denied
            var replies: [@MainActor (Bool) -> Void] = [], settings = 0, active = true
            var coordinator: GPSCoordinator? = GPSCoordinator(defaults: defaults, bluetooth: transport,
                locationManager: manager, locationServicesQuery: { replies.append($0) },
                bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { active })
            weak var weakCoordinator = coordinator
            coordinator?.setEnabled(true)
            coordinator?.retryOrOpenSettings { settings += 1 }
            coordinator?.retryOrOpenSettings { settings += 1 }
            XCTAssertEqual(replies.count, 1, action)
            XCTAssertEqual(settings, 0)
            XCTAssertFalse(manager.updating)
            switch action {
            case "grant":
                manager.authorization = .authorizedWhenInUse
                coordinator?.locationManagerDidChangeAuthorization(manager)
            case "off": coordinator?.setEnabled(false)
            case "ap": coordinator?.setAPModeBlocked(true)
            case "replace":
                coordinator?.setEnabled(false)
                coordinator?.setEnabled(true)
                XCTAssertEqual(replies.count, 2)
            case "destroy": coordinator = nil
            default: active = false
            }
            replies[0](true)
            XCTAssertEqual(settings, 0, action)
            switch action {
            case "grant":
                XCTAssertEqual(transport.starts, 1)
                XCTAssertNil(coordinator?.state.permissionIssue)
            case "off": XCTAssertEqual(coordinator?.state.status, .off)
            case "ap":
                XCTAssertEqual(coordinator?.state.status, .apUnavailable)
                XCTAssertNil(coordinator?.state.permissionIssue)
            case "replace":
                XCTAssertNil(coordinator?.state.permissionIssue)
                replies[1](false)
                XCTAssertEqual(coordinator?.state.permissionIssue, .locationServicesDisabled)
            case "destroy": XCTAssertNil(weakCoordinator)
            default: XCTAssertEqual(coordinator?.state.permissionIssue, .locationDenied)
            }
            coordinator?.setEnabled(false)
        }
    }

    @MainActor
    func testSystemSwitchCheckRoutesOnlyLatestExplicitSettingsRequestOnce() {
        for systemEnabled in [false, true] {
            let suite = "GPSSystemSwitchResult-\(UUID())", manager = GPSControlledLocationManager()
            let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.authorization = .denied
            var replies: [@MainActor (Bool) -> Void] = [], settings = 0
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport,
                locationManager: manager, locationServicesQuery: { replies.append($0) },
                bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
            defer { coordinator.setEnabled(false) }
            coordinator.setEnabled(true)
            coordinator.retryOrOpenSettings { settings += 100 }
            coordinator.retryOrOpenSettings { settings += 1 }
            coordinator.resumeAuthorizationIfNeeded()
            XCTAssertEqual(replies.count, 1)
            replies[0](systemEnabled)
            replies[0](!systemEnabled) // Duplicate delivery cannot change the result.
            XCTAssertEqual(settings, systemEnabled ? 1 : 0)
            XCTAssertEqual(coordinator.state.permissionIssue,
                systemEnabled ? .locationDenied : .locationServicesDisabled)
            XCTAssertEqual(transport.starts, 0)
        }
    }

    @MainActor
    func testLocationFailureUsesCurrentAuthorizationInsteadOfInventingAppDenial() {
        for nextAuthorization: CLAuthorizationStatus in [.notDetermined, .authorizedWhenInUse] {
            let suite = "GPSLocationFailureGrant-\(UUID())", manager = GPSControlledLocationManager()
            let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
            defer { defaults.removePersistentDomain(forName: suite) }
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
                locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
            defer { coordinator.setEnabled(false) }
            coordinator.setEnabled(true)
            transport.emit(.ready("Camera"))
            manager.authorization = nextAuthorization
            coordinator.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue))
            XCTAssertNil(coordinator.state.permissionIssue)
            if nextAuthorization == .notDetermined {
                XCTAssertEqual(manager.foregroundRequests, 1)
                XCTAssertEqual(coordinator.state.status, .starting)
            } else {
                XCTAssertEqual(coordinator.state.status, .error)
                var settings = 0
                coordinator.retryOrOpenSettings { settings += 1 }
                XCTAssertEqual(settings, 0)
                XCTAssertTrue(manager.updating)
            }
        }
    }

    @MainActor
    func testCompleteGPSRuntimeAcrossEveryFrequencyAndReconnect() async throws {
        for frequency in GPSUpdateFrequency.allCases {
            let suite = "GPSRuntime-\(UUID())", manager = GPSControlledLocationManager()
            let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
            defer { defaults.removePersistentDomain(forName: suite) }
            transport.hasSavedPairing = false
            let clock = GPSDeferredClock()
            var time = Date()
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
                now: { time }, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true },
                writeSleep: { await clock.wait($0) })
            defer { coordinator.setEnabled(false) }
            coordinator.setFrequency(frequency)
            coordinator.setEnabled(true)
            XCTAssertEqual(transport.starts, 1)
            XCTAssertFalse(manager.updating, "Fresh pairing does not prewarm GPS")
            transport.emit(.scanning)
            transport.emit(.connecting("Camera"))
            transport.emit(.pairing)
            transport.emit(.cameraConfirm)
            XCTAssertFalse(manager.updating)
            transport.emit(.verifyingPairing("Camera"))
            XCTAssertEqual(coordinator.state.status, .connecting)
            XCTAssertNil(coordinator.state.lastSentAt)
            transport.emit(.disconnected)
            transport.emit(.connecting("Camera"))
            transport.emit(.ready("Camera"))
            XCTAssertTrue(manager.updating)
            XCTAssertEqual(coordinator.state.status, .connected)
            XCTAssertTrue(transport.payloads.isEmpty)
            func fix(_ latitude: Double) -> CLLocation {
                CLLocation(coordinate: .init(latitude: latitude, longitude: 121), altitude: 83,
                    horizontalAccuracy: 5, verticalAccuracy: 1, timestamp: time)
            }
            coordinator.locationManager(manager, didUpdateLocations: [fix(31)])
            for _ in 0..<100 where transport.payloads.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(transport.payloads.count, 1)
            XCTAssertNil(coordinator.state.lastSentAt)
            transport.complete(0, success: true)
            let initialACK = time
            XCTAssertEqual(coordinator.state.status, .pairingSuccess)
            XCTAssertEqual(coordinator.state.lastSentAt, initialACK)
            for _ in 0..<100 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
            let interval = UInt64(frequency.rawValue) * 1_000_000_000
            let initialDelays = await clock.delays
            XCTAssertEqual(initialDelays, [interval])
            try await Task.sleep(for: .milliseconds(1_420))
            XCTAssertEqual(coordinator.state.status, .ready)
            time = time.addingTimeInterval(Double(frequency.rawValue))
            await clock.release(0)
            for _ in 0..<100 where transport.payloads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(transport.payloads.count, 2, "Stationary GPS still follows the interval")
            transport.complete(1, success: false)
            XCTAssertEqual(coordinator.state.status, .error)
            XCTAssertEqual(coordinator.state.lastSentAt, initialACK)
            for _ in 0..<100 where await clock.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
            let retryDelays = await clock.delays
            XCTAssertEqual(retryDelays, [interval, interval])
            time = time.addingTimeInterval(Double(frequency.rawValue))
            await clock.release(1)
            for _ in 0..<100 where transport.payloads.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(transport.payloads.count, 3)
            transport.complete(2, success: true)
            XCTAssertEqual(coordinator.state.status, .ready)
            XCTAssertEqual(coordinator.state.lastSentAt, time)
            for _ in 0..<100 where await clock.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
            transport.emit(.disconnected)
            XCTAssertFalse(manager.updating)
            coordinator.syncNow()
            XCTAssertEqual(transport.payloads.count, 3)
            manager.cachedLocation = fix(32)
            transport.emit(.ready("Camera"))
            for _ in 0..<100 where transport.payloads.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(transport.payloads.count, 4, "Reauthentication writes immediately, independently of the old interval")
            XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
            coordinator.clearPairing()
            transport.complete(3, success: true)
            await clock.release(2)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(coordinator.state.enabled)
            XCTAssertNil(coordinator.state.lastSentAt)
            XCTAssertEqual(transport.payloads.count, 4)
            XCTAssertFalse(manager.updating)
            XCTAssertNil(defaults.object(forKey: GPSPreferences.legacyEnabled))
        }
    }

    @MainActor
    func testChangingFrequencyDuringWriteAndCountdownCancelsOldCadenceWithoutDuplicateGEO() async throws {
        for initial in GPSUpdateFrequency.allCases {
            for next in GPSUpdateFrequency.allCases where next != initial {
                let suite = "GPSFrequencyChange-\(UUID())", defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let transport = GPSControlledTransport(), manager = GPSControlledLocationManager()
                let clock = GPSDeferredClock()
                var time = Date()
                let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport,
                    locationManager: manager, now: { time }, bluetoothAuthorization: { .allowedAlways },
                    applicationIsActive: { true }, writeSleep: { await clock.wait($0) })
                defer { coordinator.setEnabled(false) }
                coordinator.setFrequency(initial)
                coordinator.setEnabled(true)
                transport.emit(.ready("Camera"))
                coordinator.locationManager(manager, didUpdateLocations: [CLLocation(
                    coordinate: .init(latitude: 31, longitude: 121), altitude: 12,
                    horizontalAccuracy: 5, verticalAccuracy: 1, timestamp: time)])
                for _ in 0..<100 where transport.payloads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(transport.payloads.count, 1)

                // An in-flight write retains ownership; the new interval starts
                // from its successful ACK, not from the selection gesture.
                coordinator.setFrequency(next)
                XCTAssertEqual(transport.payloads.count, 1)
                XCTAssertNil(coordinator.state.lastSentAt)
                XCTAssertEqual(defaults.integer(forKey: GPSPreferences.updateFrequencySeconds), next.rawValue)
                XCTAssertEqual(manager.desiredAccuracy, next.desiredAccuracy)
                transport.complete(0, success: true)
                for _ in 0..<100 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
                let firstDelays = await clock.delays
                XCTAssertEqual(firstDelays, [UInt64(next.rawValue) * 1_000_000_000])
                let successfulWrite = coordinator.state.lastSentAt

                // Retarget a live countdown, then deliberately deliver its old
                // cancelled wakeup before the new one. It must not write twice.
                time = time.addingTimeInterval(5)
                coordinator.setFrequency(initial)
                coordinator.setFrequency(initial)
                for _ in 0..<100 where await clock.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
                let delays = await clock.delays
                XCTAssertEqual(delays, [UInt64(next.rawValue) * 1_000_000_000,
                                        UInt64(initial.rawValue - 5) * 1_000_000_000])
                await clock.release(0)
                try await Task.sleep(for: .milliseconds(10))
                XCTAssertEqual(transport.payloads.count, 1)
                XCTAssertEqual(coordinator.state.lastSentAt, successfulWrite)
                time = time.addingTimeInterval(Double(initial.rawValue - 5))
                await clock.release(1)
                for _ in 0..<100 where transport.payloads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(transport.payloads.count, 2)
                coordinator.setEnabled(false)
                transport.complete(1, success: true)
                XCTAssertFalse(manager.updating)
                XCTAssertEqual(coordinator.state.status, .off)
                XCTAssertNil(coordinator.state.lastSentAt)
            }
        }
    }

    @MainActor
    func testAskNextTimeRevocationPausesOldFixesAndRequestsAgain() async throws {
        let suite = "GPSAskNextTime-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        transport.emit(.ready("Camera"))
        manager.authorization = .notDetermined
        coordinator.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(manager.foregroundRequests, 1)
        XCTAssertFalse(manager.updating)
        XCTAssertEqual(coordinator.state.status, .starting)
        transport.emit(.ready("Camera"))
        coordinator.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 31, longitude: 121)])
        coordinator.scheduleWriteIfDue(force: true)
        await Task.yield()
        XCTAssertTrue(transport.payloads.isEmpty)
        XCTAssertFalse(manager.updating)
        manager.authorization = .authorizedWhenInUse
        coordinator.locationManagerDidChangeAuthorization(manager)
        XCTAssertTrue(manager.updating)
        XCTAssertEqual(coordinator.state.status, .waitingFix)
        coordinator.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 31, longitude: 121)])
        for _ in 0..<100 where transport.payloads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 1)
    }

    @MainActor
    func testBluetoothGrantCallbackClearsOldPermissionGuidanceBeforeCameraFound() {
        let suite = "GPSBluetoothGrant-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        var authorization: CBManagerAuthorization = .denied
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { authorization }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        XCTAssertEqual(coordinator.state.permissionIssue, .bluetoothDenied)
        authorization = .allowedAlways
        transport.emit(.scanning)
        XCTAssertNil(coordinator.state.permissionIssue)
        XCTAssertNil(coordinator.state.message)
        XCTAssertEqual(coordinator.state.status, .searching)
    }

    @MainActor
    func testExplicitRetryFromPairingErrorResumesAfterPermissionGranted() {
        let suite = "GPSRetryOwnership-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        transport.emit(.failed("Camera pairing handshake timeout"))
        manager.authorization = .denied
        coordinator.locationManagerDidChangeAuthorization(manager)
        var opened = 0
        coordinator.retryOrOpenSettings { opened += 1 }
        XCTAssertEqual(opened, 1)
        manager.authorization = .authorizedWhenInUse
        coordinator.resumeAuthorizationIfNeeded()
        XCTAssertEqual(transport.starts, 2)
        XCTAssertNil(coordinator.state.permissionIssue)
        XCTAssertEqual(coordinator.state.status, .searching)
    }

    @MainActor
    func testFirstGPSGrantRequestsLocationBeforeBluetoothAndDoesNotOpenSettings() {
        let suite = "GPSFirstPermission-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        manager.authorization = .notDetermined
        var servicesQueries = 0
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { servicesQueries += 1; $0(true) }, bluetoothAuthorization: { .notDetermined }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        var settings = 0
        coordinator.setEnabled(true)
        coordinator.retryOrOpenSettings { settings += 1 }
        coordinator.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(manager.foregroundRequests, 1)
        XCTAssertEqual(settings, 0)
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(servicesQueries, 0)
        XCTAssertNil(coordinator.state.permissionIssue)
        manager.authorization = .authorizedWhenInUse
        coordinator.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(manager.backgroundRequests, 0, "Do not overlap initial BLE and Always prompts")
        transport.emit(.ready("Camera"))
        XCTAssertEqual(manager.backgroundRequests, 1)
        coordinator.resumeAuthorizationIfNeeded()
        XCTAssertEqual(manager.backgroundRequests, 1)
    }

    @MainActor
    func testGPSLocationServicesOffExplainsGlobalSwitchWithoutOpeningAppSettings() {
        let suite = "GPSSystemPermission-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        var services = false, settings = 0
        manager.authorization = .denied
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(services) }, bluetoothAuthorization: { .notDetermined }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        coordinator.retryOrOpenSettings { settings += 1 }
        XCTAssertEqual(coordinator.state.permissionIssue, .locationServicesDisabled)
        XCTAssertEqual(settings, 0)
        XCTAssertEqual(manager.foregroundRequests, 0)
        XCTAssertEqual(transport.starts, 0)
        services = true
        manager.authorization = .notDetermined
        coordinator.resumeAuthorizationIfNeeded()
        XCTAssertNil(coordinator.state.permissionIssue)
        XCTAssertEqual(manager.foregroundRequests, 1)
        manager.authorization = .authorizedWhenInUse
        coordinator.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(transport.starts, 1)
    }

    @MainActor
    func testOnlyActualAppDenialsOpenSettingsAndGrantedReturnResumes() {
        let cases: [(CLAuthorizationStatus, CBManagerAuthorization, GPSPermissionIssue, Bool)] = [
            (.denied, .notDetermined, .locationDenied, true),
            (.restricted, .notDetermined, .locationRestricted, false),
            (.authorizedWhenInUse, .denied, .bluetoothDenied, true),
            (.authorizedAlways, .restricted, .bluetoothRestricted, false),
        ]
        for (location, initialBluetooth, issue, opensSettings) in cases {
            let suite = "GPSDeniedPermission-\(UUID())", manager = GPSControlledLocationManager()
            let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
            defer { defaults.removePersistentDomain(forName: suite) }
            manager.authorization = location
            var bluetooth = initialBluetooth, settings = 0
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
                locationServicesQuery: { $0(true) }, bluetoothAuthorization: { bluetooth }, applicationIsActive: { true })
            coordinator.setEnabled(true)
            coordinator.retryOrOpenSettings { settings += 1 }
            XCTAssertEqual(coordinator.state.permissionIssue, issue)
            XCTAssertEqual(settings, opensSettings ? 1 : 0)
            XCTAssertEqual(transport.starts, 0)
            manager.authorization = .authorizedWhenInUse
            bluetooth = .allowedAlways
            coordinator.resumeAuthorizationIfNeeded()
            XCTAssertNil(coordinator.state.permissionIssue)
            XCTAssertEqual(transport.starts, 1)
            coordinator.setEnabled(false)
        }
    }

    @MainActor
    func testGPSBluetoothPowerOffRetriesWithoutOpeningAppSettings() {
        let suite = "GPSBluetoothPower-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        transport.emit(.unavailable)
        var settings = 0
        coordinator.retryOrOpenSettings { settings += 1 }
        XCTAssertEqual(settings, 0)
        XCTAssertEqual(transport.starts, 2)
        XCTAssertNil(coordinator.state.permissionIssue)
    }

    @MainActor
    func testGPSDefersFirstPromptUntilActiveAndDoesNotReviveDisabledSession() {
        let suite = "GPSForegroundPermission-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        var active = false
        manager.authorization = .notDetermined
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .notDetermined }, applicationIsActive: { active })
        coordinator.setEnabled(true)
        XCTAssertEqual(manager.foregroundRequests, 0)
        active = true
        coordinator.resumeAuthorizationIfNeeded()
        XCTAssertEqual(manager.foregroundRequests, 1)
        coordinator.setEnabled(false)
        manager.authorization = .authorizedWhenInUse
        coordinator.locationManagerDidChangeAuthorization(manager)
        coordinator.resumeAuthorizationIfNeeded()
        XCTAssertEqual(transport.starts, 0)
        XCTAssertFalse(coordinator.state.enabled)
    }

    @MainActor
    func testExistingLocationGrantDefersFirstBluetoothPromptUntilActive() {
        let suite = "GPSDeferredBluetooth-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        var active = false
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .notDetermined }, applicationIsActive: { active })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(coordinator.state.status, .starting)
        active = true
        coordinator.resumeAuthorizationIfNeeded()
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(manager.foregroundRequests, 0)
        XCTAssertEqual(manager.backgroundRequests, 0)
    }

    @MainActor
    func testPermissionReturnDoesNotRetryCameraPairingErrorsOrAPBlockedGPS() {
        let suite = "GPSPermissionOwnership-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        transport.emit(.failed("Camera pairing handshake timeout"))
        coordinator.resumeAuthorizationIfNeeded()
        XCTAssertEqual(transport.starts, 1)
        coordinator.setAPModeBlocked(true)
        manager.authorization = .notDetermined
        coordinator.resumeAuthorizationIfNeeded()
        coordinator.retryOrOpenSettings { XCTFail("AP must retain ownership") }
        XCTAssertEqual(manager.foregroundRequests, 0)
        XCTAssertEqual(coordinator.state.status, .apUnavailable)
        for event: NikonGPSBluetoothState in [.scanning, .connecting("Late"), .ready("Late"), .disconnected, .failed("Camera not found")] {
            coordinator.applyBluetoothState(event)
            XCTAssertEqual(coordinator.state.status, .apUnavailable)
            XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
        }
    }

    @MainActor
    func testGPSRevocationBlocksLateReadyAndCancelsPendingWriteACK() async throws {
        let suite = "GPSRevocation-\(UUID())", manager = GPSControlledLocationManager()
        let defaults = UserDefaults(suiteName: suite)!, transport = GPSControlledTransport()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager,
            locationServicesQuery: { $0(true) }, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        transport.emit(.ready("Camera"))
        coordinator.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 31, longitude: 121)])
        for _ in 0..<100 where transport.payloads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 1)
        manager.authorization = .denied
        coordinator.locationManagerDidChangeAuthorization(manager)
        transport.complete(0, success: true)
        transport.emit(.scanning)
        transport.emit(.disconnected)
        transport.emit(.ready("Camera"))
        coordinator.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 32, longitude: 122)])
        coordinator.scheduleWriteIfDue(force: true)
        await Task.yield()
        XCTAssertEqual(coordinator.state.permissionIssue, .locationDenied)
        XCTAssertNil(coordinator.state.lastSentAt)
        XCTAssertFalse(manager.updating)
        XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
        XCTAssertEqual(transport.payloads.count, 1)
    }

    func testGPSPermissionDescriptionsPresentInBuiltApp() {
        for key in ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription", "NSBluetoothAlwaysUsageDescription"] {
            XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").isEmpty, key)
        }
    }

    func testManualSyncPresentationMatchesEveryAndroidStatus() {
        let allowed: Set<GPSStatus> = [.pairingSuccess, .connected, .waitingFix, .ready]
        let statuses: [GPSStatus] = [.off, .starting, .searching, .needsCamera, .connecting,
            .pairing, .cameraConfirm, .pairingSuccess, .connected, .writing, .waitingFix,
            .ready, .apUnavailable, .error]
        for status in statuses {
            let state = GPSState(enabled: true, status: status, latitude: 0, longitude: 0)
            XCTAssertEqual(state.canSyncNow, allowed.contains(status), status.rawValue)
            var missing = state
            missing.latitude = nil
            XCTAssertFalse(missing.canSyncNow)
            missing = state; missing.longitude = nil
            XCTAssertFalse(missing.canSyncNow)
            missing = state; missing.enabled = false
            XCTAssertFalse(missing.canSyncNow)
        }
    }

    @MainActor
    func testManualSyncUsesLatestFixSerializesTapsAndReanchorsOnlyAfterSuccess() async throws {
        let suite = "GPSSyncNow-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let transport = GPSControlledTransport(), manager = GPSControlledLocationManager()
        let clock = GPSDeferredClock()
        var time = Date()
        let coordinator = GPSCoordinator(defaults: storage, bluetooth: transport,
            locationManager: manager, now: { time }, writeSleep: { await clock.wait($0) })
        defer { coordinator.setEnabled(false) }
        coordinator.setFrequency(.fiveMinutes)
        coordinator.setEnabled(true)
        transport.emit(.ready("Camera"))
        func fix(_ latitude: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: 121), altitude: 83,
                horizontalAccuracy: 5, verticalAccuracy: 1, timestamp: time)
        }
        coordinator.locationManager(manager, didUpdateLocations: [fix(31)])
        for _ in 0..<200 where transport.payloads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 1)
        transport.complete(0, success: true)
        let originalACK = time
        for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        time = time.addingTimeInterval(10)
        coordinator.locationManager(manager, didUpdateLocations: [fix(32)])
        coordinator.syncNow()
        XCTAssertEqual(transport.payloads.count, 2)
        XCTAssertEqual(transport.payloads.last?[3], 32)
        XCTAssertEqual(coordinator.state.status, .writing)
        XCTAssertEqual(coordinator.state.lastSentAt, originalACK)
        coordinator.syncNow(); coordinator.syncNow()
        XCTAssertEqual(transport.payloads.count, 2)
        await clock.release(0) // Canceled old periodic task cannot overlap the manual write.
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(transport.payloads.count, 2)
        time = time.addingTimeInterval(1)
        transport.complete(1, success: true)
        XCTAssertEqual(coordinator.state.status, .ready)
        XCTAssertEqual(coordinator.state.lastSentAt, time)
        for _ in 0..<200 where await clock.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let delays = await clock.delays
        XCTAssertEqual(delays, [300_000_000_000, 300_000_000_000])
        // The live transport is authoritative even when the UI retains READY.
        transport.emit(.disconnected)
        XCTAssertEqual(coordinator.state.status, .ready)
        XCTAssertTrue(coordinator.state.canSyncNow)
        coordinator.syncNow()
        XCTAssertEqual(transport.payloads.count, 2)
        coordinator.setEnabled(false)
        coordinator.syncNow()
        await clock.release(1)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(transport.payloads.count, 2)
        XCTAssertEqual(coordinator.state.status, .off)
    }

    @MainActor
    func testReauthenticatedSessionDoesNotInheritOldCadenceAndFailureDoesNotAdvanceTimestamp() async throws {
        let suite = "GPSNewSession-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = GPSControlledTransport(), manager = GPSControlledLocationManager()
        var time = Date()
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport,
            locationManager: manager, now: { time })
        defer { coordinator.setEnabled(false) }
        coordinator.setFrequency(.fiveMinutes)
        coordinator.setEnabled(true)
        transport.emit(.ready("Camera"))
        func fix() -> CLLocation {
            CLLocation(coordinate: .init(latitude: 31, longitude: 121), altitude: 83,
                horizontalAccuracy: 5, verticalAccuracy: 1, timestamp: time)
        }
        coordinator.locationManager(manager, didUpdateLocations: [fix()])
        for _ in 0..<200 where transport.payloads.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        transport.complete(0, success: true)
        let lastSuccess = time
        coordinator.applyBluetoothFailure("Bluetooth setup timeout")
        // Silent error recovery, without a real disconnect callback resetting lastWrite.
        time = time.addingTimeInterval(150)
        transport.start(); transport.emit(.ready("Camera"))
        coordinator.locationManager(manager, didUpdateLocations: [fix()])
        for _ in 0..<200 where transport.payloads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 2)
        transport.complete(1, success: true)
        XCTAssertEqual(coordinator.state.lastSentAt, time)
        XCTAssertNotEqual(coordinator.state.lastSentAt, lastSuccess)
        let secondSuccess = time
        time = time.addingTimeInterval(1)
        coordinator.syncNow()
        XCTAssertEqual(transport.payloads.count, 3)
        transport.complete(2, success: false)
        XCTAssertEqual(coordinator.state.lastSentAt, secondSuccess)
        XCTAssertEqual(coordinator.state.status, .error)
        coordinator.syncNow()
        XCTAssertEqual(transport.payloads.count, 3)
    }

    @MainActor
    func testWarmupUsesOnlySystemCacheAndHandsOffWithoutLateTimeoutStoppingGPS() async throws {
        let suite = "GPSWarmupHandoff-\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let transport = GPSControlledTransport(), manager = GPSControlledLocationManager()
        let clock = GPSDeferredClock()
        let coordinator = GPSCoordinator(defaults: storage, bluetooth: transport,
            locationManager: manager, warmupSleep: { await clock.wait($0) })
        defer { coordinator.setEnabled(false) }
        coordinator.setEnabled(true)
        XCTAssertTrue(manager.updating)
        XCTAssertEqual(manager.starts, 1)
        let before = coordinator.state
        let fix = CLLocation(coordinate: .init(latitude: 31, longitude: 121), altitude: -12,
            horizontalAccuracy: 5, verticalAccuracy: 1, timestamp: Date())
        manager.cachedLocation = fix
        coordinator.locationManager(manager, didUpdateLocations: [fix])
        XCTAssertEqual(coordinator.state, before)
        coordinator.syncNow(); coordinator.scheduleWriteIfDue(force: true)
        XCTAssertTrue(transport.payloads.isEmpty)
        for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        transport.emit(.ready("Camera"))
        for _ in 0..<200 where transport.payloads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(coordinator.state.latitude, 31)
        XCTAssertEqual(coordinator.state.altitudeMeters, -12)
        XCTAssertEqual(manager.starts, 2)
        let stops = manager.stops
        await clock.release(0)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(manager.updating)
        XCTAssertEqual(manager.stops, stops)
        XCTAssertEqual(transport.payloads.count, 1)
    }

    @MainActor
    func testWarmupTimeoutAndShutdownPathsDoNotRestartLocationOnBackgroundRetry() async throws {
        for action in ["timeout", "off", "ap", "failure", "disconnect", "adapter", "clear", "destroy"] {
            let suite = "GPSWarmupStop-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let transport = GPSControlledTransport(), manager = GPSControlledLocationManager()
            let clock = GPSDeferredClock(), recovery = GPSDeferredClock()
            var coordinator: GPSCoordinator? = GPSCoordinator(defaults: defaults, bluetooth: transport,
                locationManager: manager, warmupSleep: { await clock.wait($0) },
                recoverySleep: { await recovery.wait($0) })
            coordinator?.setEnabled(true)
            XCTAssertTrue(manager.updating, action)
            for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
            let delays = await clock.delays
            XCTAssertEqual(delays, [30_000_000_000])
            switch action {
            case "off": coordinator?.setEnabled(false)
            case "ap": coordinator?.setAPModeBlocked(true)
            case "failure": transport.emit(.failed("Bluetooth setup timeout"))
            case "disconnect": transport.emit(.disconnected)
            case "adapter": transport.emit(.unavailable)
            case "clear": coordinator?.clearPairing()
            case "destroy": coordinator = nil
            default: break
            }
            if action != "timeout" { XCTAssertFalse(manager.updating, action) }
            await clock.release(0)
            for _ in 0..<200 where manager.updating { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(manager.updating, action)
            if action == "failure" {
                for _ in 0..<200 where await recovery.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
                await recovery.release(0)
                for _ in 0..<200 where transport.starts < 2 { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(transport.starts, 2)
                XCTAssertEqual(manager.starts, 1)
            }
            coordinator?.setEnabled(false)
            coordinator = nil
        }
    }

    @MainActor
    func testSavedSetupDeadlineClosesBeforeFailureAndCancelsOnRetirement() async throws {
        for action in ["expire", "stop", "adapter", "obsolete", "fresh"] {
            let suite = "GPSSetupDeadline-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let clock = GPSDeferredClock()
            let client = NikonGPSBluetoothClient(savedDevice: action == "fresh" ? nil : 123,
                savedNonce: action == "fresh" ? nil : 456, defaults: defaults,
                sleep: { await clock.wait($0) })
            var closed = false
            let subscription = client.statePublisher.sink { state in
                if state == .failed("Bluetooth setup timeout") { XCTAssertTrue(closed) }
            }
            client.beginSetupDeadline(isCurrent: { action != "obsolete" }, closeConnection: {
                client.invalidateAdapterConnection()
                closed = true
            })
            if action == "fresh" {
                try await Task.sleep(for: .milliseconds(10))
                let count = await clock.count
                XCTAssertEqual(count, 0)
            } else {
                for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
                let delays = await clock.delays
                XCTAssertEqual(delays, [15_000_000_000])
                if action == "stop" { client.stop() }
                if action == "adapter" { client.invalidateAdapterConnection() }
                await clock.release(0)
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(closed, action == "expire")
            XCTAssertEqual(client.state == .failed("Bluetooth setup timeout"), action == "expire")
            subscription.cancel()
            client.stop()
        }
    }

    @MainActor
    func testFreshPairingDoesNotPrewarmLocation() async throws {
        let suite = "GPSNoBackgroundWarmup-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = GPSControlledLocationManager(), transport = GPSControlledTransport()
        transport.hasSavedPairing = false
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager)
        coordinator.setEnabled(true)
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(manager.starts, 0)
        transport.emit(.connecting("Camera"))
        XCTAssertEqual(manager.starts, 0)
        coordinator.setEnabled(false)
    }

    @MainActor
    func testGPSPanelActualHostRendersOffAndLiveSyncStates() async throws {
        let suite = "GPSPanelSync-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = GPSControlledTransport(), manager = GPSControlledLocationManager()
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: GPSConnectionControl(coordinator: coordinator,
            expanded: .constant(true), showingResetPairing: .constant(false), availableHeight: 500)
            .frame(width: 280).padding(20).frame(width: 320, height: 500, alignment: .topLeading)
            .background(Color(white: 0.94)).environment(\.colorScheme, .light))
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        window.rootViewController = host; window.isHidden = false
        defer { coordinator.setEnabled(false); window.isHidden = true; window.rootViewController = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gps-panel-sync")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture(_ name: String) throws {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let url = directory.appendingPathComponent(name + ".png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("GPS_PANEL_IMAGE \(url.path)")
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        try capture("off")
        coordinator.setEnabled(true)
        transport.emit(.ready("Camera"))
        coordinator.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 31.2, longitude: 121.4)])
        for _ in 0..<200 where transport.payloads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 1)
        transport.complete(0, success: true)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(coordinator.state.canSyncNow)
        try capture("ready")
    }

    @MainActor
    func testCoordinatorGeoPayloadRevalidatesAltitudeOnEveryWrite() throws {
        let suite = "GPSAltitudeWrite-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = GPSCoordinator(defaults: defaults)
        let time = Date(timeIntervalSince1970: 1_735_787_045)
        func fix(latitude: Double = 31, altitude: Double = 83,
                 verticalAccuracy: Double = 1, timestamp: Date) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: 121),
                       altitude: altitude, horizontalAccuracy: 5,
                       verticalAccuracy: verticalAccuracy, timestamp: timestamp)
        }
        func payloadAltitude(_ location: CLLocation, at now: Date) throws -> UInt16 {
            let bytes = try XCTUnwrap(coordinator.prepareGeoPayload(for: location, now: now))
            XCTAssertEqual(bytes.count, 41)
            return UInt16(bytes[14]) | UInt16(bytes[15]) << 8
        }
        let original = fix(timestamp: time)
        XCTAssertEqual(try payloadAltitude(original, at: time), 83)
        XCTAssertEqual(try payloadAltitude(original, at: time.addingTimeInterval(120)), 83)
        XCTAssertEqual(try payloadAltitude(original, at: time.addingTimeInterval(120.001)), 0)
        // The five-minute ticker sees exactly the same location object.
        XCTAssertEqual(try payloadAltitude(original, at: time.addingTimeInterval(300)), 0)
        let renewed = fix(altitude: 92, timestamp: time.addingTimeInterval(301))
        XCTAssertEqual(try payloadAltitude(renewed, at: time.addingTimeInterval(301)), 92)
        let nearby = fix(altitude: 0, verticalAccuracy: -1, timestamp: time.addingTimeInterval(302))
        XCTAssertEqual(try payloadAltitude(nearby, at: time.addingTimeInterval(302)), 92)
        let distant = fix(latitude: 31.02, altitude: 0, verticalAccuracy: -1,
                          timestamp: time.addingTimeInterval(303))
        XCTAssertEqual(try payloadAltitude(distant, at: time.addingTimeInterval(303)), 0)
    }

    @MainActor
    func testDiscoveryOwnershipRejectsReplacedServiceAndSameUUIDNotifications() {
        let ownership = NikonGPSDiscoveryOwnership()
        let oldService = CBMutableService(type: CBUUID(string: "0000DE00-3DD4-4255-8D62-6DC7B9BD5561"), primary: true)
        let newService = CBMutableService(type: CBUUID(string: "0000DE00-3DD4-4255-8D62-6DC7B9BD5561"), primary: true)
        func notification(_ uuid: CBUUID) -> CBMutableCharacteristic {
            CBMutableCharacteristic(type: uuid, properties: [.notify], value: nil, permissions: [])
        }
        let oldPair = notification(CBUUID(string: "00002000-3DD4-4255-8D62-6DC7B9BD5561"))
        let oldNot1 = notification(CBUUID(string: "00002008-3DD4-4255-8D62-6DC7B9BD5561"))
        let newPair = notification(CBUUID(string: "00002000-3DD4-4255-8D62-6DC7B9BD5561"))
        let newNot1 = notification(CBUUID(string: "00002008-3DD4-4255-8D62-6DC7B9BD5561"))
        XCTAssertFalse(ownership.accepts(oldService))
        ownership.begin(oldService)
        ownership.registerNotifications([oldPair, oldNot1], for: oldService)
        XCTAssertTrue(ownership.acceptsNotification(oldNot1))
        ownership.begin(newService)
        XCTAssertFalse(ownership.accepts(oldService))
        XCTAssertFalse(ownership.acceptsNotification(oldPair))
        ownership.registerNotifications([newPair, newNot1], for: newService)
        ownership.registerNotifications([oldPair, oldNot1], for: oldService)
        XCTAssertTrue(ownership.acceptsNotification(newPair))
        XCTAssertTrue(ownership.acceptsNotification(newNot1))
        XCTAssertFalse(ownership.acceptsNotification(oldNot1))
        ownership.clear()
        XCTAssertFalse(ownership.accepts(newService))
        XCTAssertFalse(ownership.acceptsNotification(newPair))
    }

    @MainActor
    func testEnabledRecoveryRestartsTransportAndIgnoresStopDisconnect() async throws {
        for message in ["Camera not found", "Bluetooth connection failed",
                        "Camera GPS service unavailable", "GPS connection confirmation timeout"] {
            let suite = "GPSEnabledRecovery-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let transport = GPSControlledTransport()
            let clock = GPSDeferredClock()
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport,
                locationManager: GPSControlledLocationManager(), recoverySleep: { await clock.wait($0) })
            coordinator.setEnabled(true)
            XCTAssertEqual(transport.starts, 1)
            transport.emit(.failed(message))
            for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
            // stop() publishes disconnected through the real coordinator subscription.
            try await Task.sleep(for: .milliseconds(30))
            coordinator.locationManagerDidChangeAuthorization(GPSControlledLocationManager())
            XCTAssertEqual(transport.starts, 1)
            XCTAssertEqual(transport.stops, 1)
            XCTAssertTrue(coordinator.hasScheduledBluetoothRecovery)
            XCTAssertEqual(coordinator.state.message, GPSBluetoothFailurePolicy(message).message)
            let delays = await clock.delays
            XCTAssertEqual(delays, [5_000_000_000])
            await clock.release(0)
            for _ in 0..<200 where transport.starts < 2 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(transport.starts, 2)
            XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
            XCTAssertEqual(coordinator.state.status, .searching)
            coordinator.setEnabled(false)
        }
    }

    @MainActor
    func testPairingFailureWaitsForExplicitRetryThroughPublisher() async throws {
        let suite = "GPSPairingRecovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = GPSControlledTransport()
        let clock = GPSDeferredClock()
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport,
            locationManager: GPSControlledLocationManager(), recoverySleep: { await clock.wait($0) })
        coordinator.setEnabled(true)
        transport.emit(.failed("Camera pairing handshake timeout"))
        for _ in 0..<200 where coordinator.state.status != .error { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.starts, 1)
        XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
        let pending = await clock.count
        XCTAssertEqual(pending, 0)
        coordinator.locationManagerDidChangeAuthorization(GPSControlledLocationManager())
        XCTAssertEqual(transport.starts, 1)
        coordinator.retry()
        XCTAssertEqual(transport.starts, 2)
        coordinator.setEnabled(false)
    }

    @MainActor
    func testTrustedAltitudeDuringWriteForcesOneFollowupAfterACK() async throws {
        let suite = "GPSAltitudeFollowup-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = GPSControlledTransport()
        let manager = GPSControlledLocationManager()
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport, locationManager: manager)
        defer { coordinator.setEnabled(false) }
        coordinator.setFrequency(.fiveMinutes)
        coordinator.setEnabled(true)
        transport.state = .ready("Test camera")
        coordinator.applyBluetoothState(transport.state)
        func fix(_ altitude: Double, valid: Bool) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 31, longitude: 121), altitude: altitude,
                horizontalAccuracy: 5, verticalAccuracy: valid ? 1 : -1, timestamp: Date())
        }
        coordinator.locationManager(manager, didUpdateLocations: [fix(0, valid: false)])
        for _ in 0..<200 where transport.payloads.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 1)
        let first = try XCTUnwrap(transport.payloads.first)
        XCTAssertEqual(UInt16(first[14]) | UInt16(first[15]) << 8, 0)
        coordinator.locationManager(manager, didUpdateLocations: [fix(83, valid: true)])
        coordinator.locationManager(manager, didUpdateLocations: [fix(92, valid: true)])
        XCTAssertEqual(transport.payloads.count, 1)
        transport.complete(0, success: true)
        for _ in 0..<200 where transport.payloads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 2)
        let followup = try XCTUnwrap(transport.payloads.last)
        XCTAssertEqual(UInt16(followup[14]) | UInt16(followup[15]) << 8, 92)
        transport.complete(1, success: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.payloads.count, 2)
        XCTAssertNotNil(coordinator.state.lastSentAt)
    }

    @MainActor
    func testCoordinatorWritesExpiredAltitudeOnTickerAndRejectsLateACK() async throws {
        let suite = "GPSWritePipeline-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let transport = GPSControlledTransport()
        let manager = GPSControlledLocationManager()
        var time = Date()
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: transport,
            locationManager: manager, now: { time }, writeSleep: { await clock.wait($0) })
        coordinator.setFrequency(.fiveMinutes)
        coordinator.setEnabled(true)
        transport.state = .ready("Test camera")
        coordinator.applyBluetoothState(transport.state)
        let fix = CLLocation(coordinate: .init(latitude: 31, longitude: 121), altitude: 83,
            horizontalAccuracy: 5, verticalAccuracy: 1, timestamp: time)
        coordinator.locationManager(manager, didUpdateLocations: [fix])
        for _ in 0..<200 where transport.payloads.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 1)
        let first = try XCTUnwrap(transport.payloads.first)
        XCTAssertEqual(UInt16(first[14]) | UInt16(first[15]) << 8, 83)
        transport.complete(0, success: true)
        XCTAssertEqual(coordinator.state.lastSentAt, time)
        for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let delays = await clock.delays
        XCTAssertEqual(delays, [300_000_000_000])
        time = time.addingTimeInterval(300)
        await clock.release(0)
        for _ in 0..<200 where transport.payloads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.payloads.count, 2)
        let second = try XCTUnwrap(transport.payloads.last)
        XCTAssertEqual(UInt16(second[14]) | UInt16(second[15]) << 8, 0)
        coordinator.setEnabled(false)
        transport.complete(1, success: true)
        XCTAssertEqual(coordinator.state.status, .off)
        XCTAssertNil(coordinator.state.lastSentAt)
    }

    @MainActor
    func testWriteSchedulingCannotReviveDisabledGPS() async throws {
        let suite = "GPSDisabledWrite-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = GPSCoordinator(defaults: defaults)
        coordinator.setEnabled(false)
        for (force, failure) in [(false, false), (true, false), (false, true)] {
            coordinator.scheduleWriteIfDue(force: force, afterFailure: failure)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(coordinator.state.enabled)
            XCTAssertEqual(coordinator.state.status, .off)
        }
        coordinator.setAPModeBlocked(true)
        coordinator.setEnabled(true)
        let blockedStatus = coordinator.state.status
        coordinator.scheduleWriteIfDue(force: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.state.status, blockedStatus)
        coordinator.setEnabled(false)
    }

    @MainActor
    func testDisablingGPSRejectsLateRecoveryAndBluetoothStates() async throws {
        let suite = "GPSDisabledLate-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: GPSControlledTransport(),
            locationManager: GPSControlledLocationManager(), bluetoothAuthorization: { .allowedAlways },
            recoverySleep: { await clock.wait($0) })
        coordinator.setEnabled(true)
        coordinator.applyBluetoothState(.failed("Camera not found"))
        for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let pending = await clock.count
        XCTAssertEqual(pending, 1)
        coordinator.setEnabled(false)
        await clock.release(0)
        for event: NikonGPSBluetoothState in [.scanning, .connecting("Late"), .ready("Late"), .disconnected, .failed("Camera not found")] {
            coordinator.applyBluetoothState(event)
            XCTAssertFalse(coordinator.state.enabled)
            XCTAssertEqual(coordinator.state.status, .off)
            XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.state.status, .off)
        XCTAssertNil(defaults.object(forKey: GPSPreferences.legacyEnabled))
    }

    @MainActor
    func testSupersededRecoveryCannotClearCurrentRecovery() async throws {
        let suite = "GPSRecoveryReplacement-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let coordinator = GPSCoordinator(defaults: defaults, bluetooth: GPSControlledTransport(),
            locationManager: GPSControlledLocationManager(), bluetoothAuthorization: { .allowedAlways },
            recoverySleep: { await clock.wait($0) })
        coordinator.setEnabled(true)
        defer { coordinator.setEnabled(false) }
        for (index, message) in ["Camera not found", "GPS connection confirmation timeout"].enumerated() {
            coordinator.applyBluetoothState(.failed(message))
            for _ in 0..<200 where await clock.count <= index {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let delays = await clock.delays
        XCTAssertEqual(delays, [5_000_000_000, 5_000_000_000])
        await clock.release(0)
        // The injected sleep deliberately ignores cancellation, like a late callback.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(coordinator.state.enabled)
        XCTAssertTrue(coordinator.hasScheduledBluetoothRecovery)
        XCTAssertEqual(coordinator.state.message, "GPS connection confirmation timeout")
        await clock.release(1)
        for _ in 0..<200 where coordinator.hasScheduledBluetoothRecovery {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
        XCTAssertEqual(coordinator.state.message, "GPS connection confirmation timeout")
    }

    @MainActor
    func testAdapterTerminalStatesCancelPendingRecovery() async throws {
        for (event, message) in [(NikonGPSBluetoothState.unauthorized, "需要蓝牙权限"),
                                 (.unavailable, "请打开手机蓝牙")] {
            let suite = "GPSAdapterRecovery-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let clock = GPSDeferredClock()
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: GPSControlledTransport(),
                locationManager: GPSControlledLocationManager(), bluetoothAuthorization: { .allowedAlways },
                recoverySleep: { await clock.wait($0) })
            coordinator.setEnabled(true)
            coordinator.applyBluetoothState(.failed("Camera not found"))
            for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
            let delays = await clock.delays
            XCTAssertEqual(delays, [5_000_000_000])
            XCTAssertTrue(coordinator.hasScheduledBluetoothRecovery)
            coordinator.applyBluetoothState(event)
            XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
            XCTAssertEqual(coordinator.state.status, .error)
            XCTAssertEqual(coordinator.state.message, message)
            await clock.release(0)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
            XCTAssertEqual(coordinator.state.message, message)
            coordinator.setEnabled(false)
        }
    }

    @MainActor
    func testCoordinatorFailurePresentationAndRetryAreIndependent() async throws {
        let cases: [(String, GPSStatus, String, Bool)] = [
            ("Camera not found", .needsCamera, "请在相机上打开蓝牙配对", true),
            ("Camera pairing handshake timeout", .error, "Camera pairing handshake timeout", false),
            ("Camera pairing rejected", .needsCamera, "请在相机上打开蓝牙配对", false),
            ("Camera pairing identity expired", .needsCamera, "请在相机上打开蓝牙配对", false),
            ("Bluetooth permission required", .error, "需要蓝牙权限", false),
            ("Bluetooth unavailable", .error, "请打开手机蓝牙", false),
            ("Bluetooth scan failed", .error, "请打开手机蓝牙", true),
            ("GPS connection confirmation timeout", .error, "GPS connection confirmation timeout", true)
        ]
        let legacyKeys = ["gps.pairing.device", "gps.pairing.nonce"]
        let legacy = legacyKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(legacyKeys, legacy) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for (message, status, display, retries) in cases {
            let suite = "GPSRecovery-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let clock = GPSDeferredClock()
            let coordinator = GPSCoordinator(defaults: defaults, recoverySleep: { await clock.wait($0) })
            coordinator.applyBluetoothFailure(message)
            XCTAssertEqual(coordinator.state.status, status, message)
            XCTAssertEqual(coordinator.state.message, display, message)
            XCTAssertEqual(coordinator.hasScheduledBluetoothRecovery, retries, message)
            if retries {
                for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
                let delays = await clock.delays
                XCTAssertEqual(delays, [5_000_000_000])
                coordinator.applyBluetoothFailure("Camera pairing handshake timeout")
                XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
                await clock.release(0)
                for _ in 0..<20 { await Task.yield() }
                XCTAssertEqual(coordinator.state.message, "Camera pairing handshake timeout")
                XCTAssertFalse(coordinator.hasScheduledBluetoothRecovery)
            }
        }
    }

    @MainActor
    func testHandshakeDeadlineStageReplacementAndControllerIDCancellation() async throws {
        let suite = "GPSHandshakeDeadline-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let client = NikonGPSBluetoothClient(defaults: defaults, sleep: { await clock.wait($0) })
        for index in 0..<4 {
            client.beginPairingDeadline(restoringIdentity: index != 1)
            for _ in 0..<200 where await clock.count <= index {
                try await Task.sleep(for: .milliseconds(5))
            }
            if index == 0 {
                await clock.release(0)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(client.state, .failed("Camera pairing identity expired"))
            } else if index == 1 {
                await clock.release(1)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(client.state, .failed("Camera pairing handshake timeout"))
            } else if index == 3 {
                await clock.release(2)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(client.state, .failed("Camera pairing handshake timeout"))
                XCTAssertNotNil(client.takeControllerIDPayload())
                await clock.release(3)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(client.state, .failed("Camera pairing handshake timeout"))
            }
        }
        let delays = await clock.delays
        XCTAssertEqual(delays, Array(repeating: 7_000_000_000, count: 4))
        client.stop()
    }

    @MainActor
    func testConnectionRetirementWaitsForExactOwnerAndKeepsNewestRequest() {
        let retirement = NikonGPSConnectionRetirement()
        let old = NSObject(), unrelated = NSObject()
        var starts: [Int] = []
        retirement.begin(old)
        XCTAssertTrue(retirement.deferIfNeeded { starts.append(1) })
        XCTAssertTrue(retirement.deferIfNeeded { starts.append(2) })
        XCTAssertFalse(retirement.finish(unrelated))
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(retirement.finish(old))
        XCTAssertEqual(starts, [2])
        XCTAssertFalse(retirement.finish(old))
        XCTAssertFalse(retirement.deferIfNeeded { starts.append(3) })
        XCTAssertEqual(starts, [2])
        retirement.begin(old)
        XCTAssertTrue(retirement.deferIfNeeded { starts.append(4) })
        retirement.cancelPending()
        XCTAssertTrue(retirement.contains(old), "Stop must still fence old callbacks")
        XCTAssertTrue(retirement.finish(old))
        XCTAssertEqual(starts, [2])
        retirement.begin(old)
        XCTAssertTrue(retirement.deferIfNeeded { starts.append(5) })
        retirement.invalidate()
        XCTAssertFalse(retirement.contains(old))
        XCTAssertFalse(retirement.finish(old))
        XCTAssertEqual(starts, [2])
    }

    @MainActor
    func testRetirementCompletionCanSynchronouslyStartAndStopAnotherConnection() {
        let retirement = NikonGPSConnectionRetirement()
        let peripheral = NSObject()
        var starts = 0
        retirement.begin(peripheral)
        XCTAssertTrue(retirement.deferIfNeeded {
            starts += 1
            // The resumed start can synchronously publish a state whose
            // subscriber stops it. This creates a new retirement immediately.
            retirement.begin(peripheral)
            XCTAssertTrue(retirement.deferIfNeeded { starts += 100 })
            retirement.cancelPending()
        })
        XCTAssertTrue(retirement.finish(peripheral))
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(retirement.isRetiring, "Old completion must not clear the new retirement")
        XCTAssertTrue(retirement.deferIfNeeded { starts += 1 })
        XCTAssertTrue(retirement.finish(peripheral))
        XCTAssertEqual(starts, 2)
        XCTAssertFalse(retirement.isRetiring)
    }

    @MainActor
    func testSynchronousStopFromScanPublicationDoesNotRecreateDeadline() async throws {
        let suite = "GPSScanPublicationStop-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let sleepFinished = expectation(description: "Cancelled deadline sleep unwound")
        let client = NikonGPSBluetoothClient(defaults: defaults, sleep: {
            await clock.wait($0)
            XCTAssertTrue(Task.isCancelled, "Synchronous stop must cancel the registered deadline")
            sleepFinished.fulfill()
        })
        let subscription = client.statePublisher.sink { state in
            if state == .scanning {
                XCTAssertEqual(client.state, .scanning, "Lifecycle notification must follow assignment")
                client.stop()
            }
        }
        defer { subscription.cancel() }
        client.beginScanDeadline { XCTFail("Stopped scan deadline ran") }
        for _ in 0..<200 where await clock.count == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        // The injected sleep deliberately ignores cancellation, just like the
        // other deferred-clock tests. Release it and inspect the task flag.
        await clock.release(0)
        await fulfillment(of: [sleepFinished], timeout: 2)
        XCTAssertEqual(client.state, .disconnected, "Older publication must not overwrite the nested stop")
    }

    @MainActor
    func testAdapterLossCancelsOutstandingConnectionDeadlines() async throws {
        let suite = "GPSAdapterLoss-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let client = NikonGPSBluetoothClient(savedDevice: 123, savedNonce: 456,
            defaults: defaults, sleep: { await clock.wait($0) })
        var reconnects = 0, scanStops = 0, pendingChecks = 0
        client.beginDirectReconnectDeadline { reconnects += 1 }
        client.beginScanDeadline { scanStops += 1 }
        client.beginPairingDeadline(restoringIdentity: true)
        client.beginIDWriteDeadline { pendingChecks += 1; return true }
        for _ in 0..<200 where await clock.count < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await clock.count
        XCTAssertEqual(count, 4)
        client.invalidateAdapterConnection()
        client.invalidateAdapterConnection()
        let stateAfterInvalidation = client.state
        for index in 0..<count { await clock.release(index) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(reconnects, 0)
        XCTAssertEqual(scanStops, 0)
        XCTAssertEqual(pendingChecks, 0)
        XCTAssertEqual(client.state, stateAfterInvalidation)
        XCTAssertTrue(client.hasSavedPairing)
        client.stop()
    }

    @MainActor
    func testUnownedCentralStateCallbackCannotReplacePendingClientState() {
        let suite = "GPSUnownedCentral-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = NikonGPSBluetoothClient(defaults: defaults)
        let unrelated = CBCentralManager(delegate: nil, queue: .main)
        client.beginScanDeadline(stopScan: {})
        client.centralManagerDidUpdateState(unrelated)
        XCTAssertEqual(client.state, .scanning)
        client.stop()
        client.centralManagerDidUpdateState(unrelated)
        XCTAssertEqual(client.state, .disconnected)
    }

    @MainActor
    func testDirectReconnectDeadlineReplacesAndCancelsLateFallback() async throws {
        let suite = "GPSDirectDeadline-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let client = NikonGPSBluetoothClient(defaults: defaults, sleep: { await clock.wait($0) })
        var fallbacks: [Int] = []
        for index in 0..<3 {
            client.beginDirectReconnectDeadline { fallbacks.append(index) }
            for _ in 0..<200 where await clock.count <= index {
                try await Task.sleep(for: .milliseconds(5))
            }
            if index == 1 {
                await clock.release(0)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(fallbacks.isEmpty)
                await clock.release(1)
                for _ in 0..<200 where fallbacks.isEmpty {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertEqual(fallbacks, [1])
            }
        }
        client.stop()
        await clock.release(2)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fallbacks, [1])
        let delays = await clock.delays
        XCTAssertEqual(delays, [4_500_000_000, 4_500_000_000, 4_500_000_000])
    }

    @MainActor
    func testScanAndSavedIdentityConfirmationDeadlinesUseAndroidDurations() async throws {
        let suite = "GPSDeadlines-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let client = NikonGPSBluetoothClient(savedDevice: 123, savedNonce: 456, defaults: defaults,
            sleep: { await clock.wait($0) })
        var scanStops = 0
        client.beginScanDeadline { scanStops += 1 }
        for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        await clock.release(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(scanStops, 1)
        XCTAssertEqual(client.state, .failed("Camera not found"))
        client.beginIDWriteDeadline(isPending: { true })
        for _ in 0..<200 where await clock.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await clock.release(1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(client.state, .failed("GPS connection confirmation timeout"))
        client.beginScanDeadline { scanStops += 1 }
        for _ in 0..<200 where await clock.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        client.stop()
        await clock.release(2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(scanStops, 1)
        XCTAssertEqual(client.state, .disconnected)
        client.beginIDWriteDeadline(isPending: { false })
        for _ in 0..<200 where await clock.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
        await clock.release(3)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(client.state, .disconnected)
        let delays = await clock.delays
        XCTAssertEqual(delays, [15_000_000_000, 3_000_000_000, 15_000_000_000, 3_000_000_000])
        let fresh = NikonGPSBluetoothClient(defaults: defaults, sleep: { _ in XCTFail("No saved-identity deadline during fresh pairing") })
        _ = fresh.preparePairingIdentity()
        fresh.beginIDWriteDeadline(isPending: { true })
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    func testMissingAnyRequiredGPSCharacteristicIsRejected() {
        let identifiers = ["2000", "2008", "2002", "2007"].map {
            CBUUID(string: "0000\($0)-3DD4-4255-8D62-6DC7B9BD5561")
        }
        let complete = Set(identifiers)
        XCTAssertTrue(NikonGPSBluetoothClient.supportsGPSCharacteristics(complete))
        for id in identifiers { XCTAssertFalse(NikonGPSBluetoothClient.supportsGPSCharacteristics(complete.subtracting([id]))) }
    }

    @MainActor
    func testControllerFallbackDoesNotPostponeOrCrossConnectionCancellation() async throws {
        let clock = GPSDeferredClock()
        let fallback = NikonGPSDeferredAction(sleep: { await clock.wait($0) })
        let queue = NikonGPSWriteQueue<NSObject>()
        let old = NSObject(), current = NSObject(), id = NSObject()
        XCTAssertTrue(fallback.schedule(after: 1_500_000_000) {
            queue.enqueue(owner: old, characteristic: id, data: Data([1]))
        })
        XCTAssertFalse(fallback.schedule(after: 1_500_000_000) { XCTFail("Duplicate postponed deadline") })
        for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        fallback.cancel()
        XCTAssertTrue(fallback.schedule(after: 1_500_000_000) {
            queue.enqueue(owner: current, characteristic: id, data: Data([2]))
        })
        for _ in 0..<200 where await clock.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await clock.release(0) // Deliberately ignores cancellation until released.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(queue.next(owner: old))
        XCTAssertNil(queue.next(owner: current))
        XCTAssertFalse(fallback.schedule(after: 1) { XCTFail("Old completion cleared new task") })
        await clock.release(1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(queue.next(owner: current)?.data, Data([2]))
        let delays = await clock.delays
        XCTAssertEqual(delays, [1_500_000_000, 1_500_000_000])
    }

    @MainActor
    func testControllerIDUsesFixedWidthAndroidASCIIWithoutUTF8Expansion() throws {
        let suite = "GPSControllerASCII-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cases: [(String, [UInt8])] = [
            ("ZTransfer", Array("ZTransfer".utf8)),
            ("", []),
            ("A\u{4E2D}\u{1F4F7}e\u{301}Z", [65, 63, 63, 101, 63, 90]),
            (String(repeating: "\u{4E2D}", count: 40), [UInt8](repeating: 63, count: 32)),
            (String(repeating: "x", count: 40), [UInt8](repeating: 120, count: 32))
        ]
        for (name, prefix) in cases {
            let client = NikonGPSBluetoothClient(controllerName: name, defaults: defaults)
            let payload = try XCTUnwrap(client.takeControllerIDPayload())
            XCTAssertEqual(payload.count, 32)
            XCTAssertEqual(Array(payload), prefix + [UInt8](repeating: 0, count: 32 - prefix.count))
            XCTAssertNil(client.takeControllerIDPayload())
        }
    }

    @MainActor
    func testNOT1ConfirmationCancelsFallbackAndEnqueuesOneProductionWrite() async throws {
        let suite = "GPSCombined-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = NikonGPSBluetoothClient(defaults: defaults)
        let queue = NikonGPSWriteQueue<NSObject>()
        let owner = NSObject(), id = NSObject()
        let clock = GPSDeferredClock()
        let fallback = NikonGPSDeferredAction(sleep: { await clock.wait($0) })
        let enqueue: @MainActor () -> Void = {
            guard let data = client.takeControllerIDPayload() else { return }
            fallback.cancel()
            queue.enqueue(owner: owner, characteristic: id, data: data)
        }
        fallback.schedule(after: 1_500_000_000, action: enqueue)
        for _ in 0..<200 where await clock.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let not1 = CBUUID(string: "00002008-3DD4-4255-8D62-6DC7B9BD5561")
        if NikonGPSBluetoothClient.notificationRoute(uuid: not1, value: Data([1, 0])) == .controllerConfirmation {
            enqueue()
            enqueue()
        }
        XCTAssertEqual(queue.next(owner: owner)?.data.count, 32)
        XCTAssertNotNil(queue.acknowledge(owner: owner, characteristic: id))
        await clock.release(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(queue.next(owner: owner))
    }

    @MainActor
    func testWriteCancellationCanSynchronouslyStartReplacementWrite() {
        let queue = NikonGPSWriteQueue<NSObject>()
        let owner = NSObject(), characteristic = NSObject()
        var outcomes: [String] = []
        queue.enqueue(owner: owner, characteristic: characteristic, data: Data([1])) { success in
            outcomes.append("old:\(success)")
            queue.enqueue(owner: owner, characteristic: characteristic, data: Data([3])) {
                outcomes.append("replacement:\($0)")
            }
            XCTAssertEqual(queue.next(owner: owner)?.data, Data([3]))
        }
        queue.enqueue(owner: owner, characteristic: characteristic, data: Data([2])) {
            outcomes.append("queued:\($0)")
        }
        XCTAssertEqual(queue.next(owner: owner)?.data, Data([1]))
        queue.cancelAll()
        XCTAssertEqual(outcomes, ["old:false", "queued:false"])
        XCTAssertTrue(queue.isPending(owner: owner, characteristic: characteristic))
        XCTAssertNil(queue.next(owner: owner))
        let completed = queue.acknowledge(owner: owner, characteristic: characteristic)
        XCTAssertEqual(completed?.data, Data([3]))
        completed?.completion?(true)
        queue.cancelAll()
        XCTAssertEqual(outcomes, ["old:false", "queued:false", "replacement:true"])
    }

    @MainActor
    func testProductionWriteQueueRejectsOldOwnerAndWrongCharacteristicACKs() {
        let queue = NikonGPSWriteQueue<NSObject>()
        let old = NSObject(), current = NSObject(), geo = NSObject(), id = NSObject()
        var outcomes: [String] = []
        queue.enqueue(owner: old, characteristic: geo, data: Data([1])) { outcomes.append("old:\($0)") }
        XCTAssertEqual(queue.next(owner: old)?.data, Data([1]))
        queue.cancelAll()
        XCTAssertEqual(outcomes, ["old:false"])
        queue.enqueue(owner: current, characteristic: geo, data: Data([2])) { outcomes.append("geo:\($0)") }
        queue.enqueue(owner: current, characteristic: id, data: Data([3])) { outcomes.append("id:\($0)") }
        XCTAssertNil(queue.acknowledge(owner: current, characteristic: geo)) // Not sent yet.
        XCTAssertNil(queue.next(owner: old))
        XCTAssertEqual(queue.next(owner: current)?.data, Data([2]))
        XCTAssertNil(queue.next(owner: current)) // Single in-flight write.
        XCTAssertNil(queue.acknowledge(owner: old, characteristic: geo)) // Same characteristic, stale owner.
        XCTAssertNil(queue.acknowledge(owner: current, characteristic: id))
        XCTAssertEqual(outcomes, ["old:false"])
        let finished = queue.acknowledge(owner: current, characteristic: geo)
        XCTAssertEqual(finished?.data, Data([2]))
        finished?.completion?(true)
        XCTAssertNil(queue.acknowledge(owner: current, characteristic: geo))
        XCTAssertEqual(queue.next(owner: current)?.data, Data([3]))
        XCTAssertNil(queue.acknowledge(owner: current, characteristic: geo))
        queue.acknowledge(owner: current, characteristic: id)?.completion?(true)
        XCTAssertEqual(outcomes, ["old:false", "geo:true", "id:true"])
        queue.cancelAll()
        XCTAssertEqual(outcomes.count, 3)
    }

    @MainActor
    func testBluetoothManagerIsLazySessionOnlyAndReusedAfterRestart() {
        let suite = "GPSBluetoothSession-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: GPSPreferences.legacyEnabled)
        var creations = 0
        let client = NikonGPSBluetoothClient(defaults: defaults, centralFactory: { delegate, options in
            creations += 1
            XCTAssertNil(options, "No restoration identifier: cold launch must not restore GPS")
            return CBCentralManager(delegate: delegate, queue: .main, options: options)
        })
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(client.state, .disconnected)
        client.stop()
        XCTAssertEqual(creations, 0)
        client.start()
        XCTAssertEqual(creations, 1)
        client.stop()
        client.start()
        XCTAssertEqual(creations, 1)
        client.stop()
        XCTAssertEqual(client.state, .disconnected)
    }

    @MainActor
    func testEnabledSessionSurvivesForegroundReturnButNotNewCoordinator() {
        let suite = "GPSSessionIntent-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstTransport = GPSControlledTransport(), firstLocation = GPSControlledLocationManager()
        var first: GPSCoordinator? = GPSCoordinator(defaults: defaults, bluetooth: firstTransport,
            locationManager: firstLocation, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
        first?.setEnabled(true)
        firstTransport.emit(.scanning)
        first?.resumeAuthorizationIfNeeded()
        XCTAssertEqual(firstTransport.starts, 1)
        XCTAssertTrue(first?.state.enabled == true)
        XCTAssertNil(defaults.object(forKey: GPSPreferences.legacyEnabled))
        first = nil
        let secondTransport = GPSControlledTransport(), secondLocation = GPSControlledLocationManager()
        let second = GPSCoordinator(defaults: defaults, bluetooth: secondTransport,
            locationManager: secondLocation, bluetoothAuthorization: { .allowedAlways }, applicationIsActive: { true })
        second.resumeAuthorizationIfNeeded()
        XCTAssertFalse(second.state.enabled)
        XCTAssertEqual(second.state.status, .off)
        XCTAssertEqual(secondTransport.starts, 0)
        XCTAssertEqual(secondLocation.starts, 0)
        second.setEnabled(true)
        XCTAssertEqual(secondTransport.starts, 1)
        second.setEnabled(false)
        XCTAssertNil(defaults.object(forKey: GPSPreferences.legacyEnabled))
    }

    @MainActor
    func testNOT1RoutesConfirmationAndControllerIDGateIsSharedWithFallback() {
        let not1 = CBUUID(string: "00002008-3DD4-4255-8D62-6DC7B9BD5561")
        let pair = CBUUID(string: "00002000-3DD4-4255-8D62-6DC7B9BD5561")
        let other = CBUUID(string: "00002007-3DD4-4255-8D62-6DC7B9BD5561")
        let ack = Data([1, 0])
        XCTAssertEqual(NikonGPSBluetoothClient.notificationRoute(uuid: not1, value: ack), .controllerConfirmation)
        XCTAssertEqual(NikonGPSBluetoothClient.notificationRoute(uuid: not1, value: Data([1])), .ignored)
        XCTAssertEqual(NikonGPSBluetoothClient.notificationRoute(uuid: not1, value: Data([1, 0, 0])), .ignored)
        XCTAssertEqual(NikonGPSBluetoothClient.notificationRoute(uuid: other, value: ack), .ignored)
        XCTAssertEqual(NikonGPSBluetoothClient.notificationRoute(uuid: pair, value: ack), .pairing)
        XCTAssertNil(NikonGPSPairingPacket.decode(ack)) // PAIR's two bytes are not a stage4 packet.
        let suite = "GPSNotifications-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = NikonGPSBluetoothClient(defaults: defaults)
        for not1First in [true, false] {
            client.stop()
            var writes: [Data] = []
            // Exercise the production gate in both notification/fallback orders.
            for isNOT1 in [not1First, !not1First, true] {
                if !isNOT1 || NikonGPSBluetoothClient.notificationRoute(uuid: not1, value: ack) == .controllerConfirmation,
                   let data = client.takeControllerIDPayload() { writes.append(data) }
            }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?.count, 32)
            XCTAssertEqual(writes.first?.prefix(9), Data("ZTransfer".utf8))
        }
        client.stop()
        XCTAssertNotNil(client.takeControllerIDPayload())
        XCTAssertNil(client.takeControllerIDPayload())
    }

    @MainActor
    func testPairingFailureClearsRuntimeIdentityOnlyForRejectionOrExpiry() {
        let legacyKeys = ["gps.pairing.device", "gps.pairing.nonce"]
        let legacy = legacyKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(legacyKeys, legacy) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for (message, invalidates) in [("Camera pairing identity expired", true),
                                      ("Camera PAIRING REJECTED", true),
                                      ("Camera pairing handshake timeout", false),
                                      ("Camera not found", false)] {
            let suite = "GPSIdentity-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(UInt32(123), forKey: GPSPreferences.deviceID)
            defaults.set(UInt32(456), forKey: GPSPreferences.nonce)
            defaults.set(true, forKey: GPSPreferences.pairingConfirmed)
            let address = UUID().uuidString
            defaults.set(address, forKey: GPSPreferences.bleAddress)
            let bluetooth = NikonGPSBluetoothClient(defaults: defaults)
            let coordinator = GPSCoordinator(defaults: defaults, bluetooth: bluetooth)
            XCTAssertTrue(coordinator.bluetooth.hasSavedPairing)
            coordinator.applyBluetoothFailure(message)
            XCTAssertEqual(coordinator.bluetooth.hasSavedPairing, !invalidates)
            XCTAssertEqual(defaults.object(forKey: GPSPreferences.deviceID) != nil, !invalidates)
            XCTAssertEqual(defaults.object(forKey: GPSPreferences.nonce) != nil, !invalidates)
            XCTAssertEqual(defaults.string(forKey: GPSPreferences.bleAddress), invalidates ? nil : address)
            coordinator.bluetooth.stop()
            let packet = bluetooth.preparePairingIdentity()
            if invalidates {
                XCTAssertFalse(packet.device == 123 && packet.nonce == 456)
            } else {
                XCTAssertEqual(packet.device, 123)
                XCTAssertEqual(packet.nonce, 456)
            }
            XCTAssertEqual((defaults.object(forKey: GPSPreferences.deviceID) as? NSNumber)?.uint32Value, invalidates ? nil : packet.device)
            XCTAssertEqual((defaults.object(forKey: GPSPreferences.nonce) as? NSNumber)?.uint32Value, invalidates ? nil : packet.nonce)
        }
    }
    #endif
    func testPairingMatchesAndroidCapturedVector() {
        let first = NikonGPSPairingPacket(stage: 1, timestamp: 0x677da144ec13e1db,
                                          device: 0x3c3ae501, nonce: 0x3fdaa451)
        let second = NikonGPSPairingPacket(stage: 2, timestamp: 0xb9943d5e8026fa29,
                                           device: 0xa8b3f2e4, nonce: 0x16d56a13)
        let third = NikonGPSPairingProtocol().stage3(for: first, stage2: second)
        XCTAssertEqual(third?.device, 0x79f1ad53)
        XCTAssertEqual(third?.nonce, 0x23838a35)
    }

    func testGeoPayloadMatchesAndroidFieldLayout() {
        let payload = NikonGeoPayloadEncoder.encode(
            latitude: 39.9042, longitude: -116.4074, altitudeMeters: -12.5,
            satellites: 14, timestamp: Date(timeIntervalSince1970: 1_735_787_045))
        guard let payload else { return XCTFail("payload rejected") }
        XCTAssertEqual(payload.count, 41)
        XCTAssertEqual(payload[2], 78)
        XCTAssertEqual(payload[3], 39)
        XCTAssertEqual(payload[4], 54)
        XCTAssertEqual(payload[7], 87)
        XCTAssertEqual(payload[8], 116)
        XCTAssertEqual(payload[9], 24)
        XCTAssertEqual(payload[12], 14)
        XCTAssertEqual(payload[13], 77)
        XCTAssertEqual(UInt16(payload[14]) | UInt16(payload[15]) << 8, 12)
        XCTAssertEqual(String(decoding: payload[25..<31], as: UTF8.self), "WGS-84")
    }

    func testCachedAltitudeInclusiveAgeAndDistanceBoundaries() {
        let time = Date(timeIntervalSince1970: 1_735_787_045)
        for distance in [999.999, 1_000] {
            XCTAssertTrue(canReuseGPSAltitude(now: time.addingTimeInterval(120), timestamp: time, distanceMeters: distance))
        }
        for distance in [1_000.001, Double.infinity, Double.nan] {
            XCTAssertFalse(canReuseGPSAltitude(now: time, timestamp: time, distanceMeters: distance))
        }
        XCTAssertFalse(canReuseGPSAltitude(now: time.addingTimeInterval(120.001), timestamp: time, distanceMeters: 0))
        XCTAssertFalse(canReuseGPSAltitude(now: Date(timeIntervalSince1970: 1), timestamp: Date(timeIntervalSince1970: 0), distanceMeters: 0))
        let invalidCached = GPSTrustedAltitudeFix(altitudeMeters: 83, latitude: 31, longitude: 121, timestamp: Date(timeIntervalSince1970: 0))
        let location = CLLocation(coordinate: .init(latitude: 31, longitude: 121), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date(timeIntervalSince1970: 1))
        XCTAssertNil(resolvedGPSAltitude(for: location, cached: invalidCached, now: location.timestamp).0)
    }

    func testAltitudePolicyReusesRecentNearbyTrustedFix() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let trusted = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 18.5,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: now,
        )
        let first = resolvedGPSAltitude(for: trusted, cached: nil, now: now)
        XCTAssertEqual(first.0, 18.5)

        let nearbyWithoutAltitude = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2310, longitude: 121.4740),
            altitude: 0,
            horizontalAccuracy: 20,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(60),
        )
        XCTAssertEqual(
            resolvedGPSAltitude(for: nearbyWithoutAltitude, cached: first.1,
                                now: now.addingTimeInterval(60)).0,
            18.5
        )
    }

    func testAltitudePolicyRejectsStaleOrDistantFix() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cached = GPSTrustedAltitudeFix(
            altitudeMeters: 22, latitude: 31.2304, longitude: 121.4737,
            timestamp: now.addingTimeInterval(-121),
        )
        let current = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2305, longitude: 121.4738),
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: now,
        )
        XCTAssertNil(resolvedGPSAltitude(for: current, cached: cached, now: now).0)

        let freshFar = GPSTrustedAltitudeFix(
            altitudeMeters: 22, latitude: 30, longitude: 120,
            timestamp: now,
        )
        XCTAssertNil(resolvedGPSAltitude(for: current, cached: freshFar, now: now).0)
    }
}

#if !SWIFT_PACKAGE
@MainActor
private final class GPSControlledTransport: GPSBluetoothTransport {
    var state = NikonGPSBluetoothState.disconnected
    private let events = PassthroughSubject<NikonGPSBluetoothState, Never>()
    var statePublisher: AnyPublisher<NikonGPSBluetoothState, Never> { events.eraseToAnyPublisher() }
    private(set) var starts = 0
    private(set) var stops = 0
    func emit(_ value: NikonGPSBluetoothState) {
        switch value {
        case .disconnected, .failed, .unauthorized, .unavailable: isRunning = false
        default: isRunning = true
        }
        state = value; events.send(value)
    }
    var hasSavedPairing = true
    private(set) var isRunning = false
    var payloads: [Data] = []
    private var completions: [Int: (Bool) -> Void] = [:]
    func start() { starts += 1; isRunning = true }
    func stop() { stops += 1; isRunning = false; emit(.disconnected) }
    func clearPairing() { stop() }
    func writeGeo(_ data: Data, completion: @escaping (Bool) -> Void) {
        completions[payloads.count] = completion
        payloads.append(data)
    }
    func complete(_ index: Int, success: Bool) { completions.removeValue(forKey: index)?(success) }
}

private final class GPSControlledLocationManager: CLLocationManager {
    var cachedLocation: CLLocation?
    override var location: CLLocation? { cachedLocation }
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var updating = false
    private weak var controlledDelegate: (any CLLocationManagerDelegate)?
    override var delegate: (any CLLocationManagerDelegate)? {
        get { controlledDelegate }
        set { controlledDelegate = newValue }
    }
    var authorization: CLAuthorizationStatus = .authorizedWhenInUse
    private(set) var foregroundRequests = 0
    private(set) var backgroundRequests = 0
    override var authorizationStatus: CLAuthorizationStatus { authorization }
    override func requestWhenInUseAuthorization() { foregroundRequests += 1 }
    override func requestAlwaysAuthorization() { backgroundRequests += 1 }
    override func startUpdatingLocation() { starts += 1; updating = true }
    override func stopUpdatingLocation() { stops += 1; updating = false }
}

@MainActor
private final class GPSControlledSystemPairing: NikonGPSSystemPairing {
    private(set) var names: [String] = []
    private var completions: [@MainActor (NikonGPSSystemPairingResult) -> Void] = []
    private(set) var cancellations = 0
    func pair(cameraName: String, completion: @escaping @MainActor (NikonGPSSystemPairingResult) -> Void) {
        names.append(cameraName); completions.append(completion)
    }
    func cancel() { cancellations += 1 }
    func complete(_ index: Int, _ result: NikonGPSSystemPairingResult) { completions[index](result) }
}

private actor GPSDeferredClock {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var delays: [UInt64] = []
    var count: Int { delays.count }
    func wait(_ delay: UInt64) async {
        let index = delays.count
        delays.append(delay)
        await withCheckedContinuation { continuations[index] = $0 }
    }
    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
}
#endif
