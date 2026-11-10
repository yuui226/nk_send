import Foundation
import ImageIO

/// Android 431132ca, util/PhotoCaptureExif.kt. Both effect exports and
/// coefficient crops use this allowlist. Geometry belongs to the output;
/// embedded previews, MakerNote, XMP and opaque offsets never cross it.
enum PhotoCaptureExif {
    struct Field: Sendable {
        let tag: UInt16
        let key: String
        init(_ tag: UInt16, _ key: CFString) { self.tag = tag; self.key = key as String }
    }

    static let tiff: [Field] = [
        Field(0x010f, kCGImagePropertyTIFFMake),
        Field(0x0110, kCGImagePropertyTIFFModel),
        Field(0x0131, kCGImagePropertyTIFFSoftware),
        Field(0x013b, kCGImagePropertyTIFFArtist),
        Field(0x8298, kCGImagePropertyTIFFCopyright),
        Field(0x010e, kCGImagePropertyTIFFImageDescription),
        Field(0x0132, kCGImagePropertyTIFFDateTime),
    ]
    static let exif: [Field] = [
        Field(0x9003, kCGImagePropertyExifDateTimeOriginal),
        Field(0x9004, kCGImagePropertyExifDateTimeDigitized),
        Field(0x9290, kCGImagePropertyExifSubsecTime),
        Field(0x9291, kCGImagePropertyExifSubsecTimeOriginal),
        Field(0x9292, kCGImagePropertyExifSubsecTimeDigitized),
        Field(0x9010, kCGImagePropertyExifOffsetTime),
        Field(0x9011, kCGImagePropertyExifOffsetTimeOriginal),
        Field(0x9012, kCGImagePropertyExifOffsetTimeDigitized),
        Field(0x829a, kCGImagePropertyExifExposureTime),
        Field(0x9201, kCGImagePropertyExifShutterSpeedValue),
        Field(0x829d, kCGImagePropertyExifFNumber),
        Field(0x9202, kCGImagePropertyExifApertureValue),
        Field(0x9205, kCGImagePropertyExifMaxApertureValue),
        Field(0x9203, kCGImagePropertyExifBrightnessValue),
        Field(0x8827, kCGImagePropertyExifISOSpeedRatings),
        Field(0x8830, kCGImagePropertyExifSensitivityType),
        Field(0x8831, kCGImagePropertyExifStandardOutputSensitivity),
        Field(0x8832, kCGImagePropertyExifRecommendedExposureIndex),
        Field(0x8833, kCGImagePropertyExifISOSpeed),
        Field(0x920a, kCGImagePropertyExifFocalLength),
        Field(0xa405, kCGImagePropertyExifFocalLenIn35mmFilm),
        Field(0xa404, kCGImagePropertyExifDigitalZoomRatio),
        Field(0xa432, kCGImagePropertyExifLensSpecification),
        Field(0xa433, kCGImagePropertyExifLensMake),
        Field(0xa434, kCGImagePropertyExifLensModel),
        Field(0xa435, kCGImagePropertyExifLensSerialNumber),
        Field(0xa431, kCGImagePropertyExifBodySerialNumber),
        Field(0xa430, kCGImagePropertyExifCameraOwnerName),
        Field(0x8822, kCGImagePropertyExifExposureProgram),
        Field(0xa402, kCGImagePropertyExifExposureMode),
        Field(0x9204, kCGImagePropertyExifExposureBiasValue),
        Field(0x9207, kCGImagePropertyExifMeteringMode),
        Field(0x9208, kCGImagePropertyExifLightSource),
        Field(0x9209, kCGImagePropertyExifFlash),
        Field(0xa403, kCGImagePropertyExifWhiteBalance),
        Field(0xa406, kCGImagePropertyExifSceneCaptureType),
        Field(0x9206, kCGImagePropertyExifSubjectDistance),
        Field(0xa40c, kCGImagePropertyExifSubjectDistRange),
        Field(0xa001, kCGImagePropertyExifColorSpace),
    ]
    static let gps: [Field] = [
        Field(0, kCGImagePropertyGPSVersion),
        Field(1, kCGImagePropertyGPSLatitudeRef),
        Field(2, kCGImagePropertyGPSLatitude),
        Field(3, kCGImagePropertyGPSLongitudeRef),
        Field(4, kCGImagePropertyGPSLongitude),
        Field(5, kCGImagePropertyGPSAltitudeRef),
        Field(6, kCGImagePropertyGPSAltitude),
        Field(7, kCGImagePropertyGPSTimeStamp),
        Field(29, kCGImagePropertyGPSDateStamp),
        Field(27, kCGImagePropertyGPSProcessingMethod),
        Field(12, kCGImagePropertyGPSSpeedRef),
        Field(13, kCGImagePropertyGPSSpeed),
        Field(14, kCGImagePropertyGPSTrackRef),
        Field(15, kCGImagePropertyGPSTrack),
        Field(16, kCGImagePropertyGPSImgDirectionRef),
        Field(17, kCGImagePropertyGPSImgDirection),
        Field(18, kCGImagePropertyGPSMapDatum),
        Field(31, kCGImagePropertyGPSHPositioningError),
    ]

    static let tiffTags = Set(tiff.map(\.tag))
    static let exifTags = Set(exif.map(\.tag))
    static let gpsTags = Set(gps.map(\.tag))

    static func copiedValues(from source: NSDictionary?, fields: [Field]) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        for field in fields {
            // Keep the actual ImageIO numbers/arrays, never the display strings.
            if let value = source?[field.key] { result[field.key as CFString] = value }
        }
        return result
    }
}
