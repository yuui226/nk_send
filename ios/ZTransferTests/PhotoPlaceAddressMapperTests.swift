import XCTest
@testable import ZTransfer

final class PhotoPlaceAddressMapperTests: XCTestCase {
    func testForeignNamesNeverUseMainlandRulesAndLowerLevelsDoNotBecomeAdministrativeNames() {
        for country in ["BR", "JP", "KR", "DE", "EG", "TH", "ZZ"] {
            for city in ["São Paulo", "東京", "서울", "München", "القاهرة", "กรุงเทพมหานคร"] {
                XCTAssertEqual(photoFramePlace(city: city, district: "neighborhood", subAdmin: "administrative area", admin: "parent", countryCode: country),
                               .init(city: city, region: "administrative area"))
            }
        }
        for lower in ["幸福社区", "幸福社區", "文新街道", "经济技术开发区", "經濟技術開發區", "高新区", "工業區"] {
            XCTAssertEqual(photoFramePlace(city: "杭州市", district: lower, subAdmin: nil, admin: "浙江省", countryCode: "CN"), .init(city: "杭州市", region: nil))
            XCTAssertEqual(photoFramePlace(city: lower, district: nil, subAdmin: "杭州市", admin: "浙江省", countryCode: "CN"), .init(city: "杭州市", region: nil))
            XCTAssertEqual(photoFramePlace(city: "杭州市", district: lower, subAdmin: "桐庐县", admin: "浙江省", countryCode: "CN"), .init(city: "杭州市", region: "桐庐县"))
        }
    }

    func testDeterministicMappingOnlyReturnsSuppliedSpellingAcrossCountries() {
        let values: [String?] = [nil, "", "  ", " 北京市 ", "Beijing", "吉林", "吉林市", "大理白族自治州", "大理市", "区", "西湖区", "港区",
            "Santa Clara County", "Taipei", "Taipei City", "香港", "Hong Kong", "昆山市", "苏州市", "中央里", "幸福社区", "City", "new locality"]
        let countries: [String?] = [nil, "", "CN", "cn", "HK", "MO", "TW", "US", "JP", "ZZ"]
        var seed: UInt64 = 20261025
        func next(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 32) % count }
        for _ in 0..<1_000 {
            let supplied = (0..<4).map { _ in values[next(values.count)] }, country = countries[next(countries.count)]
            let mapper = PhotoPlaceAddressMapper(city: supplied[0], district: supplied[1], subAdmin: supplied[2], admin: supplied[3], countryCode: country)
            let result = mapper.resolve()
            let names = supplied.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for name in [result.city, result.region].compactMap({ $0 }) { XCTAssertTrue(names.contains(name)) }
            XCTAssertEqual(result, mapper.resolve())
        }
    }
    // Literal expected results copied from the three Android provider-field
    // suites at 431132ca; no iOS output was used to derive these expectations.
    func testAndroidRegionalInternationalAndOriginalProviderFixtures() {
        let cases: [(String, [String?])] = [
            ("ordinary city and district", ["苏州市", "吴中区", "苏州市", "江苏省", "CN", "苏州市", "吴中区"]),
            ("county in locality with prefecture city in subAdmin", ["桐庐县", "桐君街道", "杭州市", "浙江省", "CN", "杭州市", "桐庐县"]),
            ("Kunshan is subordinate only because Suzhou is supplied", ["昆山市", "玉山镇", "苏州市", "江苏省", "CN", "苏州市", "昆山市"]),
            ("county city in subLocality", [nil, "昆山市", "苏州市", "江苏省", "CN", "苏州市", "昆山市"]),
            ("prefecture in locality with county city below", ["苏州市", "昆山市", nil, "江苏省", "CN", "苏州市", "昆山市"]),
            ("county city repeated in both subdivision fields stays below locality", ["苏州市", "昆山市", "昆山市", "江苏省", "CN", "苏州市", "昆山市"]),
            ("county city without its parent remains the supplied locality", ["昆山市", "玉山镇", nil, "江苏省", "CN", "昆山市", nil]),
            ("autonomous prefecture and county", ["理塘县", nil, "甘孜藏族自治州", "四川省", "CN", "甘孜藏族自治州", "理塘县"]),
            ("autonomous prefecture and autonomous county", ["漾濞彝族自治县", "苍山西镇", "大理白族自治州", "云南省", "CN", "大理白族自治州", "漾濞彝族自治县"]),
            ("autonomous prefecture and county city", ["大理市", "下关街道", "大理白族自治州", "云南省", "CN", "大理白族自治州", "大理市"]),
            ("league and banner", ["阿拉善左旗", nil, "阿拉善盟", "内蒙古自治区", "CN", "阿拉善盟", "阿拉善左旗"]),
            ("league and county city", ["锡林浩特市", nil, "锡林郭勒盟", "内蒙古自治区", "CN", "锡林郭勒盟", "锡林浩特市"]),
            ("prefecture city and autonomous banner", ["鄂温克族自治旗", nil, "呼伦贝尔市", "内蒙古自治区", "CN", "呼伦贝尔市", "鄂温克族自治旗"]),
            ("region and county", ["噶爾縣", nil, "阿里地區", "西藏自治區", "CN", "阿里地區", "噶爾縣"]),
            ("region and county city", ["漠河市", nil, "大兴安岭地区", "黑龙江省", "CN", "大兴安岭地区", "漠河市"]),
            ("English banner below league", ["Alxa Left Banner", nil, "Alxa League", "Inner Mongolia Autonomous Region", "CN", "Alxa League", "Alxa Left Banner"]),
            ("special district with a supplied parent", ["六枝特区", nil, "六盘水市", "贵州省", "CN", "六盘水市", "六枝特区"]),
            ("forest district without a prefecture", ["神农架林区", nil, nil, "湖北省", "CN", nil, "神农架林区"]),
            ("province direct county city without a parent", ["仙桃市", nil, nil, "湖北省", "CN", "仙桃市", nil]),
            ("another province direct city without a parent", ["济源市", nil, nil, "河南省", "CN", "济源市", nil]),
            ("province direct autonomous county", ["陵水黎族自治县", nil, nil, "海南省", "CN", nil, "陵水黎族自治县"]),
            ("administrative grouping is not a named parent", ["仙桃市", nil, "省直辖县级行政区划", "湖北省", "CN", "仙桃市", nil]),
            ("province alone provides neither requested level", [nil, nil, nil, "湖北省", "CN", nil, nil]),
            ("Beijing short name", [nil, "海淀区", nil, "北京", "CN", "北京", "海淀区"]),
            ("Shanghai English alias", [nil, "Huangpu District", nil, "Shanghai Shi", "cn", "Shanghai Shi", "Huangpu District"]),
            ("Tianjin full name", [nil, "和平区", nil, "天津市", "CN", "天津市", "和平区"]),
            ("Chongqing traditional alias", [nil, "渝中區", nil, "重慶", "CN", "重慶", "渝中區"]),
            ("municipality inferred only from supplied fields when country absent", [nil, "黄浦区", nil, "上海市", nil, "上海市", "黄浦区"]),
            ("municipality placeholder district is omitted", ["北京市", "市辖区", nil, "北京市", "CN", "北京市", nil]),
            ("Hong Kong district supplied as subLocality", [nil, "中西區", nil, "香港", "HK", "香港", "中西區"]),
            ("Hong Kong district supplied as locality", ["中西區", "中環", nil, "香港", "HK", "香港", "中西區"]),
            ("Hong Kong repeated city with district", ["香港", "中西區", "香港", "香港", "HK", "香港", "中西區"]),
            ("Macao parish supplied as subLocality", [nil, "花地瑪堂區", nil, "澳門", "MO", "澳門", "花地瑪堂區"]),
            ("Macao parish supplied as locality", ["大堂區", nil, nil, "澳門", "MO", "澳門", "大堂區"]),
            ("Macao city only does not invent a parish", ["澳門", nil, nil, "澳門", "MO", "澳門", nil]),
            ("municipality and district", ["大安區", "龍坡里", nil, "臺北市", "TW", "臺北市", "大安區"]),
            ("city and district in separate fields", ["臺北市", "大安區", nil, "臺北市", "TW", "臺北市", "大安區"]),
            ("county and county administered city", ["竹北市", nil, nil, "新竹縣", "TW", "新竹縣", "竹北市"]),
            ("county and township", ["秀林鄉", nil, nil, "花蓮縣", "TW", "花蓮縣", "秀林鄉"]),
            ("county and town", ["羅東鎮", nil, nil, "宜蘭縣", "TW", "宜蘭縣", "羅東鎮"]),
            ("county supplied in subAdmin below province", ["羅東鎮", nil, "宜蘭縣", "臺灣省", "TW", "宜蘭縣", "羅東鎮"]),
            ("county city in an island county", ["馬公市", nil, nil, "澎湖縣", "TW", "澎湖縣", "馬公市"]),
            ("county only remains the top supplied administrative level", [nil, nil, nil, "新竹縣", "TW", "新竹縣", nil]),
            ("Taipei character variant is not a second place", ["台北市", "大安區", "臺北市", "臺北市", "TW", "臺北市", "大安區"]),
            ("English city without City suffix remains a locality", ["Taipei", "Da'an District", nil, "Taiwan", "TW", "Taipei", "Da'an District"]),
            ("territory name alone is not a city", ["Taiwan", nil, nil, "Taiwan", "TW", nil, nil]),
            ("neighborhood is not a county", ["New York", "SoHo", nil, "New York", "US", "New York", nil]),
            ("structured county wins over neighborhood", ["San Jose", "Downtown", "Santa Clara County", "California", "US", "San Jose", "Santa Clara County"]),
            ("structured subAdmin keeps a name without an English suffix", ["London", "Soho", "Greater London", "England", "GB", "London", "Greater London"]),
            ("overseas duplicate names compare case insensitively", [" Paris ", "Montmartre", "PARIS", "Île-de-France", "FR", "Paris", nil]),
            ("Japanese locality is not interpreted as a Chinese county", ["新宿区", nil, nil, "東京都", "JP", "新宿区", nil]),
            ("missing country does not turn Japanese locality into a Chinese district", ["新宿区", nil, nil, "東京都", nil, "新宿区", nil]),
            ("overseas subAdmin without locality remains only a region", [nil, nil, "Somerset", "England", "GB", nil, "Somerset"]),
            ("all missing", [nil, nil, nil, nil, nil, nil, nil]),
            ("all blank", [" ", "\t", "\n", " ", "CN", nil, nil]),
            ("repeated city", ["苏州市", "苏州市", "苏州市", "江苏省", "CN", "苏州市", nil]),
            ("repeated autonomous prefecture", ["大理白族自治州", "大理白族自治州", "大理白族自治州", "云南省", "CN", "大理白族自治州", nil]),
            ("generic administrative labels", ["市辖区", "区", "县", "浙江省", "CN", nil, nil]),
            ("trim only supplied names", [" 杭州市 ", " 西湖区 ", " 杭州市 ", " 浙江省 ", "CN", "杭州市", "西湖区"]),
            ("pinyin city and district", ["Hangzhou Shi", "Xihu Qu", nil, "Zhejiang Sheng", "CN", "Hangzhou Shi", "Xihu Qu"]),
            ("pinyin county city retains its parent", ["Kunshan Shi", "Yushan Zhen", "Suzhou Shi", "Jiangsu Sheng", "CN", "Suzhou Shi", "Kunshan Shi"]),
            ("pinyin county in locality", ["Tonglu Xian", nil, "Hangzhou Shi", "Zhejiang Sheng", "CN", "Hangzhou Shi", "Tonglu Xian"]),
            ("pinyin province is not a city", ["Zhejiang Sheng", nil, nil, "Zhejiang Sheng", "CN", nil, nil]),
            ("pinyin district words outside China retain their structured meaning", ["Example Qu", nil, nil, "Example Province", "US", "Example Qu", nil]),
            ("no country or province but explicit district", ["杭州市", "西湖区", nil, nil, nil, "杭州市", "西湖区"]),
            ("only an explicit county is supplied", [nil, "桐庐县", nil, nil, nil, nil, "桐庐县"]),
            ("unknown country still excludes neighborhood", ["杭州市", "幸福社区", nil, nil, nil, "杭州市", nil]),
            ("unknown country still excludes industrial zone", ["杭州市", "高新区", nil, nil, nil, "杭州市", nil]),
            ("Japanese locality remains a locality", ["新宿区", "西新宿", nil, "東京都", nil, "新宿区", nil]),
            ("municipality City suffix", [nil, "Haidian District", nil, "Beijing City", "CN", "Beijing City", "Haidian District"]),
            ("municipality bilingual duplicate", ["Beijing City", "北京市", nil, "Beijing", "CN", "Beijing City", nil]),
            ("municipality Chinese spelling wins when supplied", ["重庆市", "Chongqing Shi", nil, "重慶", "CN", "重庆市", nil]),
            ("province and namesake city must remain distinct", ["吉林市", "丰满区", nil, "吉林省", "CN", "吉林市", "丰满区"]),
            ("bare province name cannot erase a same-named city", ["吉林市", "船营区", nil, "吉林", "CN", "吉林市", "船营区"]),
            ("bare English province cannot erase a same-named city", ["Jilin City", "Chuanying District", nil, "Jilin", "CN", "Jilin City", "Chuanying District"]),
            ("city abbreviation is not a second city", ["苏州", "苏州市", nil, "江苏省", "CN", "苏州", nil]),
            ("width and whitespace variations do not duplicate city", ["Hangzhou City", "Ｈａｎｇｚｈｏｕ　Ｃｉｔｙ", nil, "Zhejiang", "CN", "Hangzhou City", nil]),
            ("city and autonomous prefecture remain separate", ["大理市", nil, "大理白族自治州", "云南省", "CN", "大理白族自治州", "大理市"]),
            ("bare labels", ["City", "District", "County", "Province", "CN", nil, nil]),
            ("labels with different case", ["CITY", "DISTRICT", "Prefecture", "Province", "CN", nil, nil]),
            ("legitimate short city name is retained", ["Xi", nil, nil, "Example Province", "CN", "Xi", nil]),
            ("Hong Kong subAdmin does not require a District suffix", [nil, "Central", "Central and Western", "Hong Kong", "HK", "Hong Kong", "Central and Western"]),
            ("Macao subAdmin does not require a Parish suffix", [nil, nil, "Nossa Senhora de Fátima", "Macau", "MO", "Macau", "Nossa Senhora de Fátima"]),
            ("Chinese Hong Kong repeats the English territory", [nil, nil, "香港", "Hong Kong", "HK", "Hong Kong", nil]),
            ("English Macau repeats the Chinese territory", [nil, nil, "Macau", "澳門", "MO", "澳門", nil]),
            ("bare admin supplies a parent when locality is absent", [nil, "Da'an District", nil, "Taipei", "TW", "Taipei", "Da'an District"]),
            ("bare locality remains a city when no parent is supplied", ["Taipei", nil, nil, nil, "TW", "Taipei", nil]),
            ("bare county-administered city retains its explicit county", ["Zhubei", nil, "Hsinchu County", "Taiwan", "TW", "Hsinchu County", "Zhubei"]),
            ("bare town retains its explicit county", ["Luodong", nil, "Yilan County", "Taiwan", "TW", "Yilan County", "Luodong"]),
            ("repeated city fields do not replace the actual district", ["Taipei", "Da'an District", "TAIPEI", "Taipei", "TW", "Taipei", "Da'an District"]),
            ("a science park is not a district despite ending in 區", ["臺中市", "中部科學園區", nil, "臺中市", "TW", "臺中市", nil]),
            ("a community is not a district despite ending in 區", ["臺北市", "幸福社區", nil, "臺北市", "TW", "臺北市", nil]),
            ("an English science park is not a local city or town", ["Central Taiwan Science Park", nil, nil, "Taichung City", "TW", "Taichung City", nil]),
            ("explicit District can fill an absent subAdmin", ["Example City", "Example District", nil, "Example State", "US", "Example City", "Example District"]),
            ("SoHo is not promoted from neighborhood to county or district", ["New York", "SoHo", nil, "New York", "US", "New York", nil]),
            ("supplied administrative county takes precedence over subLocality", ["San Jose", "Downtown District", "Santa Clara County", "California", "US", "San Jose", "Santa Clara County"]),
            ("case and surrounding whitespace do not duplicate a city as its region", [" Paris ", "Montmartre", "PARIS", "Île-de-France", "FR", "Paris", nil]),
            ("all fields missing", [nil, nil, nil, nil, nil, nil, nil]),
            ("all fields blank even with a known regional format", [" ", "\t", "\n", "  ", "TW", nil, nil]),
            ("PhotoFramePlaceTest line 92", [nil, "黄浦区", nil, "上海市", nil, "上海市", "黄浦区"]),
            ("PhotoFramePlaceTest line 93", ["Paris", nil, "Paris", "Île-de-France", nil, "Paris", nil]),
            ("PhotoFramePlaceTest line 94", ["杭州市", "西湖区", "杭州市", "浙江省", nil, "杭州市", "西湖区"]),
            ("PhotoFramePlaceTest line 98", [nil, nil, "桐庐县", "浙江省", "CN", nil, "桐庐县"]),
            ("PhotoFramePlaceTest line 99", ["桐庐县", nil, nil, "浙江省", "CN", nil, "桐庐县"]),
            ("PhotoFramePlaceTest line 100", ["浙江省", nil, nil, "浙江省", "CN", nil, nil]),
            ("PhotoFramePlaceTest line 101", [nil, "广西壮族自治区", nil, "广西壮族自治区", "CN", nil, nil]),
            ("PhotoFramePlaceTest line 102", [nil, nil, "Santa Clara County", "California", "US", nil, "Santa Clara County"]),
            ("PhotoFramePlaceTest line 103", ["Santa Clara County", nil, nil, "California", "US", nil, "Santa Clara County"]),
            ("PhotoFramePlaceTest line 107", ["大理市", "下关街道", "大理白族自治州", "云南省", "CN", "大理白族自治州", "大理市"]),
            ("PhotoFramePlaceTest line 109", [nil, "大理市", "大理白族自治州", "云南省", "CN", "大理白族自治州", "大理市"]),
            ("PhotoFramePlaceTest line 111", [nil, nil, "大理白族自治州", "云南省", "CN", "大理白族自治州", nil]),
            ("PhotoFramePlaceTest line 113", ["漾濞彝族自治县", nil, "大理白族自治州", "云南省", "CN", "大理白族自治州", "漾濞彝族自治县"]),
            ("PhotoFramePlaceTest line 115", ["大理白族自治州", "大理市", nil, "云南省", "CN", "大理白族自治州", "大理市"]),
            ("PhotoFramePlaceTest line 117", ["大理白族自治州", "大理白族自治州", nil, "云南省", "CN", "大理白族自治州", nil]),
            ("PhotoFramePlaceTest line 119", ["大理市", nil, "大理白族自治州", "雲南省", "CN", "大理白族自治州", "大理市"]),
            ("PhotoFramePlaceTest line 124", ["漠河市", nil, "大兴安岭地区", "黑龙江省", "CN", "大兴安岭地区", "漠河市"]),
            ("PhotoFramePlaceTest line 126", ["噶爾縣", nil, "阿里地區", "西藏自治區", "CN", "阿里地區", "噶爾縣"]),
            ("PhotoFramePlaceTest line 128", ["锡林浩特市", nil, "锡林郭勒盟", "内蒙古自治区", "CN", "锡林郭勒盟", "锡林浩特市"]),
            ("PhotoFramePlaceTest line 130", ["Dali City", nil, "Dali Bai Autonomous Prefecture", "Yunnan", "CN", "Dali Bai Autonomous Prefecture", "Dali City"]),
            ("PhotoFramePlaceTest line 133", [nil, nil, "Example Prefecture", "Example State", "US", nil, "Example Prefecture"]),
            ("PhotoFramePlaceTest line 135", ["贵州", nil, nil, "贵州", "CN", nil, nil]),
            ("PhotoFramePlaceTest line 136", ["杭州市", nil, "杭州", "浙江省", "CN", "杭州市", nil]),
            ("PhotoFramePlaceTest line 140", ["杭州市", "幸福社区", nil, "浙江省", "CN", "杭州市", nil]),
            ("PhotoFramePlaceTest line 141", ["杭州市", "幸福社区", "西湖区", "浙江省", "CN", "杭州市", "西湖区"]),
            ("PhotoFramePlaceTest line 142", ["杭州市", "高新区", nil, "浙江省", "CN", "杭州市", nil]),
            ("PhotoFramePlaceTest line 143", ["幸福社区", nil, "杭州市", "浙江省", "CN", "杭州市", nil]),
            ("PhotoFramePlaceTest line 144", ["New York", "SoHo", nil, "New York", "US", "New York", nil]),
            ("PhotoFramePlaceTest line 145", ["San Jose", "Downtown", "Santa Clara County", "California", "US", "San Jose", "Santa Clara County"]),
            ("PhotoFramePlaceTest line 149", [nil, "渝中區", nil, "重慶市", "CN", "重慶市", "渝中區"]),
            ("PhotoFramePlaceTest line 150", [nil, "Haidian District", nil, "Beijing", "CN", "Beijing", "Haidian District"]),
            ("PhotoFramePlaceTest line 151", [nil, "市辖区", nil, "上海市", "CN", "上海市", nil]),
            ("PhotoFramePlaceTest line 152", [" Paris ", "Montmartre", "PARIS", "Île-de-France", "FR", "Paris", nil]),
            ("PhotoFramePlaceTest line 153", [" ", nil, nil, "California", "US", nil, nil]),
            ("PhotoFramePlaceTest line 154", ["新宿区", nil, nil, "東京都", "JP", "新宿区", nil]),
        ]
        for (label, c) in cases {
            XCTAssertEqual(photoFramePlace(city: c[0], district: c[1], subAdmin: c[2], admin: c[3], countryCode: c[4]),
                           .init(city: c[5], region: c[6]), label)
        }
    }
}
