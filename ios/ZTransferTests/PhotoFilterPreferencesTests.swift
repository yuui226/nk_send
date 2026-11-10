import XCTest
@testable import ZTransfer

final class PhotoFilterPreferencesTests: XCTestCase {
    func testOldPreferencesAndMissingControlMemoryAreNeutral() {
        XCTAssertTrue(PhotoFilterPreferences.decodeAdjustments(nil).isEmpty)
        XCTAssertTrue(PhotoFilterPreferences.decodeAdjustments("").isEmpty)
        XCTAssertTrue(PhotoFilterPreferences.decodeIntensities(nil).isEmpty)
        var settings = PhotoEffectsSettings()
        settings.selectTestFilter(TestPhotoFilterCatalog.presets.first!.id)
        XCTAssertEqual(settings.selectedFilter?.lutAdjustments, .init())
    }
    func testEveryControlAndBoundaryHasDeterministicRoundTrip() {
        let a = "np3:" + String(repeating: "a", count: 64), b = "np3:" + String(repeating: "b", count: 64)
        let values = [b: LUTAdjustments(contrast: -100, saturation: 100, highlights: -100, shadows: 100),
            "builtin": .init(contrast: 17, saturation: -22, highlights: 38, shadows: -49), a: .init()]
        let encoded = PhotoFilterPreferences.encodeAdjustments(values)
        XCTAssertEqual(encoded, PhotoFilterPreferences.encodeAdjustments(Dictionary(uniqueKeysWithValues: values.reversed())))
        XCTAssertEqual(PhotoFilterPreferences.decodeAdjustments(encoded, validKeys: ["builtin"]), values)
        XCTAssertEqual(PhotoFilterPreferences.encodeIntensities([b: 33, a: 101]), "\(a),100;\(b),34")
    }
    func testMalformedAndDuplicateEntriesDoNotConsumeAValidMemorySlot() {
        let key = "np3:" + String(repeating: "c", count: 64)
        let raw = "missing,1,2,3,4;np3:bad,1,2,3,4;bad/key,1,2,3,4;forest,no,1,2,3;forest,200,-200,11,-12;forest,1,2,3,4;\(key),1,2,3;\(key),4,3,2,1;trailing,1,2,3,4,5"
        XCTAssertEqual(PhotoFilterPreferences.decodeAdjustments(raw, validKeys: ["forest"]),
            ["forest": .init(contrast: 100, saturation: -100, highlights: 11, shadows: -12), key: .init(contrast: 4, saturation: 3, highlights: 2, shadows: 1)])
        XCTAssertEqual(PhotoFilterPreferences.decodeIntensities("\(key),2147483648;\(key),+42;\(key),90;bad,20"), [key: 42])
        XCTAssertTrue(PhotoFilterPreferences.decodeAdjustments("forest,2147483648,0,0,0", validKeys: ["forest"]).isEmpty)
    }
    func testConverterRevisionsShareMemoryButDetachedCustomKeysRemainValid() throws {
        let flexible = try photoNp3SnapshotFixture(), key = PhotoEffectsSettings.filterKey(flexible.preset.id)
        let classicID = "np3:" + String(repeating: "a", count: 64) + ":np3-classic-srgb-v1"
        XCTAssertEqual(key, PhotoFilterPreferences.catalogKey(classicID))
        let values = [key: LUTAdjustments(contrast: 17), "removed": .init(), "np3:bad": .init()]
        XCTAssertEqual(PhotoFilterPreferences.normalizeAdjustments(values), [key: .init(contrast: 17)])
        XCTAssertEqual(PhotoFilterPreferences.decodeIntensities("\(key),72", validKeys: []), [key: 72])
    }
    func testSettingsCodableMemoryAndPixelIdentityStayIndependentOfAppliedRecipe() throws {
        var settings = PhotoEffectsSettings()
        XCTAssertTrue(settings.selectPhotoFilter(try photoNp3SnapshotFixture(), explicit: true))
        let applied = settings.selectedFilter, originalPixels = photoEffectsPreviewPixelSettings(settings)
        settings.filterAdjustments[PhotoEffectsSettings.filterKey(applied!.preset.id)] = .init(contrast: 67)
        let restored = try JSONDecoder().decode(PhotoEffectsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.filterAdjustments, settings.filterAdjustments)
        XCTAssertEqual(restored.selectedFilter, applied)
        XCTAssertEqual(photoEffectsPreviewPixelSettings(restored), originalPixels)
        let legacy = try JSONDecoder().decode(PhotoEffectsSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.filterAdjustments.isEmpty)
    }
    func testPassiveImportedRecipeRefreshKeepsOffAndActiveCubeSeparate() throws {
        let a = try photoNp3SnapshotFixture("F:0"), c = try photoNp3SnapshotFixture("C:2061:0")
        var settings = PhotoEffectsSettings()
        settings.filterIntensities[PhotoEffectsSettings.filterKey(a.preset.id)] = 62
        settings.filterAdjustments[PhotoEffectsSettings.filterKey(a.preset.id)] = .init(contrast: 41)
        XCTAssertTrue(settings.selectPhotoFilter(a, explicit: false)); XCTAssertFalse(settings.photoFilterEnabled)
        XCTAssertEqual(settings.selectedFilter?.intensityPercent, 62)
        XCTAssertEqual(settings.selectedFilter?.lutAdjustments.contrast, 41)
        // The transition model only inspects Cube identity; rendering eligibility
        // remains separately guarded by the production LUT runtime/store tests.
        let cube = testPhotoFilterSelection(preset: .init(id: "cube:fixture", name: "Cube"), intensityPercent: 38)
        settings.selectedFilter = cube; settings.photoFilterEnabled = true
        XCTAssertTrue(settings.selectPhotoFilter(c, explicit: false))
        XCTAssertEqual(settings.selectedFilter, cube); XCTAssertTrue(settings.photoFilterEnabled)
        XCTAssertEqual(settings.rememberedBuiltinFilter?.np3Recipe, c)
        settings.clearNP3DirectorySettings()
        XCTAssertEqual(settings.selectedFilter, cube); XCTAssertTrue(settings.photoFilterEnabled)
        XCTAssertNil(settings.rememberedBuiltinFilter)
    }
}

@MainActor
final class PhotoNp3OwnerTests: XCTestCase {
    @MainActor private final class Fixture {
        let suite = "PhotoNp3OwnerTests-" + UUID().uuidString
        let defaults: UserDefaults
        let np3: PhotoNp3Store
        let root = URL(fileURLWithPath: "/np3-owner/a/", isDirectory: true)
        init() {
            defaults = UserDefaults(suiteName: suite)!
            np3 = PhotoNp3Store(defaults: defaults)
            np3.replaceFolder(root, bookmark: Data([1]))
        }
        func source(_ name: String = "file.NP3") -> String { root.appendingPathComponent(name).absoluteString }
        func effects(_ scope: PhotoEffectsStore.Scope = .cameraTransfer) -> PhotoEffectsStore {
            PhotoEffectsStore(defaults: defaults, scope: scope, np3Store: np3)
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
    private func draft(_ recipe: PhotoNp3Recipe, strength: Int = 74, controls: LUTAdjustments = .init(contrast: 17)) throws -> PhotoEffectsSettings {
        var result = PhotoEffectsSettings()
        let key = PhotoEffectsSettings.filterKey(recipe.preset.id)
        result.filterIntensities[key] = strength; result.filterAdjustments[key] = controls
        XCTAssertTrue(result.selectPhotoFilter(recipe, explicit: true))
        return result
    }
    func testTransferAppliedControlsStaySeparateFromRememberedDraftAcrossRestart() throws {
        let f = Fixture(); defer { f.clean() }
        let recipe = try photoNp3SnapshotFixture(), effects = f.effects()
        let committed = try draft(recipe)
        XCTAssertTrue(effects.commitFromEditor(committed, np3Source: f.source()))
        var edit = effects.beginDraft(), selection = try XCTUnwrap(edit.selectedFilter)
        let key = PhotoEffectsSettings.filterKey(recipe.preset.id)
        selection.intensityPercent = 56; selection.lutAdjustments = .init(contrast: -39)
        edit.selectedFilter = selection; edit.filterIntensities[key] = 56; edit.filterAdjustments[key] = selection.lutAdjustments
        effects.persistEditorPreferences(from: edit)
        XCTAssertEqual(effects.settings.selectedFilter, committed.selectedFilter)
        XCTAssertEqual(effects.settings.filterAdjustments[key]?.contrast, -39)
        let cold = f.effects()
        XCTAssertEqual(cold.settings.selectedFilter?.np3Recipe, recipe)
        XCTAssertEqual(cold.settings.selectedFilter?.lutAdjustments.contrast, 17)
        // Android restores strength from its latest detent map; applied
        // finishing controls have their own committed preference key.
        XCTAssertEqual(cold.settings.selectedFilter?.intensityPercent, 56)
        XCTAssertEqual(cold.settings.filterAdjustments[key]?.contrast, -39)
        XCTAssertEqual(f.np3.source(.transfer), f.source())
        XCTAssertTrue(cold.commitFromEditor(edit, np3Source: f.source()))
        XCTAssertEqual(f.effects().settings.selectedFilter?.lutAdjustments.contrast, -39)
    }
    func testBothEntriesRestoreTheirOwnRecipeAndControlMemoryWithoutSourceIO() throws {
        let f = Fixture(); defer { f.clean() }
        let transferRecipe = try photoNp3SnapshotFixture(), localRecipe = try photoNp3SnapshotFixture("C:2061:1")
        let transfer = f.effects(), local = f.effects(.localPhotos)
        XCTAssertTrue(transfer.commitFromEditor(try draft(transferRecipe), np3Source: f.source()))
        XCTAssertTrue(local.commitFromEditor(try draft(localRecipe, strength: 38, controls: .init(saturation: -42)), np3Source: f.source("local.NP3")))
        let coldTransfer = f.effects(), coldLocal = f.effects(.localPhotos)
        XCTAssertEqual(coldTransfer.settings.selectedFilter?.np3Recipe, transferRecipe)
        XCTAssertEqual(coldTransfer.settings.selectedFilter?.intensityPercent, 74)
        XCTAssertEqual(coldTransfer.settings.selectedFilter?.lutAdjustments.contrast, 17)
        XCTAssertEqual(coldLocal.settings.selectedFilter?.np3Recipe, localRecipe)
        XCTAssertEqual(coldLocal.settings.selectedFilter?.intensityPercent, 38)
        XCTAssertEqual(coldLocal.settings.selectedFilter?.lutAdjustments.saturation, -42)
        XCTAssertNil(coldTransfer.settings.filterAdjustments[PhotoEffectsSettings.filterKey(localRecipe.preset.id)])
    }
    func testGlobalReplacementClearsInactiveLocalPreferencesAndLiveTransferButNotCapturedTask() throws {
        let f = Fixture(); defer { f.clean() }
        let recipe = try photoNp3SnapshotFixture(), transfer = f.effects()
        var local: PhotoEffectsStore? = f.effects(.localPhotos)
        var value = try draft(recipe); value.photoFrameEnabled = true; value.photoFramePreset = .plaque
        XCTAssertTrue(transfer.commitFromEditor(value, np3Source: f.source()))
        XCTAssertTrue(local!.commitFromEditor(value, np3Source: f.source("local.NP3")))
        let captured = transfer.settings
        weak var weakLocal = local; local = nil; XCTAssertNil(weakLocal)
        f.np3.replaceFolder(URL(fileURLWithPath: "/np3-owner/b/", isDirectory: true), bookmark: Data([2]))
        XCTAssertNil(transfer.settings.selectedFilter); XCTAssertFalse(transfer.settings.photoFilterEnabled)
        XCTAssertTrue(transfer.settings.filterAdjustments.isEmpty)
        XCTAssertTrue(transfer.settings.photoFrameEnabled); XCTAssertEqual(transfer.settings.photoFramePreset, .plaque)
        XCTAssertEqual(captured.selectedFilter?.np3Recipe, recipe)
        XCTAssertNil(f.defaults.string(forKey: "filter_id"))
        XCTAssertTrue(PhotoFilterPreferences.decodeAdjustments(f.defaults.string(forKey: "filter_adjustments_v1")).isEmpty)
        let cold = f.effects(.localPhotos)
        XCTAssertNil(cold.settings.selectedFilter); XCTAssertFalse(cold.settings.photoFilterEnabled)
        XCTAssertTrue(cold.settings.photoFrameEnabled); XCTAssertEqual(cold.settings.photoFramePreset, .plaque)
        XCTAssertFalse(transfer.commitFromEditor(captured, np3Source: f.source()))
        XCTAssertFalse(transfer.commitFromEditor(captured, np3Source: nil))
        XCTAssertNil(transfer.settings.selectedFilter)
    }
    func testReplacementClearsImportedControlsAndPreservesOtherEffects() throws {
        let f = Fixture(); defer { f.clean() }
        let effects = f.effects(), first = TestPhotoFilterCatalog.presets[0]
        let customKey = PhotoEffectsSettings.filterKey(try photoNp3SnapshotFixture().preset.id)
        var settings = PhotoEffectsSettings()
        settings.selectTestFilter(first.id)
        settings.photoFrameEnabled = true
        settings.photoFramePreset = .plaque
        settings.selectedFilter?.lutAdjustments = .init(contrast: -15)
        settings.filterAdjustments[PhotoEffectsSettings.filterKey(first.id)] = .init(contrast: -15)
        settings.filterAdjustments[customKey] = .init(contrast: 30); settings.filterIntensities[customKey] = 42
        XCTAssertTrue(effects.commitFromEditor(settings, np3Source: f.source()))
        f.np3.replaceFolder(URL(fileURLWithPath: "/np3-owner/b/", isDirectory: true), bookmark: Data([2]))
        XCTAssertNil(effects.settings.selectedFilter)
        XCTAssertTrue(effects.settings.photoFrameEnabled)
        XCTAssertEqual(effects.settings.photoFramePreset, .plaque)
        XCTAssertNil(effects.settings.filterAdjustments[customKey]); XCTAssertNil(effects.settings.filterIntensities[customKey])
        XCTAssertNil(f.effects().settings.selectedFilter)
        XCTAssertNil(effects.settings.filterAdjustments[PhotoEffectsSettings.filterKey(first.id)])
    }
    func testCorruptOneRoleDoesNotDiscardOtherRoleFrameOrMemory() throws {
        let f = Fixture(); defer { f.clean() }
        let a = try photoNp3SnapshotFixture(), c = try photoNp3SnapshotFixture("C:2061:0")
        let transfer = f.effects(), local = f.effects(.localPhotos)
        var value = try draft(a); value.photoFrameEnabled = true
        XCTAssertTrue(transfer.commitFromEditor(value, np3Source: f.source()))
        XCTAssertTrue(local.commitFromEditor(try draft(c), np3Source: f.source("local.NP3")))
        var fields = f.defaults.dictionary(forKey: PhotoNp3Store.preferencesKey)!
        fields["transfer:snapshot"] = "invalid!"; f.defaults.set(fields, forKey: PhotoNp3Store.preferencesKey)
        let restored = f.effects()
        XCTAssertFalse(restored.settings.photoFilterEnabled); XCTAssertTrue(restored.settings.photoFrameEnabled)
        XCTAssertNotNil(restored.settings.filterAdjustments[PhotoEffectsSettings.filterKey(a.preset.id)])
        XCTAssertEqual(f.effects(.localPhotos).settings.selectedFilter?.np3Recipe, c)
    }
    func testOffRetainsRecipeAndControlsAndSameDirectoryDoesNotClearThem() throws {
        let f = Fixture(); defer { f.clean() }
        let recipe = try photoNp3SnapshotFixture(), effects = f.effects()
        var value = try draft(recipe); value.photoFilterEnabled = false
        XCTAssertTrue(effects.commitFromEditor(value, np3Source: f.source()))
        f.np3.replaceFolder(f.root, bookmark: Data([9]))
        let cold = f.effects()
        XCTAssertEqual(cold.settings.selectedFilter?.np3Recipe, recipe)
        XCTAssertEqual(cold.settings.selectedFilter?.lutAdjustments.contrast, 17)
        XCTAssertFalse(cold.settings.photoFilterEnabled)
        XCTAssertEqual(f.np3.source(.transfer), f.source())
    }
    func testBothPrivateRecipesAreAvailableBeforePreferenceIDValidation() throws {
        let f = Fixture(); defer { f.clean() }
        let recipe = try photoNp3SnapshotFixture()
        try f.np3.save(.local, recipe: recipe, source: f.source())
        f.defaults.set(recipe.preset.id, forKey: "photo_filter_selected_id")
        f.defaults.set(true, forKey: "photo_filter_enabled")
        let effects = f.effects()
        XCTAssertEqual(effects.settings.selectedFilter?.np3Recipe, recipe)
        XCTAssertTrue(effects.settings.photoFilterEnabled)
        XCTAssertNil(f.np3.savedID(.transfer), "Restoring a shared recipe does not commit a different role")
    }
    func testNewerValidSelectionCannotBeOverwrittenByOldDirectoryDraft() throws {
        let f = Fixture(); defer { f.clean() }
        let effects = f.effects(), old = try draft(photoNp3SnapshotFixture())
        XCTAssertTrue(effects.commitFromEditor(old, np3Source: f.source()))
        let b = URL(fileURLWithPath: "/np3-owner/b/", isDirectory: true)
        f.np3.replaceFolder(b, bookmark: Data([2]))
        let new = try draft(photoNp3SnapshotFixture("C:2061:0"), strength: 26)
        XCTAssertTrue(effects.commitFromEditor(new, np3Source: b.appendingPathComponent("new.NP3").absoluteString))
        XCTAssertFalse(effects.commitFromEditor(old, np3Source: f.source()))
        XCTAssertEqual(effects.settings.selectedFilter, new.selectedFilter)
        XCTAssertEqual(f.effects().settings.selectedFilter, new.selectedFilter)
    }
}
