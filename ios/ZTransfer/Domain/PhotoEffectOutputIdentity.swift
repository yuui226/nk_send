import Foundation
import CryptoKit

/// Android PhotoFrameExporter: short visible names, exact recipe in JPEG APP15.
/// Preserve old identities only where the rendered layout is unchanged.
func photoEffectOutputName(sourceName: String, settings: PhotoEffectsSettings) -> String {
    let decoration = settings.photoFrameEnabled ? (settings.photoFrameBorderEnabled ? "_f" : (settings.watermark.enabled ? "_w" : "")) : ""
    let suffix = decoration + (settings.photoFilterEnabled && settings.selectedFilter != nil ? "_e" : "") + (settings.photoGrain.isEnabled ? "_g" : "")
    let stem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
    return "\(stem)\(suffix.isEmpty ? "_e" : suffix).jpg"
}

func photoEffectOutputIdentity(sourceName: String, settings: PhotoEffectsSettings,
                               renderedPlace: PhotoFramePlace? = nil) -> String {
    var value = androidPhotoFrameOutputName(sourceName: sourceName, settings: settings).lowercased()
    if settings.photoGrain.isEnabled {
        value += "\0grain-v=1\0i=\(settings.photoGrain.normalizedIntensity)\0seed=\(photoGrainSeed(sourceName))"
        if settings.photoGrain.style != .fine { value += "\0style=\(settings.photoGrain.style.rawValue)" }
    }
    if settings.usesRenderedPlaceIdentity {
        let city = settings.metadata.showCity ? (renderedPlace?.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let region = settings.metadata.showRegion ? (renderedPlace?.region ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // Kotlin String.length counts UTF-16 units, not Swift graphemes.
        value += "\0place-v=1\0city=\(city.utf16.count):\(city)\0region=\(region.utf16.count):\(region)"
    }
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

enum PhotoEffectIdentityJPEG {
    private static let magic = Data("ZTransfer.PhotoEffectIdentity\0v1\0".utf8)
    private static let maximumHeaderBytes = 4 * 1024 * 1024

    private static func valid(_ identity: String) -> Bool {
        identity.utf8.count == 64 && identity.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func inserting(_ identity: String, into jpeg: Data) -> Data? {
        guard valid(identity), jpeg.count >= 4 else { return nil }
        // Data's starting index need not be zero (callers may pass a slice).
        let bytes = jpeg.prefix(6).map { $0 }
        guard bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }
        var offset = 2
        if bytes[2] == 0xff, bytes[3] == 0xe0 {
            guard bytes.count == 6 else { return nil }
            let length = Int(bytes[4]) * 256 + Int(bytes[5])
            guard length >= 2, length <= jpeg.count - 4 else { return nil }
            offset = 4 + length
        }
        let payload = magic + Data(identity.utf8)
        let length = payload.count + 2
        let segment = Data([0xff, 0xef, UInt8(length >> 8), UInt8(length & 255)]) + payload
        var result = Data(jpeg)
        result.insert(contentsOf: segment, at: offset)
        return result
    }

    /// Read bounded header segments, never decode pixels or read the full file.
    static func read(from url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        return read { try file.read(upToCount: $0) ?? Data() }
    }

    /// Android wraps its header stream in a buffer. Keep single-byte marker
    /// parsing in memory too: a directory lookup must not issue a disk read for
    /// every marker byte. Only the small identity payload is copied; unrelated
    /// EXIF/ICC segments are skipped through the bounded 8 KiB buffer.
    static func read(using source: (Int) throws -> Data) -> String? {
        var remaining = maximumHeaderBytes
        var buffer = Data()
        var cursor = 0
        func refill() -> Bool {
            if cursor < buffer.endIndex { return true }
            guard remaining > 0, !Task.isCancelled else { return false }
            let requested = min(8 * 1024, remaining)
            guard let next = try? source(requested), !next.isEmpty, next.count <= requested else { return false }
            buffer = next; cursor = next.startIndex; remaining -= next.count
            return true
        }
        func byte() -> UInt8? {
            guard refill() else { return nil }
            defer { cursor += 1 }
            return buffer[cursor]
        }
        func consume(_ count: Int, copying: Bool) -> Data? {
            guard count >= 0, count <= remaining + buffer.endIndex - cursor else { return nil }
            var result = Data()
            if copying { result.reserveCapacity(count) }
            var left = count
            while left > 0 {
                guard refill() else { return nil }
                let chunk = min(left, buffer.endIndex - cursor)
                if copying { result.append(buffer[cursor..<cursor + chunk]) }
                cursor += chunk; left -= chunk
            }
            return result
        }
        guard byte() == 0xff, byte() == 0xd8 else { return nil }
        while !Task.isCancelled {
            guard byte() == 0xff else { return nil }
            var marker = byte()
            while marker == 0xff { marker = byte() }
            guard let marker, ![0, 0xd8, 0xd9, 0xda].contains(marker) else { return nil }
            if marker == 1 || (0xd0...0xd7).contains(marker) { continue }
            guard marker >= 0xc0, let high = byte(), let low = byte() else { return nil }
            let length = Int(high) * 256 + Int(low) - 2
            let mayContainIdentity = marker == 0xef && length == magic.count + 64
            guard let payload = consume(length, copying: mayContainIdentity) else { return nil }
            if mayContainIdentity, payload.starts(with: magic) {
                guard let identity = String(data: payload.dropFirst(magic.count), encoding: .ascii), valid(identity) else { return nil }
                return identity
            }
        }
        return nil
    }
}
