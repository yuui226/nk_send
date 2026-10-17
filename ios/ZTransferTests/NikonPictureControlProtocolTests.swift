import XCTest
@testable import ZTransfer

final class NikonPictureControlProtocolTests: XCTestCase {
    private let operations: Set<UInt16> = [0x1014, 0x1015, 0x1016, 0x90CC, 0x90CD, 0x90CE, 0x90CF]
    private func repository(_ wire: PictureControlWire) -> CameraRepository {
        let info = PTPDeviceInfo(standardVersion: 100, vendorExtensionID: 10, vendorExtensionVersion: 100,
            vendorExtensionDescription: "", functionalMode: 0, manufacturer: "Nikon", model: "Z30", version: "1.20",
            serialNumber: "test-body", operations: operations, events: [], properties: [], captureFormats: [], imageFormats: [])
        return CameraRepository(session: PTPSession(transport: wire), isUSBConnection: true, deviceInfo: info)
    }
    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func descriptor(movie: Bool = false) -> Data {
        let values: [UInt16] = [1, 3, 5, 111] + Array(201...209)
        var data = staInteger(UInt16(movie ? 0xD237 : 0xD200)) + staInteger(UInt16(4)) + Data([1])
        data += staInteger(UInt16(1)) + staInteger(UInt16(5)) + Data([2]) + staInteger(UInt16(values.count))
        for value in values { data += staInteger(value) }
        return data
    }
    private func dataset(base: UInt16 = 1) -> Data {
        var data = Data(repeating: 0, count: 36)
        data.replaceSubrange(0..<2, with: staInteger(base))
        data.replaceSubrange(2..<6, with: Data("Base".utf8))
        return data
    }
    func testActivationReadsEffectiveUserModeAndNeverRewritesSlotInEitherBank() async throws {
        for movie in [false, true] {
            for mode in [UInt8(18), 19, 20, 21, 22, 23] {
                let property: UInt32 = movie ? 0xD237 : 0xD200, bank: UInt32 = movie ? 1 : 0
                var steps: [PictureControlWire.Step] = [
                    .init(0x1014, [property], reply: descriptor(movie: movie)),
                    .init(0x1015, [0x500E], reply: staInteger(UInt16(0x8051))),
                    .init(0x1015, [0xD0FC], reply: Data([mode]))
                ]
                if (19...22).contains(mode) {
                    steps += [.init(0x90CC, [201, 0, bank], reply: dataset()), .init(0x90CC, [201, 1, bank], reply: dataset()),
                              .init(0x1015, [property], reply: staInteger(UInt16(5))),
                              .init(0x1016, [property], outgoing: staInteger(UInt16(201))),
                              .init(0x1015, [property], reply: staInteger(UInt16(201)))]
                }
                let wire = PictureControlWire(steps)
                let root = directory()
                do {
                    try await repository(wire).changePictureControl(slot: 201, change: .activate, movie: movie,
                        backupDirectory: root, isCurrent: { true })
                    XCTAssertTrue((19...22).contains(mode))
                } catch is PictureControlExposureModeError { XCTAssertFalse((19...22).contains(mode)) }
                let remaining = await wire.remaining
                XCTAssertEqual(remaining, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Activation must not create backups")
            }
        }
    }
    func testProductionOverviewReadsExactlyNineSlotsAndKeepsMalformedSlotUnreadable() async throws {
        var steps: [PictureControlWire.Step] = [
            .init(0x1014, [0xD200], reply: descriptor()),
            .init(0x1015, [0xD200], reply: staInteger(UInt16(209)))
        ]
        for slot in UInt32(201)...209 {
            let data = slot == 204 ? Data([1]) : slot == 209 ? dataset() : Data(repeating: 0, count: 36)
            steps.append(.init(0x90CC, [slot, 0, 0], reply: data))
        }
        let wire = PictureControlWire(steps), root = directory()
        let overview = try await repository(wire).readPictureControlOverview(movie: false, backupDirectory: root, isCurrent: { true })
        XCTAssertEqual(overview.slots.count, 9); XCTAssertEqual(overview.selected, 209)
        XCTAssertEqual(overview.slots[3].availability, .unreadable)
        XCTAssertEqual(overview.slots.last?.availability, .occupied)
        XCTAssertEqual(overview.slots.first?.availability, .empty)
        XCTAssertTrue(overview.canEdit); XCTAssertTrue(overview.canActivate)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testProductionWriteBacksUpEmptySlotAndAcceptsOnlyDocumentedDefaultCurveOmission() async throws {
        let file = try XCTUnwrap(builtInPictureControls().first).read()
        let encoded = try file.encodeClassicPictureControl()
        var defaultHeader = Data(encoded.prefix(36)); defaultHeader[35] = 0
        let empty = Data(repeating: 0, count: 36)
        let wire = PictureControlWire([
            .init(0x1014, [0xD200], reply: descriptor()),
            .init(0x1015, [0x500E], reply: staInteger(UInt16(1))),
            .init(0x90CC, [3, 1, 0], reply: dataset(base: 3)),
            .init(0x90CF, [3, 0], reply: Data(repeating: 128, count: 28)),
            .init(0x90CC, [209, 0, 0], reply: empty), .init(0x90CC, [209, 1, 0], reply: empty),
            .init(0x1015, [0xD200], reply: staInteger(UInt16(5))),
            .init(0x90CD, [209, 0, 0], outgoing: encoded),
            .init(0x90CC, [209, 0, 0], reply: encoded), .init(0x90CC, [209, 1, 0], reply: defaultHeader),
            .init(0x1016, [0xD200], outgoing: staInteger(UInt16(209))),
            .init(0x1015, [0xD200], reply: staInteger(UInt16(209)))
        ])
        let root = directory()
        try await repository(wire).changePictureControl(slot: 209, change: .write(file), movie: false,
            backupDirectory: root, isCurrent: { true })
        let original = try PictureControlBackupStore(directory: root).load(identity: "Nikon\0Z30\0test-body\0picture-control-photo", slot: 209)
        XCTAssertNotNil(original); XCTAssertNil(original?.data); XCTAssertEqual(original?.selection, 5)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testAmbiguousWriteFailureRestoresOriginalThroughActualRepositoryProtocol() async throws {
        let file = try XCTUnwrap(builtInPictureControls().first).read()
        let encoded = try file.encodeClassicPictureControl()
        let previous = dataset()
        let wire = PictureControlWire([
            .init(0x1014, [0xD200], reply: descriptor()),
            .init(0x1015, [0x500E], reply: staInteger(UInt16(1))),
            .init(0x90CC, [3, 1, 0], reply: dataset(base: 3)),
            .init(0x90CF, [3, 0], reply: Data(repeating: 128, count: 28)),
            .init(0x90CC, [209, 0, 0], reply: previous), .init(0x90CC, [209, 1, 0], reply: previous),
            .init(0x1015, [0xD200], reply: staInteger(UInt16(5))),
            // The camera changes its slot but returns GeneralError: rollback
            // must re-read and restore, never assume the write did nothing.
            .init(0x90CD, [209, 0, 0], outgoing: encoded, response: 0x2002),
            .init(0x90CC, [209, 0, 0], reply: encoded), .init(0x90CC, [209, 1, 0], reply: encoded),
            .init(0x90CD, [209, 0, 0], outgoing: previous),
            .init(0x90CC, [209, 0, 0], reply: previous), .init(0x90CC, [209, 1, 0], reply: previous),
            .init(0x1016, [0xD200], outgoing: staInteger(UInt16(5))),
            .init(0x1015, [0xD200], reply: staInteger(UInt16(5)))
        ])
        let root = directory()
        do {
            try await repository(wire).changePictureControl(slot: 209, change: .write(file), movie: false,
                backupDirectory: root, isCurrent: { true })
            XCTFail("Failed write must remain a failure even after successful rollback")
        } catch let error as PictureControlReplacementError {
            XCTAssertEqual(error.stage, .write); XCTAssertTrue(error.originalRestored)
        }
        let original = try XCTUnwrap(PictureControlBackupStore(directory: root)
            .load(identity: "Nikon\0Z30\0test-body\0picture-control-photo", slot: 209))
        XCTAssertEqual(original.data, try NikonPictureControlSlotState(slot: 209, dataset: previous).data)
        XCTAssertEqual(original.selection, 5)
        let remaining = await wire.remaining
        XCTAssertEqual(remaining, 0)
    }
}

private actor PictureControlWire: PTPCommandTransport {
    struct Step: Sendable {
        let code: UInt16; let parameters: [UInt32]; let outgoing: Data?; let reply: Data; let response: UInt16
        init(_ code: UInt16, _ parameters: [UInt32], outgoing: Data? = nil, reply: Data = Data(), response: UInt16 = 0x2001) {
            self.code = code; self.parameters = parameters; self.outgoing = outgoing; self.reply = reply
            self.response = response
        }
    }
    private var steps: [Step]
    var remaining: Int { steps.count }
    init(_ steps: [Step]) { self.steps = steps }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let decoded = try PTPCodec.decode(command)
        guard !steps.isEmpty else { throw PTPSessionError.invalidResponse }
        let step = steps.removeFirst()
        XCTAssertEqual(decoded.code, step.code)
        XCTAssertEqual(decoded.payload, step.parameters.reduce(into: Data()) { $0 += staInteger($1) })
        XCTAssertEqual(data, step.outgoing)
        return (PTPCodec.encode(type: .response, code: step.response, transactionID: decoded.transactionID), step.reply)
    }
}
