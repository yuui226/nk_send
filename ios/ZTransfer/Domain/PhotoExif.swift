import Foundation
import ImageIO

struct PhotoExif: Equatable, Sendable {
    let aperture: String?
    let shutterSpeed: String?
    let iso: String?
    let focalLength: String?
    let dateTime: String?
    let lensModel: String?
    let exposureCompensation: String?
}

enum PhotoExifParser {
    static func parse(_ data: Data) -> PhotoExif? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let aperture = (exif?[kCGImagePropertyExifFNumber] as? NSNumber).map { String(format: "f/%.1f", $0.doubleValue) }
        let exposure = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let shutter = exposure.flatMap(formatShutter)
        let iso = ((exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first)?.stringValue
        let focal = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber).map { String(format: "%.0fmm", $0.doubleValue) }
        let dateTime = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let lens = exif?[kCGImagePropertyExifLensModel] as? String
        let compensation = (exif?[kCGImagePropertyExifExposureBiasValue] as? NSNumber).flatMap(formatEV)
        return PhotoExif(aperture: aperture, shutterSpeed: shutter, iso: iso, focalLength: focal, dateTime: dateTime, lensModel: lens, exposureCompensation: compensation)
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
}
