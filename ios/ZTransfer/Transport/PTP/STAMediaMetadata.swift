import Foundation

/// Bounded Nikon metadata parsers ported from NikonCamera.kt. No network I/O,
/// locale-dependent numbers or guessed model/file names live in these helpers.
enum STAMediaMetadata {
    struct Preview: Hashable, Sendable { let offset: Int; let length: Int; var imageType: Int = 0 }
    struct FileNumber: Equatable, Sendable { let directory: Int; let number: Int }
    struct Anchor: Sendable { let sequence: UInt32; let file: FileNumber }
    struct Header: Sendable { let captureDate: String?; let previews: [Preview] }

    static func extensionFromHandle(_ handle: UInt32) -> String? {
        switch handle >> 24 { case 0x29: return ".jpg"; case 0x09: return ".nef"; case 0x61: return ".mp4"; default: return nil }
    }
    static func detectedExtension(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return ".jpg" }
        if data.starts(with: [0x49, 0x49, 42, 0]) || data.starts(with: [0x4D, 0x4D, 0, 42]) { return ".nef" }
        if data.count >= 12, data[4..<8] == Data("ftyp".utf8) { return data[8..<12] == Data("qt  ".utf8) ? ".mov" : ".mp4" }
        return ".bin"
    }
    static func captureDate(_ raw: String?) -> String? {
        guard let digits = raw?.filter(\.isNumber), digits.count >= 14 else { return nil }
        return String(digits.prefix(8)) + "T" + String(digits.dropFirst(8).prefix(6))
    }
    static func derive(_ anchor: Anchor, handle: UInt32) -> FileNumber? {
        let number = anchor.file.number + Int(handle & 0x00FFFFFF) - Int(anchor.sequence)
        let quotient = Int(floor(Double(number) / 10000))
        let directory = anchor.file.directory + quotient
        guard (99...999).contains(directory) else { return nil }
        return FileNumber(directory: directory, number: number - quotient * 10000)
    }
    static func defaultFileName(_ file: FileNumber, extension ext: String) -> String? {
        guard [".jpg", ".jpeg", ".nef", ".mov", ".mp4"].contains(ext.lowercased()) else { return nil }
        return String(format: "DSC_%04d", file.number) + ext.uppercased()
    }
    static func cameraBaseFileName(_ value: String) -> String? {
        let name = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, name.count <= 255,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == ":" }) else { return nil }
        return name
    }
    static func fileNamePropertyList(_ data: Data) -> [UInt32: String] {
        var reader = PTPDataReader(data)
        guard let count = reader.readUInt32(), count <= reader.remaining / 9 else { return [:] }
        var names: [UInt32: String] = [:]
        for _ in 0..<count {
            guard let handle = reader.readUInt32(), reader.readUInt16() == 0xDC07,
                  reader.readUInt16() == 0xFFFF, let text = reader.readPTPString(requireNullTerminator: true),
                  let name = cameraBaseFileName(text) else { return [:] }
            names[handle] = name
        }
        return names
    }
    static func indexedDates(_ data: Data) -> [UInt32: String] {
        var reader = PTPDataReader(data)
        guard reader.readUInt32() == 100, let count = reader.readUInt32(), count > 0,
              UInt64(count) * 16 == reader.remaining else { return [:] }
        var result: [UInt32: String] = [:]
        for _ in 0..<count {
            guard let handle = reader.readUInt32(), reader.skipBytes(count: 5),
                  let second = reader.readUInt8(), let minute = reader.readUInt8(), let hour = reader.readUInt8(),
                  let day = reader.readUInt8(), let month = reader.readUInt8(), let year = reader.readUInt16() else { return [:] }
            if handle != 0, (1990...2200).contains(year), (1...12).contains(month), (1...31).contains(day),
               hour <= 23, minute <= 59, second <= 60 {
                result[handle] = String(format: "%04d%02d%02dT%02d%02d%02d", year, month, day, hour, minute, second)
            }
        }
        return result
    }
    static func embeddedFileName(_ data: Data, extension ext: String) -> String? {
        // ASCII fields only, as in readStaDirectObjectHeaderInternal.
        let bytes = [UInt8](data)
        func stem(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45 }
        guard bytes.count >= 6 else { return nil }
        for dot in 2..<(bytes.count - 3) where bytes[dot] == 46 {
            var start = dot - 1, end = dot + 1
            while start >= 0 && dot - start <= 32 && stem(bytes[start]) { start -= 1 }
            start += 1
            while end < bytes.count && end - dot <= 5 && stem(bytes[end]) { end += 1 }
            let name = String(decoding: bytes[start..<end], as: UTF8.self)
            let base = bytes[start..<dot]
            if (2...32).contains(base.count), base.contains(where: { (48...57).contains($0) }), name.lowercased().hasSuffix(ext) { return name }
        }
        return nil
    }

    static func jpegSegment(_ data: Data, marker target: UInt8, prefix: Data) -> Range<Int>? {
        guard data.starts(with: [0xFF, 0xD8]) else { return nil }
        var offset = 2
        while offset + 4 <= data.count {
            guard data[offset] == 0xFF else { return nil }
            while offset < data.count && data[offset] == 0xFF { offset += 1 }
            guard offset < data.count else { return nil }
            let marker = data[offset]; offset += 1
            if marker == 0xD9 || marker == 0xDA { return nil }
            if marker == 1 || (0xD0...0xD7).contains(marker) { continue }
            guard offset + 2 <= data.count else { return nil }
            let size = Int(data[offset]) << 8 | Int(data[offset + 1])
            guard size >= 2, offset + size <= data.count else { return nil }
            let payload = (offset + 2)..<(offset + size)
            if marker == target && data[payload].starts(with: prefix) { return payload }
            offset += size
        }
        return nil
    }
    static func exifBase(_ data: Data) -> Int? {
        if data.starts(with: [0x49, 0x49]) || data.starts(with: [0x4D, 0x4D]) { return 0 }
        return jpegSegment(data, marker: 0xE1, prefix: Data([69, 120, 105, 102, 0, 0])).map { $0.lowerBound + 6 }
    }
    static func makerFileNumber(_ data: Data) -> FileNumber? {
        guard let base = exifBase(data), let outer = TIFF(data, base: base),
              let ifd = outer.firstIFD, let exif = outer.entries(ifd)?.first(where: { $0.tag == 0x8769 }),
              exif.type == 4, exif.count == 1,
              let maker = outer.entries(base + exif.value)?.first(where: { $0.tag == 0x927C }),
              let makerOffset = outer.valueOffset(maker, required: 18),
              data[makerOffset..<(makerOffset + 6)] == Data([78, 105, 107, 111, 110, 0]),
              let inner = TIFF(data, base: makerOffset + 10), let innerIFD = inner.firstIFD,
              let info = inner.entries(innerIFD)?.first(where: { $0.tag == 0x00B8 }),
              let offset = inner.valueOffset(info, required: 10) else { return nil }
        func candidate(_ little: Bool) -> FileNumber? {
            guard let dir = TIFF.integer(data, offset: offset + 6, size: 2, little: little),
                  let num = TIFF.integer(data, offset: offset + 8, size: 2, little: little),
                  (99...999).contains(dir), (0...9999).contains(num) else { return nil }
            return FileNumber(directory: dir, number: num)
        }
        return candidate(inner.little) ?? candidate(!inner.little)
    }
    static func tiffHeader(_ data: Data) -> Header {
        guard let base = exifBase(data), let tiff = TIFF(data, base: base), let first = tiff.firstIFD else {
            return Header(captureDate: nil, previews: [])
        }
        var visited = Set<Int>(), previews = Set<Preview>()
        var bestDate: (priority: Int, value: String)?
        func walk(_ offset: Int, depth: Int) {
            guard depth <= 8, offset >= base + 8, visited.insert(offset).inserted, let entries = tiff.entries(offset) else { return }
            var children: [Int] = [], jpegOffsets: [Int] = [], jpegLengths: [Int] = []
            var stripOffsets: [Int] = [], stripLengths: [Int] = [], compression: Int?
            for entry in entries {
                let values = tiff.numbers(entry)
                switch entry.tag {
                case 0x0103: compression = values.first
                case 0x0111: stripOffsets = values
                case 0x0117: stripLengths = values
                case 0x014A, 0x8769: children += values.map { base + $0 }
                case 0x0201: jpegOffsets = values
                case 0x0202: jpegLengths = values
                case 0x0132, 0x9003, 0x9004:
                    let priority = entry.tag == 0x9003 ? 3 : entry.tag == 0x9004 ? 2 : 1
                    if entry.type == 2, (2...128).contains(entry.count), let start = tiff.valueOffset(entry, required: entry.count),
                       let date = captureDate(String(data: data[start..<(start + entry.count)], encoding: .ascii)),
                       bestDate == nil || priority > bestDate!.priority { bestDate = (priority, date) }
                default: break
                }
            }
            for (relative, size) in Array(zip(jpegOffsets, jpegLengths)) + (compression == 6 ? Array(zip(stripOffsets, stripLengths)) : []) {
                if relative > 0 && (4...(16 * 1024 * 1024)).contains(size) { previews.insert(Preview(offset: base + relative, length: size)) }
            }
            if let next = tiff.u32(offset + 2 + entries.count * 12), next > 0 { children.append(base + next) }
            children.forEach { walk($0, depth: depth + 1) }
        }
        walk(first, depth: 0)
        return Header(captureDate: bestDate?.value, previews: previews.sorted { $0.length > $1.length })
    }
    static func mpfPreviews(_ data: Data, objectSize: UInt64) -> [Preview] {
        guard let segment = jpegSegment(data, marker: 0xE2, prefix: Data([77, 80, 70, 0])),
              let tiff = TIFF(Data(data.prefix(segment.upperBound)), base: segment.lowerBound + 4),
              let first = tiff.firstIFD, let entries = tiff.entries(first), entries.count <= 64,
              let table = entries.first(where: { $0.tag == 0xB002 && $0.type == 7 && (16...1024).contains($0.count) && $0.count % 16 == 0 }),
              let start = tiff.valueOffset(table, required: table.count) else { return [] }
        let declared = entries.first { $0.tag == 0xB001 && $0.type == 4 && $0.count == 1 }?.value ?? table.count / 16
        var previews = Set<Preview>()
        for index in 0..<min(declared, table.count / 16, 64) {
            let offset = start + index * 16
            guard let attributes = tiff.u32(offset), let length = tiff.u32(offset + 4), let relative = tiff.u32(offset + 8) else { continue }
            let type = attributes & 0xFFFFFF, absolute = tiff.base + relative
            if (attributes >> 24) & 7 == 0, (0x010001...0x010005).contains(type), relative > 0,
               (4...(16 * 1024 * 1024)).contains(length), UInt64(absolute + length) <= objectSize {
                previews.insert(Preview(offset: absolute, length: length, imageType: type))
            }
        }
        func priority(_ item: Preview) -> Int { item.imageType == 0x010002 ? 0 : item.imageType == 0x010003 ? 1 : item.imageType == 0x010001 ? 2 : 3 }
        return previews.sorted { priority($0) == priority($1) ? $0.length < $1.length : priority($0) < priority($1) }
    }
    static func largestEmbeddedJPEG(_ data: Data) -> Preview? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        var start: Int?, best: Preview?, index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 255 && bytes[index + 1] == 216 { start = index; index += 2; continue }
            if let begin = start, bytes[index] == 255 && bytes[index + 1] == 217 {
                let length = index + 2 - begin
                if length > (best?.length ?? 0) { best = Preview(offset: begin, length: length) }
                start = nil; index += 2; continue
            }
            index += 1
        }
        return best
    }
    static func videoDate(_ data: Data) -> String? {
        guard let range = data.range(of: Data("mvhd".utf8)), range.lowerBound + 12 <= data.count else { return nil }
        let offset = range.lowerBound, version = data[offset + 4]
        guard version <= 1, let seconds = TIFF.integer(data, offset: offset + 8, size: version == 0 ? 4 : 8, little: false),
              seconds > 2_082_844_800 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(seconds - 2_082_844_800)))
    }
}

private struct TIFF {
    struct Entry { let tag: Int; let type: Int; let count: Int; let value: Int; let inline: Int }
    let data: Data; let base: Int; let little: Bool
    init?(_ data: Data, base: Int) {
        guard base >= 0, base + 8 <= data.count else { return nil }
        let little = data[base] == 73 && data[base + 1] == 73
        guard little || (data[base] == 77 && data[base + 1] == 77),
              Self.integer(data, offset: base + 2, size: 2, little: little) == 42 else { return nil }
        self.data = data; self.base = base; self.little = little
    }
    static func integer(_ data: Data, offset: Int, size: Int, little: Bool) -> Int? {
        guard offset >= 0, size > 0, offset <= data.count - size else { return nil }
        var value: UInt64 = 0
        for index in 0..<size {
            value |= UInt64(data[offset + index]) << ((little ? index : size - 1 - index) * 8)
        }
        return Int(exactly: value)
    }
    func u16(_ offset: Int) -> Int? { Self.integer(data, offset: offset, size: 2, little: little) }
    func u32(_ offset: Int) -> Int? { Self.integer(data, offset: offset, size: 4, little: little) }
    var firstIFD: Int? { u32(base + 4).map { base + $0 } }
    func entries(_ offset: Int) -> [Entry]? {
        guard let count = u16(offset), count <= 512, offset + 2 + count * 12 + 4 <= data.count else { return nil }
        return (0..<count).map { index in
            let at = offset + 2 + index * 12
            return Entry(tag: u16(at)!, type: u16(at + 2)!, count: u32(at + 4)!, value: u32(at + 8)!, inline: at + 8)
        }
    }
    func valueOffset(_ entry: Entry, required: Int) -> Int? {
        let unit: Int
        switch entry.type { case 1, 2, 7: unit = 1; case 3: unit = 2; case 4, 9: unit = 4; case 5, 10: unit = 8; default: return nil }
        guard entry.count > 0, entry.count <= Int(Int32.max) / unit, entry.count * unit >= required else { return nil }
        let offset = entry.count * unit <= 4 ? entry.inline : base + entry.value
        return offset >= 0 && offset <= data.count - required ? offset : nil
    }
    func numbers(_ entry: Entry) -> [Int] {
        guard entry.type == 3 || entry.type == 4, entry.count <= 64,
              let offset = valueOffset(entry, required: entry.count * (entry.type == 3 ? 2 : 4)) else { return [] }
        return (0..<entry.count).compactMap { entry.type == 3 ? u16(offset + $0 * 2) : u32(offset + $0 * 4) }
    }
}
