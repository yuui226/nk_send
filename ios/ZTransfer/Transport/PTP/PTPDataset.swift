import Foundation

struct PTPDataReader: Sendable {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    mutating func readUInt8() -> UInt8? { readByte() }
    mutating func readUInt16() -> UInt16? { read(UInt16.self) }
    mutating func readUInt32() -> UInt32? { read(UInt32.self) }
    mutating func readUInt64() -> UInt64? { read(UInt64.self) }

    mutating func readBytes(count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + count))
    }

    mutating func skipBytes(count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }

    /// PTP strings are a one-byte UTF-16 code-unit count including the null terminator.
    /// Object cache identities require the terminator; DeviceInfo follows Android's
    /// general cursor which decodes the declared units and trims trailing nulls.
    mutating func readPTPString(requireNullTerminator: Bool = false) -> String? {
        guard let units = readByte() else { return nil }
        guard units > 0 else { return "" }
        guard remaining >= Int(units) * 2 else { return nil }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(Int(units))
        for _ in 0..<units {
            guard let unit = readUInt16() else { return nil }
            codeUnits.append(unit)
        }
        if requireNullTerminator && codeUnits.last != 0 { return nil }
        while codeUnits.last == 0 { codeUnits.removeLast() }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private mutating func readByte() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    private mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        guard remaining >= MemoryLayout<T>.size else { return nil }
        defer { offset += MemoryLayout<T>.size }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
}

struct PTPDeviceInfo: Equatable, Sendable {
    let standardVersion: UInt16
    let vendorExtensionID: UInt32
    let vendorExtensionVersion: UInt16
    let vendorExtensionDescription: String
    let functionalMode: UInt16
    let manufacturer: String
    let model: String
    let version: String
    let serialNumber: String
    let operations: Set<UInt16>
    let events: Set<UInt16>
    let properties: Set<UInt16>
    let captureFormats: Set<UInt16>
    let imageFormats: Set<UInt16>
}

enum PTPDatasetParser {
    static func parseDeviceInfo(_ data: Data) -> PTPDeviceInfo? {
        var reader = PTPDataReader(data)
        guard let standardVersion = reader.readUInt16(),
              let vendorExtensionID = reader.readUInt32(),
              let vendorExtensionVersion = reader.readUInt16(),
              let vendorExtensionDescription = reader.readPTPString(),
              let functionalMode = reader.readUInt16(),
              let operations = readUInt16Array(&reader),
              let events = readUInt16Array(&reader),
              let properties = readUInt16Array(&reader),
              let captureFormats = readUInt16Array(&reader),
              let imageFormats = readUInt16Array(&reader),
              let manufacturer = reader.readPTPString(),
              let model = reader.readPTPString(),
              let version = reader.readPTPString(),
              let serialNumber = reader.readPTPString() else { return nil }
        return PTPDeviceInfo(
            standardVersion: standardVersion, vendorExtensionID: vendorExtensionID,
            vendorExtensionVersion: vendorExtensionVersion,
            vendorExtensionDescription: vendorExtensionDescription, functionalMode: functionalMode,
            manufacturer: manufacturer, model: model, version: version, serialNumber: serialNumber,
            operations: Set(operations), events: Set(events), properties: Set(properties),
            captureFormats: Set(captureFormats), imageFormats: Set(imageFormats)
        )
    }

    static func readObjectHandles(_ data: Data) -> [UInt32]? {
        var reader = PTPDataReader(data)
        guard let values = readUInt32Array(&reader) else { return nil }
        return values
    }

    static func readStorageIDs(_ data: Data) -> [UInt32]? {
        var reader = PTPDataReader(data)
        return readUInt32Array(&reader)
    }

    private static func readUInt16Array(_ reader: inout PTPDataReader) -> [UInt16]? {
        guard let count = reader.readUInt32(), count <= UInt32(reader.remaining / 2) else { return nil }
        return (0..<count).compactMap { _ in reader.readUInt16() }
    }

    private static func readUInt32Array(_ reader: inout PTPDataReader) -> [UInt32]? {
        guard let count = reader.readUInt32(), count <= UInt32(reader.remaining / 4) else { return nil }
        return (0..<count).compactMap { _ in reader.readUInt32() }
    }
}

struct CameraFile: Identifiable, Equatable, Sendable, Codable {
    let id: UInt32
    let storageID: UInt32
    let format: UInt16
    let size: UInt64
    let fileName: String
    let captureDate: String?
    let isProtected: Bool

    var fileExtension: String {
        guard let dot = fileName.lastIndex(of: ".") else { return "" }
        return fileName[dot...].lowercased()
    }

    /// Android PtpConstants.FORMAT_EXT, used only when the object name is missing.
    static func defaultExtension(for format: UInt16) -> String {
        switch format {
        case 0x3001, 0x3801, 0x3808: return ".jpg"
        case 0x3802: return ".tif"
        case 0x3804: return ".png"
        case 0x3805: return ".bmp"
        case 0x3806: return ".gif"
        case 0x3807: return ".ico"
        case 0x300D: return ".mov"
        case 0x300B: return ".avi"
        case 0x300E: return ".mp4"
        case 0xB101...0xB106: return ".nef"
        case 0xB801: return ".crw"
        case 0xB802: return ".cr2"
        case 0xB803: return ".cr3"
        case 0xB808, 0xB809: return ".arw"
        default: return ".bin"
        }
    }
}

struct PTPObjectInfoResult: Equatable, Sendable {
    let file: CameraFile?
    /// Directories are successful but have no file. Truncated identities retain
    /// Android's display fallback but must not authorize cache reconciliation.
    let successful: Bool
}

extension PTPDatasetParser {
    static func parseObjectInfo(handle: UInt32, _ data: Data) -> CameraFile? {
        parseObjectInfoResult(handle: handle, data).file
    }

    static func parseObjectInfoResult(handle: UInt32, _ data: Data) -> PTPObjectInfoResult {
        guard data.count >= 53 else { return PTPObjectInfoResult(file: nil, successful: false) }
        var reader = PTPDataReader(data)
        guard let storage = reader.readUInt32(), let format = reader.readUInt16(),
              let protection = reader.readUInt16(), let compressedSize = reader.readUInt32() else {
            return PTPObjectInfoResult(file: nil, successful: false)
        }
        guard format != 0x3001 else { return PTPObjectInfoResult(file: nil, successful: true) }
        // ObjectInfo's fixed prefix is 52 bytes. Filename starts at byte 52,
        // independent of any thumbnail, image dimensions or sequence values.
        guard reader.skipBytes(count: 40) else { return PTPObjectInfoResult(file: nil, successful: false) }
        let decodedName = reader.readPTPString(requireNullTerminator: true)
        let nameIsComplete = decodedName?.isEmpty == false
        let fallback = String(format: "DSC_%04u", handle & 0xFFFF) + CameraFile.defaultExtension(for: format)
        var captureDate: String?
        var complete = false
        if nameIsComplete && reader.remaining > 0 {
            let explicitlyEmptyDate = data[data.startIndex + reader.offset] == 0
            if let date = reader.readPTPString(requireNullTerminator: true) {
                captureDate = date.utf16.count >= 8 ? date : nil
                complete = explicitlyEmptyDate || captureDate != nil
            }
        }
        let file = CameraFile(
            id: handle, storageID: storage, format: format, size: UInt64(compressedSize),
            fileName: nameIsComplete ? decodedName! : fallback,
            captureDate: captureDate, isProtected: protection != 0
        )
        return PTPObjectInfoResult(file: file, successful: complete)
    }
}
