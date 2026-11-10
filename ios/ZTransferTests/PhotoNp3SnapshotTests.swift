import Combine
import CryptoKit
import UIKit
import XCTest
@testable import ZTransfer

/// Same inputs as the retained Android SnapshotCodec oracle; no Swift output
/// is used to produce its 69 versioned binary fixtures.
func photoNp3SnapshotFixture(_ key: String = "G:1") throws -> PhotoNp3Recipe {
    let parts = key.split(separator: ":")
    if parts[0] == "C" {
        let base = try XCTUnwrap(ClassicNp3Style(rawValue: Int(parts[1])!))
        return .init(preset: .init(id: "np3:\(String(repeating: "c", count: 64)):np3-classic-srgb-v1", name: "Classic fixture"),
            parameters: .classic(try .init(base: base, contrastQuarter: -128, brightnessQuarter: -6,
                saturationQuarter: -128, hueQuarter: 12, filterEffect: 0, toningEffect: 0,
                toningDensityQuarter: 16, effectLevel: base.isCreative ? 40 : 100,
                toneCurve: parts[2] == "1" ? (0...256).map { UInt16($0 * 32767 / 256) } : nil)))
    }
    let grade: Np3ColorGrading
    if parts[0] == "G" {
        grade = .init(highlights: .init(hue: 360, chroma: 100, brightness: -100),
            midtones: .init(hue: 127, chroma: -27, brightness: 53), shadows: .init(hue: 0, chroma: -100, brightness: 100),
            blending: 71, balance: -43)
    } else if parts[0] == "N" {
        grade = .init(highlights: .init(hue: 360), midtones: .init(hue: 120), shadows: .init(hue: 240), blending: 100, balance: -100)
    } else { grade = .init() }
    let name = key == "U" ? "影像 😀é" : key == "L" ? String(repeating: "😀", count: 128) : "NP3 fixture"
    return .init(preset: .init(id: "np3:\(String(repeating: "a", count: 64)):np3-srgb-v1", name: name),
        parameters: .flexible(.init(contrast: -100, highlights: -57, shadows: -3, whites: 2, blacks: 51, saturation: 100,
            colorBands: Np3FilterParameters.colorBandCenters.enumerated().map { i, c in
                .init(centerDegrees: c, hue: i - 7, chroma: i * 12, brightness: 100 - i * 11)
            }, toneCurve: parts.last == "1" ? (0...256).map { UInt16($0 * 32767 / 256) } : nil, colorGrading: grade)))
}

final class PhotoNp3SnapshotCodecTests: XCTestCase {
    func testAll69AndroidSnapshotsMatchBothDirectionsIncludingModifiedUTF() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("PictureControlFixtures/np3-snapshot-oracle.txt")
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(rows.count, 69)
        for row in rows {
            let fields = row.split(separator: "|")
            XCTAssertEqual(fields.count, 2)
            let expected = try XCTUnwrap(Data(base64Encoded: String(fields[1])))
            let recipe = try photoNp3SnapshotFixture(String(fields[0]))
            XCTAssertEqual(try PhotoNp3SnapshotCodec.encode(recipe), expected, String(fields[0]))
            XCTAssertEqual(try PhotoNp3SnapshotCodec.decode(expected), recipe)
        }
    }

    func testOriginalFlexibleV1HashRemainsExactAndInactiveMetadataUsesV3() throws {
        let data = try PhotoNp3SnapshotCodec.encode(photoNp3SnapshotFixture("F:1"))
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       "747d79fe0dd567a3d45899113677f12d9cc263a20425a2d99a841404060b61ec")
        XCTAssertEqual(data[7], 1)
        let inactive = try photoNp3SnapshotFixture("N")
        let snapshot = try PhotoNp3SnapshotCodec.encode(inactive)
        XCTAssertEqual(snapshot[7], 3)
        XCTAssertEqual(try PhotoNp3SnapshotCodec.decode(snapshot), inactive)
    }

    func testEveryTruncationBitCorruptionAndOversizeIsRejected() throws {
        let data = try PhotoNp3SnapshotCodec.encode(photoNp3SnapshotFixture())
        for end in 0..<data.count { XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(Data(data.prefix(end)))) }
        for index in data.indices {
            var changed = data; changed[index] ^= 1
            XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(changed))
        }
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(Data(repeating: 0, count: 4097)))
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(data + [0]))
    }

    func testChecksummedMalformedControlsCurvesAndGradingCannotReachRenderer() throws {
        let recipe = try photoNp3SnapshotFixture(), data = try PhotoNp3SnapshotCodec.encode(recipe)
        let payload = Data(data.dropLast(32))
        let start = 8 + 2 + recipe.preset.id.utf8.count + 2 + recipe.preset.name.utf8.count
        for field in 0..<30 {
            for value in [-101, 101] { try reject(payload, offset: start + field * 4, value: value) }
        }
        let grading = payload.count - 44
        for region in 0..<3 {
            for (field, value) in [(0, -1), (0, 361), (1, -101), (1, 101), (2, -101), (2, 101)] {
                try reject(payload, offset: grading + (region * 3 + field) * 4, value: value)
            }
        }
        for (field, value) in [(9, -1), (9, 101), (10, -101), (10, 101)] {
            try reject(payload, offset: grading + field * 4, value: value)
        }
        try reject(payload, offset: start + 30 * 4, value: 256)
        var invalidCurve = payload; invalidCurve[grading - 2] = 255; invalidCurve[grading - 1] = 255
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(checked(invalidCurve)))
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(checked(Data(payload.prefix(grading)))))
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(checked(payload + [0])))
        for version in [0, 1, 2, 4] { try reject(payload, offset: 4, value: version) }
    }

    func testClassicKindsIDsAndBaseCannotBeSubstituted() throws {
        let flexible = try photoNp3SnapshotFixture(), classic = try photoNp3SnapshotFixture("C:1:1")
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.encode(.init(preset: flexible.preset, parameters: classic.parameters)))
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.encode(.init(preset: classic.preset, parameters: flexible.parameters)))
        let data = try PhotoNp3SnapshotCodec.encode(classic)
        var payload = Data(data.dropLast(32)); payload[8] = 2
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(checked(payload)))
        payload[8] = 1
        let offset = 9 + 2 + classic.preset.id.utf8.count + 2 + classic.preset.name.utf8.count
        try reject(payload, offset: offset, value: 0xeeee)
        try reject(payload, offset: offset + 4, value: 127)
        for id in [flexible.preset.id.uppercased(), flexible.preset.id + "\n", "np3:abc:np3-srgb-v1",
                   "np3:\(String(repeating: "a", count: 64)):np3-srgb-v2"] {
            XCTAssertNil(PhotoNp3RecipeKind.from(id: id))
            XCTAssertThrowsError(try PhotoNp3SnapshotCodec.encode(.init(preset: .init(id: id, name: "Fixture"), parameters: flexible.parameters)))
        }
    }

    func testNamesRejectBlankControlsAndUTF16OverLimit() throws {
        let recipe = try photoNp3SnapshotFixture("F:0")
        for name in ["", "  ", "\n", "A\u{7f}", "A\u{80}", String(repeating: "😀", count: 129)] {
            XCTAssertThrowsError(try PhotoNp3SnapshotCodec.encode(.init(preset: .init(id: recipe.preset.id, name: name), parameters: recipe.parameters)))
        }
        for name in ["\u{feff}NP3", "\u{200b}", "e\u{301}😀"] {
            let named = PhotoNp3Recipe(preset: .init(id: recipe.preset.id, name: name), parameters: recipe.parameters)
            XCTAssertEqual(try PhotoNp3SnapshotCodec.decode(PhotoNp3SnapshotCodec.encode(named)), named)
        }
    }

    func testSelectionCodableOwnsRecipeAndRetainsRenderingIdentity() throws {
        for key in ["F:1", "G:1", "C:2061:1"] {
            let selected = try PhotoFilterSelection(np3Recipe: photoNp3SnapshotFixture(key), intensityPercent: 80,
                lutAdjustments: .init(contrast: 17, saturation: -23, highlights: 31, shadows: -19))
            let restored = try JSONDecoder().decode(PhotoFilterSelection.self, from: JSONEncoder().encode(selected))
            XCTAssertEqual(restored.np3Recipe, selected.np3Recipe); XCTAssertEqual(restored, selected)
            var first = PhotoEffectsSettings(); first.selectedFilter = selected; first.photoFilterEnabled = true
            var second = first; second.selectedFilter = restored
            XCTAssertEqual(androidPhotoFrameOutputName(sourceName: "fixture.jpg", settings: first),
                           androidPhotoFrameOutputName(sourceName: "fixture.jpg", settings: second))
            second.selectedFilter?.intensityPercent = 60
            XCTAssertNotEqual(androidPhotoFrameOutputName(sourceName: "fixture.jpg", settings: first),
                              androidPhotoFrameOutputName(sourceName: "fixture.jpg", settings: second))
        }
    }

    func testInvalidPrivateSnapshotDoesNotDiscardOtherSettings() throws {
        var settings = PhotoEffectsSettings(); settings.photoFrameEnabled = true; settings.photoFramePreset = .plaque
        settings.selectedFilter = try .init(np3Recipe: photoNp3SnapshotFixture(), intensityPercent: 80)
        settings.photoFilterEnabled = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var selection = try XCTUnwrap(object["selectedFilter"] as? [String: Any])
        for invalid in ["broken!", String(repeating: "a", count: 5500)] {
            selection["np3Snapshot"] = invalid; object["selectedFilter"] = selection
            let restored = try JSONDecoder().decode(PhotoEffectsSettings.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(restored.selectedFilter?.np3Recipe)
            XCTAssertFalse(restored.selectedFilter?.hasPhotoFilterRecipe ?? true)
            XCTAssertTrue(restored.photoFrameEnabled); XCTAssertEqual(restored.photoFramePreset, .plaque)
        }
    }

    func testRestoredPrivateRecipeActuallyRendersWithoutSourceFile() throws {
        let sourceBytes = Data([160, 80, 40, 255, 40, 160, 100, 255])
        let source = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: XCTUnwrap(CGDataProvider(data: sourceBytes as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for key in ["G:1", "C:2061:1"] {
            let recipe = try PhotoNp3SnapshotCodec.decode(PhotoNp3SnapshotCodec.encode(photoNp3SnapshotFixture(key)))
            var settings = PhotoEffectsSettings(); settings.photoFilterEnabled = true
            settings.selectedFilter = try .init(np3Recipe: recipe, intensityPercent: 80, lutAdjustments: .init(contrast: 17))
            let expected = try Np3BitmapFilter.apply(source, parameters: recipe.parameters, intensityPercent: 80,
                adjustments: .init(contrast: 17))
            for execution in [PhotoFilterExecution.preview, .original] {
                let actual = try PhotoEffectsRenderer.render(UIImage(cgImage: source), settings: settings, filterExecution: execution)
                func normalized(_ image: CGImage) throws -> Data {
                    let cg = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                        space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                    cg.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
                    return Data(bytes: try XCTUnwrap(cg.data), count: 8)
                }
                XCTAssertEqual(try normalized(XCTUnwrap(actual.cgImage)), try normalized(expected))
            }
        }
    }

    private func checked(_ payload: Data) -> Data { payload + Data(SHA256.hash(data: payload)) }
    private func reject(_ payload: Data, offset: Int, value: Int) throws {
        var changed = payload
        let v = UInt32(truncatingIfNeeded: value)
        changed.replaceSubrange(offset..<(offset + 4), with: [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)])
        XCTAssertThrowsError(try PhotoNp3SnapshotCodec.decode(checked(changed)))
    }
}

@MainActor
final class PhotoNp3StoreTests: XCTestCase {
    private var suite: String!, defaults: UserDefaults!, store: PhotoNp3Store!
    override func setUp() async throws {
        suite = "np3-store-\(UUID())"; defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); store = .init(defaults: defaults)
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite); store = nil; defaults = nil }
    private func url(_ path: String) -> String { URL(fileURLWithPath: "/np3-fixture/" + path).absoluteString }
    private func root(_ name: String) -> URL { URL(fileURLWithPath: "/np3-fixture/" + name, isDirectory: true) }

    func testRolesRestorePrivateRecipesWithoutSourceAndDisableIsIndependent() throws {
        let a = try photoNp3SnapshotFixture(), b = try photoNp3SnapshotFixture("C:1:1")
        try store.save(.transfer, recipe: a, source: url("a/one.NP3"))
        try store.save(.local, recipe: b, source: url("a/two.NP3"))
        let restarted = PhotoNp3Store(defaults: defaults)
        XCTAssertEqual(restarted.restore(.transfer), a); XCTAssertEqual(restarted.restore(.local), b)
        XCTAssertEqual(restarted.source(.local), url("a/two.NP3"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root("a").path))
        try restarted.save(.local, recipe: nil, source: nil)
        XCTAssertNil(restarted.restore(.local)); XCTAssertEqual(restarted.restore(.transfer), a)
    }

    func testDirectoryReplacementInvalidatesCustomDraftsButRetainsQueuedValueAndBuiltin() throws {
        let a = try photoNp3SnapshotFixture()
        store.replaceFolder(root("a"), bookmark: Data([1]))
        try store.save(.transfer, recipe: a, source: url("a/one.NP3"))
        let known = TestPhotoFilterCatalog.np3Presets[0]
        let builtin = PhotoNp3Recipe(preset: .init(id: known.id, name: known.name), parameters: .flexible(known.parameters))
        try store.save(.local, recipe: builtin, source: url("a/known.NP3"))
        try store.rememberSource(url("a/one.NP3"), sha256: String(repeating: "a", count: 64), presetID: a.preset.id)
        let queued = try PhotoFilterSelection(np3Recipe: XCTUnwrap(store.restore(.transfer)), intensityPercent: 80)
        store.replaceFolder(root("b"), bookmark: Data([2]))
        XCTAssertNil(store.restore(.transfer)); XCTAssertNil(store.restore(.local))
        XCTAssertNil(store.source(.local)); XCTAssertNil(store.sourceHints().knownPresetID(url("a/one.NP3")))
        XCTAssertFalse(try store.save(.transfer, recipe: a, source: url("a/one.NP3")))
        XCTAssertFalse(try store.save(.transfer, recipe: a, source: nil))
        XCTAssertFalse(try store.save(.transfer, recipe: a, source: url("b-extra/one.NP3")))
        XCTAssertEqual(queued.np3Recipe, a)
    }

    func testFolderNotificationsAreSharedDeduplicatedAndCancelled() throws {
        let second = PhotoNp3Store(defaults: defaults)
        var count = 0
        var observation: AnyCancellable? = second.observeFolderChanges { count += 1 }
        store.replaceFolder(root("a"), bookmark: Data([1])); XCTAssertEqual(count, 1)
        store.replaceFolder(root("a"), bookmark: Data([2])); XCTAssertEqual(count, 1)
        try store.save(.local, recipe: photoNp3SnapshotFixture(), source: url("a/one.NP3"))
        store.replaceFolder(URL(fileURLWithPath: root("a").path), bookmark: Data([5]))
        XCTAssertNotNil(store.restore(.local))
        XCTAssertEqual(count, 1)
        store.replaceFolder(root("b"), bookmark: Data([3])); XCTAssertEqual(count, 2)
        observation?.cancel(); observation = nil
        store.replaceFolder(root("c"), bookmark: Data([4])); XCTAssertEqual(count, 2)
    }

    func testSourceHintsSurviveOffRefreshOnlyAfterReadAndAreIndependentSnapshots() throws {
        let recipe = try photoNp3SnapshotFixture(), uri = url("one.NP3")
        try store.rememberSource(uri, sha256: String(repeating: "a", count: 64), presetID: recipe.preset.id)
        let old = store.sourceHints()
        try store.save(.transfer, recipe: recipe, source: uri)
        try store.save(.transfer, recipe: nil, source: nil)
        XCTAssertEqual(store.sourceHints().knownPresetID(uri), recipe.preset.id)
        let changed = "np3:\(String(repeating: "b", count: 64)):np3-srgb-v1"
        try store.rememberSource(uri, sha256: String(repeating: "b", count: 64), presetID: changed)
        XCTAssertEqual(old.knownPresetID(uri), recipe.preset.id)
        XCTAssertEqual(try store.sourceHints().knownPresetIDs([uri, url("missing.NP3")]), [uri: changed])
        XCTAssertThrowsError(try store.sourceHints().knownPresetIDs([uri]) { throw CancellationError() })
        XCTAssertThrowsError(try store.rememberSource(uri, sha256: String(repeating: "a", count: 64), presetID: changed))
    }

    func testRenamingUpdatesOnlyLabelAndDuplicateLabelsMatchCatalogOrder() throws {
        let uri = url("one.NP3"), recipe = try photoNp3SnapshotFixture()
        try store.save(.transfer, recipe: recipe, source: uri)
        let label = PhotoNp3SourceLabel(name: "我的滤镜 | 暮色", category: "人像\n收藏", showCategory: true, ordinal: 3)
        store.rememberSourceLabel(uri, label: label)
        XCTAssertEqual(PhotoNp3Store(defaults: defaults).sourceLabel(uri), label)
        XCTAssertEqual(label.displayName(uncategorized: "未分类"), "我的滤镜 | 暮色 · 人像\n收藏 · 3")
        store.rememberSourceLabel(uri, label: .init(name: "Renamed", category: nil, showCategory: true, ordinal: 2))
        XCTAssertEqual(store.restore(.transfer), recipe); XCTAssertEqual(store.source(.transfer), uri)
        XCTAssertEqual(store.sourceLabel(uri)?.displayName(uncategorized: "未分类"), "Renamed · 未分类 · 2")
        let files = [PresetFile(identifier: "1", name: "Look.NP3", relativePath: "Portrait/Look.NP3", size: 1),
                     .init(identifier: "2", name: "look.np3", relativePath: "look.np3", size: 1),
                     .init(identifier: "3", name: "LOOK.NP3", relativePath: "Portrait/LOOK.NP3", size: 1)]
        XCTAssertEqual(PhotoNp3SourceLabel.forSource("3", in: files), .init(name: "LOOK", category: "Portrait", showCategory: true, ordinal: 3))
        XCTAssertEqual(PhotoNp3SourceLabel.forSource("2", in: files), .init(name: "look", category: nil, showCategory: true, ordinal: nil))
    }

    func testCorruptMismatchedOversizedSnapshotsAndLabelsFailIndependently() throws {
        let recipe = try photoNp3SnapshotFixture(), uri = url("one.NP3")
        try store.save(.transfer, recipe: recipe, source: uri)
        let original = try XCTUnwrap(defaults.dictionary(forKey: PhotoNp3Store.preferencesKey))
        for invalid: Any in ["not base64!", "a", String(repeating: "a", count: 5500), 123] {
            var changed = original; changed["transfer:snapshot"] = invalid
            defaults.set(changed, forKey: PhotoNp3Store.preferencesKey)
            XCTAssertNil(store.restore(.transfer))
        }
        var mismatch = original; mismatch["transfer:id"] = "np3:\(String(repeating: "b", count: 64)):np3-srgb-v1"
        defaults.set(mismatch, forKey: PhotoNp3Store.preferencesKey); XCTAssertNil(store.restore(.transfer))
        defaults.set(original, forKey: PhotoNp3Store.preferencesKey)
        store.rememberSourceLabel(uri, label: .init(name: "Valid", category: nil, showCategory: false, ordinal: nil))
        let valid = try XCTUnwrap(defaults.dictionary(forKey: PhotoNp3Store.preferencesKey))
        let key = try XCTUnwrap(valid.keys.first { $0.hasSuffix(":label") })
        for invalid: Any in ["bad", "2|VmFsaWQ=|-|0|0", "1|***|-|0|0", "1|VmFsaWQ=|-|0|1", String(repeating: "x", count: 8193), 42] {
            var changed = valid; changed[key] = invalid
            defaults.set(changed, forKey: PhotoNp3Store.preferencesKey)
            XCTAssertNil(store.sourceLabel(uri)); XCTAssertEqual(store.restore(.transfer), recipe)
        }
    }

    func testNormalizationRetainsPrivateRecipeAndFinishingWithoutMergingRoles() throws {
        let transfer = PhotoEffectsStore(defaults: defaults), local = PhotoEffectsStore(defaults: defaults, scope: .localPhotos)
        var value = PhotoEffectsSettings(); value.photoFilterEnabled = true
        value.selectedFilter = try .init(np3Recipe: photoNp3SnapshotFixture(), intensityPercent: 79, lutAdjustments: .init(contrast: 17))
        transfer.update(value)
        XCTAssertEqual(transfer.settings.selectedFilter?.np3Recipe, value.selectedFilter?.np3Recipe)
        XCTAssertEqual(transfer.settings.selectedFilter?.intensityPercent, 80)
        XCTAssertEqual(transfer.settings.selectedFilter?.lutAdjustments.contrast, 17)
        XCTAssertNotEqual(local.settings.selectedFilter?.preset.id, value.selectedFilter?.preset.id)
        var builtin = value; builtin.selectedFilter = testPhotoFilterSelection(preset: TestPhotoFilterCatalog.presets[0], intensityPercent: 80, lutAdjustments: .init(contrast: 17))
        transfer.update(builtin); XCTAssertEqual(transfer.settings.selectedFilter?.lutAdjustments.contrast, 17)
    }
}

@MainActor
final class RemovedBundledPhotoFilterTests: XCTestCase {
    func testRetiredSelectionIsRemovedFromRestoredTaskWithoutRemovingOtherEffects() throws {
        var legacy = PhotoEffectsSettings()
        legacy.photoFilterEnabled = true
        legacy.selectedFilter = .init(preset: .init(id: "forest_verdure", name: "Retired"), intensityPercent: 80)
        legacy.rememberedBuiltinFilter = legacy.selectedFilter
        legacy.photoFrameEnabled = true
        legacy.photoFramePreset = .plaque
        legacy.watermark.text = "Owner"
        let restored = try JSONDecoder().decode(PhotoEffectsSettings.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(restored.selectedFilter)
        XCTAssertNil(restored.rememberedBuiltinFilter)
        XCTAssertFalse(restored.photoFilterEnabled)
        XCTAssertEqual(restored.photoFramePreset, .plaque)
        XCTAssertTrue(restored.photoFrameEnabled)
        XCTAssertEqual(restored.watermark, legacy.watermark)
    }

    func testUpgradeDropsRetiredPreferencesButRetainsImportedMemoryAndFrame() throws {
        let suite = "RemovedBundledPhotoFilterTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldKey = "0d277cf79b6f91dbb70849a34a61d8fbc3a471838731267c3874d2c50061602d"
        let importedKey = PhotoEffectsSettings.filterKey(TestPhotoFilterCatalog.presets[0].id)
        defaults.set("forest_verdure", forKey: "photo_filter_selected_id")
        defaults.set(true, forKey: "photo_filter_enabled")
        defaults.set(true, forKey: "photo_frame_enabled")
        defaults.set("\(oldKey),80;\(importedKey),42", forKey: "photo_filter_intensities_v1")
        defaults.set("\(oldKey);\(importedKey)", forKey: "favorite_photo_filters_v1")
        let value = PhotoEffectsStore(defaults: defaults).settings
        XCTAssertNil(value.selectedFilter)
        XCTAssertFalse(value.photoFilterEnabled)
        XCTAssertTrue(value.photoFrameEnabled)
        XCTAssertEqual(value.filterIntensities, [importedKey: 42])
        XCTAssertEqual(value.favoriteFilterIDs, [importedKey])
    }

    func testImportedTaskRetainsItsOwnedRecipeAfterCatalogRemoval() throws {
        var settings = PhotoEffectsSettings()
        settings.selectTestFilter(TestPhotoFilterCatalog.presets[0].id)
        let restored = try JSONDecoder().decode(PhotoEffectsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.selectedFilter, settings.selectedFilter)
        XCTAssertNotNil(restored.selectedFilter?.np3Recipe)
        XCTAssertTrue(restored.photoFilterEnabled)
    }
}
