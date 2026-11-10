import XCTest
import Combine
@testable import ZTransfer

final class PhotoLUTParameterMemoryTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let source = "/test/a.cube"
    private var legacy: String { "lut_adjustments_v1:" + digest }
    private func resolve(_ values: [String: Any], role: String = "transfer", source: String? = nil,
                         applied: [String: Any]? = nil) -> PhotoLUTParameterMemory {
        .resolve(values: values, role: role, digest: digest, source: source, applied: applied)
    }

    func testEachAppliedRoleWinsOverOldSharedValues() {
        let old: [String: Any] = [legacy + ":intensity": 70, legacy: ["contrast": 60, "saturation": 50]]
        XCTAssertEqual(resolve(old, applied: ["digest": digest, "intensity": 42, "adjustments": ["contrast": 15]]),
                       .init(intensity: 42, adjustments: .init(contrast: 15)))
        XCTAssertEqual(resolve(old, role: "local", applied: ["digest": digest, "intensity": 88, "adjustments": ["contrast": -20]]),
                       .init(intensity: 88, adjustments: .init(contrast: -20)))
    }

    func testScopedMemoryWinsWithoutImportingTheOtherRole() {
        let own = PhotoLUTParameterMemory.key(role: "transfer", digest: digest)
        let other = PhotoLUTParameterMemory.key(role: "local", digest: digest)
        let values: [String: Any] = [own + ":intensity": 54, own: ["contrast": 0],
            other + ":intensity": 92, other: ["contrast": 40], legacy + ":intensity": 66, legacy: ["saturation": 90]]
        XCTAssertEqual(resolve(values, applied: ["digest": digest, "intensity": 76, "adjustments": ["contrast": 20]]),
                       .init(intensity: 54, adjustments: .init()))
        XCTAssertEqual(resolve(values, role: "local"), .init(intensity: 92, adjustments: .init(contrast: 40)))
    }

    func testLegacyURIIsUsedOnlyWhenItBelongsToTheRequestedDigest() {
        let values: [String: Any] = ["strength:" + source: 35, legacy: ["highlights": -37]]
        XCTAssertEqual(resolve(values, applied: ["digest": digest, "source": source]),
                       .init(intensity: 36, adjustments: .init(highlights: -37)))
        XCTAssertEqual(resolve(values, role: "local", source: source),
                       .init(intensity: 36, adjustments: .init(highlights: -37)))
        XCTAssertEqual(resolve(values, role: "local").intensity, 80)
        XCTAssertEqual(resolve(values, applied: ["digest": String(repeating: "b", count: 64),
            "source": source, "intensity": 20, "adjustments": ["shadows": -80]]).intensity, 80)
    }

    func testDigestMemoryBeatsLegacySourceAndUnrelatedAppliedFile() {
        XCTAssertEqual(resolve([legacy + ":intensity": 65, legacy: ["shadows": 75], "strength:" + source: 30],
            source: source, applied: ["digest": String(repeating: "b", count: 64), "intensity": 20,
                                      "adjustments": ["shadows": -80]]),
            .init(intensity: 66, adjustments: .init(shadows: 75)))
    }

    func testCorruptScopedFieldsStayNeutralAndDoNotReimportLegacyData() {
        let own = PhotoLUTParameterMemory.key(role: "transfer", digest: digest)
        for invalid: Any in ["bad", true, 9.25, Int64.max, UInt64.max] {
            XCTAssertEqual(resolve([own + ":intensity": invalid,
                own: ["contrast": invalid, "saturation": 120, "shadows": -120],
                legacy + ":intensity": 20, legacy: ["contrast": 90]]),
                .init(intensity: 80, adjustments: .init(saturation: 100, shadows: -100)))
        }
        XCTAssertEqual(resolve([:]), .init(intensity: 80, adjustments: .init()))
        XCTAssertEqual(PhotoLUTParameterMemory.integer(Int32.min), Int(Int32.min))
        XCTAssertEqual(PhotoLUTParameterMemory.integer(Int32.max), Int(Int32.max))
    }
}

@MainActor
final class PhotoLUTRoleMemoryTests: XCTestCase {
    @MainActor private struct Fixture {
        let suite = "lut-v2-migration-\(UUID())"
        let defaults: UserDefaults
        let directory: URL
        let a: CubeLUT
        let b: CubeLUT
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            a = try CubeLUTParser.parse(Data(("TITLE A\nLUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
            b = try CubeLUTParser.parse(Data(("TITLE B\nLUT_3D_SIZE 2\n" + String(repeating: "1 1 1\n", count: 8)).utf8))
            let writer = PhotoLUTStore(defaults: defaults, directory: directory)
            _ = try writer.saveSnapshot(a); _ = try writer.saveSnapshot(b)
            for (key, intensity, contrast) in [("photo_lut_selected", 42, 15), ("photo_lut_local_selected", 88, -20)] {
                defaults.set("/old/a.cube", forKey: key)
                defaults.set(["digest": a.digest, "name": "A", "source": "/old/a.cube", "intensity": intensity,
                              "adjustments": ["contrast": contrast]], forKey: key + "_recipe")
            }
            defaults.set(72, forKey: "lut_adjustments_v1:\(a.digest):intensity")
            defaults.set(["contrast": 60, "saturation": 50], forKey: "lut_adjustments_v1:\(a.digest)")
            defaults.set(66, forKey: "strength:/old/b.cube")
            defaults.set(["highlights": -37], forKey: "lut_adjustments_v1:\(b.digest)")
        }
        func store(_ role: PhotoLUTStore.Role, draft: Bool = false) -> PhotoLUTStore {
            .init(role: role, defaults: defaults, directory: directory, savesOnCommit: draft)
        }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    }

    func testActualStoresMigrateSeparatelyAndKeepAppliedRecipeAndQueuedValue() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let camera = fixture.store(.camera, draft: true)
        let local = fixture.store(.local)
        XCTAssertEqual(camera.intensityPercent, 42)
        XCTAssertEqual(camera.adjustments, .init(contrast: 15))
        XCTAssertEqual(local.intensityPercent, 88)
        XCTAssertEqual(local.adjustments, .init(contrast: -20))
        let queued = try XCTUnwrap(camera.restoreSelection())
        camera.setIntensity(50); camera.setAdjustments(.init(contrast: 9, saturation: -30))
        local.setIntensity(92); local.setAdjustments(.init())
        camera.select(nil)
        let reopenedDraft = try camera.selectLUT(fixture.a, name: "copy", sourceIdentifier: "/old/copy.cube")
        XCTAssertEqual(reopenedDraft.intensityPercent, 50)
        XCTAssertEqual(reopenedDraft.lutAdjustments, .init(contrast: 9, saturation: -30))
        XCTAssertEqual(fixture.store(.camera).restoreSelection(), queued, "Unapplied detents must not alter transfer output")
        XCTAssertEqual(queued.intensityPercent, 42)
        XCTAssertEqual(queued.lutAdjustments, .init(contrast: 15))
        camera.commitDraft()
        XCTAssertEqual(fixture.store(.camera).restoreSelection(), reopenedDraft)
        local.select(nil)
        XCTAssertEqual(try local.selectLUT(fixture.a, name: "A", sourceIdentifier: "/old/a.cube").intensityPercent, 92)
        XCTAssertTrue(local.adjustments.isNeutral)
        XCTAssertEqual(fixture.defaults.integer(forKey: "lut_adjustments_v1:\(fixture.a.digest):intensity"), 72)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: "lut_adjustments_v1:\(fixture.a.digest)") as? [String: Int],
                       ["contrast": 60, "saturation": 50])
    }

    func testSecondRoleStillMigratesOldValuesAfterFirstRoleEditsAndResetPersists() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let camera = fixture.store(.camera, draft: true)
        camera.select(nil); camera.commitDraft()
        XCTAssertNil(fixture.store(.camera).restoreSelection())
        XCTAssertEqual(try camera.selectLUT(fixture.a, name: "A", sourceIdentifier: "/old/a.cube").intensityPercent, 42)
        XCTAssertEqual(try camera.selectLUT(fixture.b, name: "B", sourceIdentifier: "/old/b.cube").intensityPercent, 66)
        camera.setIntensity(54); camera.setAdjustments(.init())
        let local = fixture.store(.local)
        let other = try local.selectLUT(fixture.b, name: "B", sourceIdentifier: "/old/b.cube")
        XCTAssertEqual(other.intensityPercent, 66)
        XCTAssertEqual(other.lutAdjustments, .init(highlights: -37))
        camera.setIntensity(80); camera.setAdjustments(.init())
        camera.select(nil)
        let reset = try camera.selectLUT(fixture.b, name: "same bytes", sourceIdentifier: "/old/copy.cube")
        XCTAssertEqual(reset.intensityPercent, 80); XCTAssertTrue(reset.lutAdjustments.isNeutral)
        camera.commitDraft()
        XCTAssertEqual(fixture.store(.camera).restoreSelection(), reset)
        XCTAssertEqual(fixture.store(.local).restoreSelection(), other)
    }

    func testFolderReplacementClearsBothRolesAndMemoryWithoutChangingQueuedRecipe() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let camera = fixture.store(.camera, draft: true), local = fixture.store(.local)
        let old = URL(fileURLWithPath: "/old", isDirectory: true)
        let next = URL(fileURLWithPath: "/new", isDirectory: true)
        camera.acceptFolder(.init(bookmark: Data([1]), files: [], root: old), replacing: false, previous: nil)
        let effects = PhotoEffectsStore(defaults: fixture.defaults, premiumAccess: .init(.lifetime), lutStore: camera)
        let localEffects = PhotoEffectsStore(defaults: fixture.defaults, scope: .localPhotos,
            premiumAccess: .init(.lifetime), lutStore: local)
        let queued = try XCTUnwrap(camera.restoreSelection())
        camera.toggleFavorite("/old/a.cube")
        fixture.defaults.set(1, forKey: "remote_lut_untouched")
        var notifications = 0
        let observation = camera.folderChanges.sink { notifications += 1 }
        defer { observation.cancel() }
        camera.acceptFolder(.init(bookmark: Data([2]), files: [], root: old), replacing: true, previous: old)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(camera.restoreSelection(), queued)
        XCTAssertFalse(local.favorites.isEmpty)
        local.acceptFolder(.init(bookmark: Data([3]), files: [], root: next), replacing: true, previous: old)
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(camera.restoreSelection()); XCTAssertNil(local.restoreSelection())
        XCTAssertFalse(camera.hasSelection); XCTAssertTrue(camera.favorites.isEmpty)
        XCTAssertFalse(effects.settings.photoFilterEnabled); XCTAssertFalse(localEffects.settings.photoFilterEnabled)
        XCTAssertNotEqual(effects.settings.colorEffectModule, .lut)
        XCTAssertNotEqual(localEffects.settings.colorEffectModule, .lut)
        XCTAssertFalse(fixture.defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix("lut_adjustments_") || $0.hasPrefix("strength:")
        })
        XCTAssertFalse(camera.canCommitSelection(queued))
        XCTAssertThrowsError(try camera.selectLUT(fixture.a, name: "stale", sourceIdentifier: "/old/a.cube"))
        XCTAssertNil(fixture.store(.camera).restoreSelection())
        XCTAssertEqual(queued.intensityPercent, 42); XCTAssertEqual(queued.lutAdjustments, .init(contrast: 15))
        XCTAssertEqual(fixture.defaults.integer(forKey: "remote_lut_untouched"), 1)
        let fresh = try camera.selectLUT(fixture.a, name: "new", sourceIdentifier: "/new/a.cube")
        XCTAssertEqual(fresh.intensityPercent, 80); XCTAssertTrue(fresh.lutAdjustments.isNeutral)
        camera.setIntensity(50); camera.setAdjustments(.init(contrast: 20))
        camera.acceptFolder(.init(bookmark: Data([4]), files: [], root: old), replacing: true, previous: next)
        let returned = try camera.selectLUT(fixture.a, name: "old", sourceIdentifier: "/old/a.cube")
        XCTAssertEqual(returned.intensityPercent, 80); XCTAssertTrue(returned.lutAdjustments.isNeutral)
    }
}
