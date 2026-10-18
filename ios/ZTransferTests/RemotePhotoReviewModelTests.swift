import XCTest
import Combine
import SwiftUI
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
    func testSnapshotReusedDuringLoadingAndLateJPEGKeepsCaptureIdentity() async throws {
        let raw = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
            fileName: "A.NEF", captureDate: nil, isProtected: false)
        let others = (2...13).map { id in CameraFile(id: UInt32(id), storageID: 1, format: 0x3801,
            size: 100, fileName: "B\(id).JPG", captureDate: nil, isProtected: false) }
        let jpeg = CameraFile(id: 14, storageID: 1, format: 0x3801, size: 100,
            fileName: "a.jpg", captureDate: nil, isProtected: false)
        let files = [raw] + others + [jpeg]
        let model = RemotePhotoReviewModel(frames: RemoteReviewFrameGate(), openCatalog: {
            RemoteReviewCatalog(handlesByStorage: [files.map(\.id)]) { id in files[Int(id) - 1] }
        }, endLiveView: {}, restartLiveView: {}, isConnected: { true })
        let lifetime = RemotePhotoReviewLifetime(model)
        var pageUpdates = 0
        let observer = lifetime.objectWillChange.sink { pageUpdates += 1 }
        defer { observer.cancel() }
        model.open()
        try await settled(model)
        XCTAssertEqual(pageUpdates, 1)
        let initial = model.displaySnapshot
        let address = initial.files.withUnsafeBufferPointer { $0.baseAddress }
        XCTAssertEqual(initial.files.count, 12)
        XCTAssertEqual(initial.files.first?.id, 1)
        for _ in 0..<120 {
            XCTAssertTrue(model.displaySnapshot === initial)
            XCTAssertEqual(model.displaySnapshot.files.withUnsafeBufferPointer { $0.baseAddress }, address)
        }
        model.loadMore()
        XCTAssertTrue(model.displaySnapshot === initial, "Loading state alone must not discard the catalog")
        try await settled(model)
        let complete = model.displaySnapshot
        XCTAssertFalse(complete === initial)
        XCTAssertEqual(complete.files.count, 13)
        XCTAssertEqual(complete.files.first?.id, 14)
        XCTAssertEqual(complete.photosByPreferredHandle[14]?.pairedRawExtension, ".nef")
        XCTAssertEqual(complete.captureByHandle[1], 1)
        XCTAssertEqual(complete.captureByHandle[14], 1)
        let before = photoPreviewPages(initial.files.map { .photo($0) }, captureByHandle: initial.captureByHandle)
        let after = photoPreviewPages(complete.files.map { .photo($0) }, captureByHandle: complete.captureByHandle)
        XCTAssertEqual(before.first?.id, after.first?.id)
        XCTAssertEqual(after.first?.entry.file?.id, 14)
        XCTAssertEqual(pageUpdates, 1, "The underlying monitor observes only open/close")
        for _ in 0..<120 { model.loadMore() }
        XCTAssertTrue(model.displaySnapshot === complete)
        await model.close()
        XCTAssertEqual(pageUpdates, 2)
        model.open()
        XCTAssertTrue(model.displaySnapshot.files.isEmpty)
        try await settled(model)
        XCTAssertEqual(model.displaySnapshot.files.first?.id, 1)
        await model.close()
    }

    func testActualReviewLoadingAndRetryUpdateSurfaceWithoutUpdatingMonitor() async throws {
        var fail = true
        let photo = photo()
        let model = RemotePhotoReviewModel(frames: RemoteReviewFrameGate(), openCatalog: {
            if fail { throw CameraRepositoryError.invalidDataset }
            return RemoteReviewCatalog(handlesByStorage: [[1]]) { _ in photo }
        }, endLiveView: {}, restartLiveView: {}, isConnected: { true })
        let lifetime = RemotePhotoReviewLifetime(model)
        let name = "review-surface-\(UUID())"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let transfer = await Task.detached { TransferQueue(defaults: UserDefaults(suiteName: name)!) }.value
        let queue = TransferQueueViewModel(queue: transfer)
        let session = CameraSession(repository: CameraRepository(session: PTPSession(transport: STAScriptTransport([]))))
        let counter = ReviewBodyCounter()
        let host = UIHostingController(rootView: ReviewHarness(lifetime: lifetime, queue: queue, session: session, counter: counter))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        model.open()
        try await Task.sleep(for: .milliseconds(80))
        let loading = reviewSnapshot(window)
        let count = counter.value
        try await settled(model)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.failed)
        let failed = reviewSnapshot(window)
        XCTAssertNotEqual(loading, failed, "Real loading and retry controls must render despite root isolation")
        XCTAssertEqual(counter.value, count)
        fail = false
        model.retry()
        try await settled(model)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertFalse(model.failed)
        XCTAssertNotEqual(failed, reviewSnapshot(window))
        XCTAssertEqual(counter.value, count)
        await model.close()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(counter.value, count)
    }

    func testReviewLifetimeObservationDoesNotRetainItsOwner() {
        weak var weakModel: RemotePhotoReviewModel?
        weak var weakLifetime: RemotePhotoReviewLifetime?
        do {
            let model = RemotePhotoReviewModel(frames: RemoteReviewFrameGate(), openCatalog: {
                RemoteReviewCatalog(handlesByStorage: []) { _ in nil }
            }, endLiveView: {}, restartLiveView: {}, isConnected: { true })
            let lifetime = RemotePhotoReviewLifetime(model)
            weakModel = model; weakLifetime = lifetime
        }
        XCTAssertNil(weakLifetime)
        XCTAssertNil(weakModel)
    }

    private final class ReviewBodyCounter { var value = 0 }
    private struct ReviewHarness: View {
        @ObservedObject var lifetime: RemotePhotoReviewLifetime
        let queue: TransferQueueViewModel
        let session: CameraSession
        let counter: ReviewBodyCounter
        var body: some View {
            counter.value += 1
            return ZStack {
                Color.gray
                if lifetime.active {
                    RemotePhotoReviewView(model: lifetime.review, session: session, queue: queue, connected: false)
                }
            }
        }
    }
    private func reviewSnapshot(_ window: UIWindow) -> Data? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.pngData()
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
