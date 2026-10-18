import XCTest
@testable import ZTransfer

final class PhotoRatingScanTests: XCTestCase {
    @MainActor
    func testOldReadFinishingCannotDetachReplacementBeforeSecondDisable() async throws {
        let gate = RatingLookupGate()
        let stub = Stub()
        let scheduler = CameraIOGate()
        let model = PhotoRatingScanController(io: PhotoRatingScanIO(
            generation: { await stub.generation }, invalidate: { await stub.invalidate() },
            cached: { _ in nil },
            beginPhase: { await scheduler.beginRatingPhase(); await stub.begin() },
            endPhase: { await scheduler.endRatingPhase(); await stub.end() },
            read: { _, _ in await gate.lookup()?.value }))
        defer { model.cancel() }
        let files = [file(1, "A.JPG", "20261007T120000"), file(2, "B.JPG", "20261007T120001")]
        let scanInput = input(files, sta: false, loading: false)
        model.update(scanInput, enabled: true)
        for _ in 0..<100 where await gate.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        model.update(scanInput, enabled: false)
        model.update(scanInput, enabled: true)
        for _ in 0..<100 where await gate.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let started = await gate.calls
        XCTAssertEqual(started, 2)
        // Old generation unwinds while the replacement still owns its read.
        await gate.release(1, value: PhotoRatingCacheEntry(value: 5, origin: "old"))
        for _ in 0..<100 {
            if await stub.snapshot().1 == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.update(scanInput, enabled: false)
        await gate.release(2, value: PhotoRatingCacheEntry(value: 2, origin: "replacement"))
        for _ in 0..<100 {
            if await stub.snapshot().1 == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let phases = await stub.snapshot()
        let reads = await gate.calls
        XCTAssertEqual(reads, 2, "Second disable must cancel the replacement before its next file")
        XCTAssertEqual(phases.0, 2)
        XCTAssertEqual(phases.1, 2, "Both generations must release their rating phase")
        let finalScheduler = await scheduler.snapshot()
        XCTAssertEqual(finalScheduler.ratingPhaseCount, 0)
        XCTAssertFalse(model.state.loading)
        XCTAssertTrue(model.state.values.isEmpty)
        // Keep a failing regression from leaving its unexpected third read suspended.
        model.cancel()
        await gate.release(3, value: nil)
    }

    func testNoMatchMessageRequiresConcreteEnabledRatingStillLoadingToHide() {
        let cases: [(enabled: Bool, rating: Int?, loading: Bool, showsMessage: Bool)] = [
            (false, nil, false, true), (false, nil, true, true),
            (true, nil, false, true), (true, nil, true, true),
            (true, 0, true, false), (true, 5, true, false),
            (true, 0, false, true), (true, 5, false, true),
            (false, 5, true, true)
        ]
        for item in cases {
            var filter = PhotoFilterState()
            filter.ratingEnabled = item.enabled
            filter.rating = item.rating
            XCTAssertEqual(filter.showsNoMatchMessage(ratingLoading: item.loading), item.showsMessage)
        }
    }

    @MainActor
    func testNoMatchMessageWaitsForRealListRatingReadAndSurvivesBusyPause() async throws {
        let saved = PhotoFilterPersistence.load()
        defer { PhotoFilterPersistence.save(saved) }
        let gate = RatingLookupGate()
        let stub = Stub()
        let files = [file(1, "A.JPG", "20261016T120000")]
        let io = PhotoRatingScanIO(generation: { await stub.generation },
            invalidate: { await stub.invalidate() }, cached: { _ in nil },
            beginPhase: { await stub.begin() }, endPhase: { await stub.end() },
            read: { _, _ in await gate.lookup()?.value })
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, setRemoteGate: { _ in }, ratingIO: io)
        defer { model.cancelRatingScan(); model.cancelLoading() }
        model.load()
        await waitUntil { model.hasCompletedFileScan }
        XCTAssertTrue(model.hasCompletedFileScan)
        var filter = PhotoFilterState()
        filter.ratingEnabled = true
        filter.rating = 5
        model.setFilter(filter)
        for _ in 0..<100 {
            if await gate.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let readCalls = await gate.calls
        XCTAssertEqual(readCalls, 1)
        XCTAssertTrue(model.ratingScan.loading)
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertFalse(model.filter.showsNoMatchMessage(ratingLoading: model.ratingScan.loading))
        model.setTransferBusy(true)
        XCTAssertFalse(model.filter.showsNoMatchMessage(ratingLoading: model.ratingScan.loading))
        model.setTransferBusy(false)
        await gate.release(1, value: PhotoRatingCacheEntry(value: 2, origin: "test"))
        await waitUntil { model.ratingScan.complete }
        XCTAssertTrue(model.ratingScan.complete)
        XCTAssertFalse(model.ratingScan.loading)
        XCTAssertTrue(model.sections.isEmpty, "The completed two-star result does not match five stars")
        XCTAssertTrue(model.filter.showsNoMatchMessage(ratingLoading: model.ratingScan.loading))
        model.clearFilter()
        XCTAssertEqual(model.sections.flatMap(\.files), files)
    }

    @MainActor
    func testOrdinaryRatingUpdatesPreserveExplicitDiagnosticCapture() async {
        defer { PhotoRatingDiagnostics.setEnabled(false) }
        for enabled in [false, true] {
            let model = controller(Stub())
            let files = [file(1, "A.JPG", "20261007T120000")]
            model.update(input(files, sta: false, loading: false), enabled: enabled)
            if enabled { await waitUntil { model.state.complete } }
            let previous = PhotoRatingDiagnostics.beginProbe()
            PhotoRatingDiagnostics.detail("first-probe")
            model.update(input(files + [file(2, "B.JPG", "20261006T120000")],
                sta: false, loading: false, readyDays: 5, paused: true), enabled: enabled)
            PhotoRatingDiagnostics.detail("second-probe")
            let capturing = PhotoRatingDiagnostics.snapshot()
            XCTAssertTrue(capturing.contains("first-probe"))
            XCTAssertTrue(capturing.contains("second-probe"))
            PhotoRatingDiagnostics.restore(previous, preserveEntries: true)
            model.update(input(files, sta: false, loading: false, paused: false), enabled: enabled)
            PhotoRatingDiagnostics.detail("must-not-record-detail")
            PhotoRatingDiagnostics.note("normal-summary")
            let restored = PhotoRatingDiagnostics.snapshot()
            XCTAssertTrue(restored.contains("first-probe"))
            XCTAssertTrue(restored.contains("second-probe"))
            XCTAssertFalse(restored.contains("must-not-record-detail"))
            XCTAssertEqual(restored.contains("normal-summary"), enabled)
            model.cancel()
        }
    }

    @MainActor
    func testRatingRangeRestorationDistinguishesMissingFromExplicitAll() {
        let key = "filter_rating_days"
        let suite = "rating-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PhotoFilterPersistence.load(from: defaults).ratingDays, 3)
        for (stored, expected) in [(0, 0), (1, 1), (3, 3), (5, 5), (-1, 3), (2, 3), (999, 3)] {
            defaults.set(stored, forKey: key)
            XCTAssertEqual(PhotoFilterPersistence.load(from: defaults).ratingDays, expected)
        }
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for stored in [nil, 0, 5] as [Int?] {
            if let stored { UserDefaults.standard.set(stored, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            let session = CameraSession(repository: CameraRepository(session: PTPSession(transport: STAScriptTransport([]))))
            let model = PhotoListViewModel(session: session)
            XCTAssertEqual(model.filter.ratingDays, stored ?? 3)
            XCTAssertFalse(model.filter.ratingEnabled)
            model.cancelRatingScan()
        }
    }

    private actor Stub {
        var generation = 0
        var values: [UInt32: PhotoRatingCacheEntry] = [:]
        var reads: [UInt32] = []
        var beginCount = 0
        var endCount = 0
        var readValues: [UInt32: Int?] = [:]

        func invalidate() -> Int { generation += 1; values.removeAll(); return generation }
        func cached(_ handle: UInt32) -> PhotoRatingCacheEntry? { values[handle] }
        func begin() { beginCount += 1 }
        func end() { endCount += 1 }
        func read(_ file: CameraFile) -> Int? {
            reads.append(file.id)
            return readValues[file.id] ?? nil
        }
        func snapshot() -> (Int, Int, Int, [UInt32]) {
            (beginCount, endCount, reads.count, reads)
        }
    }

    private func file(_ id: UInt32, _ name: String, _ date: String) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 1,
                   fileName: name, captureDate: date, isProtected: false)
    }

    private func input(_ files: [CameraFile], sta: Bool = true,
                       loading: Bool = true, readyDays: Int = 0,
                       ratingDays: Int = 3, photoDays: Int = 0,
                       paused: Bool = false) -> PhotoRatingScanInput {
        PhotoRatingScanInput(files: files, paused: paused,
                             useObjectRating: !sta, staConnection: sta,
                             listLoading: loading,
                             recentThumbnailReadyDays: readyDays,
                             ratingDays: ratingDays,
                             photoLoadingDays: photoDays)
    }

    @MainActor
    private func controller(_ stub: Stub) -> PhotoRatingScanController {
        PhotoRatingScanController(io: PhotoRatingScanIO(
            generation: { await stub.generation },
            invalidate: { await stub.invalidate() },
            cached: { await stub.cached($0) },
            beginPhase: { await stub.begin() },
            endPhase: { await stub.end() },
            read: { file, _ in await stub.read(file) }
        ))
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testEffectiveRatingRangeIsIntersectionAndZeroUsesOtherBoundary() {
        XCTAssertEqual(PhotoRatingScanPolicy.effectiveDays(ratingDays: 5, photoLoadingDays: 3), 3)
        XCTAssertEqual(PhotoRatingScanPolicy.effectiveDays(ratingDays: 0, photoLoadingDays: 5), 5)
        XCTAssertEqual(PhotoRatingScanPolicy.effectiveDays(ratingDays: 3, photoLoadingDays: 0), 3)
        XCTAssertEqual(PhotoRatingScanPolicy.effectiveDays(ratingDays: 0, photoLoadingDays: 0), 0)
    }

    func testRatingCacheUsesGenerationAndEvictsOldestAfter8192Values() {
        var cache = PhotoRatingCache()
        let generation = cache.invalidate()
        for handle in 0..<8_193 {
            cache.remember(handle: UInt32(handle), value: handle % 6,
                           origin: "header", generation: generation)
        }
        XCTAssertEqual(cache.count, 8_192)
        XCTAssertNil(cache.value(for: 0))
        XCTAssertEqual(cache.value(for: 1)?.value, 1)
        cache.remember(handle: 9, value: 4, origin: "object-read", generation: generation - 1)
        XCTAssertEqual(cache.value(for: 9)?.origin, "header")
        XCTAssertEqual(cache.invalidate(), generation + 1)
        XCTAssertEqual(cache.count, 0)
    }

    @MainActor
    func testSTAWaitsForRecentDateBoundaryBeforeStartingReadsMainActor() async {
        let stub = Stub()
        let model = controller(stub)
        let first = [file(1, "A.JPG", "20261007T120000")]
        model.update(input(first, readyDays: 0), enabled: true)
        await waitUntil { model.state.waitingForRange }
        let waiting = model.state
        XCTAssertTrue(waiting.loading)
        XCTAssertTrue(waiting.waitingForRange)
        let expanded = first + [file(2, "B.JPG", "20261006T120000"),
                                file(3, "C.JPG", "20261005T120000")]
        model.update(input(expanded, readyDays: 3), enabled: true)
        await waitUntil { model.state.complete }
        XCTAssertTrue(model.state.complete)
        XCTAssertEqual(model.state.total, 3)
        XCTAssertEqual(model.state.completed, 3)
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.2, 3)
    }

    @MainActor
    func testPairReadIsOneSourceButProgressCountsBothVisibleFiles() async {
      for includeIndependent in [false, true] {
        let stub = Stub()
        let model = controller(stub)
        let jpg = file(10, "DSC_0010.JPG", "20261007T120000")
        let raw = CameraFile(id: 11, storageID: 1, format: 0x3802, size: 1,
                             fileName: "DSC_0010.NEF", captureDate: jpg.captureDate,
                             isProtected: false)
        let files = [jpg, raw] + (includeIndependent ? [file(12, "OTHER.JPG", "20261007T120000")] : [])
        model.update(input(files, sta: false, loading: false), enabled: true)
        await waitUntil { model.state.complete }
        XCTAssertTrue(model.state.complete)
        XCTAssertFalse(model.state.loading)
        XCTAssertEqual(model.state.total, files.count)
        XCTAssertEqual(model.state.completed, files.count)
        XCTAssertEqual(model.state.values[10], .unknown)
        XCTAssertEqual(model.state.values[11], .unknown)
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.2, includeIndependent ? 2 : 1)
        XCTAssertEqual(Set(snapshot.3), includeIndependent ? [10, 12] : [10])
        XCTAssertEqual(snapshot.0, 1)
        XCTAssertEqual(snapshot.1, 1)
      }
    }

    @MainActor
    func testRatingReadsFollowFirstSourceAppearanceIncludingRawBeforeJPEG() async {
        for rawFirst in [false, true] {
            let stub = Stub()
            let model = controller(stub)
            let jpg = file(20, "PAIR.JPG", "20261007T120000")
            let raw = file(21, "PAIR.NEF", "20261007T120000")
            let independent = file(30, "OTHER.JPG", "20261006T120000")
            let older = file(40, "OLD.JPG", "20261005T120000")
            let files = rawFirst ? [raw, independent, jpg, older] : [jpg, independent, raw, older]
            model.update(input(files, sta: false, loading: false), enabled: true)
            await waitUntil { model.state.complete }
            XCTAssertTrue(model.state.complete)
            XCTAssertEqual(model.state.completed, 4)
            let snapshot = await stub.snapshot()
            XCTAssertEqual(snapshot.3, [20, 30, 40])
            XCTAssertEqual(snapshot.2, 3)
            model.cancel()
        }
    }

    @MainActor
    func testPhotoListRangeEntryRebuildsEnabledRatingScan() async {
        let savedRange = PhotoFilterPersistence.loadPhotoLoadingRange()
        let savedFilter = PhotoFilterPersistence.load()
        defer {
            PhotoFilterPersistence.savePhotoLoadingRange(savedRange)
            PhotoFilterPersistence.save(savedFilter)
        }
        let stub = Stub()
        let files = (1...5).map { index in
            file(UInt32(index), "\(index).JPG", "2026100\(8 - index)T120000")
        }
        let io = PhotoRatingScanIO(generation: { await stub.generation },
            invalidate: { await stub.invalidate() }, cached: { await stub.cached($0) },
            beginPhase: { await stub.begin() }, endPhase: { await stub.end() },
            read: { file, _ in await stub.read(file) })
        let model = PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1])
        }, setRemoteGate: { _ in }, sequentialLoading: true, ratingIO: io)
        defer { model.cancelRatingScan() }
        model.setPhotoLoadingRange(.one)
        model.load()
        await waitUntil { model.hasCompletedFileScan }
        XCTAssertTrue(model.hasCompletedFileScan)
        var filter = PhotoFilterState()
        filter.ratingEnabled = true
        filter.ratingDays = 5
        model.setFilter(filter)
        for range in [PhotoLoadingRange.one, .five, .one] {
            model.setPhotoLoadingRange(range)
            await waitUntil { model.ratingScan.complete && model.ratingScan.total == range.days }
            XCTAssertTrue(model.ratingScan.complete)
            XCTAssertEqual(model.ratingScan.total, range.days)
            XCTAssertEqual(model.ratingScan.completed, range.days)
        }
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.2, 7)
        XCTAssertEqual(snapshot.0, 3)
        XCTAssertEqual(snapshot.1, 3)
    }

    @MainActor
    func testCancelledReadCannotOverwriteCompletedReplacementScan() async throws {
        let gate = RatingLookupGate()
        let stub = Stub()
        let model = PhotoRatingScanController(io: PhotoRatingScanIO(
            generation: { await stub.generation }, invalidate: { await stub.invalidate() },
            cached: { _ in nil }, beginPhase: { await stub.begin() }, endPhase: { await stub.end() },
            read: { _, _ in await gate.lookup()?.value }))
        let files = [file(1, "A.JPG", "20261007T120000")]
        model.update(input(files, sta: false, loading: false, photoDays: 1), enabled: true)
        for _ in 0..<100 where await gate.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        model.update(input(files, sta: false, loading: false, photoDays: 5), enabled: true)
        for _ in 0..<100 where await gate.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let calls = await gate.calls
        XCTAssertEqual(calls, 2)
        await gate.release(2, value: PhotoRatingCacheEntry(value: 2, origin: "new"))
        await waitUntil { model.state.complete }
        XCTAssertTrue(model.state.complete)
        XCTAssertEqual(model.state.values[1], .known(2))
        await gate.release(1, value: PhotoRatingCacheEntry(value: 5, origin: "old"))
        for _ in 0..<100 {
            if await stub.snapshot().1 == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Both endPhase callbacks prove both reads returned, including the
        // cancelled task which deliberately ignored cancellation while held.
        let phases = await stub.snapshot()
        XCTAssertEqual(phases.0, 2)
        XCTAssertEqual(phases.1, 2)
        XCTAssertTrue(model.state.complete)
        XCTAssertFalse(model.state.loading)
        XCTAssertEqual(model.state.values[1], .known(2))
        model.cancel()
    }

    @MainActor
    func testCancelledCacheLookupCannotSupplyTheReplacementScan() async throws {
        let gate = RatingLookupGate()
        let stub = Stub()
        let model = PhotoRatingScanController(io: PhotoRatingScanIO(
            generation: { await stub.generation }, invalidate: { await stub.invalidate() },
            cached: { _ in await gate.lookup() }, beginPhase: { await stub.begin() },
            endPhase: { await stub.end() }, read: { file, _ in await stub.read(file) }))
        let files = [file(1, "A.JPG", "20261007T120000")]
        model.update(input(files, sta: false, loading: false, photoDays: 1), enabled: true)
        for _ in 0..<100 where await gate.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        model.update(input(files, sta: false, loading: false, photoDays: 5), enabled: true)
        for _ in 0..<100 where await gate.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let calls = await gate.calls
        XCTAssertEqual(calls, 2)
        await gate.release(1, value: PhotoRatingCacheEntry(value: 5, origin: "old"))
        // Wait for the cancelled evaluation to finish consuming its reply;
        // only the replacement evaluation must remain suspended.
        await waitUntil { model.activeEvaluationCount == 1 }
        XCTAssertEqual(model.activeEvaluationCount, 1)
        await gate.release(2, value: nil)
        await waitUntil { model.state.complete }
        XCTAssertTrue(model.state.complete)
        XCTAssertEqual(model.state.values[1], .unknown)
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.3, [1])
        model.cancel()
    }

    @MainActor
    func testGenerationChangedWhileInitialInvalidationIsReturningIsNotLost() async throws {
        let repository = CameraRepository(session: PTPSession(transport: STAScriptTransport([])))
        let gate = RatingLookupGate()
        let stub = Stub()
        let observed = STARecorder<Int>()
        let model = PhotoRatingScanController(io: PhotoRatingScanIO(
            generation: {
                let value = await repository.photoRatingGeneration()
                await observed.append(value)
                return value
            },
            generationUpdates: { await repository.photoRatingGenerationUpdates() },
            invalidate: {
                let value = await repository.invalidatePhotoRatings()
                _ = await gate.lookup()
                return value
            }, cached: { _ in nil }, beginPhase: { await stub.begin() }, endPhase: { await stub.end() },
            read: { file, _ in await stub.read(file) }))
        model.update(input([file(1, "A.JPG", "20261007T120000")], sta: false, loading: false), enabled: true)
        for _ in 0..<100 where await gate.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await gate.calls
        XCTAssertEqual(waiting, 1)
        let newGeneration = await repository.invalidatePhotoRatings()
        XCTAssertEqual(newGeneration, 2)
        await gate.release(1, value: nil)
        for _ in 0..<100 {
            if await observed.values.contains(2), model.state.complete { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let generations = await observed.values
        XCTAssertTrue(generations.contains(2))
        XCTAssertTrue(model.state.complete)
        XCTAssertEqual(model.state.completed, 1)
        let finalGeneration = await repository.photoRatingGeneration()
        XCTAssertEqual(finalGeneration, 2)
        model.cancel()
    }

    @MainActor
    func testRepositoryGenerationNotificationRestartsWithoutAnotherInputUpdate() async {
        let repository = CameraRepository(session: PTPSession(transport: STAScriptTransport([])))
        let session = CameraSession(repository: repository)
        let stub = Stub()
        let model = PhotoRatingScanController(io: PhotoRatingScanIO(
            generation: { await session.photoRatingGeneration() },
            generationUpdates: { await session.photoRatingGenerationUpdates() },
            invalidate: { await session.invalidatePhotoRatings() },
            cached: { _ in nil }, beginPhase: { await stub.begin() }, endPhase: { await stub.end() },
            read: { file, _ in await stub.read(file) }))
        model.update(input([file(1, "A.JPG", "20261007T120000")], sta: false, loading: false), enabled: true)
        await waitUntil { model.state.complete }
        XCTAssertTrue(model.state.complete)
        _ = await repository.invalidatePhotoRatings()
        for _ in 0..<100 {
            if await stub.snapshot().1 == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await waitUntil { model.state.complete }
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.2, 2)
        XCTAssertEqual(snapshot.0, 2)
        XCTAssertEqual(snapshot.1, 2)
        XCTAssertTrue(model.state.complete)
        let generation = await repository.photoRatingGeneration()
        XCTAssertEqual(generation, 2)
        model.cancel()
    }

    @MainActor
    func testEnabledPhotoRangeChangesRebuildWithoutInvalidatingCameraCache() async {
        let stub = Stub()
        let model = controller(stub)
        let files = (1...5).map { index in
            file(UInt32(index), "\(index).JPG", "2026100\(8 - index)T120000")
        }
        for days in [1, 5, 1] {
            model.update(input(files, loading: false, readyDays: 5, ratingDays: 5, photoDays: days), enabled: true)
            await waitUntil { model.state.complete && model.state.total == days }
            XCTAssertTrue(model.state.complete)
            XCTAssertEqual(model.state.total, days)
            XCTAssertEqual(model.state.completed, days)
        }
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.2, 7)
        XCTAssertEqual(snapshot.0, 3)
        XCTAssertEqual(snapshot.1, 3)
        let generation = await stub.generation
        XCTAssertEqual(generation, 1)
        model.update(input(files, loading: false, readyDays: 6, ratingDays: 5, photoDays: 1), enabled: true)
        await Task.yield()
        let unchanged = await stub.snapshot()
        XCTAssertEqual(unchanged.2, 7)
    }

    @MainActor
    func testDisableCancelsReadAndEndsRatingPhaseBeforeNextGeneration() async {
        let stub = Stub()
        let model = controller(stub)
        let first = [file(1, "A.JPG", "20261007T120000")]
        model.update(input(first, sta: false, loading: false), enabled: true)
        await waitUntil { model.state.loading }
        model.update(input(first, sta: false, loading: false), enabled: false)
        await waitUntil { !model.state.loading }
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.0, snapshot.1)
    }
}

private actor RatingLookupGate {
    private(set) var calls = 0
    private var waiters: [Int: CheckedContinuation<PhotoRatingCacheEntry?, Never>] = [:]
    func lookup() async -> PhotoRatingCacheEntry? {
        calls += 1
        let call = calls
        return await withCheckedContinuation { waiters[call] = $0 }
    }
    func release(_ call: Int, value: PhotoRatingCacheEntry?) {
        waiters.removeValue(forKey: call)?.resume(returning: value)
    }
}

@MainActor
final class PhotoListCatalogPerformanceTests: XCTestCase {
    private func file(_ id: UInt32, date: String? = "20261018T120000", ext: String = "JPG") -> CameraFile {
        CameraFile(id: id, storageID: id % 2 + 1, format: 0x3801, size: UInt64(id + 1),
                   fileName: String(format: "DSC_%04d.%@", id, ext), captureDate: date, isProtected: id % 2 == 0)
    }
    private func list(_ files: [CameraFile], ratingIO: PhotoRatingScanIO = .noop) -> PhotoListViewModel {
        PhotoListViewModel(scanCatalog: { _, _, _, _, _ in
            PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                            handleQueriesSucceeded: true, metadataComplete: true, filterStorageIDs: [1, 2])
        }, setRemoteGate: { _ in }, ratingIO: ratingIO)
    }

    func testEveryRatingStillArrivesWithoutRebuildingUnfilteredCatalog() async throws {
        let saved = PhotoFilterPersistence.load()
        let savedRange = PhotoFilterPersistence.loadPhotoLoadingRange()
        defer { PhotoFilterPersistence.save(saved); PhotoFilterPersistence.savePhotoLoadingRange(savedRange) }
        PhotoFilterPersistence.save(PhotoFilterState())
        let files = (1...120).map { file(UInt32($0)) }
        let io = PhotoRatingScanIO(generation: { 0 }, invalidate: { 0 }, cached: { _ in nil },
            beginPhase: {}, endPhase: {}, read: { file, _ in
                try await Task.sleep(for: .milliseconds(2))
                return Int(file.id % 6)
            })
        let model = list(files, ratingIO: io)
        defer { model.cancelRatingScan(); model.cancelLoading() }
        model.setPhotoLoadingRange(.all)
        await model.reload()
        let before = model.sections, grouped = model.catalogGroupingCount
        var sectionUpdates = 0, progressUpdates = 0, rootUpdates = 0
        let sections = model.$sections.dropFirst().sink { _ in sectionUpdates += 1 }
        let progress = model.ratingProgress.objectWillChange.sink { progressUpdates += 1 }
        let root = model.objectWillChange.sink { rootUpdates += 1 }
        defer { sections.cancel(); progress.cancel(); root.cancel() }
        model.setFilter(PhotoFilterState(ratingEnabled: true, ratingDays: 0))
        let baselineRoot = rootUpdates, baselineFilters = model.filteredSectionBuildCount
        for _ in 0..<500 where !model.ratingScan.complete { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.ratingScan.complete)
        XCTAssertEqual(model.ratingScan.completed, 120)
        XCTAssertEqual(model.ratingScan.values.count, 120)
        XCTAssertGreaterThanOrEqual(progressUpdates, 120)
        XCTAssertEqual(model.ratingProgress.snapshot.completed, 120)
        XCTAssertEqual(model.sections, before)
        XCTAssertEqual(sectionUpdates, 0)
        XCTAssertEqual(rootUpdates, baselineRoot)
        XCTAssertEqual(model.catalogGroupingCount, grouped)
        XCTAssertEqual(model.filteredSectionBuildCount, baselineFilters)
        model.setFilter(PhotoFilterState(ratingEnabled: true, rating: 5, ratingDays: 0))
        XCTAssertEqual(model.sections.flatMap(\.files).map(\.id), files.filter { $0.id % 6 == 5 }.map(\.id))
        XCTAssertEqual(sectionUpdates, 1)
        XCTAssertEqual(model.catalogGroupingCount, grouped)
        model.setFilter(PhotoFilterState(ratingEnabled: true, ratingDays: 0))
        XCTAssertEqual(model.sections, before)
        XCTAssertEqual(sectionUpdates, 2)
    }

    func testCachedOrderMatchesOriginalFilterThenSortAcrossScopeAndMetadataChanges() async throws {
        let saved = PhotoFilterPersistence.load()
        let savedRange = PhotoFilterPersistence.loadPhotoLoadingRange()
        defer { PhotoFilterPersistence.save(saved); PhotoFilterPersistence.savePhotoLoadingRange(savedRange) }
        PhotoFilterPersistence.save(PhotoFilterState())
        var files = (1...90).map { index -> CameraFile in
            let day = 18 - index / 30
            let stamp = index % 17 == 0 ? nil : String(format: "202610%02dT1200%02d", day, index % 30)
            return file(UInt32(index), date: stamp, ext: index % 7 == 0 ? "NEF" : "JPG")
        }
        // Equal timestamps must keep camera enumeration order, including JPEG/RAW.
        files += [file(300, date: nil), file(302), file(301)]
        let model = list(files)
        defer { model.cancelRatingScan(); model.cancelLoading() }
        model.setPhotoLoadingRange(.all)
        await model.reload()
        let grouped = model.catalogGroupingCount
        for i in 0..<120 {
            let criteria = PhotoFilterState(extensions: i % 3 == 0 ? [".jpg"] : nil,
                protectedOnly: i % 4 == 0, burstOnly: i % 5 == 0, untransferredOnly: i % 7 == 0,
                storageSlot: i % 2 == 0 ? 1 : nil,
                dateRange: i % 6 == 0 ? PhotoDateRange(start: "20261017", end: "20261018") : nil)
            model.setFilter(criteria)
            let reference = PhotoCatalogGrouping.byCaptureDay(PhotoFilter.apply(model.displayedFiles, state: model.filter,
                storageIDsBySlot: [1: [1], 2: [2]]))
            XCTAssertEqual(model.sections, reference, "Filter case \(i)")
        }
        XCTAssertEqual(model.catalogGroupingCount, grouped)
        model.clearFilter()
        for _ in 0..<5 { await model.applyCatalogUpdate(files) }
        XCTAssertEqual(model.catalogGroupingCount, grouped)
        files[0] = file(files[0].id, date: "20261019T120000", ext: "NEF")
        files.remove(at: 2)
        await model.applyCatalogUpdate(files)
        XCTAssertEqual(model.catalogGroupingCount, grouped + 1)
        XCTAssertEqual(model.sections, PhotoCatalogGrouping.byCaptureDay(files))
        model.setPhotoLoadingRange(.one)
        XCTAssertEqual(model.sections, PhotoCatalogGrouping.byCaptureDay(files.filter {
            $0.captureDate == nil || $0.captureDate?.hasPrefix("20261019") == true
        }))
        model.setPhotoLoadingRange(.all)
        XCTAssertEqual(model.sections, PhotoCatalogGrouping.byCaptureDay(files))
    }
}
