import XCTest
@testable import ZTransfer

final class RemoteReviewCatalogTests: XCTestCase {
    @MainActor
    func testFramePauseWaitsForAcceptedPacketAndBlocksNextRead() async throws {
        let gate = RemoteReviewFrameGate()
        let entered = GateTestLatch(), release = GateTestLatch()
        let frame = Task {
            try await gate.withFrame { await entered.signal(); await release.wait() }
        }
        await entered.wait()
        gate.pause()
        var idle = false
        let idleTask = Task { try await gate.awaitIdle(); idle = true }
        var nextStarted = false
        let next = Task { try await gate.withFrame { nextStarted = true } }
        await Task.yield()
        XCTAssertFalse(idle)
        XCTAssertFalse(nextStarted)
        await release.signal()
        try await frame.value
        try await idleTask.value
        XCTAssertFalse(nextStarted)
        gate.resume()
        try await next.value
        XCTAssertTrue(nextStarted)
    }

    @MainActor
    func testCancelledPausedFrameDoesNotReadAndFailureReleasesGate() async throws {
        let gate = RemoteReviewFrameGate()
        gate.pause()
        var calls = 0
        let old = Task { try await gate.withFrame { calls += 1 } }
        await Task.yield()
        old.cancel()
        do { try await old.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        gate.resume()
        do {
            try await gate.withFrame { throw CameraRepositoryError.invalidDataset }
            XCTFail("Expected failure")
        } catch CameraRepositoryError.invalidDataset {}
        gate.pause()
        try await gate.awaitIdle()
        gate.resume()
        try await gate.withFrame { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    private func file(_ id: UInt32, _ name: String, _ date: String? = "20261015T120003") -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 100, fileName: name,
                   captureDate: date, isProtected: false)
    }
    func testPairsRawJPEGAndBackupsWithoutMergingDistinctCaptures() {
        let raw = file(1, "DSC_0001.NEF")
        let jpeg = file(2, "dsc_0001.jpg")
        let result = reviewPhotos([raw, jpeg, file(3, "dsc_0001.jpg"),
                                   file(4, "dsc_0001.jpg", "20261015T120002"), file(5, "movie.mov")])
        XCTAssertEqual(result.map(\.id), [1, 4])
        XCTAssertEqual(result[0].file, jpeg)
        XCTAssertEqual(result[0].pairedRawExtension, ".nef")
    }
    func testUnknownAndPartialDatesUseUnambiguousCompanionsOnly() {
        XCTAssertEqual(reviewPhotos([file(1, "A.NEF", nil), file(2, "a.jpg", nil)]).count, 1)
        XCTAssertEqual(reviewPhotos([file(1, "A.NEF", nil), file(2, "a.nef", nil),
                                      file(3, "a.jpg", nil)]).count, 3)
        let result = reviewPhotos([file(1, "A.NEF", "20261015"),
                                   file(2, "a.jpg", "20261015T120003.120"),
                                   file(3, "a.jpg", "20261015T120003")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].captureDate, "20261015T120003")
    }
    func testDualCardPairIsCompleteBeforePublishingFirstPage() async throws {
        let files = [file(1, "A.NEF"), file(2, "B.NEF", "20261015T120002"),
                     file(3, "A.JPG"), file(4, "B.JPG", "20261015T120002")]
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let catalog = RemoteReviewCatalog(handlesByStorage: [[1, 2], [3, 4]]) { byID[$0] }
        let first = try await catalog.loadNextPage(pageSize: 1)
        XCTAssertEqual(first.map(\.file.id), [3])
        let more = await catalog.hasMore
        XCTAssertTrue(more)
        let second = try await catalog.loadNextPage(pageSize: 1)
        XCTAssertEqual(second.map(\.file.id), [3, 4])
        let remaining = await catalog.hasMore
        XCTAssertFalse(remaining)
    }
    func testPagingReadsOnlyLookaheadAndLateCompanionKeepsStableIdentity() async throws {
        actor Reads {
            var handles: [UInt32] = []
            func record(_ id: UInt32) { handles.append(id) }
        }
        let reads = Reads()
        let files = (1...30).map { id in file(UInt32(id), "\(id).JPG", String(format: "20261015T1200%02d", 31 - id)) }
        let catalog = RemoteReviewCatalog(handlesByStorage: [files.map(\.id)]) { id in
            await reads.record(id)
            return files[Int(id) - 1]
        }
        let first = try await catalog.loadNextPage(pageSize: 3)
        XCTAssertEqual(first.map(\.id), [1, 2, 3])
        let initialReads = await reads.handles
        XCTAssertEqual(initialReads, [1, 2, 3, 4])
        let next = try await catalog.loadNextPage(pageSize: 3)
        XCTAssertEqual(Array(next.prefix(3)), first)
        let allReads = await reads.handles
        XCTAssertEqual(Set(allReads).count, allReads.count)

        let late = [file(1, "A.NEF", nil), file(2, "B.JPG", nil), file(3, "A.JPG", nil)]
        let lateCatalog = RemoteReviewCatalog(handlesByStorage: [[1, 2, 3]]) { late[Int($0) - 1] }
        let raw = try await lateCatalog.loadNextPage(pageSize: 1)
        let paired = try await lateCatalog.loadNextPage(pageSize: 3)
        XCTAssertEqual(paired.map(\.file.id), [3, 2])
        XCTAssertEqual(paired.first?.id, raw.first?.id)
        XCTAssertEqual(paired.first?.pairedRawExtension, ".nef")
        let rawPages = photoPreviewPages(raw.map { .photo($0.file) }, reviewPhotos: raw)
        let pairedPages = photoPreviewPages(paired.map { .photo($0.file) }, reviewPhotos: paired)
        XCTAssertEqual(rawPages.first?.id, pairedPages.first?.id, "Late JPEG must not recreate the pager/gesture state")
        XCTAssertEqual(pairedPages.first?.entry.file?.id, 3, "I/O must still switch to the preferred JPEG")
        XCTAssertEqual(pairedPages.map(\.index), [0, 1])
        XCTAssertEqual(photoPreviewPages([.photo(late[0])]).first?.id, "photo_1", "Normal preview identity is unchanged")
    }

    func testMissingDateDualCardCompanionPublishesTogetherAndVideoOnlyCatalogEnds() async throws {
        for date in [Optional<String>.none, "20261015T120003"] {
            let files = [file(1, "A.NEF", nil), file(2, "B.NEF", nil), file(3, "A.JPG", date), file(4, "B.JPG", nil)]
            let catalog = RemoteReviewCatalog(handlesByStorage: [[1, 2], [3, 4]]) { files[Int($0) - 1] }
            let first = try await catalog.loadNextPage(pageSize: 1)
            XCTAssertEqual(first.map(\.file.id), [3])
            XCTAssertEqual(first.first?.pairedRawExtension, ".nef")
            let all = try await catalog.loadNextPage(pageSize: 1)
            XCTAssertEqual(all.map(\.file.id), [3, 4])
        }
        let video = file(2, "A.MOV")
        let catalog = RemoteReviewCatalog(handlesByStorage: [[1, 2]]) { $0 == 1 ? nil : video }
        let photos = try await catalog.loadNextPage()
        let more = await catalog.hasMore
        XCTAssertTrue(photos.isEmpty)
        XCTAssertFalse(more)
    }
    func testCancelledQueuedPageDoesNotWaitForOrCancelActiveRead() async throws {
        let entered = GateTestLatch(), release = GateTestLatch()
        let photo = file(1, "A.JPG")
        let catalog = RemoteReviewCatalog(handlesByStorage: [[1]]) { _ in
            await entered.signal()
            await release.wait()
            return photo
        }
        let first = Task { try await catalog.loadNextPage() }
        await entered.wait()
        let second = Task { try await catalog.loadNextPage() }
        await Task.yield()
        second.cancel()
        do { _ = try await second.value; XCTFail("Cancelled waiter must throw") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await release.signal()
        let completed = try await first.value
        XCTAssertEqual(completed.map(\.id), [1])
    }

    func testReadFailureKeepsCursorAndPendingGroupRetryable() async throws {
        actor Reader {
            var failed = false
            let files: [UInt32: CameraFile]
            init(_ files: [UInt32: CameraFile]) { self.files = files }
            func read(_ id: UInt32) throws -> CameraFile? {
                if id == 2 && !failed { failed = true; throw CameraRepositoryError.invalidDataset }
                return files[id]
            }
        }
        let reader = Reader([1: file(1, "A.JPG"), 2: file(2, "B.JPG", "20261015T120002")])
        let catalog = RemoteReviewCatalog(handlesByStorage: [[1, 2]]) { try await reader.read($0) }
        do { _ = try await catalog.loadNextPage(); XCTFail("Expected injected read failure") } catch {}
        let recovered = try await catalog.loadNextPage()
        XCTAssertEqual(recovered.map(\.id), [1, 2])
    }
}
