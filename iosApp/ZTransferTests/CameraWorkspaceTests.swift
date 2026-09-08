import Foundation
import Network
import XCTest
import ZTransferShared
@testable import ZTransfer

final class CameraWorkspaceTests: XCTestCase {
    func testResolvedEndpointIsUnavailableBeforeReadyAndAfterCancellation() async throws {
        let wire = WorkspaceWire(bytes: Data(), remoteHost: "192.168.10.7")
        let stream = CameraTCPStream(connection: wire)
        let before = await stream.resolvedRemoteHost(); XCTAssertNil(before)
        try await stream.connect(timeout: 1)
        let ready = await stream.resolvedRemoteHost(); XCTAssertEqual(ready, "192.168.10.7")
        stream.close()
        let closed = await stream.resolvedRemoteHost(); XCTAssertNil(closed)
    }
    func testBonjourHistoryUsesResolvedReadyAddressButNeverAdvertisementName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try CameraEndpointHistory(file: root.appendingPathComponent("history.json"), now: { 1 })
        let service = CameraBonjourService(endpoint: .service(name: "Camera", type: "_ptp._tcp", domain: "local.", interface: nil), name: "Camera")
        let id = "00112233445566778899aabbccddeeff"
        try CameraHandshakeProbe.recordVerifiedStationEndpoint(stationMode: true, service: service, host: "",
            responderGUID: id, displayName: "Camera", history: { history })
        XCTAssertTrue(try history.entries().isEmpty)
        try CameraHandshakeProbe.recordVerifiedStationEndpoint(stationMode: true, service: service, host: "",
            responderGUID: id, displayName: "Camera", resolvedHost: "192.168.10.7", history: { history })
        XCTAssertEqual(try history.select(responderGUID: id)?.address.host, "192.168.10.7")
        try CameraHandshakeProbe.recordVerifiedStationEndpoint(stationMode: true, service: service, host: "",
            responderGUID: nil, displayName: "Unknown", resolvedHost: "192.168.10.8", history: { history })
        XCTAssertEqual(try history.entries().count, 1)
    }
    func testResolvedRouteNeverUsesHostnamesOrServiceLabelsAsNumericEvidence() {
        XCTAssertEqual(CameraNetworkPathPolicy.numericRemoteHost(.hostPort(host: "192.168.10.7", port: 15740)), "192.168.10.7")
        XCTAssertNotNil(CameraNetworkPathPolicy.numericRemoteHost(.hostPort(host: "fe80::1234", port: 15740)))
        XCTAssertNil(CameraNetworkPathPolicy.numericRemoteHost(.hostPort(host: "camera.local", port: 15740)))
        XCTAssertNil(CameraNetworkPathPolicy.numericRemoteHost(.service(name: "Camera", type: "_ptp._tcp", domain: "local.", interface: nil)))
        XCTAssertNil(CameraNetworkPathPolicy.numericRemoteHost(nil))
    }
    func testExplicitLocalNetworkDenialIsDistinctFromUnavailableWifi() {
        XCTAssertEqual(CameraNetworkPathPolicy.failure(satisfied: false, wifi: false, denied: true), .localNetworkDenied)
        XCTAssertEqual(CameraNetworkPathPolicy.failure(satisfied: false, wifi: true, denied: false), .wifiUnavailable)
        XCTAssertEqual(CameraNetworkPathPolicy.failure(satisfied: true, wifi: false, denied: false), .wifiUnavailable)
        XCTAssertNil(CameraNetworkPathPolicy.failure(satisfied: true, wifi: true, denied: false))
        XCTAssertNotEqual(CameraStreamError.timedOut, CameraStreamError.localNetworkDenied)
    }
    @MainActor func testConnectionModeRoundTripStoresOnlyPresentationPreference() throws {
        let suite = "connection-mode-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CameraConnectionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.read(), "ap")
        XCTAssertTrue(preferences.save("sta"))
        let workspace = CameraWorkspaceBridge(connectionPreferences: CameraConnectionPreferences(defaults: defaults))
        defer { workspace.close() }
        XCTAssertEqual(workspace.readConnectionMode(), "sta")
        XCTAssertFalse(workspace.model.isReady()); XCTAssertFalse(workspace.session.running)
        let data = try XCTUnwrap(defaults.data(forKey: CameraConnectionPreferences.key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["version", "mode"]))
    }
    @MainActor func testInvalidConnectionModeNeverOverwritesUnknownBytes() throws {
        let suite = "connection-mode-invalid-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for bytes in [Data("broken".utf8), Data(#"{"version":2,"mode":"sta"}"#.utf8),
                      Data(#"{"version":1,"mode":"usb"}"#.utf8), Data(repeating: 0, count: 4097)] {
            defaults.set(bytes, forKey: CameraConnectionPreferences.key)
            let preferences = CameraConnectionPreferences(defaults: defaults)
            XCTAssertNil(preferences.read()); XCTAssertFalse(preferences.save("ap"))
            XCTAssertEqual(defaults.data(forKey: CameraConnectionPreferences.key), bytes)
        }
    }
    @MainActor func testWorkspaceAndDiagnosticEntryUseTheSameSessionInstance() {
        let owner = CameraHandshakeProbe()
        let workspace = CameraWorkspaceBridge(session: owner)
        XCTAssertTrue(workspace.session === owner)
        XCTAssertFalse(owner.sessionReady); XCTAssertFalse(owner.canOpenSharedWorkspace)
        XCTAssertFalse(workspace.model.isReady())
        workspace.openCameraFiles(); workspace.openTransferQueue()
        XCTAssertNil(owner.filesPage); XCTAssertNil(owner.queuePage)
        workspace.close()
    }

    @MainActor func testInvalidProductAddressNeverCreatesRunningSession() {
        let owner = CameraHandshakeProbe()
        for address in ["", "https://camera.local", "1.2.3.999", "camera.local:15740"] {
            XCTAssertFalse(owner.connectProduct(host: address, stationMode: false, allowPairing: false, requestID: 1))
            XCTAssertFalse(owner.running); XCTAssertNil(owner.productState)
        }
    }

    @MainActor func testProductConnectAndImmediateCancelAreMutuallyExclusiveBeforeAnyIo() async throws {
        let owner = CameraHandshakeProbe()
        XCTAssertTrue(owner.connectProduct(host: "camera.local", stationMode: false, allowPairing: false, requestID: 1))
        XCTAssertEqual(owner.productState?.phase, "connecting")
        XCTAssertFalse(owner.sessionReady); XCTAssertFalse(owner.canOpenSharedWorkspace)
        XCTAssertFalse(owner.connectProduct(host: "other.local", stationMode: true, allowPairing: false, requestID: 2))
        owner.cancel() // Same MainActor turn, before the connection task can touch storage or sockets.
        XCTAssertEqual(owner.productState?.phase, "closing")
        let deadline = Date().addingTimeInterval(2)
        while owner.running && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(owner.running); XCTAssertFalse(owner.sessionReady)
        XCTAssertEqual(owner.productState?.requestID, 1); XCTAssertEqual(owner.productState?.phase, "idle")
        XCTAssertTrue(owner.connectProduct(host: "camera.local", stationMode: false, allowPairing: false, requestID: 2))
        owner.cancel()
    }

    @MainActor func testWorkspaceBackgroundStopsItsExistingOwnerRatherThanCreatingAnother() async throws {
        let owner = CameraHandshakeProbe()
        let workspace = CameraWorkspaceBridge(session: owner)
        defer { workspace.close() }
        XCTAssertTrue(workspace.session.connectProduct(host: "camera.local", stationMode: false, allowPairing: false, requestID: 9))
        workspace.enterBackground()
        XCTAssertEqual(workspace.session.productState?.phase, "closing")
        XCTAssertTrue(workspace.session === owner)
        let deadline = Date().addingTimeInterval(2)
        while workspace.session.running && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(workspace.session.productState?.phase, "idle")
    }

    func testResponderIdentityIsAvailableOnlyForAnActuallyReadySession() async throws {
        let guid = Data([0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255])
        let command = WorkspaceWire(bytes: Data([28, 0, 0, 0, 2, 0, 0, 0, 0x44, 0x33, 0x22, 0x11]) + guid
            + response(transaction: 1) + response(transaction: 2, code: 0x2005))
        let camera = CameraWiFiConnection(command: CameraTCPStream(connection: command),
            event: CameraTCPStream(connection: WorkspaceWire(bytes: Data([8, 0, 0, 0, 4, 0, 0, 0]))))
        let before = await camera.responderGUID(); XCTAssertNil(before)
        _ = try await camera.connect(guid: Data(repeating: 1, count: 16))
        let ready = await camera.responderGUID(); XCTAssertEqual(ready, "00112233445566778899aabbccddeeff")
        await camera.abort()
        let closed = await camera.responderGUID(); XCTAssertNil(closed)
    }

    func testApReadyCannotOverwriteTheSameCamerasVerifiedStaAddress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try CameraEndpointHistory(file: root.appendingPathComponent("history.json"))
        let guid = "00112233445566778899aabbccddeeff"
        try CameraHandshakeProbe.recordVerifiedStationEndpoint(stationMode: true, service: nil, host: "192.168.20.9",
            responderGUID: guid, displayName: "Camera", history: { history })
        var opened = false
        try CameraHandshakeProbe.recordVerifiedStationEndpoint(stationMode: false, service: nil, host: "192.168.1.1",
            responderGUID: guid, displayName: "Camera hotspot", history: { opened = true; return history })
        XCTAssertFalse(opened)
        XCTAssertEqual(try history.select(responderGUID: guid)?.address.host, "192.168.20.9")
    }

    @MainActor func testInitialPageReusesCompletedCatalogButExplicitRefreshStillReadsCameraAndOriginals() async throws {
        let fixture = try pageFixture()
        let baseline = try await fixture.catalog.refresh()
        let state = await fixture.source.snapshot()
        XCTAssertTrue(fixture.page.loadInitialCatalog(baseline, state: state))
        await fixture.page.originalIndexTask?.value
        let firstScans = await fixture.source.scans, firstInfos = await fixture.source.infoReads
        let firstOriginals = await fixture.originals.requests
        XCTAssertEqual(firstScans, 1); XCTAssertEqual(firstInfos, 1)
        XCTAssertEqual(firstOriginals, [true], "Reusing camera metadata must still initialize local originals")
        fixture.page.refresh() // Real NativeFilesPagePlatform action, not a cache-helper call.
        try await until { await fixture.source.infoReads == 2 }
        await fixture.page.originalIndexTask?.value
        let nextScans = await fixture.source.scans, nextOriginals = await fixture.originals.requests
        XCTAssertEqual(nextScans, 2); XCTAssertEqual(nextOriginals, [true, true])
        await close(fixture)
    }

    @MainActor func testInitialPageRescansWhenAnEventArrivedAfterBaselineWasRead() async throws {
        let fixture = try pageFixture()
        let baseline = try await fixture.catalog.refresh()
        await fixture.source.advanceRevision()
        // Same ordering as openSharedFiles: catalog first, then current connection state.
        let current = await fixture.source.snapshot()
        XCTAssertFalse(fixture.page.loadInitialCatalog(baseline, state: current))
        try await until { await fixture.catalog.snapshot()?.revision == current.eventRevision }
        let scans = await fixture.source.scans
        XCTAssertEqual(scans, 2)
        await close(fixture)
    }

    @MainActor func testInitialPageRejectsMissingOtherSessionPartialAndChangedCatalogCandidates() async throws {
        for variant in 0..<4 {
            let fixture = try pageFixture()
            let baseline = try await fixture.catalog.refresh()
            let candidate: CameraCatalogSnapshot? = variant == 0 ? nil : CameraCatalogSnapshot(
                connectionID: variant == 1 ? UUID() : baseline.connectionID, revision: baseline.revision,
                storageIDs: baseline.storageIDs, files: baseline.files, objectInfos: baseline.objectInfos,
                totalHandles: baseline.totalHandles, metadataComplete: variant != 2,
                changedWhileScanning: variant == 3, publicationRevision: baseline.publicationRevision)
            let current = await fixture.source.snapshot()
            XCTAssertFalse(fixture.page.loadInitialCatalog(candidate, state: current))
            try await until { await fixture.source.infoReads == 2 }
            let scans = await fixture.source.scans
            XCTAssertEqual(scans, 2, "Invalid reuse candidate must use the real camera refresh route")
            await close(fixture)
        }
    }

    @MainActor func testInitialPageCannotLoadAfterCloseOrWithAnotherOrClosedConnectionState() async throws {
        let fixture = try pageFixture()
        let baseline = try await fixture.catalog.refresh()
        for state in [CameraConnectionSnapshot(connectionID: UUID(), phase: .ready, eventRevision: 0, errorDescription: nil),
                      CameraConnectionSnapshot(connectionID: fixture.camera.connectionID, phase: .closed, eventRevision: 0, errorDescription: nil)] {
            XCTAssertFalse(fixture.page.loadInitialCatalog(baseline, state: state))
        }
        fixture.page.close()
        let current = await fixture.source.snapshot()
        XCTAssertFalse(fixture.page.loadInitialCatalog(baseline, state: current))
        let scans = await fixture.source.scans, originals = await fixture.originals.requests
        XCTAssertEqual(scans, 1); XCTAssertTrue(originals.isEmpty)
        await close(fixture)
    }

    @MainActor func testRejectedOlderPublicationReleasesScanBeforeFallbackRefresh() async throws {
        let fixture = try pageFixture()
        let older = try await fixture.catalog.refresh()
        let newer = try await fixture.catalog.refresh()
        let current = await fixture.source.snapshot()
        XCTAssertTrue(fixture.page.loadInitialCatalog(newer, state: current))
        // Same event revision can still have a newer catalog publication (another complete scan).
        // acceptCatalog must finish the rejected scan token, allowing refresh() to begin its own.
        XCTAssertFalse(fixture.page.loadInitialCatalog(older, state: current))
        try await until { await fixture.source.infoReads == 3 }
        let scans = await fixture.source.scans
        XCTAssertEqual(scans, 3, "Rejected cache must not leave the shared page in scanning=true")
        await close(fixture)
    }

    @MainActor private func pageFixture() throws -> WorkspacePageFixture {
        let camera = CameraWiFiConnection(command: try CameraTCPStream(host: "127.0.0.1", port: 15740),
            event: try CameraTCPStream(host: "127.0.0.1", port: 15740))
        var payload = Data(repeating: 0, count: 52)
        payload[0] = 1; payload[2] = 1; payload[4] = 1; payload[5] = 0x38; payload[8] = 10
        for text in ["BASELINE.JPG", "20260908T120000", ""] {
            payload.append(UInt8(text.utf16.count + 1))
            for unit in text.utf16 { payload.append(UInt8(truncatingIfNeeded: unit)); payload.append(UInt8(unit >> 8)) }
            payload.append(contentsOf: [0, 0])
        }
        let info = try XCTUnwrap(PtpIPChannel.objectInfo(handle: 1, payload: payload))
        let source = WorkspaceCatalogSource(connectionID: camera.connectionID, info: info)
        let catalog = CameraCatalog(source: source, stationMode: false)
        let originals = WorkspaceOriginalsSource(), previews = CameraPreviewStore(source: camera)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = CameraOriginalQueue(camera: camera, store: CameraOriginalStore(root: root))
        let page = OriginalFilesPageBridge(connectionID: camera.connectionID, catalog: catalog, queue: queue,
            previews: previews, exifSource: camera, exifCache: NativePreviewExifCache(), stationMode: false, originals: originals)
        page.setConnected(true)
        return WorkspacePageFixture(camera: camera, source: source, catalog: catalog, originals: originals, previews: previews, page: page)
    }
    @MainActor private func close(_ fixture: WorkspacePageFixture) async {
        fixture.page.close(); await fixture.catalog.close(); await fixture.previews.close(); await fixture.camera.abort()
    }
    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !(await predicate()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Initial workspace catalog route did not settle"); throw CameraStreamError.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func response(transaction: UInt32, code: UInt16 = 0x2001) -> Data {
        Data([14, 0, 0, 0, 7, 0, 0, 0, UInt8(truncatingIfNeeded: code), UInt8(code >> 8)])
            + Data((0..<4).map { UInt8(truncatingIfNeeded: transaction >> ($0 * 8)) })
    }
}

private struct WorkspacePageFixture {
    let camera: CameraWiFiConnection
    let source: WorkspaceCatalogSource
    let catalog: CameraCatalog
    let originals: WorkspaceOriginalsSource
    let previews: CameraPreviewStore
    let page: OriginalFilesPageBridge
}

private actor WorkspaceCatalogSource: CameraCatalogSource {
    nonisolated let connectionID: UUID
    private let info: PtpObjectInfo
    private var revision: UInt64 = 0
    private(set) var scans = 0
    private(set) var infoReads = 0
    init(connectionID: UUID, info: PtpObjectInfo) { self.connectionID = connectionID; self.info = info }
    func storageIDs() -> [Int32] { scans += 1; return [info.storageId] }
    func objectHandles(storageID: Int32) -> [Int32] { [info.handle] }
    func objectInfo(handle: Int32) -> PtpObjectInfo { infoReads += 1; return info }
    func snapshot() -> CameraConnectionSnapshot {
        CameraConnectionSnapshot(connectionID: connectionID, phase: .ready, eventRevision: revision, errorDescription: nil)
    }
    func advanceRevision() { revision += 1 }
}

private actor WorkspaceOriginalsSource: OriginalFilesReading {
    private(set) var requests: [Bool] = []
    func originals(since revision: Int64, rescan: Bool) -> OriginalIndexUpdate {
        requests.append(rescan)
        return OriginalIndexUpdate(revision: 0, baseRevision: revision, fullSnapshot: true, entries: [])
    }
    func originalData(locator: String) throws -> Data { throw OriginalIndexError.unsafeRoot }
    func originalRawPreviewData(locator: String) -> Data? { nil }
    func originalExif(locator: String) -> PhotoExif? { nil }
}

private final class WorkspaceWire: CameraByteConnection {
    private let lock = NSLock()
    private var bytes: Data
    private var held: ((Data?, Bool, Error?) -> Void)?
    private let remoteHost: String?
    init(bytes: Data, remoteHost: String? = nil) { self.bytes = bytes; self.remoteHost = remoteHost }
    func resolvedRemoteHost() -> String? { remoteHost }
    func start(on queue: DispatchQueue, state: @escaping (CameraConnectionEvent) -> Void) { state(.ready) }
    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        lock.lock()
        let count = min(bytes.count, maximumLength), result = Data(bytes.prefix(maximumLength))
        bytes.removeFirst(count)
        if count == 0 { held = completion }
        lock.unlock()
        if count > 0 { completion(result, false, nil) }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) { completion(nil) }
    func cancel() { lock.lock(); held = nil; lock.unlock() }
}
