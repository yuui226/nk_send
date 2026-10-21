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
                    .init(0x90CC, [1, 0, bank], reply: dataset()),
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
            .init(0x90CC, [1, 0, 0], reply: dataset()),
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
        let file = try SyntheticPictureControlFixture.file()
        let encoded = try file.encodeClassicPictureControl()
        var defaultHeader = Data(encoded.prefix(36)); defaultHeader[35] = 0
        let empty = Data(repeating: 0, count: 36)
        let wire = PictureControlWire([
            .init(0x90CC, [1, 0, 0], reply: dataset()),
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
        let file = try SyntheticPictureControlFixture.file()
        let encoded = try file.encodeClassicPictureControl()
        let previous = dataset()
        let wire = PictureControlWire([
            .init(0x90CC, [1, 0, 0], reply: dataset()),
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

/// Android NikonPictureControlProtocolTest + V2EncoderTest. Synthetic wire
/// fixtures assert command shapes; they do not claim D5600 hardware coverage.
final class NikonLegacyPictureControlTests: XCTestCase {
    private let operations: Set<UInt16> = [0x1014, 0x1015, 0x1016, 0x90CC, 0x940E, 0x90CE, 0x90CF]
    fileprivate static func legacy(_ item: Int = 1, curve: Bool = false) -> Data {
        var data = Data(repeating: 0, count: curve ? 610 : 32)
        data[0] = 1; data[2] = item >= 201 ? 1 : 0
        data.replaceSubrange(3..<11, with: Data("STANDARD".utf8))
        data[27] = 12; data[31] = curve ? 1 : 0
        if curve { for i in 32..<610 { data[i] = UInt8(truncatingIfNeeded: i * 37 + 11) } }
        return data
    }
    fileprivate static func empty() -> Data { var d = Data(repeating: 90, count: 32); d[2] = 2; return d }
    fileprivate static func descriptor() -> Data {
        let values = [UInt16](1...7) + [UInt16](201...209)
        var d = staInteger(UInt16(0xD200)) + staInteger(UInt16(4)) + Data([1]) + staInteger(UInt16(1)) + staInteger(UInt16(5)) + Data([2]) + staInteger(UInt16(values.count))
        for v in values { d += staInteger(v) }; return d
    }
    private func discover(_ steps: [PictureControlWire.Step], movie: Bool = false,
        properties: Set<UInt16> = [], operations: Set<UInt16>? = nil) async throws -> NikonPictureControlProtocol {
        let wire = PictureControlWire(steps), session = PTPSession(transport: wire)
        do {
            let result = try await discoverPictureControlProtocol(operations: operations ?? self.operations, properties: properties,
                exchange: { try await session.executeResponse(operation: $0, parameters: $1, data: $2) },
                sessionCheck: { true }, movie: movie)
            let left = await wire.remaining; XCTAssertEqual(left, 0); return result
        } catch { let left = await wire.remaining; XCTAssertEqual(left, 0); throw error }
    }
    func testDiscoveryConfirmsExplicitLegacyReadsAndMovieBankBeforeCaching() async throws {
        for movie in [false, true] {
            for first in [UInt16(0x2001), 0x2006, 0x201D] {
                for curve in [false, true] {
                    let result = try await discover([
                        .init(0x90CC, [1, 0, movie ? 1 : 0], reply: first == 0x2001 ? Self.legacy(curve: curve) : Data(), response: first),
                        .init(0x90CC, [1, 0], reply: Self.legacy(curve: curve)), .init(0x1014, [0xD237], response: 0x200A)
                    ], movie: movie)
                    XCTAssertEqual(result, NikonPictureControlProtocol(format: .legacyV2, supportsMovie: true))
                    XCTAssertNoThrow(try result.requireMode(movie))
                    XCTAssertEqual(result.format.selectionProperty(movie), 0xD200)
                }
            }
        }
    }
    func testUnverifiedMovieBankIsNotCachedAndAdvertisedBankIsPhotoOnly() async throws {
        for response in [UInt16(0x2001), 0x2019, 0x2002, 0x2006, 0x201D, 0x200F] {
            let result = try await discover([.init(0x90CC, [1, 0, 0], response: 0x201D),
                .init(0x90CC, [1, 0], reply: Self.legacy()), .init(0x1014, [0xD237], reply: Data([1]), response: response)])
            XCTAssertFalse(result.cacheable); XCTAssertFalse(result.supportsMovie)
            XCTAssertThrowsError(try result.requireMode(true)); XCTAssertNoThrow(try result.requireMode(false))
        }
        for advertised in [false, true] {
            let result = try await discover([.init(0x90CC, [1, 0, 0], response: 0x2006), .init(0x90CC, [1, 0], reply: Self.legacy())],
                properties: advertised ? [0xD237] : [], operations: operations.subtracting([0x1014]))
            XCTAssertEqual(result.cacheable, advertised); XCTAssertFalse(result.supportsMovie)
        }
        var descriptor = Self.descriptor(); descriptor[0] = 0x37; descriptor[1] = 0xD2
        let valid = try await discover([.init(0x90CC, [1, 0, 0], response: 0x201D),
            .init(0x90CC, [1, 0], reply: Self.legacy()), .init(0x1014, [0xD237], reply: descriptor)])
        XCTAssertTrue(valid.cacheable); XCTAssertFalse(valid.supportsMovie)
    }
    func testBusyMalformedAndOldLayoutsCannotTriggerProtocolFallback() async {
        for code in [UInt16(0x2019), 0x2002, 0x2003, 0x2005, 0x200A, 0x201F] {
            do { _ = try await discover([.init(0x90CC, [1, 0, 0], response: code)]); XCTFail() } catch {}
        }
        var invalidBase = Self.legacy(); invalidBase[0] = 2
        var invalidFlag = Self.legacy(); invalidFlag[2] = 2
        var truncatedCurve = Self.legacy(); truncatedCurve[31] = 1
        for payload in [Data(), Data([1]), Data(repeating: 0, count: 31), Data(repeating: 0, count: 609),
                        Data(repeating: 0, count: 32), Data(repeating: 0, count: 36), invalidBase, invalidFlag, truncatedCurve] {
            do { _ = try await discover([.init(0x90CC, [1, 0, 0], reply: payload)]); XCTFail("Accepted malformed data") } catch {}
        }
        for code in [UInt16(0x2006), 0x201D, 0x2019] {
            do { _ = try await discover([.init(0x90CC, [1, 0, 0], reply: Self.legacy()), .init(0x90CC, [1, 0], response: code)]); XCTFail() } catch {}
        }
    }
    func testDiscoveryCancellationAndSessionGuardsNeverWriteOrRetry() async {
        for error in [CancellationError() as any Error, URLError(.networkConnectionLost)] {
            let script = DiscoveryFailureScript(error: error)
            do {
                _ = try await discoverPictureControlProtocol(operations: operations, properties: [], exchange: { try await script.exchange($0, $1, $2) },
                    sessionCheck: { true }, movie: false)
                XCTFail()
            } catch { XCTAssertTrue(error is CancellationError || error is URLError) }
            let count = await script.count; XCTAssertEqual(count, 1)
        }
        for missing in [false, true] {
            do {
                _ = try await discoverPictureControlProtocol(operations: missing ? [] : operations, properties: [], exchange: { _, _, _ in
                    XCTFail("No command may be sent"); throw PTPSessionError.invalidResponse
                }, sessionCheck: { false }, movie: false); XCTFail()
            } catch {}
        }
    }
    func testLegacyDataPreservesOpaqueCurvesRegistrationAndNamePadding() throws {
        for count in [32, 610] {
            var empty = Data(repeating: 90, count: count); empty[2] = 2
            let parsed = try NikonPictureControlData(item: 209, responseCode: 0x2001, data: empty, format: .legacyV2)
            XCTAssertTrue(parsed.isEmpty); XCTAssertEqual(parsed.data, empty)
            XCTAssertThrowsError(try NikonPictureControlData(item: 1, responseCode: 0x2001, data: empty, format: .legacyV2))
        }
        var mono = Self.legacy(203, curve: true); mono[0] = 4; mono[1] = 1; mono[15] = 120
        var adjusted = mono; adjusted[25] = 20; adjusted[120] ^= 0x55
        let original = try NikonPictureControlData(item: 203, responseCode: 0x2001, data: mono, format: .legacyV2)
        let current = try NikonPictureControlData(item: 203, responseCode: 0x2001, data: adjusted, format: .legacyV2)
        let snapshot = try NikonPictureControlSlotState(defaults: original, current: current).data
        let restored = try NikonPictureControlSlotState(slot: 203, snapshot: snapshot, format: .legacyV2)
        XCTAssertEqual(restored.defaults.data, mono); XCTAssertEqual(restored.current.data, adjusted)
        XCTAssertThrowsError(try NikonPictureControlSlotState(slot: 203, snapshot: snapshot))
        for index in [0, 1, 2, 31] {
            var bad = Self.legacy(203); bad[index] = index == 0 ? 0 : 3
            XCTAssertThrowsError(try NikonPictureControlData(item: 203, responseCode: 0x2001, data: bad, format: .legacyV2))
        }
    }
    func testUserNP3V2EncodingPreservesCurveAndRejectsNewerAdjustments() throws {
        for withCurve in [false, true] {
            let file = try SyntheticPictureControlFixture.file(withCurve: withCurve)
            XCTAssertEqual(try file.encodePictureControl(format: .classicZ), try file.encodeClassicPictureControl())
            let data = try file.encodePictureControl(format: .legacyV2)
            let parsed = try NikonPictureControlData(item: 209, responseCode: 0x2001, data: data, format: .legacyV2)
            XCTAssertEqual(parsed.name, file.name)
            XCTAssertEqual(data.count, withCurve ? 610 : 32)
            XCTAssertEqual(data[2], 1, "User NP3 must be registered as custom")
            if withCurve { XCTAssertEqual(data.subdata(in: 32..<610), SyntheticPictureControlFixture.curve) }
        }
        let unsupported = try SyntheticPictureControlFixture.file(midRange: 4)
        XCTAssertNoThrow(try unsupported.encodePictureControl(format: .classicZ))
        XCTAssertThrowsError(try unsupported.encodePictureControl(format: .legacyV2)) {
            guard case NikonPictureControlError.presetUnsupported = $0 else { return XCTFail("Wrong error: \($0)") }
        }
        let file = try SyntheticPictureControlFixture.file()
        let classic = try file.encodeClassicPictureControl()
        for (offset, value) in [(0, 111), (25, 255), (26, 4), (22, 10), (23, 1), (24, 1), (32, 1), (33, 1), (34, 1)] {
            var changed = classic; changed[offset] = UInt8(value)
            XCTAssertThrowsError(try encodeV2PictureControl(changed)) { XCTAssertTrue($0 is NikonPictureControlError) }
        }
        var scalars = Data(classic.prefix(36))
        for (i, v) in [(25, 36), (27, 236), (28, 128), (29, 6), (30, 128), (31, 244), (35, 0)] { scalars[i] = UInt8(v) }
        let data = try encodeV2PictureControl(scalars)
        XCTAssertEqual(data.subdata(in: 23..<32), Data([0, 0, 128, 244, 36, 128, 6, 236, 0]))
        var caps = Data(repeating: 0, count: 39); caps[0] = 1
        caps.replaceSubrange(1...7, with: Data(repeating: 129, count: 7))
        XCTAssertNoThrow(try validateV2PictureControlCapabilities(dataset: data, capabilities: caps))
        caps[4] = 128
        XCTAssertThrowsError(try validateV2PictureControlCapabilities(dataset: data, capabilities: caps))
        for invalid in [Data(repeating: 0, count: 28), Data(repeating: 0, count: 39), Data(repeating: 0, count: 40)] {
            XCTAssertThrowsError(try validateV2PictureControlCapabilities(dataset: data, capabilities: invalid))
        }
    }
}

private actor DiscoveryFailureScript {
    let error: any Error
    var count = 0
    init(error: any Error) { self.error = error }
    func exchange(_ code: UInt16, _ parameters: [UInt32], _ data: Data?) throws -> PTPResponse {
        count += 1; XCTAssertEqual(code, 0x90CC); XCTAssertEqual(parameters, [1, 0, 0]); XCTAssertNil(data)
        throw error
    }
}

private actor LegacyPictureControlFixture: PTPCommandTransport {
    struct Call: Equatable { let code: UInt16; let params: [UInt32]; let data: Data? }
    struct Slot: Equatable { var defaults: Data; var current: Data }
    static let operations: Set<UInt16> = [0x1014, 0x1015, 0x1016, 0x90CC, 0x940E, 0x90CE, 0x90CF]
    var slots: [Int: Slot]
    var selected = 5
    var failDelete = false
    var rejectSelection: Int?
    var capabilities: Data
    var calls: [Call] = []
    init() {
        slots = Dictionary(uniqueKeysWithValues: (201...209).map { slot in
            var bytes = slot == 209 ? NikonLegacyPictureControlTests.empty() : NikonLegacyPictureControlTests.legacy(slot, curve: slot == 203)
            if slot == 203 { bytes[0] = 4; bytes[1] = 1 }
            var adjusted = bytes
            if slot == 203 { adjusted[25] = 24; adjusted[197] ^= 0x42 }
            return (slot, Slot(defaults: bytes, current: adjusted))
        })
        capabilities = Data(repeating: 0, count: 39); capabilities[0] = 1
        capabilities.replaceSubrange(1...7, with: Data(repeating: 129, count: 7))
    }
    func configure(selected: Int? = nil, failDelete: Bool = false, rejectSelection: Int? = nil, invalidCapabilities: Bool = false) {
        if let selected { self.selected = selected }
        self.failDelete = failDelete; self.rejectSelection = rejectSelection
        if invalidCapabilities { capabilities = Data(repeating: 0, count: 28) }
    }
    func makeOccupied(_ slot: Int) { let d = NikonLegacyPictureControlTests.legacy(slot, curve: true); slots[slot] = Slot(defaults: d, current: d) }
    func malformed(_ slot: Int) { slots[slot]?.current = Data(repeating: 0, count: 32) }
    nonisolated func access(_ slot: Int, movie: Bool = false, operations: Set<UInt16> = operations) throws -> NikonPictureControlAccess {
        try NikonPictureControlAccess(cameraIdentity: "synthetic-d5600\0picture-control-photo", slot: slot, movie: movie,
            operations: operations, sessionCheck: { true }, exchange: { try await self.exchange($0, $1, $2) }, format: .legacyV2)
    }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let decoded = try PTPCodec.decode(command); var reader = PTPDataReader(decoded.payload); var params: [UInt32] = []
        while let value = reader.readUInt32() { params.append(value) }
        let response = try exchange(decoded.code, params, data)
        return (PTPCodec.encode(type: .response, code: response.code, transactionID: decoded.transactionID), response.data)
    }
    func exchange(_ code: UInt16, _ parameters: [UInt32], _ data: Data?) throws -> PTPResponse {
        calls.append(Call(code: code, params: parameters, data: data))
        func response(_ code: UInt16 = 0x2001, _ data: Data = Data()) -> PTPResponse { .init(code: code, transactionID: 1, data: data) }
        switch code {
        case 0x1014:
            if parameters == [0xD237] { return response(0x200A) }
            XCTAssertEqual(parameters, [0xD200]); return response(0x2001, NikonLegacyPictureControlTests.descriptor())
        case 0x1015:
            XCTAssertEqual(parameters.count, 1); XCTAssertTrue([0x500E, 0xD200].contains(parameters[0]))
            return response(0x2001, staInteger(UInt16(parameters[0] == 0x500E ? 1 : selected)))
        case 0x1016:
            XCTAssertEqual(parameters, [0xD200]); let d = try XCTUnwrap(data); XCTAssertEqual(d.count, 2)
            let target = Int(d[0]) | Int(d[1]) << 8
            if rejectSelection == target { rejectSelection = nil; return response(0x201F) }
            if target >= 201 { XCTAssertEqual(slots[target]?.current[2], 1) }
            selected = target; return response()
        case 0x90CC:
            if parameters.count == 3 { XCTAssertEqual(parameters[0], 1); return response(0x201D) }
            XCTAssertEqual(parameters.count, 2); XCTAssertTrue(parameters[1] <= 1)
            if let slot = slots[Int(parameters[0])] { return response(0x2001, parameters[1] == 0 ? slot.current : slot.defaults) }
            XCTAssertEqual(parameters[0], 1); return response(0x2001, NikonLegacyPictureControlTests.legacy())
        case 0x90CF:
            XCTAssertEqual(parameters, [1]); return response(0x2001, capabilities)
        case 0x940E:
            XCTAssertEqual(parameters.count, 3); XCTAssertEqual(parameters[2], 1)
            let target = Int(parameters[0]), bytes = try XCTUnwrap(data)
            XCTAssertEqual(bytes[2], 1); XCTAssertTrue((201...209).contains(target))
            if parameters[1] == 0 { slots[target] = Slot(defaults: bytes, current: bytes) }
            else { XCTAssertEqual(parameters[1], 1); slots[target]?.current = bytes }
            return response()
        case 0x90CE:
            XCTAssertEqual(parameters.count, 1); let target = Int(parameters[0]); XCTAssertNotEqual(selected, target)
            let bytes = NikonLegacyPictureControlTests.empty(); slots[target] = Slot(defaults: bytes, current: bytes)
            if failDelete { failDelete = false; return response(0x2002) }; return response()
        default: XCTFail("Unexpected command \(code)"); throw PTPSessionError.invalidResponse
        }
    }
}

final class NikonLegacyPictureControlMutationTests: XCTestCase {
    private func backup() -> PictureControlBackupStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PictureControlBackupStore(directory: root)
    }
    func testNineSlotsReadAndMalformedSlotRemainsUnreadableWithoutMutations() async throws {
        for movie in [false, true] {
            let camera = LegacyPictureControlFixture(), store = backup()
            let access = try camera.access(201, movie: movie)
            let overview = try await access.overview(backup: store)
            XCTAssertEqual(overview.slots.map(\.slot), Array(201...209)); XCTAssertEqual(overview.slots.last?.availability, .empty)
            XCTAssertTrue(overview.canActivate); XCTAssertTrue(overview.canEdit)
            await camera.malformed(204)
            let next = try await access.overview(backup: store)
            XCTAssertEqual(next.slots[3].availability, .unreadable)
            XCTAssertTrue(next.slots.enumerated().filter { $0.offset != 3 }.allSatisfy { $0.element.readable })
            let calls = await camera.calls; XCTAssertFalse(calls.contains { [0x940E, 0x90CE, 0x1016].contains($0.code) })
        }
    }
    func testActivationKeepsEverySlotAndCreatesNoBackupInEitherMode() async throws {
        for movie in [false, true] { for slot in 201...208 {
            let camera = LegacyPictureControlFixture(), store = backup(); let before = await camera.slots
            let access = try camera.access(slot, movie: movie)
            try await access.prepareSelection(); try await PictureControlReplacement(backup: store).activate(access)
            let after = await camera.slots, selected = await camera.selected, calls = await camera.calls
            XCTAssertEqual(after, before); XCTAssertEqual(selected, slot)
            XCTAssertNil(try store.load(identity: access.cameraIdentity, slot: slot))
            XCTAssertFalse(calls.contains { [0x940E, 0x90CE].contains($0.code) })
        } }
    }
    func testReplacementAndEveryClearUseExactTargetAndPreserveNeighbors() async throws {
        for movie in [false, true] {
            let camera = LegacyPictureControlFixture(), store = backup(), access = try camera.access(207, movie: movie)
            let before = await camera.slots; var bytes = NikonLegacyPictureControlTests.legacy(207, curve: true); bytes[25] = 7
            try await access.prepare(dataset: bytes)
            try await PictureControlReplacement(backup: store).apply(access, dataset: NikonPictureControlSlotState(slot: 207, dataset: bytes, format: .legacyV2).data)
            let after = await camera.slots, calls = await camera.calls
            XCTAssertEqual(after.filter { $0.key != 207 }, before.filter { $0.key != 207 })
            XCTAssertEqual(after[207]?.defaults, bytes)
            XCTAssertEqual(calls.filter { $0.code == 0x940E }.map(\.params), [[207, 0, 1]])
            for slot in 201...209 { for active in [false, true] {
                let camera = LegacyPictureControlFixture(), store = backup(); await camera.makeOccupied(slot)
                await camera.configure(selected: active ? slot : 5)
                let before = await camera.slots, access = try camera.access(slot, movie: movie)
                try await access.prepare(); try await PictureControlReplacement(backup: store).clear(access)
                let after = await camera.slots, selected = await camera.selected, calls = await camera.calls
                XCTAssertEqual(after.filter { $0.key != slot }, before.filter { $0.key != slot })
                XCTAssertEqual(selected, active ? 1 : 5)
                let remaining = try await access.readSlot(); XCTAssertNil(remaining)
                XCTAssertEqual(calls.filter { [0x940E, 0x90CE, 0x1016].contains($0.code) }.map(\.code), active ? [0x1016, 0x90CE] : [0x90CE])
            } }
        }
    }
    func testFailedDeleteRestoresOpaqueDefaultAndCurrentCurvesAndSelection() async throws {
        for movie in [false, true] {
            let camera = LegacyPictureControlFixture(), store = backup(); await camera.configure(selected: 203, failDelete: true)
            let before = await camera.slots, access = try camera.access(203, movie: movie)
            try await access.prepare()
            do { try await PictureControlReplacement(backup: store).clear(access); XCTFail() }
            catch let error as PictureControlReplacementError { XCTAssertTrue(error.originalRestored) }
            let after = await camera.slots, selected = await camera.selected, calls = await camera.calls
            XCTAssertEqual(after, before); XCTAssertEqual(selected, 203)
            XCTAssertEqual(calls.filter { $0.code == 0x940E }.map(\.params), [[203, 0, 1], [203, 1, 1]])
            let current = try await access.readSlot(); XCTAssertEqual(try store.load(identity: access.cameraIdentity, slot: 203)?.data, current)
        }
    }
    func testInvalidCapabilitiesOrMissingV2WriteDoNotAuthorizeDeletion() async throws {
        for invalidCapabilities in [false, true] {
            let camera = LegacyPictureControlFixture(), store = backup()
            await camera.configure(invalidCapabilities: invalidCapabilities)
            let ops = invalidCapabilities ? LegacyPictureControlFixture.operations : LegacyPictureControlFixture.operations.subtracting([0x940E]).union([0x90CD])
            let access = try camera.access(203, operations: ops), before = await camera.slots
            let overview = try await access.overview(backup: store)
            XCTAssertTrue(overview.canActivate); XCTAssertEqual(overview.canEdit, invalidCapabilities)
            do { try await access.prepare(); XCTFail() } catch {}
            do { try await access.clearSlot(); XCTFail() } catch {}
            let after = await camera.slots, calls = await camera.calls; XCTAssertEqual(after, before)
            XCTAssertFalse(calls.contains { [0x940E, 0x90CE, 0x1016].contains($0.code) })
        }
    }
    func testRepositoryCachesConfirmedSharedProtocolAndUsesOneBackupBank() async throws {
        let camera = LegacyPictureControlFixture(), store = backup()
        let info = PTPDeviceInfo(standardVersion: 100, vendorExtensionID: 10, vendorExtensionVersion: 100,
            vendorExtensionDescription: "", functionalMode: 0, manufacturer: "Nikon", model: "D5600", version: "1",
            serialNumber: "legacy", operations: LegacyPictureControlFixture.operations, events: [], properties: [], captureFormats: [], imageFormats: [])
        let repository = CameraRepository(session: PTPSession(transport: camera), deviceInfo: info)
        for movie in [false, true] {
            _ = try await repository.readPictureControlOverview(movie: movie, backupDirectory: store.directory, isCurrent: { true })
            try await repository.changePictureControl(slot: 203, change: .activate, movie: movie, backupDirectory: store.directory, isCurrent: { true })
        }
        let calls = await camera.calls
        XCTAssertEqual(calls.filter { $0.code == 0x90CC && $0.params.count == 3 }.count, 1)
        XCTAssertEqual(calls.filter { $0.code == 0x1014 && $0.params == [0xD237] }.count, 1)
        try await repository.changePictureControl(slot: 203, change: .clear, movie: true, backupDirectory: store.directory, isCurrent: { true })
        XCTAssertNotNil(try store.load(identity: "Nikon\0D5600\0legacy\0picture-control-photo", slot: 203))
        XCTAssertNil(try store.load(identity: "Nikon\0D5600\0legacy\0picture-control-movie", slot: 203))
    }
}
