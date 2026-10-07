import Foundation

private struct RatingBytesNeeded: Error {
    let offset: UInt64
    let length: Int
}

private struct InvalidRatingContainer: Error {}

private struct RatingRegion {
    let offset: UInt64
    let bytes: Data
}

private func bigEndianUnsigned(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64? {
    guard count > 0, offset >= 0, offset <= bytes.count - count else { return nil }
    return bytes[offset..<(offset + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
}

private func locateNikonVideoRating(fileSize: UInt64, read: (UInt64, Int) throws -> Data) throws -> Int? {
    var boxes = 0
    let path = ["moov", "udta", "NCDT", "NCTG"]

    func tags(start: UInt64, end: UInt64) throws -> Int? {
        var position = start
        for _ in 0..<2048 {
            guard end >= position, end - position >= 8 else { return nil }
            let header = try read(position, 8)
            guard let tag = bigEndianUnsigned(header, 0, 4),
                  let type = bigEndianUnsigned(header, 4, 2),
                  let count = bigEndianUnsigned(header, 6, 2) else { throw InvalidRatingContainer() }
            let unit: UInt64
            switch type {
            case 1, 2, 6, 7: unit = 1
            case 3, 8: unit = 2
            case 4, 9, 11, 13: unit = 4
            case 5, 10, 12: unit = 8
            default: throw InvalidRatingContainer()
            }
            guard count <= UInt64.max / unit else { throw InvalidRatingContainer() }
            let length = count * unit
            guard length <= end - position - 8 else { throw InvalidRatingContainer() }
            if tag == 0x1001 {
                guard type == 8, count == 1 else { throw InvalidRatingContainer() }
                let raw = try read(position + 8, 2)
                guard let value = bigEndianUnsigned(raw, 0, 2) else { throw InvalidRatingContainer() }
                let signed = value >= 0x8000 ? Int(value) - 0x1_0000 : Int(value)
                return (-1...5).contains(signed) ? signed : nil
            }
            position += 8 + length
        }
        return nil
    }

    func walk(start: UInt64, end: UInt64, depth: Int) throws -> Int? {
        guard depth < path.count else { return nil }
        var position = start
        while end >= position, end - position >= 8 {
            boxes += 1
            if boxes > 2048 { return nil }
            let header = try read(position, 8)
            let kindData = header.subdata(in: 4..<8)
            guard let kind = String(data: kindData, encoding: .isoLatin1),
                  var size = bigEndianUnsigned(header, 0, 4) else { throw InvalidRatingContainer() }
            var headerLength: UInt64 = 8
            if size == 1 {
                guard end - position >= 16 else { throw InvalidRatingContainer() }
                let extended = try read(position + 8, 8)
                guard let value = bigEndianUnsigned(extended, 0, 8) else { throw InvalidRatingContainer() }
                size = value
                headerLength = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerLength, size <= end - position else { throw InvalidRatingContainer() }
            if kind == path[depth] {
                let result = depth == path.count - 1
                    ? try tags(start: position + headerLength, end: position + size)
                    : try walk(start: position + headerLength, end: position + size, depth: depth + 1)
                if let result { return result }
            }
            position += size
        }
        return nil
    }
    return try walk(start: 0, end: fileSize, depth: 0)
}

/// Opportunistic prefix parsing. Missing bytes remain unknown.
internal func parseNikonVideoRating(_ prefix: Data, fileSize: UInt64 = UInt64.max) -> Int? {
    do {
        return try locateNikonVideoRating(fileSize: fileSize) { offset, count in
            guard offset <= UInt64(prefix.count), count <= prefix.count - Int(offset) else {
                throw RatingBytesNeeded(offset: offset, length: count)
            }
            return prefix.subdata(in: Int(offset)..<Int(offset) + count)
        }
    } catch {
        return nil
    }
}

/// Reads only the regions needed to reach NCTG, up to 32 8 KiB windows.
internal func readNikonVideoRating(
    fileSize: UInt64,
    prefix: Data? = nil,
    read: @escaping @Sendable (UInt64, Int) async -> Data?
) async -> Int? {
    try? await readNikonVideoRatingThrowing(fileSize: fileSize, prefix: prefix, read: read)
}

/// Throwing protocol variant used by the live camera reader so a transient
/// DeviceBusy can reach the rating scan and yield instead of becoming an
/// indistinguishable unknown value. The non-throwing wrapper above preserves
/// the pure parser test helper's unknown-on-read-error contract.
internal func readNikonVideoRatingThrowing(
    fileSize: UInt64,
    prefix: Data? = nil,
    read: @escaping @Sendable (UInt64, Int) async throws -> Data?
) async throws -> Int? {
    guard fileSize >= 8, fileSize != 0xFFFF_FFFF else { return nil }
    var regions: [RatingRegion] = []
    if let prefix, !prefix.isEmpty { regions.append(RatingRegion(offset: 0, bytes: prefix)) }
    for attempt in 0...32 {
        do {
            return try locateNikonVideoRating(fileSize: fileSize) { offset, count in
                guard let region = regions.first(where: {
                    offset >= $0.offset &&
                    offset - $0.offset <= UInt64($0.bytes.count) &&
                    UInt64(count) <= UInt64($0.bytes.count) - (offset - $0.offset)
                }) else { throw RatingBytesNeeded(offset: offset, length: count) }
                let start = Int(offset - region.offset)
                return region.bytes.subdata(in: start..<(start + count))
            }
        } catch let needed as RatingBytesNeeded {
            guard attempt < 32,
                  needed.offset <= fileSize,
                  needed.length > 0,
                  UInt64(needed.length) <= fileSize - needed.offset else { return nil }
            let count = Int(min(UInt64(8192), fileSize - needed.offset))
            guard let bytes = try await read(needed.offset, count),
                  bytes.count >= needed.length, bytes.count <= count else { return nil }
            regions.append(RatingRegion(offset: needed.offset, bytes: bytes))
        } catch is InvalidRatingContainer {
            return nil
        }
    }
    return nil
}
