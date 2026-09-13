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

    init(make: String?, model: String?, lensModel: String?, focalLength: String?,
         aperture: String?, shutter: String?, iso: String?, exposureCompensation: String?,
         dateTime: String?) {
        self.make = make; self.model = model; self.lensModel = lensModel
        self.focalLength = focalLength; self.aperture = aperture; self.shutter = shutter
        self.iso = iso; self.exposureCompensation = exposureCompensation; self.dateTime = dateTime
    }

    init(_ exif: PhotoExif) {
        make = exif.make; model = exif.model; lensModel = exif.lensModel
        focalLength = exif.focalLength; aperture = exif.aperture
        shutter = exif.shutterSpeed; iso = exif.iso
        exposureCompensation = exif.exposureCompensation; dateTime = exif.dateTime
    }
}

enum PhotoExifParser {
    static func parse(_ data: Data) -> PhotoExif? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
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
        return PhotoExif(make: make, model: model, aperture: aperture, shutterSpeed: shutter, iso: iso, focalLength: focal, dateTime: dateTime, lensModel: lens, exposureCompensation: compensation)
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
