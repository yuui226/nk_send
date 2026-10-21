import XCTest
import UIKit
import SwiftUI
import os
@testable import ZTransfer

@MainActor
final class PhotoPickerFileLifetimeTests: XCTestCase {
    private func fixture() throws -> (source: URL, staging: URL, bytes: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PickerLifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.HEIC")
        let bytes = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: source)
        return (source, root.appendingPathComponent("private"), bytes)
    }

    func testCopiesOffMainBeforeReturningAndKeepsIndependentSourceLifetime() async throws {
        let fixture = try fixture()
        let entered = expectation(description: "Copy entered")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        var returned = false
        let task = Task {
            let file = try await PhotoPickerTemporaryFile.stage(fixture.source, directory: fixture.staging) { source, destination in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            returned = true
            return file
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(returned, "The importer callback must still own its provider URL")
        let heartbeat = expectation(description: "Run loop while copying")
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        gate.signal()
        let first = try await task.value
        let second = try await PhotoPickerTemporaryFile.stage(fixture.source, directory: fixture.staging)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.url.pathExtension, "HEIC")
        try FileManager.default.removeItem(at: fixture.source)
        XCTAssertEqual(try Data(contentsOf: first.url), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: second.url), fixture.bytes)
        try FileManager.default.removeItem(at: first.url)
        XCTAssertEqual(try Data(contentsOf: second.url), fixture.bytes)
    }

    func testCopyFailureRemovesPartialFileAndRetryPreservesOriginalBytes() async throws {
        let fixture = try fixture()
        do {
            _ = try await PhotoPickerTemporaryFile.stage(fixture.source, directory: fixture.staging) { _, destination in
                try Data([1, 2, 3]).write(to: destination)
                throw CocoaError(.fileWriteOutOfSpace)
            }
            XCTFail("Copy failure must propagate")
        } catch { XCTAssertEqual((error as NSError).code, NSFileWriteOutOfSpaceError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        let retried = try await PhotoPickerTemporaryFile.stage(fixture.source, directory: fixture.staging)
        XCTAssertEqual(try Data(contentsOf: retried.url), fixture.bytes)
    }

    func testCancellationBeforeOrDuringCopyLeavesNoOwnedFile() async throws {
        let fixture = try fixture()
        let cancelled = Task {
            try await PhotoPickerTemporaryFile.stage(fixture.source, directory: fixture.staging) { _, _ in
                XCTFail("Cancelled request must not copy")
            }
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Must cancel") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
        let entered = expectation(description: "Copy owns partial destination")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let copying = Task {
            try await PhotoPickerTemporaryFile.stage(fixture.source, directory: fixture.staging) { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).count, 1)
        copying.cancel()
        gate.signal()
        do { _ = try await copying.value; XCTFail("Must cancel after provider drains") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }
}

@MainActor
final class PhotoEffectsSourcePreparationTests: XCTestCase {
    private func source() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 8), format: format).image { context in
            for (rect, color) in [
                (CGRect(x: 0, y: 0, width: 8, height: 4), UIColor.red),
                (CGRect(x: 8, y: 0, width: 8, height: 4), UIColor.green),
                (CGRect(x: 0, y: 4, width: 8, height: 4), UIColor.blue),
                (CGRect(x: 8, y: 4, width: 8, height: 4), UIColor.yellow)
            ] { color.setFill(); context.fill(rect) }
        }
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 120 * 90 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 120, height: 90,
            bitsPerComponent: 8, bytesPerRow: 120 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 120, height: 90))
        return pixels
    }

    func testDisplayWrapperSharesPixelsAndRetainsTransparentSourceFill() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let source = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 8), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        }
        let cache = PhotoEffectsDisplaySourceCache()
        let first = cache.image(source, quarterTurns: 1)
        let wrappedPixels = try XCTUnwrap(first.cgImage), sourcePixels = try XCTUnwrap(source.cgImage)
        XCTAssertTrue(wrappedPixels === sourcePixels, "Direction metadata must share the immutable source pixels")
        XCTAssertTrue(first === cache.image(source, quarterTurns: 5))
        XCTAssertTrue(cache.image(source, quarterTurns: 0) === source)
        for turns in 0..<4 {
            let live = ImageRenderer(content: PhotoEffectsSourceImage(source: source, quarterTurns: turns)
                .frame(width: 120, height: 90))
            let reference = ImageRenderer(content: Image(uiImage: PhotoEffectsSourceRotation.rotate(source, quarterTurns: turns))
                .resizable().scaledToFit().frame(width: 120, height: 90))
            let actual = try bytes(XCTUnwrap(live.cgImage)), expected = try bytes(XCTUnwrap(reference.cgImage))
            if turns == 2 {
                try XCTUnwrap(live.uiImage?.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p13-alpha-live.png"))
                try XCTUnwrap(reference.uiImage?.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p13-alpha-reference.png"))
            }
            let difference = zip(actual, expected).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            XCTAssertLessThan(Double(difference) / Double(actual.count), 2, "Transparent source rotation \(turns)")
        }
    }

    func testRotationRunsOffMainOnceAndSharesBitmapAcrossConsumers() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = PhotoEffectsRotatedSourceCache { image, turns in
            XCTAssertFalse(Thread.isMainThread)
            calls.withLock { $0 += 1 }
            return PhotoEffectsSourceRotation.rotate(image, quarterTurns: turns)
        }
        defer { cache.close() }
        let source = source()
        let original = try await cache.image(source, quarterTurns: 0)
        XCTAssertTrue(original === source)
        let first = try await cache.image(source, quarterTurns: 1)
        XCTAssertEqual(first.size, CGSize(width: 8, height: 16))
        XCTAssertEqual(first.scale, 2)
        for _ in 0..<40 {
            let result = try await cache.image(source, quarterTurns: 5)
            XCTAssertTrue(result === first)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        let reverse = try await cache.image(source, quarterTurns: -1)
        XCTAssertFalse(reverse === first)
        XCTAssertEqual(calls.withLock { $0 }, 2)
        _ = try await cache.image(source, quarterTurns: 0)
        _ = try await cache.image(source, quarterTurns: 1)
        XCTAssertEqual(calls.withLock { $0 }, 3, "Only the current direction is retained")
        let other = self.source()
        let changed = try await cache.image(other, quarterTurns: 1)
        XCTAssertFalse(changed === first)
        XCTAssertEqual(calls.withLock { $0 }, 4)
        cache.close()
        _ = try await cache.image(other, quarterTurns: 1)
        XCTAssertEqual(calls.withLock { $0 }, 5, "Leaving must release the preparation cache")
    }

    func testCancelledConsumerDoesNotBlockMainOrCancelSharedRotation() async throws {
        let entered = expectation(description: "background rotation entered")
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = PhotoEffectsRotatedSourceCache { image, turns in
            XCTAssertFalse(Thread.isMainThread)
            calls.withLock { $0 += 1 }
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            return PhotoEffectsSourceRotation.rotate(image, quarterTurns: turns)
        }
        defer { release.signal(); cache.close() }
        let source = source()
        let first = Task { try await cache.image(source, quarterTurns: 1) }
        await fulfillment(of: [entered], timeout: 2)
        // This continuation executes on MainActor while the worker is blocked.
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer returned pixels") } catch is CancellationError {}
        let next = Task { try await cache.image(source, quarterTurns: 1) }
        release.signal()
        let result = try await next.value
        XCTAssertEqual(result.size, CGSize(width: 8, height: 16))
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testCloseRejectsLateRotationAndNewSourceReopensIndependently() async throws {
        let entered = expectation(description: "old rotation entered")
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = PhotoEffectsRotatedSourceCache { image, turns in
            let call = calls.withLock { value in value += 1; return value }
            if call == 1 {
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            }
            return PhotoEffectsSourceRotation.rotate(image, quarterTurns: turns)
        }
        defer { release.signal(); cache.close() }
        let source = source()
        let old = Task { try await cache.image(source, quarterTurns: 1) }
        await fulfillment(of: [entered], timeout: 2)
        cache.close()
        do { _ = try await old.value; XCTFail("Closing must reject late pixels") } catch is CancellationError {}
        let replacement = self.source()
        let next = Task { try await cache.image(replacement, quarterTurns: 3) }
        release.signal()
        let result = try await next.value
        XCTAssertEqual(result.size, CGSize(width: 8, height: 16))
        XCTAssertEqual(calls.withLock { $0 }, 2)
        let same = try await cache.image(replacement, quarterTurns: 3)
        XCTAssertTrue(same === result)
    }

    func testTemporarySourceUsesTheSameRotationFitAndPixelsWithoutNewBitmap() throws {
        let source = source()
        for orientation: UIImage.Orientation in [.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored] {
            let oriented = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: source.scale, orientation: orientation)
            for turns in [0, 1, 2, 3, -1] {
                let live = ImageRenderer(content: PhotoEffectsSourceImage(source: oriented, quarterTurns: turns)
                    .frame(width: 120, height: 90))
                let reference = ImageRenderer(content: Image(uiImage: PhotoEffectsSourceRotation.rotate(oriented, quarterTurns: turns))
                    .resizable().scaledToFit().frame(width: 120, height: 90))
                let actual = try bytes(XCTUnwrap(live.cgImage)), expected = try bytes(XCTUnwrap(reference.cgImage))
                if orientation == .up, turns == 3 {
                    try XCTUnwrap(live.uiImage?.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p13-rotation-live.png"))
                    try XCTUnwrap(reference.uiImage?.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p13-rotation-reference.png"))
                }
                let difference = zip(actual, expected).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                XCTAssertLessThan(Double(difference) / Double(actual.count), 2,
                    "Rotation \(turns), EXIF orientation \(orientation.rawValue)")
            }
        }
    }
}

final class PhotoEffectsPreviewCacheTests: XCTestCase {
    @MainActor
    func testIdentityMemoAvoidsRepeatedEncodingAndTracksAllMetadata() throws {
        let cache = PhotoEffectsPreviewIdentityCache()
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.watermark.enabled = true
        settings.watermark.text = "initial"
        let image = UIImage(), replacement = UIImage()
        var encodes = 0
        func key(_ settings: PhotoEffectsSettings, _ source: UIImage?, _ metadata: PhotoFrameMetadata?) -> String {
            cache.key(settings: settings, source: source, metadata: metadata) {
                encodes += 1
                return PhotoEffectsSettingsPreview.makeRenderKey(settings: $0, source: $1, metadata: $2)
            }
        }
        func metadata(make: String? = nil, model: String? = nil, ev: String?) -> PhotoFrameMetadata {
            .init(make: make, model: model, lensModel: nil, focalLength: nil, aperture: nil,
                shutter: nil, iso: nil, exposureCompensation: ev, dateTime: nil)
        }
        let original = key(settings, image, metadata(ev: "0 EV"))
        for i in 0..<120 {
            settings.favoriteFilterIDs = ["unused-\(i)"]
            settings.filterIntensities["unused"] = i
            XCTAssertEqual(key(settings, image, metadata(ev: "0 EV")), original)
        }
        XCTAssertEqual(encodes, 1)
        settings.watermark.text = "  initial  "
        XCTAssertEqual(key(settings, image, metadata(ev: "0 EV")), original)
        XCTAssertEqual(encodes, 1, "Display-equivalent watermark edits must not encode or rerender")
        XCTAssertNotEqual(key(settings, image, metadata(ev: "+1 EV")), original)
        XCTAssertEqual(encodes, 2)
        XCTAssertNotEqual(key(settings, image, metadata(make: "a|b", model: "c", ev: nil)),
                          key(settings, image, metadata(make: "a", model: "b|c", ev: nil)))
        let beforeReplacement = key(settings, image, nil)
        XCTAssertNotEqual(key(settings, replacement, nil), beforeReplacement)
        settings.watermark.text = "new"
        XCTAssertNotEqual(key(settings, replacement, nil), beforeReplacement)
    }

    @MainActor
    func testProductionRenderIdentityIsStableAndIgnoresNonPixelPreferences() throws {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.watermark.enabled = true
        settings.watermark.text = "render identity"
        let key = PhotoEffectsSettingsPreview.makeRenderKey(settings: settings, source: nil, metadata: nil)
        let repeated = Set((0..<100).map { _ in
            PhotoEffectsSettingsPreview.makeRenderKey(settings: settings, source: nil, metadata: nil)
        })
        XCTAssertEqual(repeated, [key], "Identical pixels must reuse one production cache key")
        settings.favoriteFilterIDs = ["unused"]
        settings.filterIntensities["unused"] = 12
        settings.rememberedBuiltinFilter = .init(preset: try XCTUnwrap(PhotoFilterCatalog.presets.first), intensityPercent: 62)
        XCTAssertEqual(PhotoEffectsSettingsPreview.makeRenderKey(settings: settings, source: nil, metadata: nil), key)
        settings.watermark.text = "changed pixels"
        XCTAssertNotEqual(PhotoEffectsSettingsPreview.makeRenderKey(settings: settings, source: nil, metadata: nil), key)
    }
    @MainActor
    func testPoolReusesThreeTargetsEvictsOldestAndInvalidatesContext() async throws {
        let pool = PhotoEffectsPreviewCachePool<String>()
        pool.request(["a", "b", "c", "d"])
        let count = CacheTestCounter()
        func load(_ key: String, _ context: String = "frame") async throws -> String {
            try await pool.value(key: key, context: context) { _ in await count.increment(); return key + context }
        }
        _ = try await load("a"); _ = try await load("b"); _ = try await load("c")
        _ = try await load("a"); _ = try await load("d")
        var calls = await count.value
        XCTAssertEqual(calls, 4)
        _ = try await load("b")
        calls = await count.value
        XCTAssertEqual(calls, 5)
        let changed = try await load("b", "new-frame")
        XCTAssertEqual(changed, "bnew-frame")
        calls = await count.value
        XCTAssertEqual(calls, 6)
        pool.request([])
        do { _ = try await load("c"); XCTFail() } catch is CancellationError {}
        pool.close()
    }
    func testCancellingAwaiterPreservesSharedWorkAndCompletedResult() async throws {
        let cache = PhotoEffectsPreviewCache<String>(), started = expectation(description: "started")
        let release = CacheTestSignal()
        let first = Task { try await cache.getOrRender { _ in started.fulfill(); await release.wait(); return "shared" } }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail() } catch is CancellationError {}
        let second = Task { try await cache.getOrRender { _ in XCTFail("duplicate render"); return "duplicate" } }
        await release.open()
        let value = try await second.value
        XCTAssertEqual(value, "shared")
        let cached = try await cache.getOrRender { _ in XCTFail("completed rerender"); return "bad" }
        XCTAssertEqual(cached, "shared")
        await cache.close()
        do { _ = try await cache.getOrRender { _ in XCTFail(); return "bad" }; XCTFail() } catch is CancellationError {}
    }
    func testClosingIntermediateReleasesGlobalGateForNextFrame() async throws {
        let gate = CancellableSerialWorkGate()
        let intermediate = PhotoEffectsPreviewCache<String>(gate: gate)
        let old = PhotoEffectsPreviewCache<String>(gate: gate), next = PhotoEffectsPreviewCache<String>(gate: gate)
        let started = expectation(description: "intermediate started")
        let request = Task {
            try await old.getOrRender { _ in
                try await intermediate.getOrRender(serialize: false) { _ in
                    started.fulfill(); try await Task.sleep(for: .seconds(30)); return "old"
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await intermediate.close()
        let value = try await next.getOrRender { _ in "next" }
        XCTAssertEqual(value, "next")
        do { _ = try await request.value; XCTFail() } catch is CancellationError {}
        await old.close(); await next.close()
    }
    func testUnrelatedCancellationIsNotRetriedButLaterRequestCanRecover() async throws {
        let cache = PhotoEffectsPreviewCache<String>()
        let count = CacheTestCounter()
        do {
            _ = try await cache.getOrRender { _ in await count.increment(); throw CancellationError() }; XCTFail()
        } catch is CancellationError {}
        let calls = await count.value
        XCTAssertEqual(calls, 1)
        let value = try await cache.getOrRender { _ in "recovered" }
        XCTAssertEqual(value, "recovered")
    }
    func testNewAwaiterRetriesCancelledOldDependencies() async throws {
        let cache = PhotoEffectsPreviewCache<String>(), started = expectation(description: "started")
        let release = CacheTestSignal()
        let old = Task { try await cache.getOrRender { _ in started.fulfill(); await release.wait(); throw CancellationError() } }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        do { _ = try await old.value; XCTFail() } catch is CancellationError {}
        let new = Task { try await cache.getOrRender { _ in "new" } }
        try await Task.sleep(for: .milliseconds(20))
        await release.open()
        let value = try await new.value
        XCTAssertEqual(value, "new")
    }
}
private actor CacheTestCounter {
    var value = 0
    func increment() { value += 1 }
}
private actor CacheTestSignal {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

@MainActor
final class PhotoEffectsFallbackLifecycleTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var settings = PhotoEffectsSettings()
        @Published var source: UIImage?
        @Published var presented = true
        var events: [String] = []
        var renderedImages: [UIImage] = []
    }
    private struct Host: View {
        @ObservedObject var state: State
        var body: some View {
            var preview = PhotoEffectsSettingsPreview(source: state.source, metadata: nil,
                settings: state.settings, onRequest: {})
            preview.lifecycleObserver = { state.events.append($0) }
            preview.renderedImageObserver = { state.renderedImages.append($0) }
            return Group { if state.presented { preview.frame(width: 320, height: 240) } }
        }
    }

    func testOfflineSettingsChangesDoNotRestartSourceGrace() async throws {
        let state = State()
        state.settings.photoFrameEnabled = true
        state.settings.photoFrameBorderEnabled = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        let beginDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !state.events.contains("fallback.grace.begin"), ContinuousClock.now < beginDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.events.filter { $0 == "fallback.grace.begin" }.count, 1)
        // Change settings while the initial real-photo grace is still pending.
        for value in [30, 40, 50] {
            state.settings.watermark.sizePercent = value
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(state.events.contains("fallback.grace.end"))
        let initialDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !state.events.contains("fallback.rendered"), ContinuousClock.now < initialDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.events.contains("fallback.rendered"))
        let renderedBefore = state.events.filter { $0 == "fallback.rendered" }.count
        state.settings.watermark.sizePercent = 60
        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        while state.events.filter({ $0 == "fallback.rendered" }).count == renderedBefore,
              ContinuousClock.now < refreshDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(state.events.filter { $0 == "fallback.rendered" }.count, renderedBefore)
        XCTAssertEqual(state.events.filter { $0 == "fallback.grace.begin" }.count, 1)
        XCTAssertEqual(state.events.filter { $0 == "fallback.grace.end" }.count, 1)
    }

    func testSourceArrivalCancelsFallbackAndReentryStartsNewGrace() async throws {
        let state = State()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        func waitFor(_ event: String, count: Int = 1) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while state.events.filter({ $0 == event }).count < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(state.events.filter { $0 == event }.count, count)
        }
        try await waitFor("fallback.grace.begin")
        state.source = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        try await waitFor("source.rendered")
        // Observe beyond the cancelled 2200 ms timer, not only before it fires.
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertFalse(state.events.contains("fallback.grace.end"))
        XCTAssertFalse(state.events.contains("fallback.rendered"))
        state.source = nil
        try await waitFor("fallback.grace.begin", count: 2)
        try await waitFor("fallback.rendered")
        state.presented = false
        try await Task.sleep(for: .milliseconds(100))
        let previousRenders = state.events.filter { $0 == "fallback.rendered" }.count
        state.presented = true
        try await waitFor("fallback.grace.begin", count: 3)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state.events.filter { $0 == "fallback.rendered" }.count, previousRenders)
        try await waitFor("fallback.rendered", count: previousRenders + 1)
        XCTAssertEqual(state.events.filter { $0 == "fallback.grace.end" }.count, 2)
    }


    func testSourceBackedPreviewPublishesLatestWatermarkPixels() async throws {
        try await verifySourceBackedWatermarkPixels(logo: false)
    }

    func testSourceBackedPreviewPublishesLatestLogoPixels() async throws {
        try await verifySourceBackedWatermarkPixels(logo: true)
    }

    private func verifySourceBackedWatermarkPixels(logo: Bool) async throws {
        let state = State()
        let source = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        state.source = source
        state.settings.photoFrameEnabled = true
        state.settings.photoFrameBorderEnabled = false
        state.settings.watermark.position = .photoBottomRight
        state.settings.watermark.text = "PREVIEW"
        if logo {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZTransfer/Watermarks")
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
            let hash = try XCTUnwrap(PhotoEffectsStore.importWatermarkImageData(XCTUnwrap(image.pngData())))
            state.settings.watermark.content = .image
            state.settings.watermark.imageHash = hash
            if !existing.contains("\(hash).png") {
                addTeardownBlock { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(hash).png")) }
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        let initialDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        while state.renderedImages.isEmpty, ContinuousClock.now < initialDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let initial = try XCTUnwrap(state.renderedImages.last?.pngData())
        let count = state.renderedImages.count
        state.settings.watermark.position = .photoCenter
        state.settings.watermark.sizePercent = 90
        state.settings.watermark.position = .photoTopLeft
        let expected = try await LocalPhotoOutput.preview(image: source,
            settings: state.settings, metadata: nil, filteredSource: nil).filtered.pngData()
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while state.renderedImages.last?.pngData() != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(state.renderedImages.count, count)
        XCTAssertNotEqual(initial, expected)
        XCTAssertEqual(state.renderedImages.last?.pngData(), expected,
                       "The published bitmap must match the latest settings, not the cached old position")
        XCTAssertFalse(state.events.contains("fallback.grace.begin"))
    }

}

@MainActor
final class PhotoEffectsVisibleFrameTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var image: UIImage
        init(_ image: UIImage) { self.image = image }
    }
    private struct Host: View {
        @ObservedObject var state: State
        var body: some View {
            PhotoEffectsAnimatedImage(frame: .init(image: state.image, comparison: nil, canvasKey: "same"),
                requestedCanvasKey: "same", showComparison: false)
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    func testNewFrameBecomesVisibleAfterFullScreenCoverDismissal() async throws {
        try await verifyNewVisibleFrame(covered: true)
    }

    func testNewFrameBecomesVisibleWithoutLeavingScreen() async throws {
        try await verifyNewVisibleFrame(covered: false)
    }

    private func verifyNewVisibleFrame(covered: Bool) async throws {
        func bitmap(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            }
        }
        let state = State(bitmap(.red))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Host(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        try await Task.sleep(for: .milliseconds(500))
        func centerPixel(_ name: String) throws -> [UInt8] {
            let snapshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let image = try XCTUnwrap(snapshot.cgImage)
            let center = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgba
        }
        let initial = try centerPixel("visible-before-cover")
        XCTAssertGreaterThan(initial[0], 240); XCTAssertLessThan(initial[2], 15)
        let cover = UIViewController()
        cover.view.backgroundColor = .green
        cover.modalPresentationStyle = .fullScreen
        if covered {
            await withCheckedContinuation { continuation in host.present(cover, animated: false) { continuation.resume() } }
        }
        state.image = bitmap(.blue)
        try await Task.sleep(for: .milliseconds(100))
        if covered {
            await withCheckedContinuation { continuation in cover.dismiss(animated: false) { continuation.resume() } }
        }
        try await Task.sleep(for: .milliseconds(700))
        let final = try centerPixel("visible-after-cover")
        XCTAssertGreaterThan(final[2], 240, "New blue frame must replace old red frame after returning")
        XCTAssertLessThan(final[0], 15)
    }
}
