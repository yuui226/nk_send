import Foundation

/// NEF/TIFF thumbnail-byte path of AndroidX ExifInterface 1.3.7, the version
/// pinned in app/build.gradle.kts. This is intentionally separate from
/// NikonCamera.parseNefHeaderMetadata (which collects all preview ranges).
/// ExifInterface instead assigns primary/preview/thumbnail IFDs, orders them by
/// dimensions, then reads only the selected thumbnail. No RAW demosaic or JPEG
/// decoding is done here; Android's caller uses thumbnailBytes, not thumbnailBitmap.
///
/// Behavior reference: ExifInterface.java getRawAttributes, readImageFileDirectory,
/// validateImages, setThumbnailData, getThumbnailBytes (Apache-2.0, Android Open
/// Source Project). https://dl.google.com/dl/android/maven2/androidx/exifinterface/exifinterface/1.3.7/exifinterface-1.3.7-sources.jar
enum NEFExifThumbnail {
    private enum Invalid: Error { case data }
    private struct Attribute {
        let format: Int
        let count: Int
        let offset: Int
    }
    private enum Group: Int { case primary, exif, gps, interop, thumbnail, preview }
    private static let sizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 1]
    // Read-schema formats matter: unknown/wrong-format entries are skipped,
    // but a truncated *known* value aborts ExifInterface's thumbnail setup.
    private static let imageTags: [Int: [Int]] = [
        254: [4], 255: [4], 256: [3, 4], 257: [3, 4], 258: [3], 259: [3],
        262: [3], 270: [2], 271: [2], 272: [2], 273: [3, 4], 274: [3], 277: [3],
        278: [3, 4], 279: [3, 4], 282: [5], 283: [5], 284: [3], 296: [3], 301: [3],
        305: [2], 306: [2], 315: [2], 318: [5], 319: [5], 330: [4], 513: [4],
        514: [4], 529: [5], 530: [3], 531: [3], 532: [5], 33432: [2], 34665: [4], 34853: [4]
    ]
    private static let exifTags: [Int: [Int]] = [
        33434: [5], 33437: [5], 34850: [3], 34852: [2], 34855: [3], 34856: [7], 34864: [3],
        34865: [4], 34866: [4], 34867: [4], 34868: [4], 34869: [4], 36864: [2], 36867: [2],
        36868: [2], 36880: [2], 36881: [2], 36882: [2], 37121: [7], 37122: [5], 37377: [10],
        37378: [5], 37379: [10], 37380: [10], 37381: [5], 37382: [5], 37383: [3], 37384: [3],
        37385: [3], 37386: [5], 37396: [3], 37500: [7], 37510: [7], 37520: [2], 37521: [2],
        37522: [2], 40960: [7], 40961: [3], 40962: [3, 4], 40963: [3, 4], 40964: [2],
        40965: [4], 41483: [5], 41484: [7], 41486: [5], 41487: [5], 41488: [3], 41492: [3],
        41493: [5], 41495: [3], 41728: [7], 41729: [7], 41730: [7], 41985: [3], 41986: [3],
        41987: [3], 41988: [5], 41989: [3], 41990: [3], 41991: [3], 41992: [3], 41993: [3],
        41994: [3], 41995: [7], 41996: [3], 42016: [2], 42032: [2], 42033: [2], 42034: [5],
        42035: [2], 42036: [2], 42240: [5], 50706: [1], 50720: [3, 4]
    ]
    private static let gpsTags: [Int: [Int]] = [
        0: [1], 1: [2], 2: [5, 10], 3: [2], 4: [5, 10], 5: [1], 6: [5], 7: [5], 8: [2],
        9: [2], 10: [2], 11: [5], 12: [2], 13: [5], 14: [2], 15: [5], 16: [2], 17: [5],
        18: [2], 19: [2], 20: [5], 21: [2], 22: [5], 23: [2], 24: [5], 25: [2], 26: [5],
        27: [7], 28: [7], 29: [2], 30: [3], 31: [5]
    ]

    static func read(_ data: Data) -> Data? {
        guard data.count >= 8 else { return nil }
        let little = data.starts(with: [73, 73])
        guard little || data.starts(with: [77, 77]) else { return nil }
        var parser = Parser(data: data, little: little)
        return try? parser.read()
    }

    private struct Parser {
        let data: Data
        let little: Bool
        var groups = Array(repeating: [Int: Attribute](), count: 6)
        var visited = Set<Int>()
        var isDNG = false

        func integer(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - size else { throw Invalid.data }
            var value = 0
            for i in 0..<size { value |= Int(data[offset + i]) << ((little ? i : size - i - 1) * 8) }
            return value
        }
        func numbers(_ attribute: Attribute?) throws -> [Int] {
            guard let a = attribute, [3, 4].contains(a.format) else { return [] }
            return try (0..<a.count).map { try integer(a.offset + $0 * sizes[a.format], sizes[a.format]) }
        }
        func scalar(_ attribute: Attribute?) throws -> Int? {
            guard let attribute else { return nil }
            guard attribute.count == 1, let value = try numbers(attribute).first else { throw Invalid.data }
            return value
        }
        func formats(_ tag: Int, _ group: Group) -> [Int]? {
            switch group {
            case .exif: return exifTags[tag]
            case .gps: return gpsTags[tag]
            case .interop: return tag == 1 ? [2] : nil
            case .primary, .preview:
                return imageTags[tag] ?? [4: [4], 5: [4], 6: [4], 7: [4], 23: [3], 46: [7], 700: [1]][tag]
            case .thumbnail:
                return imageTags[tag] ?? [50706: [1], 50720: [3, 4]][tag]
            }
        }
        mutating func directory(_ offset: Int, _ group: Group) throws {
            guard visited.insert(offset).inserted else { return }
            let count = try integer(offset, 2)
            // Java reads a signed short and returns for zero/negative counts.
            guard count > 0 && count < 0x8000 else { return }
            for index in 0..<count {
                let at = offset + 2 + index * 12
                let tag = try integer(at, 2), rawFormat = try integer(at + 2, 2)
                let components = try integer(at + 4, 4)
                guard let accepted = formats(tag, group), rawFormat > 0, rawFormat < sizes.count,
                      accepted[0] == 7 || rawFormat == 7 || accepted.contains(rawFormat) ||
                        (accepted.contains(4) && rawFormat == 3) || (accepted.contains(9) && rawFormat == 8) ||
                        (accepted.contains(12) && rawFormat == 11) else { continue }
                let format = rawFormat == 7 ? accepted[0] : rawFormat
                guard components <= Int(Int32.max) / sizes[format] else { continue }
                let size = components * sizes[format]
                let start = size > 4 ? try integer(at + 8, 4) : at + 8
                if let nextGroup: Group = [330: .preview, 34665: .exif, 34853: .gps, 40965: .interop][tag] {
                    let next = try integer(start, format == 3 ? 2 : 4)
                    if next > 0, next < data.count { try directory(next, nextGroup) }
                } else {
                    guard start <= data.count - size else { throw Invalid.data }
                    groups[group.rawValue][tag] = Attribute(format: format, count: components, offset: start)
                    if tag == 50706 { isDNG = true }
                }
            }
            let next = try integer(offset + 2 + count * 12, 4)
            if next > 0, !visited.contains(next) {
                if groups[Group.thumbnail.rawValue].isEmpty { try directory(next, .thumbnail) }
                else if groups[Group.preview.rawValue].isEmpty { try directory(next, .preview) }
            }
        }

        mutating func read() throws -> Data? {
            guard try integer(2, 2) == 42 else { return nil }
            let first = try integer(4, 4)
            guard first >= 8 else { return nil }
            try directory(first, .primary)
            var dimensions: [Group: (Int, Int)] = [:]
            for group in [Group.primary, .preview, .thumbnail] {
                let attrs = groups[group.rawValue]
                if let crop = attrs[50720] {
                    let values = try numbers(crop)
                    if values.count == 2 { dimensions[group] = (values[0], values[1]) }
                } else if group != .thumbnail, let width = try scalar(attrs[256]), let height = try scalar(attrs[257]) {
                    // IFD1 reads 256/257 as ThumbnailImageWidth/Length, not
                    // ImageWidth/Length. 1.3.7 normalizes names only *after*
                    // swapping/promoting images. Do not swap IFD1 prematurely.
                    dimensions[group] = (width, height)
                } else if let offset = try scalar(attrs[513]), let length = try scalar(attrs[514]) {
                    guard offset <= data.count - length else { throw Invalid.data }
                    dimensions[group] = try jpegDimensions(offset: offset, length: length)
                }
            }
            for (a, b) in [(Group.primary, Group.preview), (.primary, .thumbnail), (.preview, .thumbnail)] {
                if let x = dimensions[a], let y = dimensions[b], x.0 < y.0 && x.1 < y.1 {
                    groups.swapAt(a.rawValue, b.rawValue)
                    dimensions[a] = y; dimensions[b] = x
                }
            }
            if groups[Group.thumbnail.rawValue].isEmpty,
               let size = dimensions[.preview], size.0 <= 512, size.1 <= 512 {
                groups[Group.thumbnail.rawValue] = groups[Group.preview.rawValue]
            }
            let thumbnail = groups[Group.thumbnail.rawValue]
            let compression = try scalar(thumbnail[259]) ?? 6
            if compression == 6 {
                guard let offset = try scalar(thumbnail[513]), let length = try scalar(thumbnail[514]),
                      offset > 0, length > 0, offset <= data.count - length else { return nil }
                return data.subdata(in: offset..<(offset + length))
            }
            guard compression == 1 || compression == 7 else { return nil }
            let bits = try numbers(thumbnail[258])
            let greyscale = try isDNG && bits == [8] && scalar(thumbnail[262]) == 1
            guard bits == [8, 8, 8] || greyscale else { return nil }
            let offsets = try numbers(thumbnail[273]), lengths = try numbers(thumbnail[279])
            guard !offsets.isEmpty, offsets.count == lengths.count else { return nil }
            var end = 0, joined = Data()
            for (offset, length) in zip(offsets, lengths) {
                // ExifInterface reads strips forward from the file start;
                // reversed or overlapping strips are not random-access reads.
                // Android has already set hasThumbnail before a strip read
                // fails; getThumbnailBytes then returns the default 0-byte
                // range. Preserve that distinction from an unsupported type.
                guard offset >= end, offset <= data.count - length else { return Data() }
                end = offset + length
                joined.append(data[offset..<end])
            }
            // No SOI check and no "smallest strip image" selection on Android.
            return joined
        }

        func jpegDimensions(offset: Int, length: Int) throws -> (Int, Int)? {
            let end = offset + length
            guard length >= 2, data[offset] == 255, data[offset + 1] == 216 else { throw Invalid.data }
            var cursor = offset + 2
            var result: (Int, Int)?
            while cursor + 2 <= end {
                guard data[cursor] == 255 else { throw Invalid.data }
                let marker = data[cursor + 1]; cursor += 2
                if marker == 217 || marker == 218 { return result }
                guard cursor + 2 <= end else { throw Invalid.data }
                let size = Int(data[cursor]) << 8 | Int(data[cursor + 1])
                guard size >= 2, cursor + size <= end else { throw Invalid.data }
                if [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].contains(Int(marker)) {
                    guard size >= 7 else { throw Invalid.data }
                    result = (Int(data[cursor + 5]) << 8 | Int(data[cursor + 6]),
                              Int(data[cursor + 3]) << 8 | Int(data[cursor + 4]))
                }
                cursor += size
            }
            throw Invalid.data
        }
    }
}
