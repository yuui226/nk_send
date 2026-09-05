import Foundation
import ImageIO
import ZTransferShared

/// Locale rendering only; aperture/shutter branches and all EXIF fallbacks remain in shared.
/// Decimal half-up matches the intended Locale.US output. Golden boundary values must still be
/// exercised in XCTest on Apple: Foundation/Java floating formatting is not assumed identical.
final class ApplePhotoDecimalFormatter: NSObject, NativePhotoDecimalFormatter {
    func fixed(value: Double, fractionDigits: Int32) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = Int(fractionDigits)
        formatter.maximumFractionDigits = Int(fractionDigits)
        formatter.maximumIntegerDigits = 309
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Original preview Float rendering, separate from photo-frame Locale.US formatting.
/// Branches/reciprocals/APEX/signs are shared; Apple rounding/localized digits need Mac goldens.
final class ApplePreviewExifFormatter: NSObject, PreviewExifDecimalFormatter {
    private let locale: Locale
    init(locale: Locale = .current) { self.locale = locale; super.init() }

    func fixed(value: Float, fractionDigits: Int32, rootLocale: Bool) -> String {
        // Java Formatter spells these values independently of the default locale.
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let formatter = NumberFormatter()
        formatter.locale = rootLocale ? Locale(identifier: "en_US_POSIX") : locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumIntegerDigits = 1
        formatter.maximumIntegerDigits = 309
        formatter.minimumFractionDigits = Int(fractionDigits)
        formatter.maximumFractionDigits = Int(fractionDigits)
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: Double(value))) ?? String(value)
    }
}

/// Gregorian field rendering only. Validation/time fallback lives in shared, not Calendar/Date.
enum ApplePreviewDateText {
    static func date(year: Int32, month: Int32, day: Int32, locale: Locale = .current) -> String {
        parts([year, month, day], widths: [4, 2, 2], separator: "-", locale: locale)
    }
    static func time(hour: Int32, minute: Int32, second: Int32, locale: Locale = .current) -> String {
        parts([hour, minute, second], widths: [2, 2, 2], separator: ":", locale: locale)
    }
    private static func parts(_ values: [Int32], widths: [Int], separator: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = 0
        formatter.maximumIntegerDigits = 309
        formatter.positivePrefix = ""; formatter.positiveSuffix = ""
        return zip(values, widths).map { value, width in
            formatter.minimumIntegerDigits = width
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%0*d", width, value)
        }.joined(separator: separator)
    }
}

/// Reads ImageIO properties without decoding the full image or modifying the source. This is
/// metadata extraction, not a RAW decoder, output EXIF writer, or permission to publish coordinates.
actor PhotoMetadataReader {
    func read(_ url: URL) throws -> PhotoFrameMetadata {
        try Task.checkCancellation()
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw PreviewImageError.invalidImage
        }
        let metadata = Self.metadata(properties)
        try Task.checkCancellation()
        return metadata
    }

    static func metadata(_ properties: [String: Any]) -> PhotoFrameMetadata {
        NativePhotoMetadataBridge.shared.metadata(values: values(properties), formatter: ApplePhotoDecimalFormatter())
    }

    static func values(_ properties: [String: Any]) -> PhotoFrameExifValues {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        func text(_ dictionary: [String: Any], _ key: CFString) -> String? {
            let value = dictionary[key as String]
            if let number = value as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                return number.stringValue
            }
            return value as? String
        }
        func number(_ dictionary: [String: Any], _ key: CFString) -> Double {
            NativePhotoMetadataBridge.shared.number(text: text(dictionary, key))
        }
        let iso: String?
        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
           ratings.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) {
            iso = ratings.map { $0.stringValue }.joined(separator: ",")
        } else {
            iso = text(exif, kCGImagePropertyExifISOSpeedRatings)
        }
        // ImageIO exposes decimal degrees and a separate N/S/E/W reference. Use shared's raw-value
        // parser (which accepts decimal or rational/DMS); do not duplicate sign/range/zero policy.
        return PhotoFrameExifValues(make: text(tiff, kCGImagePropertyTIFFMake), model: text(tiff, kCGImagePropertyTIFFModel),
            fNumber: number(exif, kCGImagePropertyExifFNumber), apertureValue: number(exif, kCGImagePropertyExifApertureValue),
            exposureTimeSeconds: number(exif, kCGImagePropertyExifExposureTime), shutterSpeedValue: number(exif, kCGImagePropertyExifShutterSpeedValue),
            iso: iso, focalLength: number(exif, kCGImagePropertyExifFocalLength), lensModel: text(exif, kCGImagePropertyExifLensModel),
            dateTimeOriginal: text(exif, kCGImagePropertyExifDateTimeOriginal), dateTimeDigitized: text(exif, kCGImagePropertyExifDateTimeDigitized),
            dateTime: text(tiff, kCGImagePropertyTIFFDateTime), decodedLatitude: nil, decodedLongitude: nil,
            latitudeDms: text(gps, kCGImagePropertyGPSLatitude), latitudeReference: text(gps, kCGImagePropertyGPSLatitudeRef),
            longitudeDms: text(gps, kCGImagePropertyGPSLongitude), longitudeReference: text(gps, kCGImagePropertyGPSLongitudeRef),
            decodedAltitudeMeters: .nan, altitudeRational: text(gps, kCGImagePropertyGPSAltitude),
            altitudeBelowSeaLevel: number(gps, kCGImagePropertyGPSAltitudeRef) == 1)
    }
}
