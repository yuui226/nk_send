import Foundation

private func xmpRatingValue(_ text: String, prefix: String) -> Int? {
    let escaped = NSRegularExpression.escapedPattern(for: "\(prefix):Rating")
    let attribute = try? NSRegularExpression(
        pattern: "\\b\(escaped)\\s*=\\s*[\\\"']\\s*(-?\\d+)\\s*[\\\"']",
        options: []
    )
    let element = try? NSRegularExpression(
        pattern: "<\(escaped)\\s*>\\s*(-?\\d+)\\s*</\(escaped)\\s*>",
        options: []
    )
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    let match = attribute?.firstMatch(in: text, options: [], range: full)
        ?? element?.firstMatch(in: text, options: [], range: full)
    guard let match, match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text),
          let value = Int(text[range]), value >= -1, value <= 5 else { return nil }
    return value
}

private func xmpPhotoRating(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Int? {
    guard start >= 0, end >= start, end <= bytes.count,
          let text = String(bytes: bytes[start..<end], encoding: .utf8) else { return nil }
    let namespace = try? NSRegularExpression(
        pattern: "xmlns:([A-Za-z_][\\w.-]*)\\s*=\\s*[\\\"']http://ns\\.adobe\\.com/xap/1\\.0/[\\\"']",
        options: []
    )
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in namespace?.matches(in: text, options: [], range: full) ?? [] {
        guard match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { continue }
        if let value = xmpRatingValue(text, prefix: String(text[range])) { return value }
    }
    return nil
}

private func readUnsigned(_ bytes: [UInt8], _ position: Int, _ count: Int,
                          start: Int, end: Int, littleEndian: Bool) -> UInt64? {
    guard count > 0, position >= start, position <= end,
          count <= end - position else { return nil }
    var value: UInt64 = 0
    for index in 0..<count {
        let shift = littleEndian ? index : count - 1 - index
        value |= UInt64(bytes[position + index]) << UInt64(shift * 8)
    }
    return value
}

private func tiffPhotoRating(_ bytes: [UInt8], start: Int, end: Int) -> Int? {
    guard start >= 0, end <= bytes.count, end - start >= 8 else { return nil }
    let littleEndian: Bool
    if bytes[start] == 73, bytes[start + 1] == 73 { littleEndian = true }
    else if bytes[start] == 77, bytes[start + 1] == 77 { littleEndian = false }
    else { return nil }
    guard readUnsigned(bytes, start + 2, 2, start: start, end: end, littleEndian: littleEndian) == 42,
          let offset = readUnsigned(bytes, start + 4, 4, start: start, end: end, littleEndian: littleEndian),
          offset >= 8, offset <= UInt64(end - start - 2) else { return nil }
    let ifd = start + Int(offset)
    guard let count = readUnsigned(bytes, ifd, 2, start: start, end: end, littleEndian: littleEndian),
          count <= UInt64((end - ifd - 2) / 12) else { return nil }
    var rating: Int?
    for index in 0..<Int(count) {
        let position = ifd + 2 + index * 12
        guard let tag = readUnsigned(bytes, position, 2, start: start, end: end, littleEndian: littleEndian) else { return nil }
        if tag == 0x4746,
           readUnsigned(bytes, position + 2, 2, start: start, end: end, littleEndian: littleEndian) == 3,
           readUnsigned(bytes, position + 4, 4, start: start, end: end, littleEndian: littleEndian) == 1,
           let value = readUnsigned(bytes, position + 8, 2, start: start, end: end, littleEndian: littleEndian),
           value <= 5 {
            rating = Int(value)
        }
        guard tag != 700 ||
                (readUnsigned(bytes, position + 2, 2, start: start, end: end, littleEndian: littleEndian) == 1 ||
                 readUnsigned(bytes, position + 2, 2, start: start, end: end, littleEndian: littleEndian) == 7)
        else { continue }
        guard tag == 700,
              let length = readUnsigned(bytes, position + 4, 4, start: start, end: end, littleEndian: littleEndian),
              length >= 1, length <= 262_144 else { continue }
        let dataPosition: UInt64
        if length <= 4 {
            dataPosition = UInt64(position + 8)
        } else {
            guard let valueOffset = readUnsigned(bytes, position + 8, 4, start: start, end: end, littleEndian: littleEndian) else { continue }
            dataPosition = UInt64(start) + valueOffset
        }
        guard dataPosition >= UInt64(start),
              dataPosition <= UInt64(end),
              length <= UInt64(end) - dataPosition,
              let value = xmpPhotoRating(bytes, Int(dataPosition), Int(dataPosition + length)) else { continue }
        return value
    }
    return rating
}

/// Returns the camera's standard JPEG/NEF rating, preserving unknown as nil.
internal func parsePhotoRating(_ data: Data) -> Int? {
    let bytes = Array(data)
    guard bytes.count >= 8 else { return nil }
    if bytes[0] != 0xFF || bytes[1] != 0xD8 {
        return tiffPhotoRating(bytes, start: 0, end: bytes.count)
    }
    let exif = Array("Exif\0\0".utf8)
    let xmpPrefix = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    var position = 2
    var exifRating: Int?
    while position + 4 <= bytes.count {
        guard bytes[position] == 0xFF else { return exifRating }
        let marker = bytes[position + 1]
        if marker == 0xDA || marker == 0xD9 { break }
        let length = (Int(bytes[position + 2]) << 8) | Int(bytes[position + 3])
        guard length >= 2, position <= bytes.count - 2 - length else { break }
        let payloadStart = position + 4
        let payloadEnd = position + 2 + length
        if marker == 0xE1 {
            if payloadEnd - payloadStart >= exif.count,
               bytes[payloadStart..<payloadStart + exif.count].elementsEqual(exif) {
                exifRating = tiffPhotoRating(bytes, start: payloadStart + exif.count, end: payloadEnd) ?? exifRating
            } else if payloadEnd - payloadStart >= xmpPrefix.count,
                      bytes[payloadStart..<payloadStart + xmpPrefix.count].elementsEqual(xmpPrefix) {
                if let value = xmpPhotoRating(bytes, payloadStart + xmpPrefix.count, payloadEnd) { return value }
            }
        }
        position = payloadEnd
    }
    return exifRating
}

/// Nikon's proprietary object-property rating values are exact camera values.
internal func parseNikonObjectRating(_ data: Data) -> Int? {
    guard data.count == 2 else { return nil }
    let value = Int(data[data.startIndex]) | (Int(data[data.startIndex + 1]) << 8)
    switch value {
    case 0: return 0
    case 1: return 1
    case 25: return 2
    case 50: return 3
    case 75: return 4
    case 99: return 5
    default: return nil
    }
}
