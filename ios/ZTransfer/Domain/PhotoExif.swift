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

    init(make: String?, model: String?, lensModel: String?, focalLength: String?,
         aperture: String?, shutter: String?, iso: String?, exposureCompensation: String?,
         dateTime: String?, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil) {
        self.make = make; self.model = model; self.lensModel = lensModel
        self.focalLength = focalLength; self.aperture = aperture; self.shutter = shutter
        self.iso = iso; self.exposureCompensation = exposureCompensation; self.dateTime = dateTime
        self.latitude = latitude; self.longitude = longitude; self.altitude = altitude
    }

    init(_ exif: PhotoExif) {
        make = exif.make; model = exif.model; lensModel = exif.lensModel
        focalLength = exif.focalLength; aperture = exif.aperture
        shutter = exif.shutterSpeed; iso = exif.iso
        exposureCompensation = exif.exposureCompensation; dateTime = exif.dateTime
        latitude = exif.latitude; longitude = exif.longitude; altitude = exif.altitude
    }
}

enum PhotoExifParser {
    static func parse(_ data: Data) -> PhotoExif? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let gps = properties[kCGImagePropertyGPSDictionary] as? NSDictionary
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let aperture = (exif?[kCGImagePropertyExifFNumber] as? NSNumber).map { String(format: "f/%.1f", $0.doubleValue) }
        let exposure = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let shutter = exposure.flatMap(formatShutter)
        let iso = ((exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first)?.stringValue
        let focal = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber).map { String(format: "%.0fmm", $0.doubleValue) }
        let dateTime = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let lens = exif?[kCGImagePropertyExifLensModel] as? String
        let compensation = (exif?[kCGImagePropertyExifExposureBiasValue] as? NSNumber).flatMap(formatEV)
        let latitude = signedCoordinate(gps?[kCGImagePropertyGPSLatitude] as? NSNumber, reference: gps?[kCGImagePropertyGPSLatitudeRef] as? String, maximum: 90)
        let longitude = signedCoordinate(gps?[kCGImagePropertyGPSLongitude] as? NSNumber, reference: gps?[kCGImagePropertyGPSLongitudeRef] as? String, maximum: 180)
        let altitudeValue = (gps?[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        let altitude = altitudeValue.map { (gps?[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1 ? -abs($0) : $0 }
        return PhotoExif(make: make, model: model, aperture: aperture, shutterSpeed: shutter, iso: iso, focalLength: focal, dateTime: dateTime, lensModel: lens, exposureCompensation: compensation, latitude: latitude, longitude: longitude, altitude: altitude)
    }

    private static func formatShutter(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
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
