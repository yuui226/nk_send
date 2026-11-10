import Foundation

/// Android location/PlaceAddressMapper.kt (431132ca). Interpret only supplied
/// administrative levels, retain their spelling, and never invent a parent.
struct PhotoPlaceAddressMapper {
    private let locality: String?
    private let subLocality: String?
    private let subdivision: String?
    private let administration: String?
    private let code: String?
    private let chineseHierarchy: Bool

    init(city: String?, district: String?, subAdmin: String?, admin: String?, countryCode: String?) {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        locality = clean(city); subLocality = clean(district)
        subdivision = clean(subAdmin); administration = clean(admin)
        code = clean(countryCode)?.uppercased(with: Locale(identifier: "en_US_POSIX"))
        let names = [locality, subLocality, subdivision, administration].compactMap { $0 }
        chineseHierarchy = code == "CN" || (code == nil &&
            (administration.map { Self.ends($0, ["省", "自治区", "自治區"]) || Self.municipality($0) != nil } == true ||
             names.contains { Self.ends($0, ["自治州", "盟", "自治县", "自治縣", "自治旗"]) }))
    }

    func resolve() -> PhotoFramePlace {
        let sar = [nil, "CN", "HK", "MO"].contains(code)
            ? [administration, locality, subdivision].compactMap { $0 }.first { Self.specialRegions[Self.key($0)] != nil } : nil
        if code == "HK" || code == "MO" || sar != nil { return hongKongOrMacao(sar) }
        if code == "TW" { return taiwan() }
        return chineseHierarchy ? mainland() : international()
    }

    private func same(_ a: String?, _ b: String?, allowCityAbbreviation: Bool = true) -> Bool {
        guard let a, let b else { return false }
        let left = Self.key(a), right = Self.key(b)
        if left == right { return true }
        if let region = Self.specialRegions[left], region == Self.specialRegions[right] { return true }
        guard chineseHierarchy || code == "TW" else { return false }
        if chineseHierarchy, let municipality = Self.municipality(a), municipality == Self.municipality(b) { return true }
        return allowCityAbbreviation && (Self.cityStem(left) == right || Self.cityStem(right) == left)
    }
    private func sameAdmin(_ value: String) -> Bool { same(value, administration, allowCityAbbreviation: false) }
    private func placeholder(_ value: String) -> Bool {
        Self.placeholders.contains(Self.key(value)) || Self.ends(value, ["直辖县级行政区划", "直轄縣級行政區劃"])
    }
    private func province(_ value: String) -> Bool {
        Self.ends(value, ["省", "自治区", "自治區", "特别行政区", "特別行政區"]) ||
            PlaceType.province.matches(value) || (chineseHierarchy && PlaceType.pinyinProvince.matches(value))
    }
    private func neighborhoodOrZone(_ value: String) -> Bool {
        Self.ends(value, ["社区", "社區", "街道", "街道办事处", "街道辦事處", "村", "苏木", "蘇木",
            "开发区", "開發區", "高新区", "高新區", "工业区", "工業區", "园区", "園區"]) ||
            PlaceType.neighborhood.matches(value) || (code == "TW" && value.hasSuffix("里"))
    }
    private func lowerLevel(_ value: String) -> Bool {
        neighborhoodOrZone(value) || Self.ends(value, ["镇", "鎮", "乡", "鄉"]) ||
            PlaceType.township.matches(value) || (chineseHierarchy && PlaceType.pinyinTownship.matches(value))
    }
    private func cityUnit(_ value: String) -> Bool {
        !placeholder(value) && (value.hasSuffix("市") || PlaceType.city.matches(value) ||
            (chineseHierarchy && PlaceType.pinyinCity.matches(value)))
    }
    private func namedDistrict(_ value: String) -> Bool {
        !placeholder(value) && !province(value) && !lowerLevel(value) &&
            (Self.ends(value, ["区", "區", "县", "縣", "旗"]) || PlaceType.countyDistrictBanner.matches(value) ||
                (chineseHierarchy && PlaceType.pinyinCountyDistrict.matches(value)))
    }
    private func hongKongOrMacao(_ sar: String?) -> PhotoFramePlace {
        let region = [subLocality, subdivision, locality].compactMap { $0 }.first {
            !same($0, sar) && !placeholder($0) && !province($0) && !lowerLevel($0) &&
                (Self.ends($0, ["区", "區"]) || PlaceType.district.matches($0) ||
                 $0.lowercased().hasSuffix(" parish") || $0.lowercased().hasPrefix("freguesia "))
        } ?? subdivision.flatMap {
            same($0, sar) || placeholder($0) || province($0) || lowerLevel($0) ? nil : $0
        }
        return .init(city: sar, region: region)
    }
    private func taiwan() -> PhotoFramePlace {
        let parent = [administration, subdivision, locality].compactMap { $0 }.first {
            !placeholder($0) && !province($0) &&
                (cityUnit($0) || Self.ends($0, ["县", "縣"]) || PlaceType.county.matches($0))
        } ?? administration.flatMap {
            placeholder($0) || province($0) || lowerLevel($0) || namedDistrict($0) ||
                Self.taiwanNames.contains(Self.key($0)) ? nil : $0
        } ?? locality.flatMap {
            placeholder($0) || province($0) || lowerLevel($0) ||
                Self.ends($0, ["区", "區", "乡", "鄉", "镇", "鎮"]) || PlaceType.district.matches($0) ||
                Self.taiwanNames.contains(Self.key($0)) ? nil : $0
        }
        let region = [subLocality, locality, subdivision].compactMap { $0 }.first {
            !same($0, parent) && !placeholder($0) && !province($0) &&
                (Self.ends($0, ["区", "區", "乡", "鄉", "镇", "鎮", "市"]) || PlaceType.taiwanLocal.matches($0)) &&
                !neighborhoodOrZone($0)
        } ?? locality.flatMap {
            parent != nil && !same($0, parent) && !placeholder($0) && !province($0) &&
                !neighborhoodOrZone($0) && !Self.taiwanNames.contains(Self.key($0)) ? $0 : nil
        }
        return .init(city: parent, region: region)
    }
    private func mainland() -> PhotoFramePlace {
        func prefecture(_ value: String) -> Bool {
            (value.utf16.count > 1 && Self.ends(value, ["自治州", "地区", "地區", "盟"])) || PlaceType.prefecture.matches(value)
        }
        func countyOrDistrict(_ value: String) -> Bool { !prefecture(value) && namedDistrict(value) }
        let municipality = administration.flatMap { Self.municipality($0) != nil ? $0 : nil }
        let prefectureName = [subdivision, locality].compactMap { $0 }.first { prefecture($0) && !sameAdmin($0) }
        let parentCity = subdivision.flatMap { value -> String? in
            let repeatedChild = same(value, subLocality) && locality.map(cityUnit) == true && !same(value, locality)
            return cityUnit(value) && !sameAdmin(value) && !repeatedChild ? value : nil
        }
        let city = prefectureName ?? parentCity ?? locality.flatMap {
            placeholder($0) || countyOrDistrict($0) || province($0) || lowerLevel($0) ||
                (sameAdmin($0) && municipality == nil) ? nil : $0
        } ?? municipality ?? subLocality.flatMap { cityUnit($0) ? $0 : nil }
        let region = [subLocality, subdivision, locality].compactMap { $0 }.first {
            (countyOrDistrict($0) || (city != nil && cityUnit($0))) && !same($0, city) && !sameAdmin($0)
        }
        return .init(city: city, region: region)
    }
    private func international() -> PhotoFramePlace {
        let city = locality.flatMap { placeholder($0) || PlaceType.districtCounty.matches($0) ? nil : $0 }
        let region = subdivision.flatMap { placeholder($0) || same($0, city) || sameAdmin($0) ? nil : $0 }
            ?? locality.flatMap { PlaceType.districtCounty.matches($0) && !same($0, city) ? $0 : nil }
            ?? subLocality.flatMap {
                !same($0, city) && !sameAdmin($0) && !placeholder($0) && !province($0) && !lowerLevel($0) &&
                    (PlaceType.districtCounty.matches($0) || (code == nil && namedDistrict($0))) ? $0 : nil
            }
        return .init(city: city, region: region)
    }

    private static func ends(_ value: String, _ suffixes: [String]) -> Bool { suffixes.contains { value.hasSuffix($0) } }
    private static let whitespace = try! NSRegularExpression(pattern: #"[\s\p{Z}]+"#)
    private static func key(_ name: String) -> String {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return whitespace.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: " ")
            .replacingOccurrences(of: "臺", with: "台").replacingOccurrences(of: "慶", with: "庆").replacingOccurrences(of: "門", with: "门")
    }
    private static func municipality(_ name: String) -> String? { municipalities[key(name)] }
    private static func cityStem(_ name: String) -> String? {
        if name.hasSuffix("市"), name.utf16.count > 2 { return String(name.dropLast()) }
        for suffix in [" city", " shi"] where name.hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            return stem.utf16.count > 1 ? stem : nil
        }
        return nil
    }
    private static func aliases(_ groups: [[String]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.map { ($0, group[0]) } })
    }
    private static let placeholders: Set<String> = ["市辖区", "市轄區", "市辖县", "市轄縣", "县", "縣", "区", "區", "市", "旗", "盟", "自治州", "地区", "地區",
        "city", "county", "district", "province", "prefecture", "league", "banner", "municipality"]
    private static let taiwanNames: Set<String> = ["台湾", "台灣", "taiwan", "taiwan, province of china"]
    private static let specialRegions = aliases([
        ["香港", "香港特别行政区", "香港特別行政區", "hong kong", "hong kong sar", "hong kong special administrative region"],
        ["澳门", "澳门特别行政区", "澳门特別行政區", "macao", "macau", "macao sar", "macau sar", "macao special administrative region", "macau special administrative region"]])
    private static let municipalities = aliases([
        ["北京", "北京市", "beijing", "beijing city", "beijing shi"], ["上海", "上海市", "shanghai", "shanghai city", "shanghai shi"],
        ["天津", "天津市", "tianjin", "tianjin city", "tianjin shi"], ["重庆", "重庆市", "chongqing", "chongqing city", "chongqing shi"]])
}

private enum PlaceType: String, CaseIterable {
    case city = ".+\\s+City", county = ".+\\s+County", district = ".+\\s+District"
    case districtCounty = ".+\\s+(County|District)", countyDistrictBanner = ".+\\s+(County|District|Banner)"
    case prefecture = ".+\\s+(Prefecture|League)", province = ".+\\s+(Province|Autonomous Region|Special Administrative Region)"
    case neighborhood = ".+\\s+(Village|Street|Subdistrict|Community|Development Zone|Industrial Zone|Industrial Park|Science Park)"
    case township = ".+\\s+(Town|Township)", taiwanLocal = ".+\\s+(District|Township|Town|City)"
    case pinyinCity = ".+\\s+Shi", pinyinProvince = ".+\\s+(Sheng|Zizhiqu)"
    case pinyinCountyDistrict = ".+\\s+(Qu|Xian|Qi)", pinyinTownship = ".+\\s+(Zhen|Xiang)"
    private static let expressions = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, try! NSRegularExpression(pattern: "\\A(?:" + $0.rawValue + ")\\z", options: .caseInsensitive))
    })
    func matches(_ value: String) -> Bool {
        Self.expressions[self]!.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
