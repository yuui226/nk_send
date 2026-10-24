package com.ztransfer.location

import java.text.Normalizer
import java.util.Locale

/**
 * Pure address-to-display mapping, shared by every photo entry point.
 *
 * Add a region-specific mapper only for an evidenced difference in administrative levels.
 * Unknown countries use the provider's structured locality/subAdminArea; never send them
 * through Chinese suffix rules. Keep source spelling and missing levels unchanged.
 * New rules belong here with provider-field fixtures, not in preview/export/EXIF code.
 */
internal object PlaceAddressMapper {
    fun resolve(address: PlaceAddress): PlaceNames = AddressMapping(address).resolve()
}

/** Request-local context: comparison rules cannot leak between countries or requests. */
private class AddressMapping(address: PlaceAddress) {
    private fun String?.clean() = this?.trim()?.takeIf(String::isNotEmpty)
    private val locality = address.locality.clean()
    private val subLocality = address.subLocality.clean()
    private val subdivision = address.subAdminArea.clean()
    private val administration = address.adminArea.clean()
    private val code = address.countryCode?.trim()?.uppercase(Locale.ROOT)
    private val names = listOfNotNull(locality, subLocality, subdivision, administration)
    private val chineseHierarchy = code == "CN" || (code.isNullOrEmpty() &&
        (administration?.let { it.endsWithAny("省", "自治区", "自治區") || municipalityKey(it) != null } == true ||
            names.any { it.endsWithAny("自治州", "盟", "自治县", "自治縣", "自治旗") }))
    // Compare only known character variants; retain the provider's spelling for display.
    private fun same(a: String?, b: String?, allowCityAbbreviation: Boolean = true): Boolean {
        if (a == null || b == null) return false
        val left = placeComparisonKey(a)
        val right = placeComparisonKey(b)
        if (left == right) return true
        val specialRegion = SPECIAL_REGION_ALIASES[left]
        if (specialRegion != null && specialRegion == SPECIAL_REGION_ALIASES[right]) return true
        if (!chineseHierarchy && code != "TW") return false
        val municipality = if (chineseHierarchy) municipalityKey(a) else null
        if (municipality != null && municipality == municipalityKey(b)) return true
        // Match a supplied abbreviation to a city name, never two different typed levels
        // (e.g. 吉林市 and 吉林省). Do not apply this to Hong Kong's "Kowloon City" district.
        return allowCityAbbreviation && (chineseCityStem(left) == right || chineseCityStem(right) == left)
    }
    // A province may use the same bare name as a city (吉林 / 吉林市). City abbreviations
    // cannot establish equivalence across those levels; explicit municipality aliases can.
    private fun sameAdmin(value: String) = same(value, administration, allowCityAbbreviation = false)
    private fun placeholder(value: String): Boolean = placeComparisonKey(value) in ADMINISTRATIVE_PLACEHOLDERS ||
        value.endsWithAny("直辖县级行政区划", "直轄縣級行政區劃")
    private fun province(value: String): Boolean = value.endsWithAny("省", "自治区", "自治區", "特别行政区", "特別行政區") ||
        ENGLISH_PROVINCE.matches(value) || (chineseHierarchy && PINYIN_PROVINCE.matches(value))
    private fun neighborhoodOrZone(value: String): Boolean = value.endsWithAny(
        "社区", "社區", "街道", "街道办事处", "街道辦事處", "村", "苏木", "蘇木",
        "开发区", "開發區", "高新区", "高新區", "工业区", "工業區", "园区", "園區",
    ) || ENGLISH_NEIGHBORHOOD_OR_ZONE.matches(value) || (code == "TW" && value.endsWith("里"))
    private fun lowerLevel(value: String): Boolean = neighborhoodOrZone(value) ||
        value.endsWithAny("镇", "鎮", "乡", "鄉") || ENGLISH_TOWNSHIP.matches(value) ||
        (chineseHierarchy && PINYIN_TOWNSHIP.matches(value))
    private fun cityUnit(value: String): Boolean = !placeholder(value) &&
        (value.endsWith("市") || ENGLISH_CITY.matches(value) || (chineseHierarchy && PINYIN_CITY.matches(value)))
    private fun namedDistrict(value: String): Boolean = !placeholder(value) && !province(value) &&
        !lowerLevel(value) && (value.endsWithAny("区", "區", "县", "縣", "旗") ||
            ENGLISH_COUNTY_OR_DISTRICT.matches(value) || (chineseHierarchy && PINYIN_COUNTY_OR_DISTRICT.matches(value)))
    fun resolve(): PlaceNames {
        // Hong Kong/Macao have districts/parishes, not the mainland prefecture/county hierarchy.
        // Select only a supplied territory name; do not invent one from a neighborhood or street.
        val sar = if (code in setOf(null, "", "CN", "HK", "MO")) {
            sequenceOf(administration, locality, subdivision).filterNotNull().firstOrNull {
                placeComparisonKey(it) in SPECIAL_REGION_ALIASES
            }
        } else null
        return when {
            code == "HK" || code == "MO" || sar != null -> hongKongOrMacao(sar)
            code == "TW" -> taiwan()
            chineseHierarchy -> mainland()
            else -> international()
        }
    }

    private fun hongKongOrMacao(sar: String?): PlaceNames {
        val region = sequenceOf(subLocality, subdivision, locality).filterNotNull().firstOrNull {
            !same(it, sar) && !placeholder(it) && !province(it) && !lowerLevel(it) &&
                (it.endsWithAny("区", "區") || ENGLISH_DISTRICT.matches(it) ||
                    it.endsWith(" Parish", ignoreCase = true) || it.startsWith("Freguesia ", ignoreCase = true))
        } ?: subdivision?.takeUnless {
            // Structured second-level names need not contain "District" or "Parish".
            same(it, sar) || placeholder(it) || province(it) || lowerLevel(it)
        }
        return PlaceNames(sar, region)
    }

    private fun taiwan(): PlaceNames {
        // A Taiwan county is the parent of its townships/county-administered cities.
        val parent = sequenceOf(administration, subdivision, locality).filterNotNull().firstOrNull {
            !placeholder(it) && !province(it) &&
                (cityUnit(it) || it.endsWithAny("县", "縣") || ENGLISH_COUNTY.matches(it))
        } ?: administration?.takeUnless {
            placeholder(it) || province(it) || lowerLevel(it) || namedDistrict(it) ||
                placeComparisonKey(it) in TAIWAN_TERRITORY_NAMES
        } ?: locality?.takeUnless {
            // English providers may return "Taipei" without a "City" suffix.
            // Retain that structured locality, but never promote a country or local district.
            placeholder(it) || province(it) || lowerLevel(it) ||
                it.endsWithAny("区", "區", "乡", "鄉", "镇", "鎮") || ENGLISH_DISTRICT.matches(it) ||
                placeComparisonKey(it) in TAIWAN_TERRITORY_NAMES
        }
        val region = sequenceOf(subLocality, locality, subdivision).filterNotNull().firstOrNull {
            !same(it, parent) && !placeholder(it) && !province(it) &&
                (it.endsWithAny("区", "區", "乡", "鄉", "镇", "鎮", "市") ||
                    ENGLISH_TAIWAN_LOCAL.matches(it)) &&
                !neighborhoodOrZone(it)
        } ?: locality?.takeIf {
            // Keep a supplied local city/town such as "Zhubei" below an explicit parent.
            parent != null && !same(it, parent) && !placeholder(it) && !province(it) &&
                !neighborhoodOrZone(it) && placeComparisonKey(it) !in TAIWAN_TERRITORY_NAMES
        }
        return PlaceNames(parent, region)
    }

    private fun mainland(): PlaceNames {
        fun isPrefecture(value: String): Boolean =
            (value.length > 1 && value.endsWithAny("自治州", "地区", "地區", "盟")) ||
                ENGLISH_PREFECTURE.matches(value)
        fun isCountyOrDistrict(value: String) = !isPrefecture(value) && namedDistrict(value)
        val municipality = administration?.takeIf { municipalityKey(it) != null }
        val prefecture = sequenceOf(subdivision, locality).filterNotNull().firstOrNull {
            isPrefecture(it) && !sameAdmin(it)
        }
        val parentCity = subdivision?.takeIf {
            // A repeated lower city must not displace its separately supplied parent locality.
            val repeatedChild = same(it, subLocality) && locality?.let(::cityUnit) == true &&
                !same(it, locality)
            cityUnit(it) && !sameAdmin(it) && !repeatedChild
        }
        val city = prefecture ?: parentCity ?: locality?.takeUnless {
            placeholder(it) || isCountyOrDistrict(it) || province(it) || lowerLevel(it) ||
                (sameAdmin(it) && municipality == null)
        } ?: municipality ?: subLocality?.takeIf(::cityUnit)
        val region = sequenceOf(subLocality, subdivision, locality).filterNotNull().firstOrNull {
            val countyCity = city != null && cityUnit(it)
            (isCountyOrDistrict(it) || countyCity) && !same(it, city) && !sameAdmin(it)
        }
        return PlaceNames(city, region)
    }

    private fun international(): PlaceNames {
        val city = locality?.takeUnless { placeholder(it) || ENGLISH_DISTRICT_OR_COUNTY.matches(it) }
        // The structured second-level field takes precedence over a neighborhood. A missing
        // country may still supply an explicit district, without changing its city's meaning.
        val region = subdivision?.takeUnless { placeholder(it) || same(it, city) || sameAdmin(it) }
            ?: locality?.takeIf { ENGLISH_DISTRICT_OR_COUNTY.matches(it) && !same(it, city) }
            ?: subLocality?.takeIf {
                !same(it, city) && !sameAdmin(it) && !placeholder(it) && !province(it) && !lowerLevel(it) &&
                    (ENGLISH_DISTRICT_OR_COUNTY.matches(it) || (code.isNullOrEmpty() && namedDistrict(it)))
            }
        return PlaceNames(city, region)
    }
}

private fun String.endsWithAny(vararg suffixes: String): Boolean = suffixes.any { endsWith(it) }

private fun placeComparisonKey(name: String): String =
    Normalizer.normalize(name, Normalizer.Form.NFKC).trim().lowercase(Locale.ROOT)
        .replace(PLACE_WHITESPACE, " ").replace('臺', '台').replace('慶', '庆').replace('門', '门')

private fun municipalityKey(name: String): String? = MUNICIPALITY_ALIASES[placeComparisonKey(name)]

/** Only remove a type when comparing it to a separately supplied untyped city name. */
private fun chineseCityStem(key: String): String? = when {
    key.endsWith("市") && key.length > 2 -> key.dropLast(1)
    key.endsWith(" city") -> key.removeSuffix(" city").takeIf { it.length > 1 }
    key.endsWith(" shi") -> key.removeSuffix(" shi").takeIf { it.length > 1 }
    else -> null
}

private val PLACE_WHITESPACE = Regex("[\\s\\p{Z}]+")
private val ENGLISH_CITY = Regex(".+\\s+City", RegexOption.IGNORE_CASE)
private val ENGLISH_COUNTY = Regex(".+\\s+County", RegexOption.IGNORE_CASE)
private val ENGLISH_DISTRICT = Regex(".+\\s+District", RegexOption.IGNORE_CASE)
private val ENGLISH_DISTRICT_OR_COUNTY = Regex(".+\\s+(County|District)", RegexOption.IGNORE_CASE)
private val ENGLISH_COUNTY_OR_DISTRICT = Regex(".+\\s+(County|District|Banner)", RegexOption.IGNORE_CASE)
private val ENGLISH_PREFECTURE = Regex(".+\\s+(Prefecture|League)", RegexOption.IGNORE_CASE)
private val ENGLISH_PROVINCE = Regex(".+\\s+(Province|Autonomous Region|Special Administrative Region)", RegexOption.IGNORE_CASE)
private val ENGLISH_NEIGHBORHOOD_OR_ZONE = Regex(".+\\s+(Village|Street|Subdistrict|Community|Development Zone|Industrial Zone|Industrial Park|Science Park)", RegexOption.IGNORE_CASE)
private val ENGLISH_TOWNSHIP = Regex(".+\\s+(Town|Township)", RegexOption.IGNORE_CASE)
private val ENGLISH_TAIWAN_LOCAL = Regex(".+\\s+(District|Township|Town|City)", RegexOption.IGNORE_CASE)
private val PINYIN_CITY = Regex(".+\\s+Shi", RegexOption.IGNORE_CASE)
private val PINYIN_PROVINCE = Regex(".+\\s+(Sheng|Zizhiqu)", RegexOption.IGNORE_CASE)
private val PINYIN_COUNTY_OR_DISTRICT = Regex(".+\\s+(Qu|Xian|Qi)", RegexOption.IGNORE_CASE)
private val PINYIN_TOWNSHIP = Regex(".+\\s+(Zhen|Xiang)", RegexOption.IGNORE_CASE)
private val ADMINISTRATIVE_PLACEHOLDERS = setOf(
    "市辖区", "市轄區", "市辖县", "市轄縣", "县", "縣", "区", "區", "市", "旗", "盟", "自治州", "地区", "地區",
    "city", "county", "district", "province", "prefecture", "league", "banner", "municipality",
)
private val SPECIAL_REGION_ALIASES = listOf(
    listOf("香港", "香港特别行政区", "香港特別行政區", "hong kong", "hong kong sar", "hong kong special administrative region"),
    listOf("澳门", "澳门特别行政区", "澳门特別行政區", "macao", "macau", "macao sar", "macau sar",
        "macao special administrative region", "macau special administrative region"),
).flatMap { aliases -> aliases.map { it to aliases.first() } }.toMap()
private val TAIWAN_TERRITORY_NAMES = setOf("台湾", "台灣", "taiwan", "taiwan, province of china")

private val MUNICIPALITY_ALIASES = listOf(
    listOf("北京", "北京市", "beijing", "beijing city", "beijing shi"),
    listOf("上海", "上海市", "shanghai", "shanghai city", "shanghai shi"),
    listOf("天津", "天津市", "tianjin", "tianjin city", "tianjin shi"),
    listOf("重庆", "重庆市", "chongqing", "chongqing city", "chongqing shi"),
).flatMap { aliases -> aliases.map { it to aliases.first() } }.toMap()
