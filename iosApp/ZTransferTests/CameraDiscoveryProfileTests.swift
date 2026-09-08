import Foundation
import Network
import XCTest
@testable import ZTransfer

final class CameraDiscoveryProfileTests: XCTestCase {
    @MainActor func testColdStartWithCorruptHistoryStillOffersPairingProfilesAndExplicitRecovery() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        try profiles.markPaired(firstGUID)
        let file = root.appendingPathComponent("history.json"), bytes = Data("broken before launch".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try CameraEndpointHistory(file: file))
        let recovery = try CameraEndpointHistory(file: file, validateOnOpen: false)
        let coordinator = CameraDiscoveryCoordinator(history: recovery, profiles: profiles)
        XCTAssertEqual(coordinator.profiles.map(\.responderGUID), [firstGUID]); XCTAssertNotNil(coordinator.message)
        XCTAssertThrowsError(try recovery.recordSuccessful(responderGUID: firstGUID, displayName: "Camera",
            address: CameraEndpointAddress.parse("192.168.10.7")))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let archive = try XCTUnwrap(coordinator.resetHistoryAfterConfirmation(confirmed: true))
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertTrue(try profiles.isPaired(firstGUID)); XCTAssertNil(coordinator.message)
    }
    @MainActor func testBrokenAddressHistoryKeepsIndependentPairingProfilesVisible() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let history = try CameraEndpointHistory(file: file)
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        try profiles.markPaired(firstGUID)
        let coordinator = CameraDiscoveryCoordinator(history: history, profiles: profiles)
        let damaged = Data("broken".utf8); try damaged.write(to: file)
        coordinator.reloadProfiles()
        XCTAssertNotNil(coordinator.message)
        XCTAssertEqual(coordinator.profiles.map(\.responderGUID), [firstGUID])
        XCTAssertEqual(coordinator.profiles.first?.paired, true)
        XCTAssertNil(coordinator.profiles.first?.address)
        XCTAssertNil(coordinator.selectProfile(responderGUID: firstGUID))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }
    @MainActor func testPartialForgetNeverLeavesStaleTrustedRowAndKeepsOtherCamera() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let history = try CameraEndpointHistory(file: file)
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        let identity = profiles.identity
        try profiles.markPaired(firstGUID); try profiles.markPaired(secondGUID)
        let coordinator = CameraDiscoveryCoordinator(history: history, profiles: profiles)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try coordinator.forgetProfile(responderGUID: firstGUID, confirmed: true))
        XCTAssertFalse(try profiles.isPaired(firstGUID)); XCTAssertTrue(try profiles.isPaired(secondGUID))
        XCTAssertEqual(coordinator.profiles.map(\.responderGUID), [secondGUID])
        XCTAssertEqual(profiles.identity, identity)
    }
    @MainActor func testForgetThenAcknowledgedRepairRestoresOnlySelectedCamera() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let identityFile = root.appendingPathComponent("identity.json")
        let historyFile = root.appendingPathComponent("history.json")
        let profiles = try StationProfileStore(file: identityFile)
        let history = try CameraEndpointHistory(file: historyFile, now: { 10 })
        let identity = profiles.identity
        for guid in [firstGUID, secondGUID] {
            try profiles.markPaired(guid)
            try history.recordSuccessful(responderGUID: guid, displayName: guid, address: CameraEndpointAddress.parse("192.168.10.7"))
        }
        let coordinator = CameraDiscoveryCoordinator(history: history, profiles: profiles)
        try coordinator.forgetProfile(responderGUID: firstGUID, confirmed: true)
        XCTAssertNil(try history.select(responderGUID: firstGUID))
        XCTAssertEqual(try StationProfileStore(file: identityFile).identity, identity)
        // This is the same acknowledgement-only store entry invoked by CameraWiFiConnection.
        try profiles.markPaired(firstGUID)
        try history.recordSuccessful(responderGUID: firstGUID, displayName: "Repaired", address: CameraEndpointAddress.parse("192.168.10.8"))
        let reopened = try CameraDiscoveryCoordinator(history: CameraEndpointHistory(file: historyFile), profiles: StationProfileStore(file: identityFile))
        XCTAssertEqual(reopened.profiles.count, 2)
        XCTAssertEqual(reopened.selectProfile(responderGUID: firstGUID)?.host, "192.168.10.8")
        XCTAssertTrue(try profiles.isPaired(secondGUID))
    }
    func testIdentitySymlinkIsRejectedWithoutChangingItsTarget() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("identity-original.json")
        _ = try StationProfileStore(file: original)
        let before = try Data(contentsOf: original)
        let link = root.appendingPathComponent("identity-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try StationProfileStore(file: link))
        XCTAssertEqual(try Data(contentsOf: original), before)
    }
    private let firstGUID = "00112233445566778899aabbccddeeff"
    private let secondGUID = "ffeeddccbbaa99887766554433221100"

    func testSharedEndpointValidationNormalizesIPv4IPv6AndHostnameWithoutResolution() throws {
        XCTAssertEqual(try CameraEndpointAddress.parse(" 192.168.1.2 ").host, "192.168.1.2")
        XCTAssertEqual(try CameraEndpointAddress.parse("[FE80::1%en0]").host, "fe80::1%en0")
        XCTAssertEqual(try CameraEndpointAddress.parse("NIKON.local.").host, "nikon.local")
        XCTAssertEqual(try CameraEndpointAddress.parse("::ffff:192.168.1.2").port, 15740)
        for invalid in ["http://camera", "camera:15740", "[::1]:15740", "a b", "01.2.3.4", "192.168.1", "256.1.1.1", "1::2::3", "camera/path"] {
            XCTAssertThrowsError(try CameraEndpointAddress.parse(invalid), invalid)
        }
    }

    func testBonjourCoalescesSameAdvertisedInstanceButRetainsAlternativeEndpoints() {
        let nikon = endpoint("My Nikon", type: "_nikon._tcp")
        let ptp = endpoint("My Nikon", type: "_ptp._tcp")
        let grouped = CameraBonjourService.coalesced([nikon, ptp, ptp])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].endpoint, ptp)
        XCTAssertEqual(grouped[0].alternatives, [nikon])
        XCTAssertNotEqual(CameraBonjourService.coalesced([nikon]).first?.id, grouped[0].id,
            "Removing the selected PTP service must not silently reroute its retry to Nikon")
        XCTAssertEqual(grouped[0].selectableAlternatives.first?.endpoint, nikon)
        XCTAssertNotEqual(grouped[0].selectableAlternatives.first?.id, grouped[0].id)
        XCTAssertEqual(CameraBonjourService.coalesced([nikon]).first?.id, grouped[0].selectableAlternatives.first?.id)
    }

    func testBonjourDoesNotMergeDifferentInstancesOrDomainsAndIgnoresOtherServiceTypes() {
        let first = endpoint("Camera A"), second = endpoint("Camera B")
        let foreign = NWEndpoint.service(name: "Camera A", type: "_ptp._tcp", domain: "other.local.", interface: nil)
        let unrelated = endpoint("Printer", type: "_ipp._tcp")
        let values = CameraBonjourService.coalesced([first, second, foreign, unrelated, .hostPort(host: "192.168.1.2", port: 15740)])
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(Set(values.map(\.id)).count, 3)
    }

    func testDiscoveryStopRejectsLateCallbacksAndRestartDropsOldGeneration() async throws {
        let pool = ProfileBrowserPool()
        let discovery = CameraBonjourDiscovery(browserFactory: { pool.make($0) })
        let sink = ProfileDiscoverySink()
        let observer = Task { for await value in discovery.updates { await sink.append(value) } }
        defer { observer.cancel(); discovery.stop() }
        discovery.start(timeout: 5)
        try await until { pool.count == 2 }
        let old = try XCTUnwrap(pool.browser(at: 0))
        try await until { old.ready }
        let late = try XCTUnwrap(old.savedResults())
        old.emit([endpoint("Old")])
        try await until { await sink.latest?.services.first?.name == "Old" }
        discovery.stop()
        try await until { await sink.latest?.searching == false }
        late([endpoint("Stale")])
        try await Task.sleep(nanoseconds: 70_000_000)
        let stopped = await sink.latest
        XCTAssertEqual(stopped?.services.first?.name, "Old")
        discovery.start(timeout: 5)
        try await until { pool.count == 4 }
        let fresh = try XCTUnwrap(pool.browser(at: 2))
        try await until { fresh.ready }
        late([endpoint("Still stale")]); fresh.emit([endpoint("New")])
        try await until { await sink.latest?.services.first?.name == "New" }
        XCTAssertTrue(old.cancelled)
    }

    func testDiscoveryTimeoutStopsBrowserWithoutInferringLocalNetworkPermissionDenial() async throws {
        let pool = ProfileBrowserPool()
        let discovery = CameraBonjourDiscovery(browserFactory: { pool.make($0) })
        let sink = ProfileDiscoverySink()
        let observer = Task { for await value in discovery.updates { await sink.append(value) } }
        defer { observer.cancel(); discovery.stop() }
        discovery.start(timeout: 0.05)
        try await until { await sink.latest?.searching == false }
        let snapshot = await sink.latest
        XCTAssertTrue(snapshot?.services.isEmpty == true)
        XCTAssertTrue(snapshot?.message?.contains("不能据此判定") == true)
        XCTAssertTrue(pool.allCancelled)
    }

    func testHistoryStoresOnlySuccessfulEndpointsScopedToResponderAndReloadsDurably() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let history = try CameraEndpointHistory(file: file, now: { 1234 })
        XCTAssertTrue(try history.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Opening history must not imply a successful connection")
        try history.recordSuccessful(responderGUID: firstGUID, displayName: "Camera A", address: CameraEndpointAddress.parse("192.168.1.2"))
        try history.recordSuccessful(responderGUID: secondGUID, displayName: "Camera B", address: CameraEndpointAddress.parse("192.168.1.2"))
        let reloaded = try CameraEndpointHistory(file: file)
        XCTAssertEqual(try reloaded.entries().count, 2, "One IP can be reused by different cameras")
        XCTAssertEqual(try reloaded.select(responderGUID: firstGUID)?.displayName, "Camera A")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNil(json["initiator"]); XCTAssertNil(json["identity"]); XCTAssertNil(json["pairedResponders"])
    }

    func testLastSuccessfulAddressReplacesOnlyTheSameCameraAndForgetPreservesOtherRecords() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = try CameraEndpointHistory(file: root.appendingPathComponent("history.json"), now: { 100 })
        try history.recordSuccessful(responderGUID: firstGUID, displayName: "A", address: CameraEndpointAddress.parse("192.168.1.2"))
        try history.recordSuccessful(responderGUID: secondGUID, displayName: "B", address: CameraEndpointAddress.parse("192.168.1.3"))
        try history.recordSuccessful(responderGUID: firstGUID.uppercased(), displayName: "A new", address: CameraEndpointAddress.parse("camera.local"))
        XCTAssertEqual(try history.entries().count, 2)
        XCTAssertEqual(try history.select(responderGUID: firstGUID)?.address.host, "camera.local")
        try history.forget(responderGUID: firstGUID)
        XCTAssertNil(try history.select(responderGUID: firstGUID))
        XCTAssertEqual(try history.select(responderGUID: secondGUID)?.address.host, "192.168.1.3")
    }

    func testCorruptAndFutureHistoryNeverOverwrittenAndConfirmedResetArchivesExactBytes() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json")
        for original in [Data("broken".utf8), Data("{\"version\":99,\"entries\":[]}".utf8)] {
            try original.write(to: file)
            XCTAssertThrowsError(try CameraEndpointHistory(file: file))
            XCTAssertThrowsError(try CameraEndpointHistory.reset(file: file, confirmed: false))
            XCTAssertEqual(try Data(contentsOf: file), original)
            let archive = try XCTUnwrap(CameraEndpointHistory.reset(file: file, confirmed: true))
            XCTAssertEqual(try Data(contentsOf: archive), original)
            XCTAssertTrue(try CameraEndpointHistory(file: file).entries().isEmpty)
        }
    }

    func testHistoryWriteRechecksFutureVersionAppearingAfterStoreOpened() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let history = try CameraEndpointHistory(file: file)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let future = Data("{\"version\":2,\"entries\":[]}".utf8)
        try future.write(to: file)
        XCTAssertThrowsError(try history.recordSuccessful(responderGUID: firstGUID, displayName: "A", address: CameraEndpointAddress.parse("192.168.1.2")))
        XCTAssertThrowsError(try history.forget(responderGUID: firstGUID))
        XCTAssertEqual(try Data(contentsOf: file), future)
    }

    func testOversizedHistoryCanBeExplicitlyArchivedAndResetWithoutChangingPairingIdentity() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let identityFile = root.appendingPathComponent("identity.json")
        let profiles = try StationProfileStore(file: identityFile)
        try profiles.markPaired(firstGUID)
        let identityBytes = try Data(contentsOf: identityFile)
        let historyFile = root.appendingPathComponent("history.json")
        let oversized = Data(repeating: 0x61, count: 1024 * 1024 + 1)
        try oversized.write(to: historyFile)
        XCTAssertThrowsError(try CameraEndpointHistory(file: historyFile))
        let archive = try XCTUnwrap(CameraEndpointHistory.reset(file: historyFile, confirmed: true))
        XCTAssertEqual(try Data(contentsOf: archive), oversized)
        XCTAssertTrue(try CameraEndpointHistory(file: historyFile).entries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: identityFile), identityBytes)
        XCTAssertTrue(try profiles.isPaired(firstGUID))
    }

    func testPairedEnumerationForgetAndRepairPreserveInitiatorAndOtherCamera() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("identity.json")
        let profiles = try StationProfileStore(file: file)
        let identity = profiles.identity
        try profiles.markPaired(firstGUID); try profiles.markPaired(secondGUID)
        XCTAssertEqual(try profiles.pairedResponderGUIDs(), [firstGUID, secondGUID].sorted())
        try profiles.forgetResponder(firstGUID)
        XCTAssertFalse(try profiles.isPaired(firstGUID)); XCTAssertTrue(try profiles.isPaired(secondGUID))
        try profiles.markPaired(firstGUID)
        XCTAssertEqual(try StationProfileStore(file: file).identity, identity)
        XCTAssertTrue(try profiles.isPaired(firstGUID))
        XCTAssertNil(try StationProfileStore.recoverCorruptStore(file: file, confirmed: true), "Valid identity must not be reset")
        XCTAssertEqual(try StationProfileStore(file: file).identity, identity)
    }

    func testCorruptIdentityRecoveryArchivesOnlyOnConfirmationAndRejectsOldInstanceWrites() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("identity.json")
        let old = try StationProfileStore(file: file)
        let bytes = Data("{\"version\":99,\"initiator\":\"0000000000000000\",\"pairedResponders\":[]}".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try StationProfileStore.recoverCorruptStore(file: file, confirmed: false))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let archive = try XCTUnwrap(StationProfileStore.recoverCorruptStore(file: file, confirmed: true))
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        // Deterministic different new identity, not a probabilistic random-identity inequality.
        let replacement = old.identity == Data("1111111111111111".utf8) ? "2222222222222222" : "1111111111111111"
        try Data("{\"version\":1,\"initiator\":\"\(replacement)\",\"pairedResponders\":[]}".utf8).write(to: file)
        XCTAssertThrowsError(try old.markPaired(firstGUID))
        XCTAssertTrue(try StationProfileStore(file: file).pairedResponderGUIDs().isEmpty)
    }

    @MainActor func testProfileSelectionIsExplicitAndRequiresAddressWithoutStartingDiscovery() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = try CameraEndpointHistory(file: root.appendingPathComponent("history.json"), now: { 1 })
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        try profiles.markPaired(firstGUID); try profiles.markPaired(secondGUID)
        try history.recordSuccessful(responderGUID: firstGUID, displayName: "A", address: CameraEndpointAddress.parse("192.168.1.2"))
        let pool = ProfileBrowserPool()
        let coordinator = CameraDiscoveryCoordinator(history: history, profiles: profiles,
            discoveryFactory: { CameraBonjourDiscovery(browserFactory: { pool.make($0) }) })
        XCTAssertEqual(coordinator.profiles.count, 2)
        XCTAssertNil(coordinator.selectProfile(responderGUID: secondGUID))
        XCTAssertEqual(pool.count, 0, "No blind scan or automatic reconnect")
        let choice = try XCTUnwrap(coordinator.selectProfile(responderGUID: firstGUID))
        XCTAssertEqual(choice.host, "192.168.1.2"); XCTAssertEqual(choice.expectedResponderGUID, firstGUID)
        XCTAssertNil(choice.service); XCTAssertEqual(pool.count, 0)
        XCTAssertThrowsError(try coordinator.forgetProfile(responderGUID: firstGUID, confirmed: false))
        try coordinator.forgetProfile(responderGUID: firstGUID, confirmed: true)
        XCTAssertTrue(try profiles.isPaired(secondGUID)); XCTAssertFalse(try profiles.isPaired(firstGUID))
        XCTAssertNil(try history.select(responderGUID: firstGUID))
    }

    @MainActor func testCoordinatorRestartCreatesFreshStreamAndIgnoresStoppedDiscovery() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = try CameraEndpointHistory(file: root.appendingPathComponent("history.json"))
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        let pool = ProfileBrowserPool()
        let coordinator = CameraDiscoveryCoordinator(history: history, profiles: profiles,
            discoveryFactory: { CameraBonjourDiscovery(browserFactory: { pool.make($0) }) })
        coordinator.start()
        try await until { pool.count == 2 }
        let old = try XCTUnwrap(pool.browser(at: 0))
        try await until { old.ready }
        let late = try XCTUnwrap(old.savedResults())
        coordinator.stop(); coordinator.start()
        try await until { pool.count == 4 }
        let fresh = try XCTUnwrap(pool.browser(at: 2))
        try await until { fresh.ready }
        late([endpoint("Stale")]); fresh.emit([endpoint("Selected")])
        try await until { await MainActor.run { coordinator.services.first?.name == "Selected" } }
        let choice = try XCTUnwrap(coordinator.selectService(id: coordinator.services[0].id))
        XCTAssertEqual(choice.service?.name, "Selected"); XCTAssertEqual(choice.host, "")
        XCTAssertFalse(coordinator.searching)
    }

    @MainActor func testAlternateServiceIsExplicitlySelectableWithChosenCameraIdentity() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = try CameraEndpointHistory(file: root.appendingPathComponent("history.json"))
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        try profiles.markPaired(firstGUID)
        let pool = ProfileBrowserPool()
        let coordinator = CameraDiscoveryCoordinator(history: history, profiles: profiles,
            discoveryFactory: { CameraBonjourDiscovery(browserFactory: { pool.make($0) }) })
        coordinator.start()
        try await until { pool.count == 2 }
        let browser = try XCTUnwrap(pool.browser(at: 0))
        try await until { browser.ready }
        let nikon = endpoint("Same Camera", type: "_nikon._tcp")
        browser.emit([endpoint("Same Camera"), nikon])
        try await until { await MainActor.run { coordinator.selectableServices.count == 2 } }
        XCTAssertEqual(coordinator.services.count, 1)
        let alternate = try XCTUnwrap(coordinator.selectableServices.first { $0.endpoint == nikon })
        let choice = try XCTUnwrap(coordinator.selectService(id: alternate.id, expectedResponderGUID: firstGUID))
        XCTAssertEqual(choice.service?.endpoint, nikon)
        XCTAssertEqual(choice.expectedResponderGUID, firstGUID)
        XCTAssertNil(coordinator.selectProfile(responderGUID: firstGUID), "No success address is invented from service name")
    }

    @MainActor func testCorruptProfileHistoryMessageSurvivesDiscoveryUntilConfirmedReset() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let history = try CameraEndpointHistory(file: file)
        let profiles = try StationProfileStore(file: root.appendingPathComponent("identity.json"))
        try profiles.markPaired(firstGUID)
        let pool = ProfileBrowserPool()
        let coordinator = CameraDiscoveryCoordinator(history: history, profiles: profiles,
            discoveryFactory: { CameraBonjourDiscovery(browserFactory: { pool.make($0) }) })
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        coordinator.reloadProfiles()
        let message = try XCTUnwrap(coordinator.message)
        coordinator.start()
        try await until { pool.count == 2 }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(coordinator.message?.contains(message) == true)
        let archive = try XCTUnwrap(coordinator.resetHistoryAfterConfirmation(confirmed: true))
        XCTAssertEqual(try Data(contentsOf: archive), corrupt)
        XCTAssertEqual(coordinator.profiles.first?.responderGUID, firstGUID)
        coordinator.stop()
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    private func endpoint(_ name: String, type: String = "_ptp._tcp") -> NWEndpoint {
        .service(name: name, type: type, domain: "local.", interface: nil)
    }
    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Discovery fixture timed out"); throw CameraStreamError.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor ProfileDiscoverySink {
    private(set) var latest: CameraBonjourSnapshot?
    func append(_ value: CameraBonjourSnapshot) { latest = value }
}

private final class ProfileBrowserPool: @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [ProfileFakeBrowser] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return browsers.count }
    var allCancelled: Bool { lock.lock(); defer { lock.unlock() }; return browsers.allSatisfy(\.cancelled) }
    func make(_ type: String) -> CameraBonjourBrowser {
        let value = ProfileFakeBrowser()
        lock.lock(); browsers.append(value); lock.unlock()
        return value
    }
    func browser(at index: Int) -> ProfileFakeBrowser? {
        lock.lock(); defer { lock.unlock() }
        return browsers.indices.contains(index) ? browsers[index] : nil
    }
}

private final class ProfileFakeBrowser: CameraBonjourBrowser, @unchecked Sendable {
    private let lock = NSLock()
    private var results: (([NWEndpoint]) -> Void)?
    private var state: ((CameraBonjourBrowserState) -> Void)?
    private var started = false
    private var stopped = false
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return started && results != nil }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var onResults: (([NWEndpoint]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return results }
        set { lock.lock(); results = newValue; lock.unlock() }
    }
    var onState: ((CameraBonjourBrowserState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return state }
        set { lock.lock(); state = newValue; lock.unlock() }
    }
    func start(on queue: DispatchQueue) { lock.lock(); started = true; lock.unlock(); onState?(.ready) }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func savedResults() -> (([NWEndpoint]) -> Void)? { onResults }
    func emit(_ endpoints: [NWEndpoint]) { onResults?(endpoints) }
}
