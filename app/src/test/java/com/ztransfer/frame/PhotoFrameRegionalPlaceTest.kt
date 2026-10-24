package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Test

/** Provider-field fixtures: never infer a missing parent from a place-name dictionary. */
class PhotoFrameRegionalPlaceTest {
    private data class Case(
        val description: String,
        val locality: String?,
        val subLocality: String?,
        val subAdmin: String?,
        val admin: String?,
        val country: String?,
        val expected: FramePlace,
    )

    private fun checkCases(vararg cases: Case) {
        cases.forEach { case ->
            assertEquals(case.description, case.expected, framePlace(
                case.locality, case.subLocality, case.subAdmin, case.admin, case.country,
            ))
        }
    }

    @Test
    fun mainlandCitiesKeepDistrictsCountiesAndExplicitCountyCities() = checkCases(
        Case("ordinary city and district", "苏州市", "吴中区", "苏州市", "江苏省", "CN",
            FramePlace("苏州市", "吴中区")),
        Case("county in locality with prefecture city in subAdmin", "桐庐县", "桐君街道", "杭州市", "浙江省", "CN",
            FramePlace("杭州市", "桐庐县")),
        Case("Kunshan is subordinate only because Suzhou is supplied", "昆山市", "玉山镇", "苏州市", "江苏省", "CN",
            FramePlace("苏州市", "昆山市")),
        Case("county city in subLocality", null, "昆山市", "苏州市", "江苏省", "CN",
            FramePlace("苏州市", "昆山市")),
        Case("prefecture in locality with county city below", "苏州市", "昆山市", null, "江苏省", "CN",
            FramePlace("苏州市", "昆山市")),
        Case("county city repeated in both subdivision fields stays below locality", "苏州市", "昆山市", "昆山市", "江苏省", "CN",
            FramePlace("苏州市", "昆山市")),
        Case("county city without its parent remains the supplied locality", "昆山市", "玉山镇", null, "江苏省", "CN",
            FramePlace("昆山市", null)),
    )

    @Test
    fun autonomousPrefecturesLeaguesAndRegionsRetainTheirChildren() = checkCases(
        Case("autonomous prefecture and county", "理塘县", null, "甘孜藏族自治州", "四川省", "CN",
            FramePlace("甘孜藏族自治州", "理塘县")),
        Case("autonomous prefecture and autonomous county", "漾濞彝族自治县", "苍山西镇", "大理白族自治州", "云南省", "CN",
            FramePlace("大理白族自治州", "漾濞彝族自治县")),
        Case("autonomous prefecture and county city", "大理市", "下关街道", "大理白族自治州", "云南省", "CN",
            FramePlace("大理白族自治州", "大理市")),
        Case("league and banner", "阿拉善左旗", null, "阿拉善盟", "内蒙古自治区", "CN",
            FramePlace("阿拉善盟", "阿拉善左旗")),
        Case("league and county city", "锡林浩特市", null, "锡林郭勒盟", "内蒙古自治区", "CN",
            FramePlace("锡林郭勒盟", "锡林浩特市")),
        Case("prefecture city and autonomous banner", "鄂温克族自治旗", null, "呼伦贝尔市", "内蒙古自治区", "CN",
            FramePlace("呼伦贝尔市", "鄂温克族自治旗")),
        Case("region and county", "噶爾縣", null, "阿里地區", "西藏自治區", "CN",
            FramePlace("阿里地區", "噶爾縣")),
        Case("region and county city", "漠河市", null, "大兴安岭地区", "黑龙江省", "CN",
            FramePlace("大兴安岭地区", "漠河市")),
        Case("English banner below league", "Alxa Left Banner", null, "Alxa League", "Inner Mongolia Autonomous Region", "CN",
            FramePlace("Alxa League", "Alxa Left Banner")),
    )

    @Test
    fun specialCountyUnitsAndProvinceDirectUnitsDoNotInventAPrefecture() = checkCases(
        Case("special district with a supplied parent", "六枝特区", null, "六盘水市", "贵州省", "CN",
            FramePlace("六盘水市", "六枝特区")),
        Case("forest district without a prefecture", "神农架林区", null, null, "湖北省", "CN",
            FramePlace(null, "神农架林区")),
        Case("province direct county city without a parent", "仙桃市", null, null, "湖北省", "CN",
            FramePlace("仙桃市", null)),
        Case("another province direct city without a parent", "济源市", null, null, "河南省", "CN",
            FramePlace("济源市", null)),
        Case("province direct autonomous county", "陵水黎族自治县", null, null, "海南省", "CN",
            FramePlace(null, "陵水黎族自治县")),
        Case("administrative grouping is not a named parent", "仙桃市", null, "省直辖县级行政区划", "湖北省", "CN",
            FramePlace("仙桃市", null)),
        Case("province alone provides neither requested level", null, null, null, "湖北省", "CN",
            FramePlace(null, null)),
    )

    @Test
    fun municipalityAliasesPreserveSuppliedSpellingAndDistrict() = checkCases(
        Case("Beijing short name", null, "海淀区", null, "北京", "CN",
            FramePlace("北京", "海淀区")),
        Case("Shanghai English alias", null, "Huangpu District", null, "Shanghai Shi", "cn",
            FramePlace("Shanghai Shi", "Huangpu District")),
        Case("Tianjin full name", null, "和平区", null, "天津市", "CN",
            FramePlace("天津市", "和平区")),
        Case("Chongqing traditional alias", null, "渝中區", null, "重慶", "CN",
            FramePlace("重慶", "渝中區")),
        Case("municipality inferred only from supplied fields when country absent", null, "黄浦区", null, "上海市", null,
            FramePlace("上海市", "黄浦区")),
        Case("municipality placeholder district is omitted", "北京市", "市辖区", null, "北京市", "CN",
            FramePlace("北京市", null)),
    )

    @Test
    fun hongKongAndMacaoUseTheirSuppliedCityAndLocalDivision() = checkCases(
        Case("Hong Kong district supplied as subLocality", null, "中西區", null, "香港", "HK",
            FramePlace("香港", "中西區")),
        Case("Hong Kong district supplied as locality", "中西區", "中環", null, "香港", "HK",
            FramePlace("香港", "中西區")),
        Case("Hong Kong repeated city with district", "香港", "中西區", "香港", "香港", "HK",
            FramePlace("香港", "中西區")),
        Case("Macao parish supplied as subLocality", null, "花地瑪堂區", null, "澳門", "MO",
            FramePlace("澳門", "花地瑪堂區")),
        Case("Macao parish supplied as locality", "大堂區", null, null, "澳門", "MO",
            FramePlace("澳門", "大堂區")),
        Case("Macao city only does not invent a parish", "澳門", null, null, "澳門", "MO",
            FramePlace("澳門", null)),
    )

    @Test
    fun taiwanCitiesAndCountiesRetainDistrictsTownshipsAndCountyCities() = checkCases(
        Case("municipality and district", "大安區", "龍坡里", null, "臺北市", "TW",
            FramePlace("臺北市", "大安區")),
        Case("city and district in separate fields", "臺北市", "大安區", null, "臺北市", "TW",
            FramePlace("臺北市", "大安區")),
        Case("county and county administered city", "竹北市", null, null, "新竹縣", "TW",
            FramePlace("新竹縣", "竹北市")),
        Case("county and township", "秀林鄉", null, null, "花蓮縣", "TW",
            FramePlace("花蓮縣", "秀林鄉")),
        Case("county and town", "羅東鎮", null, null, "宜蘭縣", "TW",
            FramePlace("宜蘭縣", "羅東鎮")),
        Case("county supplied in subAdmin below province", "羅東鎮", null, "宜蘭縣", "臺灣省", "TW",
            FramePlace("宜蘭縣", "羅東鎮")),
        Case("county city in an island county", "馬公市", null, null, "澎湖縣", "TW",
            FramePlace("澎湖縣", "馬公市")),
        Case("county only remains the top supplied administrative level", null, null, null, "新竹縣", "TW",
            FramePlace("新竹縣", null)),
        Case("Taipei character variant is not a second place", "台北市", "大安區", "臺北市", "臺北市", "TW",
            FramePlace("臺北市", "大安區")),
        Case("English city without City suffix remains a locality", "Taipei", "Da'an District", null, "Taiwan", "TW",
            FramePlace("Taipei", "Da'an District")),
        Case("territory name alone is not a city", "Taiwan", null, null, "Taiwan", "TW",
            FramePlace(null, null)),
    )

    @Test
    fun overseasKeepsStructuredFieldsWithoutPromotingNeighborhoods() = checkCases(
        Case("neighborhood is not a county", "New York", "SoHo", null, "New York", "US",
            FramePlace("New York", null)),
        Case("structured county wins over neighborhood", "San Jose", "Downtown", "Santa Clara County", "California", "US",
            FramePlace("San Jose", "Santa Clara County")),
        Case("structured subAdmin keeps a name without an English suffix", "London", "Soho", "Greater London", "England", "GB",
            FramePlace("London", "Greater London")),
        Case("overseas duplicate names compare case insensitively", " Paris ", "Montmartre", "PARIS", "Île-de-France", "FR",
            FramePlace("Paris", null)),
        Case("Japanese locality is not interpreted as a Chinese county", "新宿区", null, null, "東京都", "JP",
            FramePlace("新宿区", null)),
        Case("missing country does not turn Japanese locality into a Chinese district", "新宿区", null, null, "東京都", null,
            FramePlace("新宿区", null)),
        Case("overseas subAdmin without locality remains only a region", null, null, "Somerset", "England", "GB",
            FramePlace(null, "Somerset")),
    )

    @Test
    fun missingFieldsDuplicatesAndPlaceholdersDoNotGenerateAdministrativeNames() = checkCases(
        Case("all missing", null, null, null, null, null, FramePlace(null, null)),
        Case("all blank", " ", "\t", "\n", " ", "CN", FramePlace(null, null)),
        Case("repeated city", "苏州市", "苏州市", "苏州市", "江苏省", "CN",
            FramePlace("苏州市", null)),
        Case("repeated autonomous prefecture", "大理白族自治州", "大理白族自治州", "大理白族自治州", "云南省", "CN",
            FramePlace("大理白族自治州", null)),
        Case("generic administrative labels", "市辖区", "区", "县", "浙江省", "CN",
            FramePlace(null, null)),
        Case("trim only supplied names", " 杭州市 ", " 西湖区 ", " 杭州市 ", " 浙江省 ", "CN",
            FramePlace("杭州市", "西湖区")),
    )

    @Test
    fun streetsCommunitiesAndDevelopmentZonesCannotFillCityOrCounty() {
        listOf("幸福社区", "幸福社區", "文新街道", "经济技术开发区", "經濟技術開發區", "高新区", "工業區")
            .forEach { lowerLevel ->
                checkCases(
                    Case("$lowerLevel is not a district", "杭州市", lowerLevel, null, "浙江省", "CN",
                        FramePlace("杭州市", null)),
                    Case("$lowerLevel is not a city", lowerLevel, null, "杭州市", "浙江省", "CN",
                        FramePlace("杭州市", null)),
                    Case("$lowerLevel does not hide an explicit county", "杭州市", lowerLevel, "桐庐县", "浙江省", "CN",
                        FramePlace("杭州市", "桐庐县")),
                )
            }
    }

    @Test
    fun pinyinAdministrativeTypesAreRecognizedOnlyInAMainlandContext() = checkCases(
        Case("pinyin city and district", "Hangzhou Shi", "Xihu Qu", null, "Zhejiang Sheng", "CN",
            FramePlace("Hangzhou Shi", "Xihu Qu")),
        Case("pinyin county city retains its parent", "Kunshan Shi", "Yushan Zhen", "Suzhou Shi", "Jiangsu Sheng", "CN",
            FramePlace("Suzhou Shi", "Kunshan Shi")),
        Case("pinyin county in locality", "Tonglu Xian", null, "Hangzhou Shi", "Zhejiang Sheng", "CN",
            FramePlace("Hangzhou Shi", "Tonglu Xian")),
        Case("pinyin province is not a city", "Zhejiang Sheng", null, null, "Zhejiang Sheng", "CN",
            FramePlace(null, null)),
        Case("pinyin district words outside China retain their structured meaning", "Example Qu", null, null, "Example Province", "US",
            FramePlace("Example Qu", null)),
    )

    @Test
    fun missingCountryRetainsAnExplicitDistrictWithoutReclassifyingForeignCities() = checkCases(
        Case("no country or province but explicit district", "杭州市", "西湖区", null, null, null,
            FramePlace("杭州市", "西湖区")),
        Case("only an explicit county is supplied", null, "桐庐县", null, null, null,
            FramePlace(null, "桐庐县")),
        Case("unknown country still excludes neighborhood", "杭州市", "幸福社区", null, null, null,
            FramePlace("杭州市", null)),
        Case("unknown country still excludes industrial zone", "杭州市", "高新区", null, null, null,
            FramePlace("杭州市", null)),
        Case("Japanese locality remains a locality", "新宿区", "西新宿", null, "東京都", null,
            FramePlace("新宿区", null)),
    )

    @Test
    fun cityAliasesDoNotDuplicateOrMergeDistinctAdministrativeLevels() = checkCases(
        Case("municipality City suffix", null, "Haidian District", null, "Beijing City", "CN",
            FramePlace("Beijing City", "Haidian District")),
        Case("municipality bilingual duplicate", "Beijing City", "北京市", null, "Beijing", "CN",
            FramePlace("Beijing City", null)),
        Case("municipality Chinese spelling wins when supplied", "重庆市", "Chongqing Shi", null, "重慶", "CN",
            FramePlace("重庆市", null)),
        Case("province and namesake city must remain distinct", "吉林市", "丰满区", null, "吉林省", "CN",
            FramePlace("吉林市", "丰满区")),
        Case("bare province name cannot erase a same-named city", "吉林市", "船营区", null, "吉林", "CN",
            FramePlace("吉林市", "船营区")),
        Case("bare English province cannot erase a same-named city", "Jilin City", "Chuanying District", null, "Jilin", "CN",
            FramePlace("Jilin City", "Chuanying District")),
        Case("city abbreviation is not a second city", "苏州", "苏州市", null, "江苏省", "CN",
            FramePlace("苏州", null)),
        Case("width and whitespace variations do not duplicate city", "Hangzhou City", "Ｈａｎｇｚｈｏｕ　Ｃｉｔｙ", null, "Zhejiang", "CN",
            FramePlace("Hangzhou City", null)),
        Case("city and autonomous prefecture remain separate", "大理市", null, "大理白族自治州", "云南省", "CN",
            FramePlace("大理白族自治州", "大理市")),
    )

    @Test
    fun englishAdministrativeLabelsAreNotNames() = checkCases(
        Case("bare labels", "City", "District", "County", "Province", "CN",
            FramePlace(null, null)),
        Case("labels with different case", "CITY", "DISTRICT", "Prefecture", "Province", "CN",
            FramePlace(null, null)),
        Case("legitimate short city name is retained", "Xi", null, null, "Example Province", "CN",
            FramePlace("Xi", null)),
    )
}
