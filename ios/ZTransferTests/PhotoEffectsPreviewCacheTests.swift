import XCTest
@testable import ZTransfer

final class PhotoEffectsPreviewCacheTests: XCTestCase {
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
