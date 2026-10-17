import Foundation

struct NikonPictureControlSlotState: Equatable, Sendable {
    let defaults: NikonPictureControlData
    let current: NikonPictureControlData
    init(defaults: NikonPictureControlData, current: NikonPictureControlData) throws {
        guard !defaults.isEmpty, !current.isEmpty, defaults.baseItem == current.baseItem else {
            throw NikonPictureControlError.invalid("Invalid Picture Control slot state")
        }
        self.defaults = defaults; self.current = current
    }
    init(slot: Int, dataset: Data) throws {
        let parsed = try NikonPictureControlData(item: slot, responseCode: 0x2001, data: dataset)
        try self.init(defaults: parsed, current: parsed)
    }
    init(slot: Int, snapshot: Data) throws {
        var reader = PTPDataReader(snapshot)
        guard reader.readUInt32() == 0x31534350,
              let d = reader.readUInt32(), let c = reader.readUInt32(),
              [36, 614].contains(d), [36, 614].contains(c), reader.remaining == Int(d + c),
              let defaults = reader.readBytes(count: Int(d)), let current = reader.readBytes(count: Int(c)) else {
            throw NikonPictureControlError.invalid("Unknown or truncated slot snapshot format")
        }
        try self.init(defaults: NikonPictureControlData(item: slot, responseCode: 0x2001, data: defaults),
                      current: NikonPictureControlData(item: slot, responseCode: 0x2001, data: current))
    }
    var data: Data {
        var result = Data()
        let header: [UInt32] = [0x31534350, UInt32(defaults.data.count), UInt32(current.data.count)]
        for value in header {
            for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        result.append(defaults.data); result.append(current.data)
        return result
    }
}

enum PictureControlSlotAvailability: Equatable, Sendable { case occupied, empty, unreadable, unsupported }
struct PictureControlSlotInfo: Identifiable, Equatable, Sendable {
    let slot: Int
    let availability: PictureControlSlotAvailability
    var name: String? = nil
    var hasOriginal = false
    var id: Int { slot }
    var number: Int { slot - 200 }
    var readable: Bool { availability == .occupied || availability == .empty }
}
struct PictureControlOverview: Equatable, Sendable {
    let slots: [PictureControlSlotInfo]
    let selected: Int
    let canActivate: Bool
    let canEdit: Bool
}
enum PictureControlChange: Sendable {
    case write(NikonPictureControlFile)
    case activate, clear, restore
}
struct PictureControlExposureModeError: Error, LocalizedError {
    let program: Int
    let userMode: Int?
    var errorDescription: String? {
        String(format: "Picture Control requires P/S/A/M: exposure=0x%04X userMode=%@", program,
               userMode.map(String.init) ?? "null")
    }
}

/// Bound to a specific body, photo/movie bank and explicit C1–C9 slot. Every
/// new action repeats descriptor and effective-exposure preflight before writes.
actor NikonPictureControlAccess: PictureControlSlotAccess {
    typealias Exchange = @Sendable (UInt16, [UInt32], Data?) async throws -> PTPResponse
    nonisolated let cameraIdentity: String
    nonisolated let slot: Int
    private let movie: Bool
    private let operations: Set<UInt16>
    private let sessionCheck: @Sendable () async -> Bool
    private let exchange: Exchange
    private let log: (@Sendable (String) -> Void)?
    private var selection: NikonPictureControlSelection?
    private var writePrepared = false
    private var selectionPrepared = false
    private let writeOperations: Set<UInt16> = [0x1014, 0x1015, 0x1016, 0x90CC, 0x90CD, 0x90CE, 0x90CF]
    private var mode: UInt32 { movie ? 1 : 0 }
    private var property: UInt32 { movie ? 0xD237 : 0xD200 }

    init(cameraIdentity: String, slot: Int, movie: Bool, operations: Set<UInt16>,
         sessionCheck: @escaping @Sendable () async -> Bool, exchange: @escaping Exchange,
         log: (@Sendable (String) -> Void)? = nil) throws {
        guard NikonPictureControlData.customSlots.contains(slot) else { throw NikonPictureControlError.invalid("Only C1–C9 are custom slots") }
        self.cameraIdentity = cameraIdentity; self.slot = slot; self.movie = movie; self.operations = operations
        self.sessionCheck = sessionCheck; self.exchange = exchange; self.log = log
    }
    func checkSession() async throws {
        guard await sessionCheck() else { throw NikonPictureControlError.invalid("Camera session changed") }
    }
    private func command(_ code: UInt16, _ parameters: [UInt32], _ data: Data? = nil) async throws -> Data {
        try await checkSession()
        if let data { log?(String(format: "out op=0x%04X params=%@ bytes=%d data=%@", code,
            parameters.map(String.init).joined(separator: ","), data.count, data.map { String(format: "%02x", $0) }.joined())) }
        let response = try await exchange(code, parameters, data)
        log?(String(format: "in op=0x%04X params=%@ rc=0x%04X bytes=%d data=%@", code,
            parameters.map(String.init).joined(separator: ","), response.code, response.data.count,
            response.data.map { String(format: "%02x", $0) }.joined()))
        guard response.code == 0x2001 else {
            throw NikonPictureControlError.invalid(String(format: "Picture Control op=0x%04X failed: 0x%04X", code, response.code))
        }
        return response.data
    }
    private func selectionDescriptor() async throws -> NikonPictureControlSelection {
        try await NikonPictureControlSelection(command(0x1014, [property]), property: UInt16(property))
    }
    func prepareSelection() async throws {
        selectionPrepared = false; writePrepared = false; selection = nil
        try require(Set<UInt16>([0x1014, 0x1015, 0x1016, 0x90CC]).isSubset(of: operations),
                    "Camera does not advertise Picture Control activation")
        let descriptor = try await selectionDescriptor()
        try require(descriptor.writable && descriptor.supportsSlot(slot), "Camera does not expose writable C\(slot - 200)")
        let program = try await readU16(0x500E)
        let userMode: Int?
        if NikonPictureControlExposure.needsUserMode(program) {
            let bytes = try await command(0x1015, [0xD0FC])
            try require(bytes.count == 1, "Unexpected UserMode property format")
            userMode = Int(bytes[bytes.startIndex])
        } else { userMode = nil }
        guard NikonPictureControlExposure.permitsAdjustment(program: program, userMode: userMode) else {
            throw PictureControlExposureModeError(program: program, userMode: userMode)
        }
        selection = descriptor; selectionPrepared = true
    }
    func prepare(dataset: Data? = nil) async throws {
        writePrepared = false
        try require(writeOperations.isSubset(of: operations), "Camera does not advertise Picture Control editing")
        try await prepareSelection()
        if let dataset {
            let parsed = try NikonPictureControlData(item: slot, responseCode: 0x2001, data: dataset)
            try require(selection?.choices.contains(parsed.baseItem) == true, "Camera does not support this base Picture Control")
            let base = try await readData(item: parsed.baseItem, defaultFlag: 1)
            try require(!base.isEmpty && base.baseItem == parsed.baseItem, "Unexpected base Picture Control layout")
            let capabilities = try await command(0x90CF, [UInt32(parsed.baseItem), mode])
            try validatePictureControlCapabilities(dataset: dataset, capabilities: capabilities)
        }
        writePrepared = true
    }
    func overview(backup: PictureControlBackupStore) async throws -> PictureControlOverview {
        try require(Set<UInt16>([0x1014, 0x1015, 0x90CC]).isSubset(of: operations), "Picture Control reading is unavailable")
        let descriptor = try await selectionDescriptor(), selected = try await readSelection()
        var slots: [PictureControlSlotInfo] = []
        for item in NikonPictureControlData.customSlots {
            let hasOriginal = (try? backup.load(identity: cameraIdentity, slot: item)) != nil
            guard descriptor.supportsSlot(item) else { slots.append(.init(slot: item, availability: .unsupported)); continue }
            do {
                let current = try await readData(item: item, defaultFlag: 0)
                slots.append(.init(slot: item, availability: current.isEmpty ? .empty : .occupied,
                                   name: current.isEmpty ? nil : current.name, hasOriginal: hasOriginal))
            } catch is CancellationError { throw CancellationError() }
            catch let error as PTPSessionError { throw error }
            catch let error as CameraTransportError { throw error }
            catch let error as URLError { throw error }
            catch { slots.append(.init(slot: item, availability: .unreadable, hasOriginal: hasOriginal)) }
        }
        return PictureControlOverview(slots: slots, selected: selected,
            canActivate: descriptor.writable && operations.contains(0x1016),
            canEdit: descriptor.writable && writeOperations.isSubset(of: operations))
    }
    private func readData(item: Int, defaultFlag: UInt32) async throws -> NikonPictureControlData {
        try await NikonPictureControlData(item: item, responseCode: 0x2001, data: command(0x90CC, [UInt32(item), defaultFlag, mode]))
    }
    func readSlot() async throws -> Data? {
        let current = try await readData(item: slot, defaultFlag: 0)
        let defaults = try await readData(item: slot, defaultFlag: 1)
        try require(current.isEmpty == defaults.isEmpty, "Custom slot current/default registration differs")
        return current.isEmpty ? nil : try NikonPictureControlSlotState(defaults: defaults, current: current).data
    }
    nonisolated func matchesSlot(expected: Data?, actual: Data?) throws -> Bool {
        guard let expected, let actual else { return expected == actual }
        let wanted = try NikonPictureControlSlotState(slot: slot, snapshot: expected)
        let received = try NikonPictureControlSlotState(slot: slot, snapshot: actual)
        guard wanted.current.data == received.current.data else { return false }
        let a = wanted.defaults.data, b = received.defaults.data
        return a == b || (a.count == 614 && b.count == 36 && a[35] == 1 && b[35] == 0 && a.prefix(35) == b.prefix(35))
    }
    func writeSlot(_ data: Data) async throws {
        try require(writePrepared, "Slot write was not prepared")
        let state = try NikonPictureControlSlotState(slot: slot, snapshot: data)
        _ = try await command(0x90CD, [UInt32(slot), 0, mode], state.defaults.data)
        if state.current.data != state.defaults.data {
            _ = try await command(0x90CD, [UInt32(slot), 1, mode], state.current.data)
        }
    }
    func clearSlot() async throws {
        try require(writePrepared, "Slot deletion was not prepared")
        _ = try await command(0x90CE, [UInt32(slot), mode])
    }
    private func readU16(_ property: UInt32) async throws -> Int {
        let data = try await command(0x1015, [property])
        var reader = PTPDataReader(data)
        guard data.count == 2, let value = reader.readUInt16() else { throw NikonPictureControlError.invalid("Unexpected Picture Control property format") }
        return Int(value)
    }
    func readSelection() async throws -> Int { try await readU16(property) }
    func select(_ value: Int) async throws {
        try require(selectionPrepared, "Picture Control selection was not prepared")
        try require(selection?.choices.contains(value) == true, "Invalid Picture Control selection")
        _ = try await command(0x1016, [property], Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]))
    }
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NikonPictureControlError.invalid(message) }
    }
}
