import CryptoKit
import Foundation

struct PictureControlSlotSnapshot: Equatable, Sendable {
    let cameraIdentity: String
    let slot: Int
    let data: Data?
    let selection: Int?

    init(cameraIdentity: String, slot: Int, data: Data?, selection: Int? = nil) throws {
        guard !cameraIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              NikonPictureControlData.customSlots.contains(slot),
              data.map({ (1...NikonPictureControlFile.maximumBytes).contains($0.count) }) ?? true,
              selection.map({ (1...65535).contains($0) }) ?? true else {
            throw NikonPictureControlError.invalid("Invalid Picture Control slot snapshot")
        }
        self.cameraIdentity = cameraIdentity; self.slot = slot
        self.data = data; self.selection = selection
    }
}

/// Exact Android PCB v1/v2 container, including Java modified UTF-8 identity.
/// Separate store instances share the first-original lock. Corruption is fatal
/// to mutation and is never silently replaced by a newer camera read.
final class PictureControlBackupStore: Sendable {
    private static let lock = NSLock()
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func saveOriginal(_ snapshot: PictureControlSlotSnapshot) throws -> PictureControlSlotSnapshot {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let existing = try loadLocked(identity: snapshot.cameraIdentity, slot: snapshot.slot) { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = try path(identity: snapshot.cameraIdentity, slot: snapshot.slot)
        let temporary = directory.appendingPathComponent("picture-control-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoded = try encode(snapshot)
        try encoded.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try FileManager.default.moveItem(at: temporary, to: target)
        guard let saved = try loadLocked(identity: snapshot.cameraIdentity, slot: snapshot.slot) else {
            throw NikonPictureControlError.invalid("Picture Control backup was not published")
        }
        return saved
    }

    func load(identity: String, slot: Int) throws -> PictureControlSlotSnapshot? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try loadLocked(identity: identity, slot: slot)
    }

    private func path(identity: String, slot: Int) throws -> URL {
        guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              NikonPictureControlData.customSlots.contains(slot) else {
            throw NikonPictureControlError.invalid("Invalid Picture Control backup identity")
        }
        return directory.appendingPathComponent("\(pictureControlSHA(Data(identity.utf8)))-\(slot).pcb")
    }

    private func loadLocked(identity: String, slot: Int) throws -> PictureControlSlotSnapshot? {
        let url = try path(identity: identity, slot: slot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              (1...(NikonPictureControlFile.maximumBytes + 2048)).contains(size.intValue) else {
            throw NikonPictureControlError.invalid("Invalid Picture Control backup size")
        }
        var input = PictureControlBackupReader(data: try Data(contentsOf: url))
        guard try input.integer(4) == 0x5A545043 else { throw NikonPictureControlError.invalid("Invalid Picture Control backup header") }
        let version = try input.integer(4)
        guard version == 1 || version == 2 else { throw NikonPictureControlError.invalid("Invalid Picture Control backup version") }
        let savedIdentity = try input.utf()
        let savedSlot = try input.integer(4)
        guard savedIdentity == identity, savedSlot == slot else {
            throw NikonPictureControlError.invalid("Picture Control backup belongs to another camera or slot")
        }
        let rawSelection = version == 2 ? try input.integer(8) : UInt64.max
        let selection: Int?
        if rawSelection == UInt64.max { selection = nil }
        else {
            guard (1...65535).contains(rawSelection) else { throw NikonPictureControlError.invalid("Invalid Picture Control backup selection") }
            selection = Int(rawSelection)
        }
        let rawLength = try input.integer(4)
        guard rawLength == UInt32.max || (1...UInt64(NikonPictureControlFile.maximumBytes)).contains(rawLength) else {
            throw NikonPictureControlError.invalid("Invalid Picture Control backup payload size")
        }
        let expectedDigest = try input.utf()
        let payload = rawLength == UInt32.max ? nil : try input.read(Int(rawLength))
        let actualDigest = version == 1 ? pictureControlSHA(payload ?? Data()) : snapshotDigest(payload, selection)
        guard input.atEnd, actualDigest == expectedDigest else {
            throw NikonPictureControlError.invalid("Picture Control backup integrity check failed")
        }
        return try PictureControlSlotSnapshot(cameraIdentity: savedIdentity, slot: slot, data: payload, selection: selection)
    }

    private func encode(_ snapshot: PictureControlSlotSnapshot) throws -> Data {
        var output = Data()
        output.appendPictureControlInteger(0x5A545043, width: 4)
        output.appendPictureControlInteger(2, width: 4)
        try output.appendPictureControlUTF(snapshot.cameraIdentity)
        output.appendPictureControlInteger(UInt64(snapshot.slot), width: 4)
        output.appendPictureControlInteger(snapshot.selection.map(UInt64.init) ?? UInt64.max, width: 8)
        output.appendPictureControlInteger(snapshot.data.map { UInt64($0.count) } ?? UInt64(UInt32.max), width: 4)
        try output.appendPictureControlUTF(snapshotDigest(snapshot.data, snapshot.selection))
        if let data = snapshot.data { output.append(data) }
        return output
    }

    private func snapshotDigest(_ data: Data?, _ selection: Int?) -> String {
        var bytes = Data()
        bytes.appendPictureControlInteger(selection.map(UInt64.init) ?? UInt64.max, width: 8)
        if let data { bytes.append(data) }
        return pictureControlSHA(bytes)
    }
}

private func pictureControlSHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    mutating func appendPictureControlInteger(_ value: UInt64, width: Int) {
        for byte in (0..<width).reversed() { append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
    }
    mutating func appendPictureControlUTF(_ text: String) throws {
        var encoded = Data()
        for unit in text.utf16 {
            if unit >= 1 && unit <= 0x7F { encoded.append(UInt8(unit)) }
            else if unit <= 0x7FF {
                encoded.append(UInt8(0xC0 | (unit >> 6)))
                encoded.append(UInt8(0x80 | (unit & 0x3F)))
            } else {
                encoded.append(UInt8(0xE0 | (unit >> 12)))
                encoded.append(UInt8(0x80 | ((unit >> 6) & 0x3F)))
                encoded.append(UInt8(0x80 | (unit & 0x3F)))
            }
        }
        guard encoded.count <= 65535 else { throw NikonPictureControlError.invalid("Picture Control identity exceeds backup format") }
        appendPictureControlInteger(UInt64(encoded.count), width: 2)
        append(encoded)
    }
}

private struct PictureControlBackupReader {
    let data: Data
    var offset = 0
    var atEnd: Bool { offset == data.count }
    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw NikonPictureControlError.invalid("Truncated Picture Control backup") }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func integer(_ width: Int) throws -> UInt64 {
        try read(width).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    mutating func utf() throws -> String {
        let length = try integer(2)
        let bytes = [UInt8](try read(Int(length)))
        var units: [UInt16] = []
        var index = 0
        while index < bytes.count {
            let first = bytes[index]; index += 1
            if first < 128 { units.append(UInt16(first)); continue }
            let count = first >> 4 == 0xE ? 2 : (first >> 5 == 0x6 ? 1 : -1)
            guard count > 0, bytes.count - index >= count else { throw NikonPictureControlError.invalid("Invalid Picture Control backup identity encoding") }
            var unit = UInt16(first & (count == 1 ? 0x1F : 0x0F))
            for _ in 0..<count {
                let next = bytes[index]; index += 1
                guard next & 0xC0 == 0x80 else { throw NikonPictureControlError.invalid("Invalid Picture Control backup identity encoding") }
                unit = (unit << 6) | UInt16(next & 0x3F)
            }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}
