import XCTest
@testable import ZTransfer

@MainActor
final class RemotePhotoReviewModelTests: XCTestCase {
    private func photo(_ id: UInt32 = 1) -> CameraFile {
        CameraFile(id: id, storageID: 1, format: 0x3801, size: 100,
                   fileName: "A.JPG", captureDate: "20261015T120003", isProtected: false)
    }
    private func settled(_ model: RemotePhotoReviewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.loading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.loading)
    }
    func testEmptyCatalogStopsLiveViewOnceAndCloseRestarts() async throws {
        let gate = RemoteReviewFrameGate()
        var reads = 0, stops = 0, restarts = 0
        let file = photo()
        let model = RemotePhotoReviewModel(frames: gate, openCatalog: {
            reads += 1
            return RemoteReviewCatalog(handlesByStorage: reads == 1 ? [] : [[1]]) { _ in file }
        }, endLiveView: { stops += 1 }, restartLiveView: { restarts += 1 }, isConnected: { true })
        model.open()
        try await settled(model)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(model.photos.map(\.id), [1])
        await model.close()
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(model.active)
        let resumed = try await gate.withFrame { true }
        XCTAssertTrue(resumed)
    }

    func testFailureCanRetryWithoutRepeatingCompatibilityStop() async throws {
        var reads = 0, stops = 0
        let file = photo()
        let model = RemotePhotoReviewModel(frames: RemoteReviewFrameGate(), openCatalog: {
            reads += 1
            if reads <= 2 { throw CameraRepositoryError.invalidDataset }
            return RemoteReviewCatalog(handlesByStorage: [[1]]) { _ in file }
        }, endLiveView: { stops += 1 }, restartLiveView: {}, isConnected: { true })
        model.open()
        try await settled(model)
        XCTAssertTrue(model.failed)
        model.retry()
        try await settled(model)
        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertEqual(stops, 1)
        await model.close()
    }

    func testCloseWaitsForAcceptedReadAndDiscardsLateCatalog() async throws {
        let entered = GateTestLatch(), release = GateTestLatch()
        let file = photo()
        let model = RemotePhotoReviewModel(frames: RemoteReviewFrameGate(), openCatalog: {
            await entered.signal()
            await release.wait()
            return RemoteReviewCatalog(handlesByStorage: [[1]]) { _ in file }
        }, endLiveView: {}, restartLiveView: {}, isConnected: { true })
        model.open()
        await entered.wait()
        let closing = Task { await model.close() }
        await Task.yield()
        await release.signal()
        await closing.value
        XCTAssertFalse(model.active)
        XCTAssertTrue(model.photos.isEmpty)
    }

    func testPreviewFailureSharesCompatibilityStopAndRejectsDisconnectedResult() async throws {
        let file = photo()
        var connected = true, stops = 0, previews = 0, restarts = 0
        let model = RemotePhotoReviewModel(frames: RemoteReviewFrameGate(), openCatalog: {
            RemoteReviewCatalog(handlesByStorage: [[1]]) { _ in file }
        }, endLiveView: { stops += 1 }, restartLiveView: { restarts += 1 }, isConnected: { connected })
        model.open()
        try await settled(model)
        let result: Int? = try await model.preview {
            previews += 1
            return previews == 1 ? nil : 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(stops, 1)
        do {
            let _: Int? = try await model.preview { connected = false; return 9 }
            XCTFail("Disconnected result must be rejected")
        } catch is CancellationError {}
        await model.close()
        XCTAssertEqual(restarts, 0, "A disconnected camera must not restart Live View")
    }
}
