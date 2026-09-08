import Foundation
import XCTest
import ZTransferShared
@testable import ZTransfer

final class CameraWorkspaceTests: XCTestCase {
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

    private func response(transaction: UInt32, code: UInt16 = 0x2001) -> Data {
        Data([14, 0, 0, 0, 7, 0, 0, 0, UInt8(truncatingIfNeeded: code), UInt8(code >> 8)])
            + Data((0..<4).map { UInt8(truncatingIfNeeded: transaction >> ($0 * 8)) })
    }
}

private final class WorkspaceWire: CameraByteConnection {
    private let lock = NSLock()
    private var bytes: Data
    private var held: ((Data?, Bool, Error?) -> Void)?
    init(bytes: Data) { self.bytes = bytes }
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
