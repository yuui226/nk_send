import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferEffects
#else
@testable import ZTransfer
#endif

final class PhotoEffectsBatchTests: XCTestCase {
    func testFailureDetailsAreBoundedRetainedAndClearedForNextBatch() async throws {
        let result = try await PhotoEffectsBatchRunner.generate(photos: Array(1...8), onProgress: { _ in }) { number in
            if number == 8 { return true }
            throw LocalPhotoExportError(stage: "save", underlying:
                NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                        userInfo: [NSLocalizedDescriptionKey: String(repeating: "x", count: 1000)]))
        }
        XCTAssertEqual(result.completed, 8)
        XCTAssertEqual(result.saved, 1)
        XCTAssertEqual(result.failures.count, 5)
        XCTAssertEqual(Set(result.failures.map(\.number)).count, 5)
        for failure in result.failures {
            XCTAssertTrue((1...7).contains(failure.number))
            XCTAssertEqual(failure.stage, "save")
            XCTAssertEqual(failure.kind, "space")
            XCTAssertLessThan(failure.detail.count, 300)
        }
        var state = LocalPhotoBatchState<Int>()
        state.select(Array(1...8))
        let generation = try XCTUnwrap(state.begin())
        state.finish(result, generation: generation)
        let terminal = state
        state.returnToReady(ifUnchanged: terminal)
        XCTAssertEqual(state.progress.failures, result.failures)
        _ = state.begin()
        XCTAssertTrue(state.progress.failures.isEmpty)
        state.cancel()
        state.select([9])
        XCTAssertTrue(state.progress.failures.isEmpty)
    }

    func testFailureClassificationUsesUnderlyingErrorPriorityAndBoundedChain() {
        for (code, kind) in [(ENOMEM, "memory"), (EACCES, "permission"), (ENOSPC, "space"), (ENOENT, "missing"), (EINVAL, "unknown")] {
            let cause = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            let outer = NSError(domain: "Provider", code: 1, userInfo: [NSUnderlyingErrorKey: cause])
            let failure = LocalPhotoFailure(number: 4, error: LocalPhotoExportError(stage: "prepare", underlying: outer))
            XCTAssertEqual(failure.kind, kind)
            XCTAssertEqual(failure.number, 4)
            XCTAssertEqual(failure.stage, "prepare")
            XCTAssertTrue(failure.detail.contains("Provider"))
            XCTAssertTrue(failure.detail.contains(NSPOSIXErrorDomain))
        }
    }

    func testSelectionPreservesOrderAndRejectsCancelledPickerOrReplacementWhileGenerating() {
        var state = LocalPhotoBatchState<String>()
        XCTAssertTrue(state.select(["B", "A", "B", "C"]))
        XCTAssertEqual(state.photos, ["B", "A", "C"])
        XCTAssertFalse(state.select([]))
        XCTAssertNotNil(state.begin())
        XCTAssertFalse(state.select(["D"]))
        XCTAssertNil(state.begin())
        XCTAssertEqual(state.photos, ["B", "A", "C"])
    }

    func testPartialProgressCountsFailuresAndStaleResultsCannotReplaceANewSelection() {
        var state = LocalPhotoBatchState<String>()
        state.select(["A", "B", "C"])
        let generation = state.begin()!
        let progress = PhotoEffectsBatchProgress(total: 3, completed: 3, saved: 2)
        state.finish(progress, generation: generation)
        XCTAssertEqual(state.phase, .partial)
        XCTAssertEqual(state.progress.failed, 1)
        let finished = state
        state.select(["D"])
        state.returnToReady(ifUnchanged: finished)
        state.finish(progress, generation: generation)
        XCTAssertEqual(state.photos, ["D"])
        XCTAssertEqual(state.progress.total, 1)
        XCTAssertEqual(state.phase, .ready)
    }

    func testTerminalStatesAndLifecycleCancellation() {
        for saved in 0...2 {
            var state = LocalPhotoBatchState<Int>()
            state.select([1, 2])
            let generation = state.begin()!
            state.finish(.init(total: 2, completed: 2, saved: saved), generation: generation)
            XCTAssertEqual(state.phase, saved == 2 ? .complete : saved == 0 ? .failed : .partial)
            let finished = state
            state.returnToReady(ifUnchanged: finished)
            XCTAssertEqual(state.phase, .ready)
            let second = state.begin()!
            state.cancel()
            state.finish(.init(total: 2, completed: 2, saved: 2), generation: second)
            XCTAssertEqual(state.phase, .ready)
            XCTAssertEqual(state.photos, [1, 2])
        }
    }

    func testBatchBoundsConcurrencyAndSettlesEverySourceIncludingFailures() async throws {
        let probe = BatchProbe()
        let result = try await PhotoEffectsBatchRunner.generate(photos: Array(0..<12), onProgress: { value in
            await probe.record(value)
        }, generate: { value in
            try await probe.generate(value)
        })
        let evidence = await probe.snapshot()
        XCTAssertEqual(evidence.maximumActive, 2)
        XCTAssertEqual(evidence.started.sorted(), Array(0..<12))
        XCTAssertEqual(evidence.progress.map(\.completed), Array(0...12))
        XCTAssertTrue(evidence.progress.allSatisfy { $0.total == 12 })
        XCTAssertEqual(result.total, 12)
        XCTAssertEqual(result.completed, 12)
        XCTAssertEqual(result.saved, 8)
        XCTAssertEqual(result.failures.count, 4)
    }

    func testEmptySelectionReportsZeroOnce() async throws {
        let probe = BatchProbe()
        let result = try await PhotoEffectsBatchRunner.generate(photos: [Int](), onProgress: { value in
            await probe.record(value)
        }, generate: { _ in XCTFail("Empty selection cannot generate"); return true })
        let evidence = await probe.snapshot()
        XCTAssertEqual(result, .init(total: 0))
        XCTAssertEqual(evidence.progress, [.init(total: 0)])
    }

    func testCancellationPropagatesInsteadOfCountingAsAnOutputFailure() async throws {
        let probe = BatchProbe()
        do {
            _ = try await PhotoEffectsBatchRunner.generate(photos: [0, 1, 2, 3], onProgress: { value in
                await probe.record(value)
            }, generate: { value in
                if value == 0 { throw CancellationError() }
                try await Task.sleep(for: .seconds(30))
                return true
            })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let evidence = await probe.snapshot()
        XCTAssertEqual(evidence.progress, [.init(total: 4)])
    }

    @MainActor
    func testWorkbenchPreferencesAreIndependentFromCameraTransferSettings() async {
        let suite = "effects-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let camera = PhotoEffectsStore(defaults: defaults)
        let local = PhotoEffectsStore(defaults: defaults, scope: .localPhotos)
        var updated = local.settings
        updated.photoFrameEnabled = true
        updated.photoFramePreset = .filmEdge
        local.update(updated)
        XCTAssertFalse(camera.settings.photoFrameEnabled)
        XCTAssertEqual(PhotoEffectsStore(defaults: defaults).settings.photoFramePreset, .mist)
        XCTAssertEqual(PhotoEffectsStore(defaults: defaults, scope: .localPhotos).settings.photoFramePreset, .filmEdge)
    }

    func testDisabledDecorationDoesNotEnableGenerationThroughItsRememberedWatermark() {
        var settings = PhotoEffectsSettings()
        XCTAssertTrue(settings.watermark.enabled)
        XCTAssertFalse(settings.hasEffect)
        settings.photoFilterEnabled = true
        XCTAssertFalse(settings.hasEffect)
        settings.selectedFilter = .init(preset: .init(id: "sample", name: "sample"), intensityPercent: 80)
        XCTAssertTrue(settings.hasEffect)
    }

    @MainActor
    func testStoredLegacyFilterSlugsMigrateToAndroidIdentityAndInvalidFiltersAreDisabled() async {
        let suite = "effects-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = PhotoEffectsSettings()
        legacy.photoFilterEnabled = true
        legacy.selectedFilter = .init(preset: .init(id: "forest_verdure", name: "森屿青"), intensityPercent: 79)
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "photoEffectsSettings.v1")
        let restored = PhotoEffectsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.selectedFilter?.preset.id, Np3FilterCatalog.presets[0].id)
        XCTAssertEqual(restored.settings.selectedFilter?.normalizedIntensityPercent, 80)
        legacy.selectedFilter = .init(preset: .init(id: "missing", name: "Missing"), intensityPercent: 80)
        restored.update(legacy)
        XCTAssertFalse(restored.settings.photoFilterEnabled)
        XCTAssertNil(restored.settings.selectedFilter)
    }
}

private actor BatchProbe {
    private var active = 0
    private var maximumActive = 0
    private var started: [Int] = []
    private var progress: [PhotoEffectsBatchProgress] = []
    private var firstWorker: CheckedContinuation<Void, Never>?

    func generate(_ value: Int) async throws -> Bool {
        active += 1
        maximumActive = max(maximumActive, active)
        started.append(value)
        defer { active -= 1 }
        if started.count == 1 {
            await withCheckedContinuation { firstWorker = $0 }
        } else if started.count == 2 {
            firstWorker?.resume()
            firstWorker = nil
        }
        try await Task.sleep(for: .milliseconds(1))
        if value % 3 == 0 { throw CocoaError(.fileWriteUnknown) }
        return true
    }

    func record(_ value: PhotoEffectsBatchProgress) { progress.append(value) }
    func snapshot() -> (maximumActive: Int, started: [Int], progress: [PhotoEffectsBatchProgress]) {
        (maximumActive, started, progress)
    }
}


/// Approved iOS difference: legacy graphical brand selections become ordinary text.
final class PhotoFrameBrandMigrationTests: XCTestCase {
    func testLegacyLogoOutputUsesTextIdentityInsteadOfPreviousGraphicalCacheKey() throws {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.watermark.enabled = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = try encoder.encode(settings)
        let legacy = try XCTUnwrap(String(data: text, encoding: .utf8))
            .replacingOccurrences(of: #""brandStyle":"text""#, with: #""brandStyle":"logo""#)
        XCTAssertTrue(legacy.contains(#""brandStyle":"logo""#))
        let restored = try JSONDecoder().decode(PhotoEffectsSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(try encoder.encode(restored), text,
                       "JSON-based preview identities must use normalized text settings")
        XCTAssertNotEqual(try encoder.encode(restored), Data(legacy.utf8))
        let name = androidPhotoFrameOutputName(sourceName: "camera.jpg", settings: restored)
        XCTAssertEqual(name, "camera_frame_mist_wc08a79143377.jpg")
        // Previous LOGO fixture used metadata's 15-field LOGO token plus
        // brand-logo-v=3. It must never be reused for the new text render.
        XCTAssertNotEqual(name, "camera_frame_mist_w1a5601a33d47.jpg")
    }

    func testLegacyLogoPayloadKeepsMetadataAndReencodesAsText() throws {
        for visible in [true, false] {
            let data = Data("""
                {"showBrand":\(visible),"brandStyle":"logo","showModel":false,
                 "showLensModel":true,"showCity":true,"showRegion":true,
                 "widthPercent":135,"backgroundBlurPercent":30,"backgroundMaskPercent":170,
                 "datePattern":"yyyy/MM/dd","timePattern":"HH.mm"}
                """.utf8)
            let value = try JSONDecoder().decode(PhotoFrameMetadataSettings.self, from: data)
            XCTAssertEqual(value.showBrand, visible)
            XCTAssertEqual(value.brandStyle, .text)
            XCTAssertFalse(value.showModel)
            XCTAssertTrue(value.showLensModel)
            XCTAssertTrue(value.showCity)
            XCTAssertTrue(value.showRegion)
            XCTAssertEqual(value.widthPercent, 135)
            XCTAssertEqual(value.backgroundBlurPercent, 30)
            XCTAssertEqual(value.backgroundMaskPercent, 170)
            XCTAssertEqual(value.datePattern, "yyyy/MM/dd")
            XCTAssertEqual(value.timePattern, "HH.mm")
            let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            XCTAssertEqual(rewritten["brandStyle"] as? String, "text")
        }
    }

    func testLegacyLogoConstructorAndAssignmentsCannotEnableGraphics() {
        var value = PhotoFrameMetadataSettings(showDate: true, showTime: false,
            showFocalLength: true, showExposure: true, showBrand: false, showModel: true,
            showLensModel: true, showCoordinates: true, showAltitude: false,
            datePattern: "yyyy/MM/dd", timePattern: "HH:mm", brandStyle: .logo)
        XCTAssertEqual(value.brandStyle, .text)
        XCTAssertFalse(value.showBrand)
        value.brandStyle = .logo
        XCTAssertEqual(value.brandStyle, .text)
        XCTAssertFalse(value.showBrand, "Normalizing a removed style cannot reveal a hidden brand")
    }

    func testLegacyLogoRecipeRetainsOtherEffectsAndCustomImageWatermark() throws {
        var original = PhotoEffectsSettings()
        original.photoFrameEnabled = true
        original.photoFramePreset = .filmNegative
        original.metadata = .defaults(for: .filmNegative)
        original.metadata.widthPercent = 135
        original.metadata.showCity = true
        original.metadataByPreset[PhotoFramePreset.filmNegative.rawValue] = original.metadata
        original.watermark.content = .image
        original.watermark.imageHash = String(repeating: "ab", count: 32)
        original.watermark.sizePercent = 42
        original.favoriteFrameEffects = [.init(preset: .filmNegative, watermark: original.watermark)]
        let encoded = try JSONEncoder().encode(original)
        let legacy = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: #""brandStyle":"text""#, with: #""brandStyle":"logo""#)
        XCTAssertTrue(legacy.contains(#""brandStyle":"logo""#))
        let restored = try JSONDecoder().decode(PhotoEffectsSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(restored, original, "Removing brand graphics must not discard an old recipe or user watermark")
        XCTAssertEqual(restored.metadataByPreset[PhotoFramePreset.filmNegative.rawValue]?.brandStyle, .text)
    }

    @MainActor
    func testLegacyLogoEntriesMigrateInBothIndependentStoreScopes() {
        let suite = "legacy-brand-logo-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (scope, key, width) in [(PhotoEffectsStore.Scope.cameraTransfer, "photo_frame_metadata_settings_v1", 65),
                                   (.localPhotos, "frame_metadata_settings_v1", 135)] {
            if scope == .localPhotos { defaults.set(3, forKey: "settings_version") }
            defaults.set("MIST|true|false|true|true|false|true|true|true|false|yyyy/MM/dd|HH.mm|true|false|LOGO|\(width)|30|170", forKey: key)
            let restored = PhotoEffectsStore(defaults: defaults, scope: scope)
            XCTAssertEqual(restored.settings.metadata.brandStyle, .text)
            XCTAssertFalse(restored.settings.metadata.showBrand)
            XCTAssertTrue(restored.settings.metadata.showLensModel)
            // The local workspace already suppresses location fields; the
            // logo migration must preserve that existing scope policy.
            XCTAssertEqual(restored.settings.metadata.showCoordinates, scope == .cameraTransfer)
            XCTAssertEqual(restored.settings.metadata.showCity, scope == .cameraTransfer)
            XCTAssertEqual(restored.settings.metadata.widthPercent, width)
            XCTAssertEqual(restored.settings.metadata.backgroundBlurPercent, 30)
            XCTAssertEqual(restored.settings.metadata.backgroundMaskPercent, 170)
            XCTAssertEqual(restored.settings.metadata.datePattern, "yyyy/MM/dd")
            XCTAssertFalse(defaults.string(forKey: key)?.contains("|LOGO") ?? true)
            XCTAssertEqual(PhotoEffectsStore(defaults: defaults, scope: scope).settings.metadata, restored.settings.metadata)
        }
        XCTAssertEqual(PhotoEffectsStore(defaults: defaults, scope: .cameraTransfer).settings.metadata.widthPercent, 65)
        XCTAssertEqual(PhotoEffectsStore(defaults: defaults, scope: .localPhotos).settings.metadata.widthPercent, 135)
    }


    func testEveryPresetCyclesOnlyOffAndTextWithoutChangingOtherFields() {
        for preset in PhotoFramePreset.allCases {
            for remembered in PhotoFrameBrandStyle.allCases {
                var value = PhotoFrameMetadataSettings.defaults(for: preset)
                value.showBrand = false; value.brandStyle = remembered
                value.showCity = true; value.widthPercent = 135
                var expected = value
                XCTAssertEqual(value.brandControlLabelKey, "photo_frame_metadata_brand")
                value.cycleBrandStyle()
                expected.showBrand = true; expected.brandStyle = .text
                XCTAssertEqual(value, expected)
                XCTAssertEqual(value.brandControlLabelKey, "photo_frame_metadata_brand_text")
                value.cycleBrandStyle(); expected.showBrand = false; expected.brandStyle = .text
                XCTAssertEqual(value, expected)
                XCTAssertEqual(value.brandControlLabelKey, "photo_frame_metadata_brand")
            }
        }
    }
}
