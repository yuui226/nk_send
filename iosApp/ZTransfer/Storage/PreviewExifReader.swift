import Foundation
import CoreGraphics
import ImageIO
import Darwin
import ZTransferShared

/// Shared cancellation flag: ImageIO may invoke a C callback without the originating Swift task.
final class PreviewExifReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Owns a duplicate of an already-validated descriptor, never reopens a URL or maps a whole RAW.
final class PreviewExifFileReader {
    private let descriptor: Int32
    private let size: Int64
    private let cancellation: PreviewExifReadCancellation
    private let lock = NSLock()
    private var readFailure = false
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return readFailure }

    init(fileDescriptor: Int32, size: Int64, cancellation: PreviewExifReadCancellation) throws {
        let duplicate = Darwin.dup(fileDescriptor)
        guard duplicate >= 0 else { throw OriginalIndexError.incompleteMetadata }
        guard Darwin.fcntl(duplicate, F_SETFD, FD_CLOEXEC) >= 0 else {
            _ = Darwin.close(duplicate); throw OriginalIndexError.incompleteMetadata
        }
        self.descriptor = duplicate; self.size = size; self.cancellation = cancellation
    }
    deinit { _ = Darwin.close(descriptor) }
    private func fail() { lock.lock(); readFailure = true; lock.unlock() }

    func read(into buffer: UnsafeMutableRawPointer, position: Int64, count: Int) -> Int {
        guard !cancellation.isCancelled, !failed, position >= 0, position <= size, count > 0 else { return 0 }
        let requested = Int(min(Int64(count), size - position))
        var loaded = 0
        while loaded < requested {
            if cancellation.isCancelled { return loaded }
            let amount = Darwin.pread(descriptor, buffer.advanced(by: loaded), min(requested - loaded, 64 * 1024), position + Int64(loaded))
            if amount < 0 && errno == EINTR { continue }
            if amount <= 0 { fail(); return loaded }
            loaded += amount
        }
        return loaded
    }
}

/// ImageIO extraction only. Preview fields, Float/GPS fallback and locale rendering use shared.
enum PreviewExifReader {
    static func metadata(fileDescriptor: Int32, size: Int64, cancellation: PreviewExifReadCancellation, locale: Locale = .current) throws -> PhotoExif? {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard size > 0 else { throw PreviewImageError.invalidImage }
        let reader = try PreviewExifFileReader(fileDescriptor: fileDescriptor, size: size, cancellation: cancellation)
        let info = Unmanaged.passRetained(reader).toOpaque()
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                return Unmanaged<PreviewExifFileReader>.fromOpaque(info).takeUnretainedValue().read(into: buffer, position: position, count: count)
            }, releaseInfo: { info in
                if let info { Unmanaged<PreviewExifFileReader>.fromOpaque(info).release() }
            })
        guard let provider = CGDataProvider(directInfo: info, size: size, callbacks: &callbacks) else {
            Unmanaged<PreviewExifFileReader>.fromOpaque(info).release()
            throw PreviewImageError.invalidImage
        }
        let result: PhotoExif?
        if let source = CGImageSourceCreateWithDataProvider(provider, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            result = metadata(properties, locale: locale)
        } else { result = nil }
        if cancellation.isCancelled { throw CancellationError() }
        if reader.failed { throw OriginalIndexError.incompleteMetadata }
        try Task.checkCancellation()
        return result
    }

    static func metadata(_ properties: [String: Any], locale: Locale = .current) -> PhotoExif? {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        func text(_ dictionary: [String: Any], _ key: CFString) -> String? {
            if let number = dictionary[key as String] as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                return number.stringValue
            }
            return dictionary[key as String] as? String
        }
        func number(_ dictionary: [String: Any], _ key: CFString) -> Double {
            guard let raw = text(dictionary, key) else { return .nan }
            return Double(raw) ?? .nan
        }
        let values = NativePreviewExifValues()
        let fields: [(PreviewExifTag, [String: Any], CFString)] = [
            (.fNumber, exif, kCGImagePropertyExifFNumber), (.apertureValue, exif, kCGImagePropertyExifApertureValue),
            (.exposureTime, exif, kCGImagePropertyExifExposureTime), (.exposureBiasValue, exif, kCGImagePropertyExifExposureBiasValue),
            (.focalLength, exif, kCGImagePropertyExifFocalLength), (.lensModel, exif, kCGImagePropertyExifLensModel),
            (.datetimeOriginal, exif, kCGImagePropertyExifDateTimeOriginal), (.datetimeDigitized, exif, kCGImagePropertyExifDateTimeDigitized),
            (.datetime, tiff, kCGImagePropertyTIFFDateTime), (.gpsLatitude, gps, kCGImagePropertyGPSLatitude),
            (.gpsLatitudeRef, gps, kCGImagePropertyGPSLatitudeRef), (.gpsLongitude, gps, kCGImagePropertyGPSLongitude),
            (.gpsLongitudeRef, gps, kCGImagePropertyGPSLongitudeRef),
        ]
        for (tag, dictionary, key) in fields { values.set(tag: tag, value: text(dictionary, key)) }
        let iso: String?
        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
           ratings.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) {
            iso = ratings.map { $0.stringValue }.joined(separator: ",")
        } else { iso = text(exif, kCGImagePropertyExifISOSpeedRatings) }
        values.set(tag: .photographicSensitivity, value: iso)
        values.setImageIoCoordinates(latitude: number(gps, kCGImagePropertyGPSLatitude), latitudeReference: text(gps, kCGImagePropertyGPSLatitudeRef),
            longitude: number(gps, kCGImagePropertyGPSLongitude), longitudeReference: text(gps, kCGImagePropertyGPSLongitudeRef))
        let altitudeRef = number(gps, kCGImagePropertyGPSAltitudeRef)
        values.setImageIoAltitude(value: number(gps, kCGImagePropertyGPSAltitude),
            reference: altitudeRef.isFinite && altitudeRef >= 0 && altitudeRef <= Double(Int32.max) &&
                altitudeRef.rounded(.towardZero) == altitudeRef ? Int32(altitudeRef) : -1)
        return NativePreviewExifBridge.shared.metadata(values: values, formatter: ApplePreviewExifFormatter(locale: locale))
    }
}
