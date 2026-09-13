import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferEffects
#else
@testable import ZTransfer
#endif

final class PhotoEffectsBatchTests: XCTestCase {
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
        XCTAssertEqual(result, .init(total: 12, completed: 12, saved: 8))
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
