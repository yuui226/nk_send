import XCTest
@testable import ZTransfer

final class PhotoThumbnailQueueEfficiencyTests: XCTestCase, @unchecked Sendable {
    func testLoadingRangeReusesDateProjectionAndInvalidatesForEveryCatalogChange() {
        func dated(_ id: UInt32, _ date: String?, protected: Bool = false) -> CameraFile {
            CameraFile(id: id, storageID: 1, format: 0x3801, size: 1,
                fileName: "\(id).JPG", captureDate: date, isProtected: protected)
        }
        var catalog = PhotoFileCatalog()
        catalog.replaceAll([dated(1, "20261028T120000"), dated(2, "20261031T120000")])
        XCTAssertEqual(catalog.loadingRange(days: 1), .init(start: "20261031", end: "20261031"))
        for _ in 0..<100 { _ = catalog.loadingRange(days: 1) }
        XCTAssertEqual(catalog.loadingRangeBuildCount, 1)
        catalog.upsert(dated(2, "20261031T120000", protected: true))
        _ = catalog.loadingRange(days: 1)
        XCTAssertEqual(catalog.loadingRangeBuildCount, 1, "Protection changes do not change the date scope")
        var retained = catalog
        catalog.upsert(dated(2, "20261027T120000"))
        XCTAssertEqual(catalog.loadingRange(days: 1), .init(start: "20261028", end: "20261028"))
        XCTAssertEqual(retained.loadingRange(days: 1), .init(start: "20261031", end: "20261031"))
        catalog.upsert(dated(3, "20261101T120000"))
        XCTAssertEqual(catalog.loadingRange(days: 3), .init(start: "20261027", end: "20261101"))
        XCTAssertNil(catalog.loadingRange(days: 0))
        XCTAssertEqual(catalog.loadingRange(days: 1), .init(start: "20261101", end: "20261101"))
        catalog.replaceAll([dated(1, "20261028T120000")])
        XCTAssertEqual(catalog.loadingRange(days: 1), .init(start: "20261028", end: "20261028"))
        catalog.replaceAll([dated(4, "20260230"), dated(5, nil)])
        XCTAssertNil(catalog.loadingRange(days: 1))
        let builds = catalog.loadingRangeBuildCount
        XCTAssertNil(catalog.loadingRange(days: 1))
        XCTAssertEqual(catalog.loadingRangeBuildCount, builds, "An invalid-date catalog must cache nil too")
        catalog.clear()
        XCTAssertNil(catalog.loadingRange(days: 1))
        catalog.upsert(dated(6, "20260101"))
        XCTAssertEqual(catalog.loadingRange(days: 1), .init(start: "20260101", end: "20260101"))
    }

    func testLargeBatchLoadingRangeCostUsesOneProjection() {
        let files = (1...8_000).map { id in
            CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 1,
                fileName: "\(id).JPG", captureDate: String(format: "202610%02dT120000", id % 31 + 1), isProtected: false)
        }
        let clock = ContinuousClock()
        let start = clock.now
        var expected: PhotoDateRange?
        for _ in 0..<128 { expected = newestCaptureDaysRange(files, days: 5) }
        let baseline = start.duration(to: clock.now)
        var catalog = PhotoFileCatalog()
        catalog.replaceAll(files)
        let cachedStart = clock.now
        for _ in 0..<128 { XCTAssertEqual(catalog.loadingRange(days: 5), expected) }
        let cached = cachedStart.duration(to: clock.now)
        XCTAssertEqual(catalog.loadingRangeBuildCount, 1)
        print("Review loading range: 8000 files / 128 admissions, original=\(baseline), cached=\(cached)")
    }

    func testVisibleCompletionsPreserveBothLaneOrdersAndPendingCount() async {
        for sequential in [false, true] {
            let queue = PhotoThumbnailFillQueue(sequential: sequential)
            await queue.seed((1...5).map(file), priorityRange: .init(start: "20260801", end: "20260802"))
            await queue.markSettled(2); await queue.markSettled(4); await queue.markSettled(4)
            let state = await queue.state()
            XCTAssertEqual(state.pending, [1, 3, 5])
            let drained = await drain(queue)
            XCTAssertEqual(drained, sequential ? [1, 3, 5] : [1, 5, 3])
            let after = await queue.state()
            XCTAssertTrue(after.pending.isEmpty)
        }
    }

    func testSettledEntriesCannotReturnAfterReprioritizingOrChangingRange() async {
        let queue = PhotoThumbnailFillQueue()
        let files = (1...5).map(file)
        await queue.seed(files)
        await queue.markSettled(2); await queue.markSettled(4)
        await queue.updatePriorityRange(files, range: .init(start: "20260801", end: "20260802"))
        let range = PhotoDateRange(start: "20260802", end: "20260805")
        await queue.updateLoadingRange(files, range: range)
        await queue.seed(files, loadingRange: range)
        let state = await queue.state()
        XCTAssertEqual(state.pending, [3, 5])
        let drained = await drain(queue)
        XCTAssertEqual(drained, [5, 3])
    }

    func testRemovedSettledHandleGetsOneNewOwnerAndNoOldLaneEntry() async throws {
        let queue = PhotoThumbnailFillQueue()
        await queue.seed((1...3).map(file))
        await queue.markSettled(2)
        await queue.remove([2])
        let replacement = CameraFile(id: 2, storageID: 1, format: 0x3801, size: 99,
            fileName: "REUSED.JPG", captureDate: "20260802T120000", isProtected: false)
        await queue.enqueueNew([replacement])
        let first = await queue.poll()
        XCTAssertEqual(first?.id, 2)
        let rest = await drain(queue)
        XCTAssertEqual(rest, [3, 1])
    }

    func testPausedWorkReturnsOnceAndVisibleCompletionCancelsReturn() async throws {
        let queue = PhotoThumbnailFillQueue()
        await queue.seed((1...3).map(file))
        await queue.markSettled(2)
        let polled = await queue.poll()
        let work = try XCTUnwrap(polled)
        await queue.returnToFront(work.id, expectedRevision: work.revision, owner: work.owner)
        await queue.returnToFront(work.id, expectedRevision: work.revision, owner: work.owner)
        let resumed = await queue.poll()
        XCTAssertEqual(resumed?.id, work.id)
        await queue.markSettled(work.id)
        await queue.returnToFront(work.id, expectedRevision: work.revision, owner: work.owner)
        let rest = await drain(queue)
        XCTAssertEqual(rest, [1])
    }

    func testVisibleCompletionRetiresPendingFailureAndAllSettledLaneDrains() async {
        let queue = PhotoThumbnailFillQueue()
        await queue.seed((1...5).map(file))
        await queue.markFailed(2)
        await queue.markSettled(2)
        await queue.retryFailed()
        let failed = await queue.state().failed
        XCTAssertTrue(failed.isEmpty)
        for id: UInt32 in [1, 3, 4, 5] { await queue.markSettled(id) }
        let state = await queue.state()
        XCTAssertTrue(state.pending.isEmpty)
        let next = await queue.poll()
        XCTAssertNil(next)
        await queue.enqueueNew([file(6)])
        let newlyAdded = await queue.poll()
        XCTAssertEqual(newlyAdded?.id, 6, "A lane drained from a nonzero slice index must still accept new objects")
    }

    func testCatalogCompletionAndDrainCostWithoutRevisitingSettledObjects() async {
        let clock = ContinuousClock()
        for count in [2_000, 8_000] {
            let queue = PhotoThumbnailFillQueue(sequential: true)
            let files = (1...count).map { id in
                CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 1,
                    fileName: "\(id).JPG", captureDate: "20260801T120000", isProtected: false)
            }
            await queue.seed(files)
            let start = clock.now
            for photo in files where photo.id.isMultiple(of: 2) { await queue.markSettled(photo.id) }
            let completed = clock.now
            let drained = await drain(queue)
            let end = clock.now
            XCTAssertEqual(drained, stride(from: UInt32(1), to: UInt32(count), by: 2).map { $0 })
            print("N23 fill count=\(count) visibleCompletion=\(start.duration(to: completed)) drain=\(completed.duration(to: end))")
        }
    }

    private func file(_ id: UInt32) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 1,
            fileName: "\(id).JPG", captureDate: String(format: "202608%02dT120000", id), isProtected: false)
    }
    private func drain(_ queue: PhotoThumbnailFillQueue) async -> [UInt32] {
        var result: [UInt32] = []
        while let next = await queue.poll() { result.append(next.id) }
        return result
    }
}
