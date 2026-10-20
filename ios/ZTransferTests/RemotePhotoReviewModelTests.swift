import XCTest
import Combine
import SwiftUI
@testable import ZTransfer

@MainActor
final class RemoteReviewPresentationTests: XCTestCase {
    func testRGBHistogramRendersFilledChannelsAndThreeColorMark() throws {
        let bins: [[CGFloat]] = [0.9, 0.6, 0.3].map { [CGFloat](repeating: $0, count: 256) }
        let renderer = ImageRenderer(content: VStack(spacing: 8) {
            HStack(spacing: 24) {
                PreviewControlMark(icon: .histogram, histogramRGB: true).frame(width: 20, height: 20)
                PreviewControlMark(icon: .histogram).frame(width: 20, height: 20)
            }
            PreviewHistogramOverlay(values: bins[1], rgb: bins, mode: .rgb)
            PreviewHistogramOverlay(values: bins[1], rgb: bins, mode: .luma)
        }.padding(8).background(Color.black))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-review-histograms.png"))
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var redArea = 0, greenMark = 0, blueMark = 0, lumaArea = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
            if r > 45 && r > g * 2 && r > b * 2 { redArea += 1 }
            if g > 100 && g > r * 13 / 10 && g > b * 13 / 10 { greenMark += 1 }
            if b > 120 && b > r * 13 / 10 && b > g * 13 / 10 { blueMark += 1 }
            if r > 35 && abs(r-g) < 5 && abs(g-b) < 5 { lumaArea += 1 }
        }
        XCTAssertGreaterThan(redArea, 4_000, "RGB must contain filled areas, not just thin lines")
        XCTAssertGreaterThan(greenMark, 20)
        XCTAssertGreaterThan(blueMark, 20)
        XCTAssertGreaterThan(lumaArea, 10_000, "Luma keeps Android's original filled white curve")
    }

    func testSafeInsetsRotateWithFullBlackCanvas() {
        let safe = EdgeInsets(top: 59, leading: 3, bottom: 34, trailing: 5)
        let values = (0...2).map { RemoteReviewLayout(size: .init(width: 382, height: 751), safe: safe, rotation: $0) }
        XCTAssertTrue(values.allSatisfy { $0.physicalSize == CGSize(width: 390, height: 844) })
        XCTAssertEqual(values[0].canvasSize, CGSize(width: 390, height: 844))
        XCTAssertEqual(values[1].canvasSize, CGSize(width: 844, height: 390))
        XCTAssertEqual(values[2].canvasSize, values[1].canvasSize)
        XCTAssertEqual(values[0].contentInsets, safe)
        XCTAssertEqual(values[1].contentInsets, EdgeInsets(top: 5, leading: 59, bottom: 3, trailing: 34))
        XCTAssertEqual(values[2].contentInsets, EdgeInsets(top: 3, leading: 34, bottom: 5, trailing: 59))
    }

    func testReviewTapGuardRejectsPagingReturnAndPinchUntilNextTouch() {
        let state = PreviewReviewTapGuard()
        XCTAssertFalse(state.allowed)
        state.begin(.init(x: 100, y: 100))
        state.observe([.init(x: 140, y: 100)])
        state.observe([.init(x: 100, y: 100)])
        XCTAssertFalse(state.allowed)
        state.begin(.init(x: 100, y: 100))
        state.observe([.init(x: 102, y: 101)])
        XCTAssertTrue(state.allowed)
        state.observe([.init(x: 100, y: 100), .init(x: 110, y: 100)])
        state.observe([.init(x: 100, y: 100)])
        XCTAssertFalse(state.allowed)
        state.begin(.zero)
        state.observe([.init(x: 8, y: 0)])
        XCTAssertTrue(state.allowed)
        state.observe([])
        XCTAssertFalse(state.allowed)
    }

    func testDismissalRetainsGateUntilFadeEndsAndCancellationDoesNotClose() async throws {
        var closed = 0
        let dismissal = RemoteReviewDismissal { closed += 1 }
        dismissal.requestClose()
        try await Task.sleep(for: .milliseconds(120))
        dismissal.requestClose()
        XCTAssertTrue(dismissal.closing)
        XCTAssertEqual(closed, 0)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(closed, 1, "Repeated close did not restart the 260ms deadline")
        dismissal.requestClose()
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertEqual(closed, 1)
        let cancelled = RemoteReviewDismissal { closed += 1 }
        cancelled.requestClose(); cancelled.cancel()
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertEqual(closed, 1)
    }

    func testEmptyAndUndecodableFHDUseCompatibilityFallbackBeforePublishing() async throws {
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: .init(width: 9, height: 6)).image { context in
            UIColor.green.setFill(); context.fill(.init(x: 0, y: 0, width: 9, height: 6))
        }.jpegData(compressionQuality: 0.9))
        for invalid in [Data(), Data([0, 1, 2])] {
            var stops = 0, restarts = 0, reads = 0
            let photo = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                fileName: "A.JPG", captureDate: nil, isProtected: false)
            let model = RemotePhotoReviewModel(frames: RemoteReviewFrameGate(), openCatalog: {
                RemoteReviewCatalog(handlesByStorage: [[1]]) { _ in photo }
            }, endLiveView: { stops += 1 }, restartLiveView: { restarts += 1 }, isConnected: { true })
            model.open()
            while model.loading { try await Task.sleep(for: .milliseconds(10)) }
            let content = try await loadRemoteReviewPreview(model) {
                reads += 1
                return reads == 1 ? invalid : jpeg
            }
            XCTAssertNotNil(content)
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(stops, 1)
            _ = try await loadRemoteReviewPreview(model) { Data() }
            XCTAssertEqual(stops, 1, "Enumeration and both preview paths share one compatibility stop")
            await model.close()
            XCTAssertEqual(restarts, 1)
        }
    }

    func testActualFHDSurfaceUsesLandscapeHeightAndFadesBackdropWithImage() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: .init(width: 900, height: 600), format: format)
            .image { context in
                UIColor(red: 0.25, green: 0.47, blue: 0.35, alpha: 1).setFill()
                context.fill(.init(x: 0, y: 0, width: 900, height: 600))
            }.jpegData(compressionQuality: 0.95))
        for rotation in 0...2 {
            let suite = "review-render-\(UUID())"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let transfer = await Task.detached { TransferQueue(defaults: UserDefaults(suiteName: suite)!) }.value
            let queue = TransferQueueViewModel(queue: transfer)
            let other = try XCTUnwrap(UIGraphicsImageRenderer(size: .init(width: 900, height: 600), format: format)
                .image { context in
                    UIColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1).setFill()
                    context.fill(.init(x: 0, y: 0, width: 900, height: 600))
                }.jpegData(compressionQuality: 0.95))
            let wire = ReviewImageTransport(jpeg: jpeg, images: [2: other, 3: other])
            let session = CameraSession(repository: CameraRepository(session: PTPSession(transport: wire)))
            let photo = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 100,
                fileName: "REVIEW_0001.JPG", captureDate: nil, isProtected: false)
            let frames = RemoteReviewFrameGate()
            let model = RemotePhotoReviewModel(frames: frames, openCatalog: {
                RemoteReviewCatalog(handlesByStorage: [[1, 2, 3]]) { handle in
                    CameraFile(id: handle, storageID: photo.storageID, format: photo.format, size: photo.size,
                        fileName: "REVIEW_000\(handle).JPG", captureDate: "20261018T12000\(4 - handle)", isProtected: false)
                }
            }, endLiveView: {}, restartLiveView: {}, isConnected: { true })
            let dismissal = RemoteReviewDismissal { await model.close() }
            let host = UIHostingController(rootView: ReviewRenderHost(model: model, session: session,
                queue: queue, rotation: rotation, dismissal: dismissal))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            model.open()
            let deadline = ContinuousClock.now + .seconds(4)
            while await wire.commands.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(420))
            let shot = snapshot(window)
            try shot.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-review-layout-\(rotation).png"))
            let rendered = try pixels(shot)
            let green = stride(from: 0, to: rendered.count, by: 4).filter {
                (55...85).contains(rendered[$0]) && (105...135).contains(rendered[$0 + 1]) && (75...105).contains(rendered[$0 + 2])
            }
            XCTAssertGreaterThan(green.count, rotation == 0 ? 60_000 : 170_000,
                                 "Actual FHD must fill the intended portrait/landscape viewport")
            for y in [2, 841] {
                let offset = (y * 390 + 195) * 4
                XCTAssertEqual(Array(rendered[offset..<(offset + 3)]), [0, 0, 0], "Backdrop must cover system-bar margin")
            }
            let operations = await wire.commands
            XCTAssertEqual(operations.first, PTPConstants.getFHDPicture)
            XCTAssertTrue(operations.contains(PTPConstants.getPartialObjectEx))
            XCTAssertTrue(queue.snapshot.items.isEmpty)
            // Exercise the real page's pinch receiver and pager after its PTP
            // image has arrived. No synthetic UITouch or UI-test process is used.
            let pinch = try XCTUnwrap(descendants(host.view, as: PreviewPinchObserver.Marker.self)
                .first { $0.recognizer.isEnabled })
            pinch.onActive?(true)
            pinch.onChange?(2, CGPoint(x: pinch.bounds.midX, y: pinch.bounds.midY), .zero)
            try await Task.sleep(for: .milliseconds(80))
            pinch.onActive?(false)
            try await Task.sleep(for: .milliseconds(80))
            let zoomed = try pixels(snapshot(window))
            XCTAssertGreaterThan(greenPixelCount(zoomed), Int(Double(green.count) * 1.2), "Actual review must zoom in in every orientation")
            XCTAssertTrue(model.active); XCTAssertTrue(queue.snapshot.items.isEmpty)
            pinch.onActive?(true)
            pinch.onChange?(0.4, CGPoint(x: pinch.bounds.midX, y: pinch.bounds.midY), .zero)
            try await Task.sleep(for: .milliseconds(80))
            pinch.onActive?(false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(Double(greenPixelCount(try pixels(snapshot(window)))), Double(green.count), accuracy: Double(green.count) * 0.03)
            let pager = try XCTUnwrap(descendants(host.view, as: UIScrollView.self)
                .first { $0.isPagingEnabled && $0.contentSize.width > $0.bounds.width * 1.5 })
            XCTAssertTrue(pager.isScrollEnabled, "Reset zoom must release paging")
            let initialOffset = pager.contentOffset
            pager.setContentOffset(CGPoint(x: initialOffset.x + pager.bounds.width, y: initialOffset.y), animated: false)
            pager.delegate?.scrollViewDidEndDecelerating?(pager)
            try await Task.sleep(for: .milliseconds(350))
            let paged = try pixels(snapshot(window))
            try snapshot(window).pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-review-paged-\(rotation).png"))
            let blue = stride(from: 0, to: paged.count, by: 4).filter {
                paged[$0+2] > 150 && paged[$0] < 80 && paged[$0+1] < 100
            }.count
            XCTAssertGreaterThan(blue, green.count / 2, "Paging must display the next photo; rotation=\(rotation)")
            pager.setContentOffset(initialOffset, animated: false)
            pager.delegate?.scrollViewDidEndDecelerating?(pager)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertGreaterThan(greenPixelCount(try pixels(snapshot(window))), green.count / 2,
                                 "Returning must display the first photo; rotation=\(rotation)")
            XCTAssertTrue(model.active); XCTAssertTrue(queue.snapshot.items.isEmpty)
            dismissal.requestClose()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(model.active, "Frame gate stays paused during fade")
            let middle = try pixels(snapshot(window))
            XCTAssertGreaterThan(middle[(2 * 390 + 195) * 4], 15, "The black backdrop must also fade to the red monitor")
            // The inset preview used to add a second black layer. During a
            // fade this left the safe-area strips brighter than the middle.
            let topRed = Int(middle[(2 * 390 + 195) * 4])
            // In landscape the photo reaches the physical side edges, so that
            // location is image content, not an uncovered black margin.
            for point in rotation == 0 ? [(2, 422), (195, 841)] : [(195, 841)] {
                let red = Int(middle[(point.1 * 390 + point.0) * 4])
                XCTAssertEqual(red, topRed, accuracy: 10, "One fullscreen backdrop must fade uniformly; rotation=\(rotation)")
            }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(model.active)
            let resumed = try await frames.withFrame { true }
            XCTAssertTrue(resumed)
        }
    }

    private func greenPixelCount(_ pixels: [UInt8]) -> Int {
        stride(from: 0, to: pixels.count, by: 4).filter {
            (55...85).contains(pixels[$0]) && (105...135).contains(pixels[$0+1]) && (75...105).contains(pixels[$0+2])
        }.count
    }
    private func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
    }
    private struct ReviewRenderHost: View {
        @ObservedObject var model: RemotePhotoReviewModel
        let session: CameraSession
        let queue: TransferQueueViewModel
        let rotation: Int
        let dismissal: RemoteReviewDismissal
        var body: some View {
            ZStack {
                Color.red.ignoresSafeArea()
                if model.active {
                    RemoteReviewSurface(rotation: rotation) { landscape, insets in
                        RemotePhotoReviewView(model: model, session: session, queue: queue, connected: true,
                            landscape: landscape, contentInsets: insets, dismissal: dismissal)
                    }
                }
            }
        }
    }
    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
    private func pixels(_ image: UIImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 390 * 844 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 390, height: 844,
            bitsPerComponent: 8, bytesPerRow: 390 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 390, height: 844))
        return bytes
    }
}

private actor ReviewImageTransport: PTPCommandTransport {
    let jpeg: Data
    private(set) var commands: [UInt16] = []
    let images: [UInt32: Data]
    init(jpeg: Data, images: [UInt32: Data] = [:]) { self.jpeg = jpeg; self.images = images }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let decoded = try PTPCodec.decode(command)
        commands.append(decoded.code)
        let handle: UInt32 = decoded.payload.count >= 4
            ? decoded.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } : 0
        return (PTPCodec.encode(type: .response, code: PTPConstants.responseOK, transactionID: decoded.transactionID), images[handle] ?? jpeg)
    }
}

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
