import CoreGraphics
import XCTest
@testable import ZTransfer

@MainActor
final class MaterialTextureStoreTests: XCTestCase {
    private final class GenerationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var usedMainThread = false
        func record() -> Int {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            usedMainThread = usedMainThread || Thread.isMainThread
            return calls
        }
        var snapshot: (count: Int, mainThread: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (calls, usedMainThread)
        }
    }

    func testPremultiplicationQuantizesAlphaBeforeColorChannels() {
        XCTAssertEqual(Array(ZTransferTextureBitmap.premultipliedRGBA([
            0x00ABCDEF, 0xFF123456, 0x80402010, 0x01FFFFFF
        ])), [0, 0, 0, 0, 18, 52, 86, 255, 32, 16, 8, 128, 1, 1, 1, 1])
    }

    func testMaterialAndPanelSelectionKeepsCameraPanelsAndGlassUntextured() {
        for dark in [false, true] {
            for skin in [ZTransferButtonSkin.frostedGlass, .liquidGlass] {
                XCTAssertNil(ZTransferTextureKey(skin: skin, dark: dark, seed: 1, panel: false))
                XCTAssertNil(ZTransferTextureKey(skin: skin, dark: dark, seed: 1, panel: true))
            }
            XCTAssertNil(ZTransferTextureKey(skin: .cameraControls, dark: dark, seed: 1, panel: true))
            XCTAssertNotNil(ZTransferTextureKey(skin: .cameraControls, dark: dark, seed: 1, panel: false))
            for skin in [ZTransferButtonSkin.titanium, .wood] {
                XCTAssertEqual(ZTransferTextureKey(skin: skin, dark: dark, seed: 1, panel: true),
                               ZTransferTextureKey(skin: skin, dark: dark, seed: 1, panel: false))
            }
        }
    }

    func testConcurrentLoadsAreSharedAndSurviveCallerCancellation() async throws {
        let probe = GenerationProbe()
        let store = ZTransferMaterialTextureStore { key in
            _ = probe.record()
            return ZTransferTextureBitmap.render(key)
        }
        let light = ZTransferTextureKey(material: .cameraControls, dark: false, seed: 17)
        let dark = ZTransferTextureKey(material: .cameraControls, dark: true, seed: 17)
        XCTAssertNil(store.image(for: light))
        let departingView = Task { await store.load(light) }
        departingView.cancel()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await store.load(light) }
                group.addTask { await store.load(dark) }
            }
        }
        await departingView.value
        let first = try XCTUnwrap(store.image(for: light))
        let second = try XCTUnwrap(store.image(for: dark))
        XCTAssertFalse(first === second)
        await store.load(light)
        XCTAssertTrue(store.image(for: light) === first)
        XCTAssertEqual(probe.snapshot.count, 2)
        XCTAssertFalse(probe.snapshot.mainThread)
        XCTAssertEqual(first.width, 256)
        XCTAssertEqual(first.height, 256)
        XCTAssertEqual(first.alphaInfo, .premultipliedLast)
        XCTAssertEqual(first.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testFailedGenerationIsNotCachedAndCanRetry() async {
        let probe = GenerationProbe()
        let store = ZTransferMaterialTextureStore { key in
            probe.record() == 1 ? nil : ZTransferTextureBitmap.render(key)
        }
        let key = ZTransferTextureKey(material: .titanium, dark: true, seed: -1)
        await store.load(key)
        XCTAssertNil(store.image(for: key))
        await store.load(key)
        XCTAssertNotNil(store.image(for: key))
        XCTAssertEqual(probe.snapshot.count, 2)
    }
}
