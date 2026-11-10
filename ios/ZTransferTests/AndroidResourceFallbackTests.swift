import XCTest
@testable import ZTransfer

final class AndroidResourceFallbackTests: XCTestCase {
    func testMissingTraditionalFrameNamesUseAndroidDefaultResource() {
        for (key, expected) in ["photo_frame_classic_signature": "Classic Signature",
                                "photo_frame_film_edge": "Film Edge",
                                "photo_frame_film_gallery": "Film Gallery",
                                "photo_frame_gallery_mat": "Gallery Mat"] {
            XCTAssertEqual(AppLocalized.resource(key, language: "hant"), expected)
        }
        XCTAssertEqual(AppLocalized.resource("photo_frame_classic_signature", language: "zh"), "经典签名")
        XCTAssertEqual(AppLocalized.resource("not_a_resource", language: "hant"), "not_a_resource")
    }

    func testLatestConnectionAndEffectCopyReachesLookupInAllLanguages() {
        for (language, noNetwork, effects) in [("en", "No network", "Effects"),
                                               ("zh", "无网络", "照片效果"),
                                               ("hant", "無網路", "照片效果")] {
            XCTAssertEqual(AppLocalized.resource("renewal_needed", language: language), noNetwork)
            XCTAssertEqual(AppLocalized.resource("photo_effects", language: language), effects)
            XCTAssertEqual(AppLocalized.resource("local_photo_effects_entry", language: language), effects)
        }
    }
}
