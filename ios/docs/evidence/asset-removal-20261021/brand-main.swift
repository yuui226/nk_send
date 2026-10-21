import Foundation

var assertionCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    guard condition() else { fatalError("Check failed: \(message)") }
}

func testTwoStateCycle() {
    for preset in PhotoFramePreset.allCases {
        for historicalStyle in PhotoFrameBrandStyle.allCases {
            var settings = PhotoFrameMetadataSettings.defaults(for: preset)
            settings.showBrand = false
            settings.brandStyle = historicalStyle
            settings.widthPercent = 135
            settings.showCity = true
            settings.backgroundMaskPercent = 170
            var expected = settings
            check(settings.brandControlLabelKey == "photo_frame_metadata_brand", "off label")
            settings.cycleBrandStyle()
            expected.showBrand = true
            expected.brandStyle = .text
            check(settings == expected, "off to text preserves all other fields")
            check(settings.brandControlLabelKey == "photo_frame_metadata_brand_text", "text label")
            settings.cycleBrandStyle()
            expected.showBrand = false
            check(settings == expected, "text to off skips removed logo state")
            check(settings.brandControlLabelKey == "photo_frame_metadata_brand", "returned off label")
        }
    }
    print("PASS: two-state cycle for \(PhotoFramePreset.allCases.count) presets and both historical style values")
}

func testLegacyJSON() throws {
    for visible in [true, false] {
        let data = Data("""
        {"showBrand":\(visible),"brandStyle":"logo","showModel":false,
         "showLensModel":true,"showCity":true,"showRegion":true,
         "widthPercent":135,"backgroundBlurPercent":30,"backgroundMaskPercent":170,
         "datePattern":"yyyy/MM/dd","timePattern":"HH.mm"}
        """.utf8)
        let settings = try JSONDecoder().decode(PhotoFrameMetadataSettings.self, from: data)
        check(settings.showBrand == visible, "JSON preserves brand visibility")
        check(settings.brandStyle == .text, "JSON logo normalizes to text")
        check(!settings.showModel && settings.showLensModel, "JSON preserves model and lens flags")
        check(settings.showCity && settings.showRegion, "JSON preserves location flags")
        check(settings.widthPercent == 135, "JSON preserves width")
        check(settings.backgroundBlurPercent == 30 && settings.backgroundMaskPercent == 170, "JSON preserves backdrop")
        check(settings.datePattern == "yyyy/MM/dd" && settings.timePattern == "HH.mm", "JSON preserves formats")
        let rewritten = try JSONEncoder().encode(settings)
        let dictionary = try JSONSerialization.jsonObject(with: rewritten) as! [String: Any]
        check(dictionary["brandStyle"] as? String == "text", "JSON writes only text")
        let reread = try JSONDecoder().decode(PhotoFrameMetadataSettings.self, from: rewritten)
        check(reread == settings, "JSON migrated value round-trips")
    }
    print("PASS: legacy JSON is preserved and rewritten as text for visible and hidden brands")
}

func testConstructionAndAssignment() {
    for visible in [true, false] {
        var settings = PhotoFrameMetadataSettings(showDate: true, showTime: false,
            showFocalLength: true, showExposure: true, showBrand: visible, showModel: true,
            showLensModel: true, showCoordinates: true, showAltitude: false,
            datePattern: "yyyy/MM/dd", timePattern: "HH:mm", brandStyle: .logo,
            widthPercent: 135, backgroundBlurPercent: 30, backgroundMaskPercent: 170)
        check(settings.brandStyle == .text, "constructor normalizes legacy logo")
        check(settings.showBrand == visible, "constructor preserves visibility")
        let expected = settings
        settings.brandStyle = .logo
        check(settings == expected, "assignment cannot enable a graphical mode or change other fields")
    }
    print("PASS: constructor and assignment cannot reactivate brand graphics")
}

try testLegacyJSON()
testTwoStateCycle()
testConstructionAndAssignment()
print("PASS: 3 Foundation checks, \(assertionCount) assertions; Store, cache, UIKit rendering and UI not covered")
