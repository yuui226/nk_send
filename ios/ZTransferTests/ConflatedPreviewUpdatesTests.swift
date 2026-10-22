import XCTest
import SwiftUI
@testable import ZTransfer

@MainActor
final class PhotoEffectsFocusedFieldVisibilityTests: XCTestCase {
    private final class Scroll: UIScrollView {
        var requests: [(CGRect, Bool)] = []
        var onRequest: (() -> Void)?
        override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
            requests.append((rect, animated))
            // Exercise UIKit's actual offset calculation without making the
            // regression depend on the duration of UIKit's scroll animation.
            super.scrollRectToVisible(rect, animated: false)
            onRequest?()
        }
    }

    @MainActor private final class Fixture {
        let window: UIWindow
        let previousWindow: UIWindow?
        let scroll = Scroll()
        let probe = PhotoEffectsFocusedFieldVisibilityProbe()

        init() throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousWindow = scene.windows.first(where: { $0.isKeyWindow })
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
            let host = UIViewController()
            window.rootViewController = host
            scroll.frame = window.bounds
            scroll.contentSize = CGSize(width: 375, height: 1_000)
            scroll.contentInsetAdjustmentBehavior = .never
            host.view.addSubview(scroll)
            probe.frame = CGRect(x: 140, y: 383, width: 200, height: 34)
            // The observed SE's main key area starts at 451; its suggestion
            // strip starts at 407.5 and must also be cleared by the full row.
            probe.keyboardFrameInWindowOverride = CGRect(x: 0, y: 407.5, width: 375, height: 259.5)
            scroll.addSubview(probe)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func close() {
            probe.configure(focused: false, active: false)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
    }

    func testWholeControlClearsSuggestionStripAfterOneFrameAnd180Milliseconds() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let requested = expectation(description: "one local visibility request")
        let started = ContinuousClock.now
        fixture.scroll.onRequest = { requested.fulfill() }
        fixture.probe.configure(focused: true, active: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.scroll.requests.isEmpty, "Do not scroll before Android's focus delay")
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(180))
        XCTAssertEqual(fixture.scroll.requests.count, 1)
        XCTAssertEqual(fixture.scroll.requests.first?.1, true)
        let scale = fixture.window.screen.scale
        XCTAssertEqual(fixture.scroll.contentOffset.y, (9.5 * scale).rounded() / scale, accuracy: 0.01)
        let control = fixture.probe.convert(fixture.probe.bounds, to: fixture.window)
        XCTAssertEqual(control.height, 34)
        XCTAssertLessThanOrEqual(control.maxY, 407.5)
        fixture.probe.configure(focused: true, active: true)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(fixture.scroll.requests.count, 1, "Ordinary view updates must not restart focus scrolling")
    }

    func testPendingFocusScrollCancelsForBlurBackgroundAndRemoval() async throws {
        for cancellation in 0..<3 {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.probe.configure(focused: true, active: true)
            try await Task.sleep(for: .milliseconds(70))
            switch cancellation {
            case 0: fixture.probe.configure(focused: false, active: true)
            case 1: fixture.probe.configure(focused: true, active: false)
            default: fixture.probe.removeFromSuperview()
            }
            try await Task.sleep(for: .milliseconds(260))
            XCTAssertTrue(fixture.scroll.requests.isEmpty, "Cancelled focus must not scroll later: \(cancellation)")
        }
    }
}

@MainActor
final class ConflatedPreviewUpdatesTests: XCTestCase {
    func testAcceptedTransitionCompletesAndOnlyLatestPendingIsConsumed() async throws {
        let queue = ConflatedPreviewUpdates<Int>()
        let started = expectation(description: "first started")
        let finished = expectation(description: "latest completed")
        var seen: [Int] = []
        var release: CheckedContinuation<Void, Never>?
        let operation: @MainActor (Int, @escaping @MainActor () -> Int) async -> Void = { value, latest in
            seen.append(value)
            if value == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
                XCTAssertFalse(Task.isCancelled)
                XCTAssertEqual(latest(), 3)
            } else { finished.fulfill() }
        }
        queue.submit(1, operation: operation)
        await fulfillment(of: [started], timeout: 2)
        queue.submit(2, operation: operation); queue.submit(3, operation: operation)
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(seen, [1, 3])
        queue.close()
    }

    func testLeavingCancelsCurrentAndDropsPendingButReentryWorks() async {
        let queue = ConflatedPreviewUpdates<Int>()
        let started = expectation(description: "started"), cancelled = expectation(description: "cancelled")
        let next = expectation(description: "new lifecycle")
        queue.submit(1) { _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)); XCTFail() }
            catch { cancelled.fulfill() }
        }
        await fulfillment(of: [started], timeout: 2)
        queue.submit(2) { _, _ in XCTFail("pending old lifecycle") }
        queue.close()
        queue.submit(3) { value, _ in XCTAssertEqual(value, 3); next.fulfill() }
        await fulfillment(of: [cancelled, next], timeout: 2)
        queue.close()
    }

    private final class ImageState: ObservableObject {
        @Published var image: UIImage
        @Published var canvas = "same"
        @Published var requestedCanvas = "same"
        @Published var failed = false
        var crossfadePrepared: (() async -> Void)?
        var visibilityStarted: ((Bool) -> Void)?
        init(_ image: UIImage) { self.image = image }
    }

    private struct ImageHost: View {
        @ObservedObject var state: ImageState
        var body: some View {
            var preview = PhotoEffectsAnimatedImage(
                frame: .init(image: state.image, comparison: nil, canvasKey: state.canvas),
                requestedCanvasKey: state.requestedCanvas, showComparison: false, failed: state.failed
            )
            preview.crossfadePrepared = { await state.crossfadePrepared?() }
            preview.visibilityStarted = { state.visibilityStarted?($0) }
            return preview.frame(width: 200, height: 200)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image {
            color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        let center = try XCTUnwrap(cg.cropping(to: CGRect(x: cg.width / 2, y: cg.height / 2, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgba
    }

    func testInitialStaleCanvasIsHiddenUnlessReplacementFailed() throws {
        for (requested, failed, expectedRed) in [("same", false, true), ("uniform", false, false), ("uniform", true, true)] {
            let image = ImageRenderer(content: PhotoEffectsAnimatedImage(
                frame: .init(image: solidImage(.red), comparison: nil, canvasKey: "same"),
                requestedCanvasKey: requested, showComparison: false, failed: failed)
                .frame(width: 100, height: 100).background(Color.white))
            let pixel = try centerPixel(XCTUnwrap(image.uiImage))
            XCTAssertGreaterThan(pixel[0], 240)
            XCTAssertEqual(pixel[1] < 15, expectedRed)
        }
    }

    func testFailedCanvasReplacementRestoresOldImageAndRejectsLateOldResult() async throws {
        let state = ImageState(solidImage(.red))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ImageHost(state: state).background(Color.white))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            state.visibilityStarted = nil
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        func pixel() throws -> [UInt8] {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            return try centerPixel(image)
        }
        try await Task.sleep(for: .milliseconds(300))
        state.requestedCanvas = "uniform"
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(try pixel()[1], 240, "Old canvas is hidden while waiting")
        state.failed = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertLessThan(try pixel()[1], 15, "A failed replacement restores the last good image")
        state.failed = false; state.image = solidImage(.blue)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(try pixel()[0], 240, "A late old-layout result is rejected")
        state.canvas = "uniform"; state.image = solidImage(.green)
        try await Task.sleep(for: .milliseconds(500))
        let recovered = try pixel()
        XCTAssertGreaterThan(recovered[1], 240); XCTAssertLessThan(recovered[0], 15)
    }

    func testUniformCanvasFadeInFinishesBeforePendingEffectCrossfade() async throws {
        func bitmap(_ color: UIColor) -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image {
                color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            }
        }
        let state = ImageState(bitmap(.red))
        let blue = bitmap(.blue), green = bitmap(.green)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ImageHost(state: state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            state.visibilityStarted = nil; state.crossfadePrepared = nil
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        let hidden = expectation(description: "old canvas hiding")
        state.visibilityStarted = { visible in if !visible { hidden.fulfill() } }
        state.requestedCanvas = "uniform"
        await fulfillment(of: [hidden], timeout: 2)
        try await Task.sleep(for: .milliseconds(150))
        let pendingBegan = expectation(description: "pending same-canvas effect starts")
        var fadeBegan: ContinuousClock.Instant?
        var pendingDelay: Duration?
        state.visibilityStarted = { visible in
            guard visible, fadeBegan == nil else { return }
            fadeBegan = .now
            // A new effect arrives while the new canvas is fading in.
            state.image = green
        }
        state.crossfadePrepared = {
            guard let began = fadeBegan, pendingDelay == nil else { return }
            pendingDelay = began.duration(to: .now)
            pendingBegan.fulfill()
        }
        state.canvas = "uniform"; state.image = blue
        await fulfillment(of: [pendingBegan], timeout: 3)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(pendingDelay), .milliseconds(180),
            "Android finishes the 190ms canvas fade before consuming a pending effect")
    }

    func testCoverInterruptingPreparedCrossfadeRestoresVisibleIncomingFrame() async throws {
        func bitmap(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            }
        }
        let state = ImageState(bitmap(.red))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ImageHost(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.crossfadePrepared = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(500))

        func centerPixel(_ name: String) throws -> [UInt8] {
            let snapshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let image = try XCTUnwrap(snapshot.cgImage)
            let center = try XCTUnwrap(image.cropping(to: CGRect(
                x: image.width / 2, y: image.height / 2, width: 1, height: 1
            )))
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgba
        }
        let initial = try centerPixel("crossfade-before-cover")
        XCTAssertGreaterThan(initial[0], 240)
        XCTAssertLessThan(initial[2], 15)
        let cover = UIViewController()
        cover.view.backgroundColor = .green
        cover.modalPresentationStyle = .fullScreen
        let interrupted = expectation(description: "cover cancelled the prepared crossfade")
        state.crossfadePrepared = {
            await withCheckedContinuation { continuation in
                host.present(cover, animated: false) { continuation.resume() }
            }
            // UIKit's presentation completion can precede SwiftUI's
            // onDisappear. Keep the prepared frame suspended until the real
            // lifecycle cancels this task, with a bounded failure timeout.
            do {
                try await Task.sleep(for: .seconds(2))
                XCTFail("The full-screen cover did not cancel the prepared crossfade")
            } catch is CancellationError {
                interrupted.fulfill()
            } catch {
                XCTFail("Unexpected crossfade suspension error: \(error)")
            }
        }
        state.image = bitmap(.blue)
        await fulfillment(of: [interrupted], timeout: 3)
        XCTAssertTrue(host.presentedViewController === cover)
        await withCheckedContinuation { continuation in
            cover.dismiss(animated: false) { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(500))
        let final = try centerPixel("crossfade-after-interrupted-cover")
        XCTAssertGreaterThan(final[2], 240, "Returning must show the accepted blue frame")
        XCTAssertLessThan(final[0], 15, "The cancelled transition must release the outgoing red frame")
    }
}
