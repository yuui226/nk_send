import Foundation

enum LosslessJpegBridge {
    private static let gate = CancellableSerialWorkGate()
    private static let nativeLock = NSLock()

    static func cropAsync(input: URL, output: URL, source: JpegCropSource, rect: CropRect) async throws -> Bool {
        try await gate.withPermit {
            crop(input: input, output: output, source: source, rect: rect)
        }
    }

    static func crop(input: URL, output: URL, source: JpegCropSource, rect: CropRect) -> Bool {
        // Synchronous callers share the same codec exclusion. Production async
        // waiters use the cancellable gate before entering this short lock path.
        nativeLock.lock()
        defer { nativeLock.unlock() }
        guard !Task.isCancelled else { return false }
        source.validate(rect)
        guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL,
              LosslessCropInput.accepts(source),
              let header = try? LosslessCropInput.sourceHeader(from: input),
              parseJpegCropHeader(header) == source,
              let marker = try? LosslessCropExif.marker(header: header, source: source, rect: rect) else { return false }
        let succeeded = input.path.withCString { inputPath in
            output.path.withCString { outputPath in
                zt_lossless_jpeg_crop(inputPath, outputPath, Int32(source.width), Int32(source.height), Int32(source.mcuWidth), Int32(source.mcuHeight), Int32(rect.left), Int32(rect.top), Int32(rect.width), Int32(rect.height)) != 0
            }
        }
        guard succeeded else { return false }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        do {
            try LosslessCropExif.insert(marker, into: output)
            return true
        } catch {
            try? FileManager.default.removeItem(at: output)
            return false
        }
    }
}

@_silgen_name("zt_lossless_jpeg_crop")
private func zt_lossless_jpeg_crop(_ input: UnsafePointer<CChar>, _ output: UnsafePointer<CChar>, _ width: Int32, _ height: Int32, _ mcuWidth: Int32, _ mcuHeight: Int32, _ x: Int32, _ y: Int32, _ cropWidth: Int32, _ cropHeight: Int32) -> Int32

/// Rebuild Android LosslessJpeg.copiedTags without copying opaque EXIF offsets,
/// MakerNotes, IFD1 thumbnails or unreferenced bytes from the original APP1.
/// JPEG coefficients are never decoded or recompressed by this metadata pass.
private enum LosslessCropExif {
    struct Field {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let bytes: [UInt8]
    }
    struct Reader {
        let bytes: [UInt8]
        let little: Bool
        func integer(_ offset: Int, _ size: Int) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count - size else { throw LosslessCropProcessorError.cropFailed }
            return (0..<size).reduce(UInt32(0)) { value, index in
                value | UInt32(bytes[offset + index]) << ((little ? index : size - 1 - index) * 8)
            }
        }
        func fields(at offset: Int, keeping allowed: Set<UInt16>) throws -> [Field] {
            guard offset >= 8 else { throw LosslessCropProcessorError.cropFailed }
            let count = Int(try integer(offset, 2))
            guard offset <= bytes.count - 2, count <= (bytes.count - offset - 2) / 12 else {
                throw LosslessCropProcessorError.cropFailed
            }
            var result: [Field] = []
            var seen = Set<UInt16>()
            for index in 0..<count {
                let entry = offset + 2 + index * 12
                let tag = UInt16(try integer(entry, 2))
                guard allowed.contains(tag), seen.insert(tag).inserted else { continue }
                let type = UInt16(try integer(entry + 2, 2))
                let elements = try integer(entry + 4, 4)
                let unit: Int
                switch type {
                case 1, 2, 7: unit = 1
                case 3: unit = 2
                case 4, 9: unit = 4
                case 5, 10: unit = 8
                default: throw LosslessCropProcessorError.cropFailed
                }
                guard elements <= bytes.count / unit else { throw LosslessCropProcessorError.cropFailed }
                let length = Int(elements) * unit
                let start = length <= 4 ? entry + 8 : Int(try integer(entry + 8, 4))
                guard start >= 0, start <= bytes.count - length else { throw LosslessCropProcessorError.cropFailed }
                result.append(Field(tag: tag, type: type, count: elements, bytes: Array(bytes[start..<(start + length)])))
            }
            return result
        }
        func pointer(_ tag: UInt16, in fields: [Field]) throws -> Int? {
            guard let field = fields.first(where: { $0.tag == tag }) else { return nil }
            guard field.type == 4, field.count == 1, field.bytes.count == 4 else { throw LosslessCropProcessorError.cropFailed }
            let value = field.bytes.enumerated().reduce(UInt32(0)) { value, pair in
                value | UInt32(pair.element) << ((little ? pair.offset : 3 - pair.offset) * 8)
            }
            return value == 0 ? nil : Int(value)
        }
    }

    static let ifd0Tags: Set<UInt16> = [0x010f, 0x0110, 0x0131, 0x0132]
    static let exifTags: Set<UInt16> = [
        0x9003, 0x9004, 0x9291, 0x9011, 0x829a, 0x829d, 0x8827,
        0x920a, 0xa405, 0xa433, 0xa434, 0x8822, 0x9204, 0x9207,
        0x9209, 0xa403, 0xa001
    ]
    static let gpsTags: Set<UInt16> = [0, 1, 2, 3, 4, 5, 6, 7, 29, 27, 12, 13, 14, 15]

    static func marker(header jpeg: Data, source: JpegCropSource, rect: CropRect) throws -> Data {
        guard jpeg.count >= 2, jpeg[0] == 0xff, jpeg[1] == 0xd8 else { throw LosslessCropProcessorError.cropFailed }
        var payload: [UInt8]?
        var offset = 2
        while offset + 2 <= jpeg.count {
            guard jpeg[offset] == 0xff else { throw LosslessCropProcessorError.cropFailed }
            while offset < jpeg.count && jpeg[offset] == 0xff { offset += 1 }
            guard offset < jpeg.count else { throw LosslessCropProcessorError.cropFailed }
            let code = jpeg[offset]; offset += 1
            if code == 0xda || code == 0xd9 { break }
            if code == 0x01 || (0xd0...0xd7).contains(code) { continue }
            guard offset + 2 <= jpeg.count else { throw LosslessCropProcessorError.cropFailed }
            let length = Int(jpeg[offset]) * 256 + Int(jpeg[offset + 1])
            guard length >= 2, length <= jpeg.count - offset else { throw LosslessCropProcessorError.cropFailed }
            if code == 0xe1, length >= 8, jpeg[(offset + 2)..<(offset + 8)].elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                payload = Array(jpeg[(offset + 8)..<(offset + length)])
            }
            offset += length
        }
        let little: Bool
        var root: [Field] = [], exif: [Field] = [], gps: [Field] = []
        if let bytes = payload {
            guard bytes.count >= 8 else { throw LosslessCropProcessorError.cropFailed }
            little = bytes[0] == 0x49 && bytes[1] == 0x49
            guard little || (bytes[0] == 0x4d && bytes[1] == 0x4d) else { throw LosslessCropProcessorError.cropFailed }
            let reader = Reader(bytes: bytes, little: little)
            guard try reader.integer(2, 2) == 42 else { throw LosslessCropProcessorError.cropFailed }
            root = try reader.fields(at: Int(reader.integer(4, 4)), keeping: ifd0Tags.union([0x8769, 0x8825]))
            if let pointer = try reader.pointer(0x8769, in: root) { exif = try reader.fields(at: pointer, keeping: exifTags) }
            if let pointer = try reader.pointer(0x8825, in: root) { gps = try reader.fields(at: pointer, keeping: gpsTags) }
            root.removeAll { $0.tag == 0x8769 || $0.tag == 0x8825 }
        } else { little = true }
        func bytes(_ value: UInt32, count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : count - 1 - $0) * 8)) }
        }
        func scalar(_ tag: UInt16, _ value: Int, short: Bool = false) -> Field {
            Field(tag: tag, type: short ? 3 : 4, count: 1, bytes: bytes(UInt32(value), count: short ? 2 : 4))
        }
        root += [scalar(0x0100, rect.width), scalar(0x0101, rect.height), scalar(0x0112, source.orientation, short: true)]
        exif += [scalar(0xa002, rect.width), scalar(0xa003, rect.height)]
        // Lay out only three explicit directories; all next-IFD links are zero.
        let rootOffset = 8
        let rootCount = root.count + 1 + (gps.isEmpty ? 0 : 1)
        let exifOffset = rootOffset + 2 + rootCount * 12 + 4
        let gpsOffset = exifOffset + 2 + exif.count * 12 + 4
        let dataOffset = gpsOffset + (gps.isEmpty ? 0 : 2 + gps.count * 12 + 4)
        root.append(scalar(0x8769, exifOffset))
        if !gps.isEmpty { root.append(scalar(0x8825, gpsOffset)) }
        var tiff = [UInt8](repeating: 0, count: dataOffset)
        tiff.replaceSubrange(0..<8, with: (little ? [0x49, 0x49] : [0x4d, 0x4d]) + bytes(42, count: 2) + bytes(8, count: 4))
        func write(_ fields: [Field], at start: Int) {
            tiff.replaceSubrange(start..<(start + 2), with: bytes(UInt32(fields.count), count: 2))
            for (index, field) in fields.sorted(by: { $0.tag < $1.tag }).enumerated() {
                let entry = start + 2 + index * 12
                let header = bytes(UInt32(field.tag), count: 2) + bytes(UInt32(field.type), count: 2) + bytes(field.count, count: 4)
                tiff.replaceSubrange(entry..<(entry + 8), with: header)
                if field.bytes.count <= 4 {
                    tiff.replaceSubrange((entry + 8)..<(entry + 8 + field.bytes.count), with: field.bytes)
                } else {
                    if tiff.count % 2 != 0 { tiff.append(0) }
                    tiff.replaceSubrange((entry + 8)..<(entry + 12), with: bytes(UInt32(tiff.count), count: 4))
                    tiff.append(contentsOf: field.bytes)
                }
            }
        }
        write(root, at: rootOffset); write(exif, at: exifOffset)
        if !gps.isEmpty { write(gps, at: gpsOffset) }
        let length = tiff.count + 8
        guard length <= 65535 else { throw LosslessCropProcessorError.cropFailed }
        return Data([0xff, 0xe1, UInt8(length >> 8), UInt8(length & 255), 0x45, 0x78, 0x69, 0x66, 0, 0] + tiff)
    }

    static func insert(_ marker: Data, into output: URL) throws {
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".exif_" + UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw LosslessCropProcessorError.cropFailed }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: temporary)
        defer { try? writer.close() }
        guard try reader.read(upToCount: 2) == Data([0xff, 0xd8]) else { throw LosslessCropProcessorError.cropFailed }
        try writer.write(contentsOf: Data([0xff, 0xd8]))
        try writer.write(contentsOf: marker)
        while let block = try reader.read(upToCount: 256 * 1024), !block.isEmpty { try writer.write(contentsOf: block) }
        try writer.synchronize()
        try writer.close()
        try reader.close()
        _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    }
}
