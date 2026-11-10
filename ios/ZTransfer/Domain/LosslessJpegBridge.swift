import Foundation

enum LosslessJpegBridge {
    private static let gate = CancellableSerialWorkGate()
    private static let nativeLock = NSLock()

    static func cropAsync(input: URL, output: URL, source: JpegCropSource, rect: CropRect,
                          locationFallback: PhotoCaptureLocation? = nil) async throws -> Bool {
        try await gate.withPermit {
            crop(input: input, output: output, source: source, rect: rect, locationFallback: locationFallback)
        }
    }

    static func crop(input: URL, output: URL, source: JpegCropSource, rect: CropRect,
                     locationFallback: PhotoCaptureLocation? = nil) -> Bool {
        // Synchronous callers share the same codec exclusion. Production async
        // waiters use the cancellable gate before entering this short lock path.
        nativeLock.lock()
        defer { nativeLock.unlock() }
        guard !Task.isCancelled else { return false }
        source.validate(rect)
        guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL,
              LosslessCropInput.accepts(source),
              let header = try? LosslessCropInput.sourceHeader(from: input),
              parseJpegCropHeader(header) == source else { return false }
        let sourceLocation = PhotoCaptureLocation.read(header: header)
        guard let marker = try? LosslessCropExif.marker(header: header, source: source, rect: rect,
            locationFallback: sourceLocation == nil ? locationFallback : nil) else { return false }
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
            if sourceLocation != nil || locationFallback != nil {
                let savedHeader = try LosslessCropInput.header(from: output)
                guard PhotoCaptureLocation.read(header: savedHeader) != nil else {
                    throw LosslessCropProcessorError.cropFailed
                }
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: output)
            return false
        }
    }
}

@_silgen_name("zt_lossless_jpeg_crop")
private func zt_lossless_jpeg_crop(_ input: UnsafePointer<CChar>, _ output: UnsafePointer<CChar>, _ width: Int32, _ height: Int32, _ mcuWidth: Int32, _ mcuHeight: Int32, _ x: Int32, _ y: Int32, _ cropWidth: Int32, _ cropHeight: Int32) -> Int32

extension PhotoCaptureLocation {
    /// Decode original EXIF rationals directly. ImageIO's GPS display dictionary
    /// may round DMS fractions even when the saved TIFF is exact.
    static func read(header: Data) -> Self? { try? LosslessCropExif.location(header: header) }
}

/// Rebuild Android PhotoCaptureExif fields without copying opaque EXIF offsets,
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

    static func reader(header jpeg: Data) throws -> Reader? {
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
        guard let bytes = payload else { return nil }
        guard bytes.count >= 8 else { throw LosslessCropProcessorError.cropFailed }
        let little = bytes[0] == 0x49 && bytes[1] == 0x49
        guard little || (bytes[0] == 0x4d && bytes[1] == 0x4d) else { throw LosslessCropProcessorError.cropFailed }
        let reader = Reader(bytes: bytes, little: little)
        guard try reader.integer(2, 2) == 42 else { throw LosslessCropProcessorError.cropFailed }
        return reader
    }

    static func location(header: Data) throws -> PhotoCaptureLocation? {
        guard let reader = try reader(header: header) else { return nil }
        let root = try reader.fields(at: Int(reader.integer(4, 4)), keeping: [0x8825])
        guard let pointer = try reader.pointer(0x8825, in: root) else { return nil }
        let gps = try reader.fields(at: pointer, keeping: [1, 2, 3, 4, 5, 6])
        func rational(_ field: Field, at index: Int) throws -> Double? {
            let value = Reader(bytes: field.bytes, little: reader.little)
            let denominator = try value.integer(index * 8 + 4, 4)
            guard denominator != 0 else { return nil }
            return Double(try value.integer(index * 8, 4)) / Double(denominator)
        }
        func coordinate(_ tag: UInt16, positive: UInt8, negative: UInt8) throws -> Double? {
            guard let ref = gps.first(where: { $0.tag == tag - 1 }), ref.type == 2,
                  let direction = ref.bytes.first, direction == positive || direction == negative,
                  let field = gps.first(where: { $0.tag == tag }), field.type == 5, field.count == 3,
                  let degrees = try rational(field, at: 0), let minutes = try rational(field, at: 1),
                  let seconds = try rational(field, at: 2) else { return nil }
            return (degrees + minutes / 60 + seconds / 3600) * (direction == negative ? -1 : 1)
        }
        let altitude: Double?
        if let ref = gps.first(where: { $0.tag == 5 }), ref.type == 1, ref.count == 1,
           let direction = ref.bytes.first, direction <= 1,
           let field = gps.first(where: { $0.tag == 6 }), field.type == 5, field.count == 1,
           let meters = try rational(field, at: 0) {
            altitude = meters * (direction == 1 ? -1 : 1)
        } else { altitude = nil }
        return try PhotoCaptureLocation(latitude: coordinate(2, positive: 78, negative: 83),
            longitude: coordinate(4, positive: 69, negative: 87), altitude: altitude)
    }

    static func marker(header jpeg: Data, source: JpegCropSource, rect: CropRect,
                       locationFallback: PhotoCaptureLocation?) throws -> Data {
        let little: Bool
        var root: [Field] = [], exif: [Field] = [], gps: [Field] = []
        if let reader = try reader(header: jpeg) {
            little = reader.little
            root = try reader.fields(at: Int(reader.integer(4, 4)), keeping: PhotoCaptureExif.tiffTags.union([0x8769, 0x8825]))
            if let pointer = try reader.pointer(0x8769, in: root) { exif = try reader.fields(at: pointer, keeping: PhotoCaptureExif.exifTags) }
            if let pointer = try reader.pointer(0x8825, in: root) { gps = try reader.fields(at: pointer, keeping: PhotoCaptureExif.gpsTags) }
            root.removeAll { $0.tag == 0x8769 || $0.tag == 0x8825 }
        } else { little = true }
        func bytes(_ value: UInt32, count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : count - 1 - $0) * 8)) }
        }
        func scalar(_ tag: UInt16, _ value: Int, short: Bool = false) -> Field {
            Field(tag: tag, type: short ? 3 : 4, count: 1, bytes: bytes(UInt32(value), count: short ? 2 : 4))
        }
        if let location = locationFallback {
            // Missing/invalid coordinates make any old altitude unreliable.
            // Preserve all other copied GPS fields; never invent GPS time/date.
            gps.removeAll { (1...6).contains($0.tag) }
            func rational(_ value: Double, precision: UInt32) throws -> [UInt8] {
                var denominator = precision
                while denominator > 1 && (value * Double(denominator)).rounded() > Double(UInt32.max) {
                    denominator /= 10
                }
                let numerator = (value * Double(denominator)).rounded()
                guard numerator.isFinite, numerator >= 0, numerator <= Double(UInt32.max) else {
                    throw LosslessCropProcessorError.cropFailed
                }
                return bytes(UInt32(numerator), count: 4) + bytes(denominator, count: 4)
            }
            func coordinate(_ tag: UInt16, _ value: Double, positive: UInt8, negative: UInt8) throws {
                let degrees = floor(abs(value)), minutes = floor((abs(value) - degrees) * 60)
                let seconds = ((abs(value) - degrees) * 60 - minutes) * 60
                gps.append(Field(tag: tag - 1, type: 2, count: 2, bytes: [value < 0 ? negative : positive, 0]))
                let encoded = try rational(degrees, precision: 1) + rational(minutes, precision: 1) + rational(seconds, precision: 10_000_000)
                gps.append(Field(tag: tag, type: 5, count: 3, bytes: encoded))
            }
            try coordinate(2, location.latitude, positive: 78, negative: 83)
            try coordinate(4, location.longitude, positive: 69, negative: 87)
            if let altitude = location.altitude {
                gps.append(Field(tag: 5, type: 1, count: 1, bytes: [altitude < 0 ? 1 : 0]))
                gps.append(Field(tag: 6, type: 5, count: 1, bytes: try rational(abs(altitude), precision: 1_000_000)))
            }
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
