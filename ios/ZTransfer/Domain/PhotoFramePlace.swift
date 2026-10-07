import Foundation

struct PhotoFramePlace: Equatable, Sendable { let city: String?; let region: String? }

func photoFramePlace(city: String?, district: String?, subAdmin: String?, admin: String?, countryCode: String? = nil) -> PhotoFramePlace {
    func clean(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    let locality = clean(city), district = clean(district), subdivision = clean(subAdmin), administration = clean(admin)
    let chinese = countryCode?.caseInsensitiveCompare("CN") == .orderedSame || [locality, district, subdivision, administration].compactMap { $0 }.contains { $0.range(of: "[\\u{4E00}-\\u{9FFF}]", options: .regularExpression) != nil }
    func county(_ value: String) -> Bool { chinese ? ["区", "區", "县", "縣", "旗"].contains(where: value.hasSuffix) : value.range(of: "\\s+(County|District)$", options: [.regularExpression, .caseInsensitive]) != nil }
    let cityName = locality.flatMap { county($0) ? nil : $0 } ?? (chinese && subdivision?.hasSuffix("市") == true ? subdivision : (!chinese ? subdivision : nil))
    let regionName = [district, subdivision, locality].compactMap { $0 }.first { county($0) && $0.caseInsensitiveCompare(cityName ?? "") != .orderedSame }
    return PhotoFramePlace(city: cityName, region: regionName)
}

func validPhotoFrameCoordinates(_ latitude: Double?, _ longitude: Double?) -> Bool {
    guard let latitude, let longitude, latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
    return latitude != 0 || longitude != 0
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
