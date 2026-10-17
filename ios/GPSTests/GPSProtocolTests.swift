import Foundation
import CoreLocation
import XCTest
#if !SWIFT_PACKAGE
import CoreBluetooth
import Combine
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
        let coordinator = GPSCoordinator(defaults: defaults, recoverySleep: { await clock.wait($0) })
        coordinator.setAPModeBlocked(true)
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
        XCTAssertFalse(defaults.bool(forKey: GPSPreferences.enabled))
    }

    @MainActor
    func testSupersededRecoveryCannotClearCurrentRecovery() async throws {
        let suite = "GPSRecoveryReplacement-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = GPSDeferredClock()
        let coordinator = GPSCoordinator(defaults: defaults, recoverySleep: { await clock.wait($0) })
        // Exercise the enabled coordinator while keeping system BLE/location stopped.
        coordinator.setAPModeBlocked(true)
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
            let coordinator = GPSCoordinator(defaults: defaults, recoverySleep: { await clock.wait($0) })
            // Enable the real state machine without starting system location/BLE.
            coordinator.setAPModeBlocked(true)
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
    func testSystemRestorationCannotReviveStoppedClientOrReplayConsumedLaunch() {
        let suite = "GPSRestoration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: GPSPreferences.enabled)
        let initial = NikonGPSBluetoothClient(defaults: defaults)
        XCTAssertTrue(initial.takeRestorationPermission())
        XCTAssertFalse(initial.takeRestorationPermission())
        let stopped = NikonGPSBluetoothClient(defaults: defaults)
        stopped.stop()
        // Enabled remains persisted during pairing-error/user-action stops.
        XCTAssertTrue(defaults.bool(forKey: GPSPreferences.enabled))
        XCTAssertFalse(stopped.takeRestorationPermission())
        XCTAssertEqual(stopped.state, .disconnected)
        defaults.set(false, forKey: GPSPreferences.enabled)
        let disabled = NikonGPSBluetoothClient(defaults: defaults)
        XCTAssertFalse(disabled.takeRestorationPermission())
        defaults.set(true, forKey: GPSPreferences.enabled)
        XCTAssertFalse(disabled.takeRestorationPermission())
        XCTAssertTrue(NikonGPSBluetoothClient(defaults: defaults).takeRestorationPermission())
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
            XCTAssertEqual((defaults.object(forKey: GPSPreferences.deviceID) as? NSNumber)?.uint32Value, packet.device)
            XCTAssertEqual((defaults.object(forKey: GPSPreferences.nonce) as? NSNumber)?.uint32Value, packet.nonce)
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
    func emit(_ value: NikonGPSBluetoothState) { state = value; events.send(value) }
    var hasSavedPairing: Bool { true }
    var payloads: [Data] = []
    private var completions: [Int: (Bool) -> Void] = [:]
    func start() { starts += 1 }
    func stop() { stops += 1; emit(.disconnected) }
    func clearPairing() { stop() }
    func writeGeo(_ data: Data, completion: @escaping (Bool) -> Void) {
        completions[payloads.count] = completion
        payloads.append(data)
    }
    func complete(_ index: Int, success: Bool) { completions.removeValue(forKey: index)?(success) }
}

private final class GPSControlledLocationManager: CLLocationManager {
    private weak var controlledDelegate: (any CLLocationManagerDelegate)?
    override var delegate: (any CLLocationManagerDelegate)? {
        get { controlledDelegate }
        set { controlledDelegate = newValue }
    }
    override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    override func requestAlwaysAuthorization() {}
    override func startUpdatingLocation() {}
    override func stopUpdatingLocation() {}
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
