import XCTest
@testable import ZTransfer

/// Android NikonPictureControlDataTest/SlotsTest at 431132ca. A registered-only
/// descriptor is deliberately independent of the camera's nine physical slots.
final class PictureControlRegisteredSlotsTests: XCTestCase {
    private func store() -> PictureControlBackupStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PictureControlBackupStore(directory: root)
    }

    func testUnusedClassicSlotUsesOnlyZeroBaseAndPreservesUndefinedBytes() throws {
        for slot in 201...209 { for count in [36, 614] { for fill in [UInt8(0), 255] {
            var bytes = Data(repeating: fill, count: count); bytes[0] = 0; bytes[1] = 0
            let parsed = try NikonPictureControlData(item: slot, responseCode: 0x2001, data: bytes)
            XCTAssertTrue(parsed.isEmpty); XCTAssertEqual(parsed.baseItem, 0)
            XCTAssertEqual(parsed.name, ""); XCTAssertNil(parsed.curve); XCTAssertEqual(parsed.data, bytes)
            let preserved = bytes; bytes[2] ^= 1
            XCTAssertEqual(parsed.data, preserved)
        } } }
        for item in [1, 100, 200, 210] { for size in [36, 614] {
            XCTAssertThrowsError(try NikonPictureControlData(item: item, responseCode: 0x2001, data: Data(repeating: 0, count: size)))
        } }
        for size in [0, 2, 31, 32, 35, 37, 610, 613, 615] {
            XCTAssertThrowsError(try NikonPictureControlData(item: 209, responseCode: 0x2001, data: Data(repeating: 0, count: size)))
        }
    }

    func testRegisteredOnlySlotsSupportWriteClearAndWriteAgainInBothBanks() async throws {
        for movie in [false, true] { for slot in [201, 209] {
            let camera = RegisteredSlotCamera(), backup = store(), access = try camera.access(slot, movie: movie)
            let empty = try await access.overview(backup: backup)
            XCTAssertEqual(empty.slots.map(\.slot), Array(201...209))
            XCTAssertTrue(empty.slots.allSatisfy { $0.availability == .empty && !$0.selectable && $0.editable })
            let otherBefore = await camera.bank(!movie)
            for base in [UInt8(1), 3] {
                let data = RegisteredSlotCamera.dataset(base)
                try await access.prepare(dataset: data)
                try await PictureControlReplacement(backup: backup).apply(access,
                    dataset: NikonPictureControlSlotState(slot: slot, dataset: data).data)
                let selected = await camera.selection(movie)
                XCTAssertEqual(selected, slot)
                let overview = try await access.overview(backup: backup)
                let occupied = try XCTUnwrap(overview.slots.first { $0.slot == slot })
                XCTAssertTrue(occupied.selectable && occupied.editable)
                try await access.prepare()
                try await PictureControlReplacement(backup: backup).clear(access)
                let cleared = try await access.readSlot()
                XCTAssertNil(cleared)
            }
            let otherAfter = await camera.bank(!movie), calls = await camera.calls
            XCTAssertEqual(otherBefore, otherAfter)
            XCTAssertTrue(calls.filter { [0x90CD, 0x90CE].contains($0.code) }.allSatisfy { $0.parameters[0] == UInt32(slot) })
            XCTAssertNotNil(try backup.load(identity: access.cameraIdentity, slot: slot))
        } }
    }

    func testMissingDescriptorEntriesAreReadAndOnlyExplicitResponsesAreUnsupported() async throws {
        for code in [UInt16(0x2005), 0x2006, 0x201D, 0x2019, 0x2002, 0x200A, 0x2001] {
            let camera = RegisteredSlotCamera(), backup = store()
            await camera.failRead(204, code: code)
            let rows = try await camera.access(201).overview(backup: backup).slots
            let row = try XCTUnwrap(rows.first { $0.slot == 204 })
            XCTAssertEqual(row.availability, [0x2005, 0x2006, 0x201D].contains(code) ? .unsupported : .unreadable)
            XCTAssertFalse(row.editable || row.selectable || row.readable)
            XCTAssertTrue(rows.filter { $0.slot != 204 }.allSatisfy { $0.availability == .empty })
            let calls = await camera.calls
            XCTAssertTrue(calls.contains { $0.code == 0x90CC && $0.parameters[0] == 204 })
            XCTAssertFalse(calls.contains { [0x90CD, 0x90CE, 0x1016].contains($0.code) })
        }
    }

    func testOccupiedUnlistedSlotCannotActivateOverwriteOrClear() async throws {
        for movie in [false, true] {
            let camera = RegisteredSlotCamera(), backup = store(), access = try camera.access(203, movie: movie)
            await camera.occupy(203, movie: movie); await camera.hide(203)
            let before = await camera.bank(movie)
            let overview = try await access.overview(backup: backup)
            let row = try XCTUnwrap(overview.slots.first { $0.slot == 203 })
            XCTAssertTrue(row.readable); XCTAssertFalse(row.selectable || row.editable)
            do { try await access.prepareSelection(); XCTFail("Activation must be rejected") } catch {}
            do { try await access.prepare(dataset: RegisteredSlotCamera.dataset(3)); XCTFail("Write must be rejected") } catch {}
            do { try await access.prepare(); XCTFail("Clear must be rejected") } catch {}
            let after = await camera.bank(movie), calls = await camera.calls
            XCTAssertEqual(before, after)
            XCTAssertFalse(calls.contains { [0x90CD, 0x90CE, 0x1016].contains($0.code) })
            XCTAssertNil(try backup.load(identity: access.cameraIdentity, slot: 203))
        }
    }

    func testActivationRechecksCurrentChoicesAndWritePermission() async throws {
        for readOnly in [false, true] {
            let camera = RegisteredSlotCamera(), access = try camera.access(203)
            await camera.occupy(203); try await access.prepareSelection()
            if readOnly { await camera.makeReadOnly() } else { await camera.hide(203) }
            do { try await access.select(203); XCTFail("Stale preparation cannot authorize activation") } catch {}
            let calls = await camera.calls
            XCTAssertFalse(calls.contains { $0.code == 0x1016 })
        }
    }

    func testRejectedPostWriteSelectionRestoresOriginalAndSelection() async throws {
        for movie in [false, true] { for occupied in [false, true] {
            let camera = RegisteredSlotCamera(), backup = store(), access = try camera.access(203, movie: movie)
            if occupied { await camera.occupy(203, movie: movie) }
            let before = await camera.bank(movie), selectedBefore = await camera.selection(movie)
            let original = try await access.readSlot(), data = RegisteredSlotCamera.dataset(3)
            try await access.prepare(dataset: data)
            await camera.rejectNextWrittenSelection()
            do {
                try await PictureControlReplacement(backup: backup).apply(access,
                    dataset: NikonPictureControlSlotState(slot: 203, dataset: data).data)
                XCTFail("Missing post-write choice must fail")
            } catch let error as PictureControlReplacementError {
                XCTAssertEqual(error.stage, .activate); XCTAssertTrue(error.originalRestored)
            }
            let after = await camera.bank(movie), selectedAfter = await camera.selection(movie)
            XCTAssertEqual(before, after); XCTAssertEqual(selectedBefore, selectedAfter)
            XCTAssertEqual(try backup.load(identity: access.cameraIdentity, slot: 203)?.data, original)
        } }
    }
}

private actor RegisteredSlotCamera {
    struct Slot: Equatable { var defaults: Data; var current: Data }
    struct Call { let code: UInt16; let parameters: [UInt32] }
    private var banks = [Bool: [Int: Slot]]()
    private var selected = [false: 5, true: 5]
    private var hidden = Set<Int>()
    private var failures: [Int: UInt16] = [:]
    private var writable = true
    private var rejectWritten = false
    private var omitted: (Bool, Int)?
    var calls: [Call] = []
    init() {
        for movie in [false, true] {
            banks[movie] = Dictionary(uniqueKeysWithValues: (201...209).map { ($0, Slot(defaults: Self.empty, current: Self.empty)) })
        }
    }
    static let empty = Data(repeating: 0, count: 36)
    static func dataset(_ base: UInt8) -> Data {
        var data = empty; data[0] = base
        data.replaceSubrange(2..<9, with: Data("Fixture".utf8)); return data
    }
    func bank(_ movie: Bool) -> [Int: Slot] { banks[movie]! }
    func selection(_ movie: Bool) -> Int { selected[movie]! }
    func occupy(_ slot: Int, movie: Bool = false) {
        let data = Self.dataset(1); banks[movie]![slot] = Slot(defaults: data, current: data)
        selected[movie] = slot
    }
    func hide(_ slot: Int) { hidden.insert(slot) }
    func failRead(_ slot: Int, code: UInt16) { failures[slot] = code }
    func makeReadOnly() { writable = false }
    func rejectNextWrittenSelection() { rejectWritten = true }
    nonisolated func access(_ slot: Int, movie: Bool = false) throws -> NikonPictureControlAccess {
        try NikonPictureControlAccess(cameraIdentity: "fixture-\(movie)", slot: slot, movie: movie,
            operations: [0x1014, 0x1015, 0x1016, 0x90CC, 0x90CD, 0x90CE, 0x90CF],
            sessionCheck: { true }, exchange: { try await self.exchange($0, $1, $2) })
    }
    private func exchange(_ code: UInt16, _ p: [UInt32], _ data: Data?) throws -> PTPResponse {
        calls.append(Call(code: code, parameters: p))
        func response(_ data: Data = Data(), code: UInt16 = 0x2001) -> PTPResponse { .init(code: code, transactionID: 1, data: data) }
        switch code {
        case 0x1014:
            let movie = p[0] == 0xD237
            let omit = omitted?.0 == movie ? omitted?.1 : nil
            if omit != nil { omitted = nil }
            let choices = [1, 3, 5] + (201...209).filter {
                banks[movie]![$0]!.current[0] != 0 && !hidden.contains($0) && $0 != omit
            }
            var bytes = staInteger(UInt16(p[0])) + staInteger(UInt16(4)) + Data([writable ? 1 : 0])
            bytes += staInteger(UInt16(1)) + staInteger(UInt16(selected[movie]!)) + Data([2]) + staInteger(UInt16(choices.count))
            for choice in choices { bytes += staInteger(UInt16(choice)) }; return response(bytes)
        case 0x1015: return response(staInteger(UInt16(p[0] == 0x500E ? 1 : selected[p[0] == 0xD237]!)))
        case 0x90CC:
            let item = Int(p[0]), movie = p[2] == 1
            if let code = failures[item] { return response(code: code) }
            if let slot = banks[movie]![item] { return response(p[1] == 0 ? slot.current : slot.defaults) }
            return response(Self.dataset(UInt8(item)))
        case 0x90CF: return response(Data(repeating: 128, count: 28))
        case 0x90CD:
            let item = Int(p[0]), movie = p[2] == 1, bytes = try XCTUnwrap(data)
            if p[1] == 0 { banks[movie]![item] = Slot(defaults: bytes, current: bytes) }
            else { banks[movie]![item]!.current = bytes }
            if rejectWritten { omitted = (movie, item); rejectWritten = false }; return response()
        case 0x90CE:
            banks[p[1] == 1]![Int(p[0])] = Slot(defaults: Self.empty, current: Self.empty); return response()
        case 0x1016:
            let bytes = try XCTUnwrap(data), value = Int(bytes[0]) | Int(bytes[1]) << 8
            XCTAssertTrue(writable); XCTAssertFalse(hidden.contains(value))
            selected[p[0] == 0xD237] = value; return response()
        default: XCTFail("Unexpected command \(code)"); throw PTPSessionError.invalidResponse
        }
    }
}
