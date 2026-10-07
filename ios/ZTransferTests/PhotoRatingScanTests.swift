import XCTest
@testable import ZTransfer

final class PhotoRatingScanTests: XCTestCase {
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
        let stub = Stub()
        let model = controller(stub)
        let jpg = file(10, "DSC_0010.JPG", "20261007T120000")
        let raw = CameraFile(id: 11, storageID: 1, format: 0x3802, size: 1,
                             fileName: "DSC_0010.NEF", captureDate: jpg.captureDate,
                             isProtected: false)
        model.update(input([jpg, raw], sta: false, loading: false), enabled: true)
        await waitUntil { model.state.complete }
        XCTAssertEqual(model.state.total, 2)
        XCTAssertEqual(model.state.completed, 2)
        XCTAssertEqual(model.state.values[10], .unknown)
        XCTAssertEqual(model.state.values[11], .unknown)
        let snapshot = await stub.snapshot()
        XCTAssertEqual(snapshot.2, 1)
        XCTAssertEqual(snapshot.3, [10])
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
