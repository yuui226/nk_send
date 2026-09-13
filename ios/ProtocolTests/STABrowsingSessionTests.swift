import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

@MainActor
final class STABrowsingSessionTests: XCTestCase {
    private let guid = String(repeating: "1", count: 32)

    func testFirstPairingMustFinishBeforeAlbumAndMarkerPrecedesOptionalEvent() async throws {
        let prefs = STAProfileFixture()
        // A route/legacy paired field is deliberately not pairing confirmation.
        prefs.store.remember(guid: guid, ip: "192.168.5.2", identity: .pairedComputer)
        prefs.connection.set(true, forKey: "sta_camera_profile_v1.\(guid).paired")
        let wire = STAScriptTransport([
            .init(0x1002, [1]), .init(0x941C), .init(0x1004, payload: staU32Array([0x10001])),
            .init(0x952B), .init(0x935A, [0x2001]), .init(0x1003),
        ])
        let stages = STARecorder<STAConnectionStage>()
        let store = prefs.store, cameraGUID = guid
        let browsing = STABrowsingSession(session: PTPSession(transport: wire, firstTransactionID: 0),
            guid: guid, identity: .pairedComputer, profiles: store,
            onStage: { await stages.append($0) }, waitForPairingEvent: { XCTAssertTrue(store.isPaired(cameraGUID)) })
        do { _ = try await browsing.open(); XCTFail("Pre-pairing album must not activate") }
        catch { XCTAssertEqual(error as? STAConnectionError, .pairingCompleted) }
        let recorded = await stages.values
        XCTAssertEqual(recorded, [.pairing])
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.transactionID), [0, 1, 2, 3, 4, 5])
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
        XCTAssertTrue(prefs.store.isPaired(guid))
    }

    func testConfirmedPairingValidatesFirstMiddleLastAndReusesHandles() async throws {
        let prefs = STAProfileFixture(); prefs.store.markPaired(guid)
        let handles: [UInt32] = [11, 12, 13, 14, 15]
        let wire = STAScriptTransport([
            .init(0x1002, [1], response: 0x201E), .init(0x941C),
            .init(0x1004, payload: staU32Array([0x10000])), .init(0x1001, payload: staDeviceInfo()),
            .init(0x1007, [.max, .max, 0], payload: staU32Array(handles)),
            .init(0x1008, [11], payload: Data(repeating: 0, count: 53)),
            .init(0x1008, [13], payload: Data(repeating: 0, count: 53)),
            .init(0x1008, [15], payload: Data(repeating: 0, count: 53)),
        ])
        let album = try await make(wire, prefs).open()
        XCTAssertFalse(album.directObjectRead)
        XCTAssertEqual(album.prefetchedHandles?.storageID, .max)
        XCTAssertEqual(album.prefetchedHandles?.handles, handles)
        XCTAssertEqual(album.deviceInfo?.model, "Z 30")
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testDeniedObjectInfoRequiresPositiveSizeAndPartialReadNotJustThumbnail() async throws {
        let prefs = STAProfileFixture(); prefs.store.markPaired(guid)
        let wire = STAScriptTransport([
            .init(0x1002, [1]), .init(0x941C), .init(0x1004, payload: staU32Array([0x10001])),
            .init(0x1001, payload: staDeviceInfo()), .init(0x1007, [.max, .max, 0], payload: staU32Array([71])),
            .init(0x1008, [71], response: 0x200F), .init(0x100A, [71], response: 0x200F),
            .init(0x9421, [71], payload: staInteger(UInt64(24_000_000))),
            .init(0x9431, [71, 0, 0, 65_536, 0], payload: Data([255, 216, 255])),
        ])
        let album = try await make(wire, prefs).open()
        XCTAssertTrue(album.directObjectRead)
        XCTAssertEqual(album.prefetchedHandles?.handles, [71])
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testEmptyHandlesCannotActivateAndFailedApplicationProbeRollsBack() async throws {
        let prefs = STAProfileFixture(); prefs.store.markPaired(guid)
        let wire = STAScriptTransport([
            .init(0x1002, [1]), .init(0x941C), .init(0x1004, payload: staU32Array([0x10001])),
            .init(0x1001, payload: staDeviceInfo()), .init(0x1007, [.max, .max, 0], payload: staU32Array([])),
            .init(0x9435, [1]), .init(0x941C), .init(0x1004, payload: staU32Array([0x10001])),
            .init(0x1007, [.max, .max, 0], payload: staU32Array([])), .init(0x9435, [0]),
        ])
        do { _ = try await make(wire, prefs).open(); XCTFail("Empty upload queue is not a usable album") }
        catch { XCTAssertEqual(error as? STAConnectionError, .noMedia) }
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testApplicationModeCanValidateAlbumAndMustRemainSelectedOnSuccess() async throws {
        let prefs = STAProfileFixture(); prefs.store.markPaired(guid)
        let wire = STAScriptTransport([
            .init(0x1002, [1]), .init(0x941C), .init(0x1004, response: 0x200F),
            .init(0x1001, payload: staDeviceInfo()), .init(0x9435, [1]), .init(0x941C),
            .init(0x1004, payload: staU32Array([0x10001])),
            .init(0x1007, [.max, .max, 0], payload: staU32Array([8])),
            .init(0x1008, [8], payload: Data(repeating: 0, count: 53)),
        ])
        _ = try await make(wire, prefs).open()
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testPairingOnlyCapabilitiesRequireExactSet() async throws {
        for (ops, pairs) in [(Set<UInt16>([0x1001, 0x1002, 0x1003, 0x952B, 0x935A]), true),
                             (Set<UInt16>([0x1001, 0x1002, 0x1003, 0x952B, 0x935A, 0x9439]), false)] {
            let prefs = STAProfileFixture()
            var exchanges: [STAExchange] = [
                .init(0x1002, [1]), .init(0x941C), .init(0x1004, response: 0x200F),
                .init(0x1001, payload: staDeviceInfo(operations: ops)),
            ]
            exchanges += pairs ? [.init(0x952B), .init(0x935A, [0x2001]), .init(0x1003)] : [.init(0x9435, [1], response: 0x2005)]
            let wire = STAScriptTransport(exchanges)
            do { _ = try await make(wire, prefs).open(); XCTFail("Unexpected album") }
            catch { XCTAssertEqual(error as? STAConnectionError, pairs ? .pairingCompleted : .albumUnavailable(0x200F)) }
            XCTAssertEqual(prefs.store.isPaired(guid), pairs)
            let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
        }
    }

    func testAlbumIdentityNeverExecutesPairingCommands() async throws {
        let prefs = STAProfileFixture()
        let wire = STAScriptTransport([
            .init(0x1002, [1]), .init(0x941C), .init(0x1004, payload: staU32Array([0x10001])),
            .init(0x1001, payload: staDeviceInfo()), .init(0x1007, [.max, .max, 0], payload: staU32Array([7])),
            .init(0x1008, [7], payload: Data(repeating: 0, count: 53)),
        ])
        _ = try await make(wire, prefs, identity: .albumExplorer).open()
        XCTAssertFalse(prefs.store.isPaired(guid))
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testPairingFailureDoesNotPersistSuccess() async throws {
        let prefs = STAProfileFixture()
        let wire = STAScriptTransport([
            .init(0x1002, [1]), .init(0x941C), .init(0x1004, payload: staU32Array([0x10001])),
            .init(0x952B), .init(0x935A, [0x2001], response: 0x200F),
        ])
        do { _ = try await make(wire, prefs).open(); XCTFail("Negative pairing response") }
        catch { XCTAssertEqual(error as? STAConnectionError, .pairingResultFailed(0x200F)) }
        XCTAssertFalse(prefs.store.isPaired(guid))
    }

    private func make(_ wire: STAScriptTransport, _ fixture: STAProfileFixture,
                      identity: STAInitiatorIdentity = .pairedComputer) -> STABrowsingSession {
        STABrowsingSession(session: PTPSession(transport: wire, firstTransactionID: 0), guid: guid,
            identity: identity, profiles: fixture.store, onStage: { _ in }, waitForPairingEvent: {})
    }
}

struct STAExchange: Sendable {
    let operation: UInt16; let parameters: [UInt32]; let response: UInt16; let payload: Data
    init(_ operation: UInt16, _ parameters: [UInt32] = [], response: UInt16 = 0x2001, payload: Data = Data()) {
        self.operation = operation; self.parameters = parameters; self.response = response; self.payload = payload
    }
}
actor STAScriptTransport: PTPCommandTransport {
    private var script: [STAExchange]
    private(set) var commands: [PTPContainer] = []
    var remaining: Int { script.count }
    init(_ script: [STAExchange]) { self.script = script }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let command = try PTPCodec.decode(command)
        commands.append(command)
        guard !script.isEmpty else { throw STAFixtureError.unexpectedCommand(command.code) }
        let expected = script.removeFirst()
        XCTAssertEqual(command.code, expected.operation)
        XCTAssertEqual(command.payload, expected.parameters.reduce(into: Data()) { $0.append(staInteger($1)) })
        guard command.code == expected.operation else { throw STAFixtureError.unexpectedCommand(command.code) }
        return (PTPCodec.encode(type: .response, code: expected.response, transactionID: command.transactionID), expected.payload)
    }
}
enum STAFixtureError: Error { case unexpectedCommand(UInt16) }
actor STARecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}
final class STAProfileFixture {
    let connection: UserDefaults; let pairing: UserDefaults; let store: STAProfileStore
    private let name = "com.ztransfer.sta-test.\(UUID().uuidString)"
    init() {
        connection = UserDefaults(suiteName: name + ".connection")!
        pairing = UserDefaults(suiteName: name + ".pairing")!
        store = STAProfileStore(preferences: connection, pairing: pairing)
    }
    deinit {
        connection.removePersistentDomain(forName: name + ".connection")
        pairing.removePersistentDomain(forName: name + ".pairing")
    }
}
func staInteger<T: FixedWidthInteger>(_ value: T) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
func staU32Array(_ values: [UInt32]) -> Data { values.reduce(into: staInteger(UInt32(values.count))) { $0.append(staInteger($1)) } }
func staString(_ value: String) -> Data { Data([UInt8(value.utf16.count + 1)]) + value.data(using: .utf16LittleEndian)! + Data([0, 0]) }
func staDeviceInfo(operations: Set<UInt16> = [0x1001, 0x1002, 0x1003, 0x1004, 0x1007, 0x1008, 0x9431]) -> Data {
    var data = staInteger(UInt16(100)) + staInteger(UInt32(10)) + staInteger(UInt16(100)) + staString("") + staInteger(UInt16(0))
    data.append(staInteger(UInt32(operations.count)))
    for operation in operations.sorted() { data.append(staInteger(operation)) }
    for _ in 0..<4 { data.append(staInteger(UInt32(0))) }
    for value in ["Nikon", "Z 30", "1.0", "123"] { data.append(staString(value)) }
    return data
}
