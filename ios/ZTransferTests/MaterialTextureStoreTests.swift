import CoreGraphics
import SwiftUI
import UIKit
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

@MainActor
final class MaterialSurfacePerformanceTests: XCTestCase {
    func testLiquidGlassShadowReusesPathButTracksGeometryAndStyleChanges() throws {
        let view = ZTransferRoundedShadowView(frame: CGRect(x: 0, y: 0, width: 90, height: 42))
        view.configure(cornerRadius: 14, opacity: 0.1, radius: 2, y: 1)
        view.layoutIfNeeded()
        let initial = view.pathBuildCount
        for _ in 0..<120 {
            view.configure(cornerRadius: 14, opacity: 0.1, radius: 2, y: 1)
            view.setNeedsLayout(); view.layoutIfNeeded()
        }
        XCTAssertEqual(view.pathBuildCount, initial)
        view.configure(cornerRadius: 14, opacity: 0.2, radius: 3, y: 2)
        view.layoutIfNeeded()
        XCTAssertEqual(view.pathBuildCount, initial)
        XCTAssertEqual(view.layer.shadowOpacity, 0.2)
        XCTAssertEqual(view.layer.shadowRadius, 3)
        XCTAssertEqual(view.layer.shadowOffset, CGSize(width: 0, height: 2))
        view.bounds.size.width = 120; view.layoutIfNeeded()
        XCTAssertEqual(view.pathBuildCount, initial + 1)
        XCTAssertEqual(view.layer.shadowPath, UIBezierPath(roundedRect: view.bounds, cornerRadius: 14).cgPath)
        view.configure(cornerRadius: 8, opacity: 0.2, radius: 3, y: 2); view.layoutIfNeeded()
        XCTAssertEqual(view.pathBuildCount, initial + 2)
        XCTAssertEqual(view.layer.shadowPath, UIBezierPath(roundedRect: view.bounds, cornerRadius: 8).cgPath)
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private let semaphore = DispatchSemaphore(value: 0)
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return started }
        func wait() {
            lock.lock(); started = true; lock.unlock()
            semaphore.wait()
        }
        func release() { semaphore.signal() }
    }
    private final class Selection: ObservableObject {
        @Published var key: ZTransferTextureKey
        init(_ key: ZTransferTextureKey) { self.key = key }
    }
    private final class Counts {
        var parent = 0, changing = 0, fixed = 0
        func parentBody() { parent += 1 }
    }
    private struct Fixture: View {
        @ObservedObject var selection: Selection
        let fixedKey: ZTransferTextureKey
        let store: ZTransferMaterialTextureStore
        let counts: Counts
        var body: some View {
            let _ = counts.parentBody()
            HStack(spacing: 0) {
                ZTransferMaterialTextureFill(key: selection.key, cornerRadius: 10, store: store,
                    didRender: { counts.changing += 1 })
                    .frame(width: 80, height: 60)
                ZTransferMaterialTextureFill(key: fixedKey, cornerRadius: 10, store: store,
                    didRender: { counts.fixed += 1 })
                    .frame(width: 80, height: 60)
            }.frame(width: 160, height: 60).background(Color.white)
        }
    }

    nonisolated private static func tile(_ rgba: [UInt8]) -> ZTransferTextureBitmap {
        let bytes = Array(repeating: rgba, count: 256 * 256).flatMap { $0 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return ZTransferTextureBitmap(image: CGImage(width: 256, height: 256,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for texture worker/view")
    }

    private func pixel(_ view: UIView, x: Int) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let offset = ((cg.height / 2) * cg.width + x) * 4
        return Array(bytes[offset..<offset + 4])
    }

    func testOnlyTextureConsumerUpdatesAndLateOldThemeCannotReplaceNewTheme() async throws {
        let light = ZTransferTextureKey(material: .titanium, dark: false, seed: 17)
        let dark = ZTransferTextureKey(material: .titanium, dark: true, seed: 17)
        let fixed = ZTransferTextureKey(material: .wood, dark: false, seed: 17)
        let unrelated = ZTransferTextureKey(material: .cameraControls, dark: false, seed: 17)
        let lightGate = Gate(), darkGate = Gate()
        let store = ZTransferMaterialTextureStore { key in
            if key == light { lightGate.wait(); return Self.tile([255, 0, 0, 255]) }
            if key == dark { darkGate.wait(); return Self.tile([0, 0, 255, 255]) }
            return Self.tile([0, 255, 0, 255])
        }
        await store.load(fixed)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 160, height: 60)
        let selection = Selection(light), counts = Counts()
        let controller = UIHostingController(rootView: Fixture(selection: selection,
            fixedKey: fixed, store: store, counts: counts).ignoresSafeArea())
        window.rootViewController = controller; window.isHidden = false
        defer { lightGate.release(); darkGate.release(); window.isHidden = true }
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        try await waitFor { lightGate.entered }
        selection.key = dark
        try await Task.sleep(for: .milliseconds(80))
        let parents = counts.parent, fixedDraws = counts.fixed
        lightGate.release()
        try await waitFor { darkGate.entered }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try pixel(controller.view, x: 40), [255, 255, 255, 255], "Cancelled light tile must never appear in the dark consumer")
        XCTAssertEqual(try pixel(controller.view, x: 120), [0, 255, 0, 255])
        darkGate.release()
        try await waitFor { store.image(for: dark) != nil }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try pixel(controller.view, x: 40), [0, 0, 255, 255])
        XCTAssertEqual(counts.parent, parents)
        XCTAssertEqual(counts.fixed, fixedDraws)
        let changingDraws = counts.changing
        await store.load(unrelated)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(counts.parent, parents)
        XCTAssertEqual(counts.fixed, fixedDraws)
        XCTAssertEqual(counts.changing, changingDraws)
        XCTAssertEqual(try pixel(controller.view, x: 40), [0, 0, 255, 255])
        // Both completed tiles remain shared even though one consumer cancelled.
        XCTAssertNotNil(store.image(for: light)); XCTAssertNotNil(store.image(for: dark))
        selection.key = light
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try pixel(controller.view, x: 40), [255, 0, 0, 255])
    }

    func testFractionalWidthsReuseGrainPathsUntilTheAndroidGridChanges() {
        let first = FrostedGrainCache.paths(size: CGSize(width: 220.1, height: 44.1))
        let generations = FrostedGrainCache.generationCount
        for index in 0..<240 {
            let width = 220.1 + CGFloat(index) / 60
            let paths = FrostedGrainCache.paths(size: CGSize(width: width, height: 44.1))
            XCTAssertEqual(paths.light, first.light); XCTAssertEqual(paths.dark, first.dark)
        }
        XCTAssertEqual(FrostedGrainCache.generationCount, generations)
        let wider = FrostedGrainCache.paths(size: CGSize(width: 225.6, height: 44.1))
        XCTAssertNotEqual(wider.light, first.light)
        let taller = FrostedGrainCache.paths(size: CGSize(width: 220.1, height: 49.6))
        XCTAssertNotEqual(taller.dark, first.dark)
        let returned = FrostedGrainCache.paths(size: CGSize(width: 220.1, height: 44.1))
        XCTAssertEqual(returned.light, first.light); XCTAssertEqual(returned.dark, first.dark)
    }
}
