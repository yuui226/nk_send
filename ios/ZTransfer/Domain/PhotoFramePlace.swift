import Foundation

struct PhotoFramePlace: Equatable, Sendable { let city: String?; let region: String? }

func photoFramePlace(city: String?, district: String?, subAdmin: String?, admin: String?, countryCode: String? = nil) -> PhotoFramePlace {
    func clean(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    let locality = clean(city), district = clean(district), subdivision = clean(subAdmin), administration = clean(admin)
    func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
    func ends(_ value: String, _ suffixes: [String]) -> Bool { suffixes.contains(where: value.hasSuffix) }
    let missingCountry = clean(countryCode) == nil
    let chineseCountry = same(countryCode, "CN")
    let chinese = chineseCountry || (missingCountry &&
        [locality, district, subdivision, administration].compactMap { $0 }.contains {
            $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        })
    let provinces = ["省", "自治区", "自治區", "特别行政区", "特別行政區"]
    let neighborhoods = ["社区", "社區", "街道", "开发区", "開發區", "高新区", "高新區", "工业区", "工業區"]
    func county(_ value: String) -> Bool {
        if chinese {
            guard !ends(value, provinces + neighborhoods.filter { $0 != "街道" }),
                  !["市辖区", "市轄區", "县", "縣", "区", "區"].contains(value) else { return false }
            if ends(value, ["区", "區", "县", "縣", "旗"]) { return true }
        }
        let pattern = chinese ? #"\A.+\s+(County|District|Autonomous County)\z"# : #"\A.+\s+(County|District)\z"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    let municipality = administration.flatMap { value -> String? in
        let names = ["北京", "北京市", "beijing", "beijing shi", "上海", "上海市", "shanghai", "shanghai shi",
                     "天津", "天津市", "tianjin", "tianjin shi", "重庆", "重庆市", "重慶", "重慶市", "chongqing", "chongqing shi"]
        return (missingCountry || chineseCountry) && names.contains(value.lowercased()) ? value : nil
    }
    let cityName = locality.flatMap { value -> String? in
        let excluded = county(value) || (chinese && (ends(value, provinces + neighborhoods) ||
            ["市辖区", "市轄區"].contains(value) || (same(value, administration) && municipality == nil)))
        return excluded ? nil : value
    } ?? subdivision.flatMap { chinese && $0.count > 1 && $0.hasSuffix("市") ? $0 : nil } ?? municipality
    let regionName: String?
    if chinese {
        regionName = [district, subdivision, locality].compactMap { $0 }.first {
            county($0) && !same($0, cityName) && !same($0, administration)
        }
    } else {
        regionName = subdivision.flatMap { same($0, cityName) || same($0, administration) ? nil : $0 }
            ?? locality.flatMap { county($0) && !same($0, cityName) ? $0 : nil }
    }
    return PhotoFramePlace(city: cityName, region: regionName)
}

func validPhotoFrameCoordinates(_ latitude: Double?, _ longitude: Double?) -> Bool {
    guard let latitude, let longitude, latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
    return latitude != 0 || longitude != 0
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }


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
