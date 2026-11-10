import Foundation

struct PhotoFramePlace: Equatable, Sendable { let city: String?; let region: String? }

extension PhotoFrameMetadata {
    var renderedPlace: PhotoFramePlace { .init(city: city, region: region) }

    /// Android withAllowedFramePlace: recheck the current connection policy
    /// before deduplication and rendering without discarding camera EXIF/GPS.
    func withAllowedFramePlace(_ allowed: Bool) -> Self {
        guard !allowed else { return self }
        return Self(make: make, model: model, lensModel: lensModel, focalLength: focalLength,
            aperture: aperture, shutter: shutter, iso: iso, exposureCompensation: exposureCompensation,
            dateTime: dateTime, latitude: latitude, longitude: longitude, altitude: altitude)
    }
}

func photoFramePlace(city: String?, district: String?, subAdmin: String?, admin: String?, countryCode: String? = nil) -> PhotoFramePlace {
    PhotoPlaceAddressMapper(city: city, district: district, subAdmin: subAdmin, admin: admin, countryCode: countryCode).resolve()
}

func validPhotoFrameCoordinates(_ latitude: Double?, _ longitude: Double?) -> Bool {
    guard let latitude, let longitude, latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
    return latitude != 0 || longitude != 0
}



/// Use the selected app language for both geocoding and preview examples.
func photoFramePlaceLocale(language: String? = UserDefaults.standard.string(forKey: "app_language"),
                           systemLocale: Locale = .current) -> Locale {
    guard let language, language != "system" else { return systemLocale }
    return Locale(identifier: language)
}

func photoFramePreviewPlace(locale: Locale) -> PhotoFramePlace {
    guard locale.language.languageCode?.identifier == "zh" else {
        return PhotoFramePlace(city: "Light & Shadow City", region: "Blue Hour District")
    }
    let traditional = locale.language.script?.identifier == "Hant" ||
        ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "")
    return PhotoFramePlace(city: "光影市", region: traditional ? "藍調區" : "蓝调区")
}
