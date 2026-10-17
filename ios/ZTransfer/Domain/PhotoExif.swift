import Foundation
import ImageIO

struct PhotoExif: Equatable, Sendable {
    let make: String?
    let model: String?
    let aperture: String?
    let shutterSpeed: String?
    let iso: String?
    let focalLength: String?
    let dateTime: String?
    let lensModel: String?
    let exposureCompensation: String?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let city: String?
    let region: String?
    var orientation: Int? = nil
}

/// Metadata presentation values consumed by the frame renderer. The strings
/// are normalized once from EXIF so every frame layout uses the same values.
struct PhotoFrameMetadata: Equatable, Sendable {
    let make: String?
    let model: String?
    let lensModel: String?
    let focalLength: String?
    let aperture: String?
    let shutter: String?
    let iso: String?
    let exposureCompensation: String?
    let dateTime: String?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let city: String?
    let region: String?

    init(make: String?, model: String?, lensModel: String?, focalLength: String?,
         aperture: String?, shutter: String?, iso: String?, exposureCompensation: String?,
         dateTime: String?, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil, city: String? = nil, region: String? = nil) {
        self.make = make; self.model = model; self.lensModel = lensModel
        self.focalLength = focalLength; self.aperture = aperture; self.shutter = shutter
        self.iso = iso; self.exposureCompensation = exposureCompensation; self.dateTime = dateTime
        self.latitude = latitude; self.longitude = longitude; self.altitude = altitude; self.city = city; self.region = region
    }

    /// Android PhotoMetadataSnapshotBounds: queued recipes retain at most
    /// 256 UTF-16 units per label, without splitting a surrogate pair.
    func boundedForQueue() -> Self {
        func bounded(_ value: String?) -> String? {
            guard let value, value.utf16.count > 256 else { return value }
            var units = Array(value.utf16.prefix(256))
            if let last = units.last, (0xD800...0xDBFF).contains(last) {
                units.removeLast()
            }
            return String(decoding: units, as: UTF16.self)
        }
        return Self(make: bounded(make), model: bounded(model), lensModel: bounded(lensModel),
                    focalLength: bounded(focalLength), aperture: bounded(aperture),
                    shutter: bounded(shutter), iso: bounded(iso),
                    exposureCompensation: exposureCompensation, dateTime: bounded(dateTime),
                    latitude: latitude, longitude: longitude, altitude: altitude,
                    city: bounded(city), region: bounded(region))
    }

    init(_ exif: PhotoExif) {
        make = exif.make; model = exif.model; lensModel = exif.lensModel
        focalLength = exif.focalLength; aperture = exif.aperture
        shutter = exif.shutterSpeed; iso = exif.iso
        exposureCompensation = exif.exposureCompensation; dateTime = exif.dateTime
        latitude = exif.latitude; longitude = exif.longitude; altitude = exif.altitude; city = nil; region = nil
    }
}

enum PhotoExifParser {
    static func parse(_ data: Data) -> PhotoExif? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var metadata = parse(source)
        if metadata?.orientation == nil { metadata?.orientation = parseJpegCropOrientation(data) }
        return metadata
    }

    static func parse(_ url: URL) -> PhotoExif? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return parse(source)
    }

    private static func parse(_ source: CGImageSource) -> PhotoExif? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let gps = properties[kCGImagePropertyGPSDictionary] as? NSDictionary
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let aperture = ((exif?[kCGImagePropertyExifFNumber] as? NSNumber)
            ?? (exif?[kCGImagePropertyExifApertureValue] as? NSNumber).map { NSNumber(value: pow(2, $0.doubleValue / 2)) })
            .map(formatAperture)
        let exposure = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let shutter = exposure.flatMap(formatShutter)
        let iso = ((exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first).map { "ISO\($0.intValue)" }
        let focal = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber).map { String(format: "%.0fmm", $0.doubleValue) }
        let dateTime = [exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                        exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
                        tiff?[kCGImagePropertyTIFFDateTime] as? String]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? metadataTIFFDate(source)
        let lens = (exif?[kCGImagePropertyExifLensModel] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let compensation = (exif?[kCGImagePropertyExifExposureBiasValue] as? NSNumber).flatMap(formatEV)
        let latitude = signedCoordinate(gps?[kCGImagePropertyGPSLatitude] as? NSNumber, reference: gps?[kCGImagePropertyGPSLatitudeRef] as? String, maximum: 90)
        let longitude = signedCoordinate(gps?[kCGImagePropertyGPSLongitude] as? NSNumber, reference: gps?[kCGImagePropertyGPSLongitudeRef] as? String, maximum: 180)
        let altitudeValue = (gps?[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        let altitude = altitudeValue.map { (gps?[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1 ? -abs($0) : $0 }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        return PhotoExif(make: make, model: model, aperture: aperture, shutterSpeed: shutter, iso: iso, focalLength: focal, dateTime: dateTime, lensModel: lens, exposureCompensation: compensation, latitude: latitude, longitude: longitude, altitude: altitude, city: nil, region: nil,
                         orientation: orientation.flatMap { (1...8).contains($0) ? $0 : nil })
    }

    private static func metadataTIFFDate(_ source: CGImageSource) -> String? {
        // ImageIO can expose TIFF DateTime only through its normalized metadata
        // tag (xmp:ModifyDate), omitting it from CopyProperties altogether.
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata,
                kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime),
              let value = CGImageMetadataTagCopyValue(tag) as? String else { return nil }
        var characters = Array(value)
        guard characters.count >= 19, characters[4] == "-", characters[7] == "-",
              characters[10] == "T" else { return nil }
        characters[4] = ":"; characters[7] = ":"; characters[10] = " "
        return String(characters.prefix(19))
    }

    private static func formatAperture(_ value: NSNumber) -> String {
        let number = value.doubleValue
        // Android tests the fractional remainder, not distance to the nearest integer.
        return number.truncatingRemainder(dividingBy: 1) < 0.05
            ? String(format: "f/%.0f", number)
            : String(format: "f/%.1f", number)
    }

    private static func formatShutter(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        let denominator = max(1, Int((1 / seconds).rounded()))
        return "1/\(denominator)"
    }

    private static func formatEV(_ value: NSNumber) -> String? {
        let ev = value.doubleValue
        guard ev.isFinite, abs(ev) >= 0.05 else { return nil }
        return String(format: "%+.1f EV", ev)
    }
    private static func signedCoordinate(_ value: NSNumber?, reference: String?, maximum: Double) -> Double? {
        guard let raw = value?.doubleValue, raw.isFinite, raw >= 0, raw <= maximum else { return nil }
        let sign = (reference?.uppercased() == "S" || reference?.uppercased() == "W") ? -1.0 : 1.0
        return raw == 0 ? nil : raw * sign
    }
}
