import XCTest
import SwiftUI
import Combine
@testable import ZTransfer

@MainActor
final class PremiumFireworksTests: XCTestCase {
    func testRenderedLaunchBurstAndFadeFrames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("premium-firework-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for seed in [1, 4] {
            for elapsed in [0.2, 0.48, 1.2, 1.8] {
                let drawing = PremiumFireworkDrawing(seed: seed)
                let canvas = Canvas { context, size in drawing.draw(context: context, size: size, elapsed: elapsed) }
                    .frame(width: 256, height: 384)
                    .background(Color.white)
                let renderer = ImageRenderer(content: canvas)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage)
                let data = try XCTUnwrap(image.pngData())
                let name = "firework-\(seed)-\(Int(elapsed * 1000))"
                let referenceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "png"))
                let reference = try XCTUnwrap(UIImage(contentsOfFile: referenceURL.path)?.cgImage)
                let actual = try XCTUnwrap(image.cgImage)
                XCTAssertTrue(try pixels(actual) == pixels(reference),
                              "Precomputed particles must preserve the original frame: \(name)")
                try data.write(to: folder.appendingPathComponent(name + ".png"))
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(image.size, CGSize(width: 256, height: 384))
            }
        }
        print("FIREWORK_FRAMES \(folder.path)")
    }

    private func pixels(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }
}

@MainActor
final class PremiumBadgePerformanceTests: XCTestCase {
    func testNativeSheenMatchesCanvasAtFixedPhasesAndSizes() throws {
        for size in [CGSize(width: 80, height: 28), CGSize(width: 140, height: 28), CGSize(width: 280, height: 48)] {
            for elapsed in [0.0, 0.25, 0.65, 1.0, 1.5, 2.3] {
                let native = ProBadgeSheenView(now: { elapsed })
                native.frame = CGRect(origin: .zero, size: size)
                native.configure(origin: 0, paused: true)
                native.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let actual = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    native.layer.render(in: context.cgContext)
                }
                let reference = ImageRenderer(content: Canvas { graphics, bounds in
                    let x = bounds.width * (-1 + elapsed / 2.6 * 3)
                    graphics.fill(Path(CGRect(x: x, y: 0, width: bounds.width, height: bounds.height)),
                        with: .linearGradient(Gradient(colors: [.clear,
                            Color(red: 1, green: 229.0 / 255, blue: 160.0 / 255).opacity(0.65), .clear]),
                            startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + bounds.width, y: 0)))
                }.frame(width: size.width, height: size.height).background(.white))
                reference.scale = 1
                let expected = try XCTUnwrap(reference.uiImage)
                let lhs = try pixels(actual), rhs = try pixels(expected)
                if size.width == 140 && elapsed == 1 {
                    for (name, image) in [("pro-sheen-native", actual), ("pro-sheen-canvas", expected)] {
                        let attachment = XCTAttachment(image: image)
                        attachment.name = name; attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
                XCTAssertEqual(lhs.count, rhs.count)
                let differences = zip(lhs, rhs).map { abs(Int($0.0) - Int($0.1)) }
                let mean = Double(differences.reduce(0, +)) / Double(max(1, differences.count))
                XCTAssertLessThanOrEqual(mean, 0.25, "size=\(size), elapsed=\(elapsed), mean=\(mean)")
                XCTAssertFalse(native.isAnimating)
            }
        }
    }

    func testLayerRunsWithoutSwiftUIFrameUpdatesAndPreservesPauseResizeReentry() async throws {
        let counts = Counts()
        let configuration = Configuration()
        let host = UIHostingController(rootView: Harness(configuration: configuration, counts: counts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let sheen = try XCTUnwrap(find(in: host.view))
        let band = try XCTUnwrap(sheen.layer.sublayers?.first)
        XCTAssertTrue(sheen.isAnimating)
        let first = try XCTUnwrap(band.presentation()).position.x
        let bodyCount = counts.body
        let parentCount = counts.parent
        try await Task.sleep(for: .milliseconds(140))
        let later = try XCTUnwrap(band.presentation()).position.x
        XCTAssertGreaterThan(later, first)
        XCTAssertEqual(later - first, sheen.bounds.width * 3 * 0.14 / 2.6, accuracy: 6)
        XCTAssertEqual(counts.body, bodyCount)
        XCTAssertEqual(counts.parent, parentCount)
        let animation = try XCTUnwrap(band.animation(forKey: "pro-sheen"))
        for _ in 0..<120 { sheen.configure(origin: configuration.origin, paused: false); sheen.layoutIfNeeded() }
        XCTAssertEqual(band.animation(forKey: "pro-sheen")?.beginTime, animation.beginTime)
        configuration.paused = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(sheen.isAnimating)
        let frozen = band.position.x
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(band.position.x, frozen)
        configuration.paused = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(sheen.isAnimating)
        configuration.width = 200
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sheen.bounds.width, 200)
        let resized = try XCTUnwrap(band.animation(forKey: "pro-sheen") as? CABasicAnimation)
        XCTAssertEqual(resized.fromValue as? Double, -100)
        XCTAssertEqual(resized.toValue as? Double, 500)
        XCTAssertEqual(resized.duration, 2.6)
        host.view.removeFromSuperview()
        XCTAssertFalse(sheen.isAnimating)
        host.view.frame = window.bounds; window.addSubview(host.view)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(sheen.isAnimating)
        sheen.stop()
        XCTAssertFalse(sheen.isAnimating)
    }

    func testRepeatedEntitlementAndClearMessageDoNotRepublishEmptyState() {
        let suite = "premium-publish-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let entitlements = PremiumEntitlementStore(access: PremiumAccess(.free))
        entitlements.enableDevelopmentPurchases(defaults: defaults)
        let purchases = StoreKitPurchaseStore(entitlementStore: entitlements)
        var entitlementUpdates = 0, purchaseUpdates = 0
        let a = entitlements.objectWillChange.sink { entitlementUpdates += 1 }
        let b = purchases.objectWillChange.sink { purchaseUpdates += 1 }
        defer { a.cancel(); b.cancel() }
        for _ in 0..<120 { entitlements.publish(.free); purchases.clearMessage() }
        XCTAssertEqual(entitlementUpdates, 0); XCTAssertEqual(purchaseUpdates, 0)
        entitlements.simulatePurchase(.lifetime)
        XCTAssertEqual(entitlements.entitlement, .lifetime)
        let updated = entitlementUpdates
        for _ in 0..<120 { entitlements.publish(.free) }
        XCTAssertEqual(entitlementUpdates, updated)
        entitlements.endSimulatedPurchase()
        XCTAssertEqual(entitlements.entitlement, .free)
        let revoked = entitlementUpdates
        for _ in 0..<120 { entitlements.endSimulatedPurchase() }
        XCTAssertEqual(entitlementUpdates, revoked)
    }

    private final class Counts { var parent = 0; var body = 0 }
    @MainActor private final class Configuration: ObservableObject {
        @Published var paused = false
        @Published var width: CGFloat = 140
        let origin = Date().timeIntervalSinceReferenceDate - 0.5
    }
    private struct Harness: View {
        @ObservedObject var configuration: Configuration
        let counts: Counts
        var body: some View {
            counts.parent += 1
            return Child(origin: configuration.origin, paused: configuration.paused, width: configuration.width, counts: counts)
        }
    }
    private struct Child: View {
        let origin: TimeInterval
        let paused: Bool
        let width: CGFloat
        let counts: Counts
        var body: some View {
            counts.body += 1
            return ProBadgeSheen(origin: origin, paused: paused).frame(width: width, height: 28)
        }
    }
    private func find(in view: UIView) -> ProBadgeSheenView? {
        (view as? ProBadgeSheenView) ?? view.subviews.lazy.compactMap { self.find(in: $0) }.first
    }
    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        var result = [UInt8](repeating: 0, count: source.width * source.height * 4)
        try result.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        }
        return result
    }
}

@MainActor
final class PremiumFireworksPerformanceTests: XCTestCase {
    func testIndependentLaunchesKeepIdentityAndUnknownFinishDoesNotPublish() {
        let state = PremiumFireworks()
        var publications = 0
        let observation = state.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<120 { state.finish(-1) }
        XCTAssertEqual(publications, 0)
        for _ in 0..<20 { state.launch() }
        XCTAssertEqual(state.active.map(\.id), Array(1...20))
        XCTAssertEqual(publications, 20)
        state.finish(7)
        XCTAssertEqual(state.active.map(\.id), Array(1...20).filter { $0 != 7 })
        let removed = publications
        for _ in 0..<120 { state.finish(7) }
        XCTAssertEqual(publications, removed)
        state.launch()
        XCTAssertEqual(state.active.last?.id, 21)
    }

    func testRealOverlayRunsConcurrentLaunchesWithoutRebuildingOwnerAndFinishes() async throws {
        let state = PremiumFireworks()
        let counts = Counts()
        var memberships: [[Int]] = []
        let observation = state.$active.sink { memberships.append($0.map(\.id)) }
        defer { observation.cancel() }
        let (host, window) = try mount(Harness(state: state, counts: counts))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(80))
        let bodyCount = counts.body
        let firstStart = CACurrentMediaTime()
        state.launch()
        try await Task.sleep(for: .milliseconds(250))
        let secondStart = CACurrentMediaTime()
        state.launch()
        XCTAssertEqual(state.active.map(\.id), [1, 2])
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(counts.body, bodyCount, "Animation and membership changes must stay below the owner")
        XCTAssertEqual(counts.exploded.count, 2)
        for (index, start) in [firstStart, secondStart].enumerated() {
            XCTAssertGreaterThanOrEqual(counts.exploded[index] - start, 0.39)
            XCTAssertLessThan(counts.exploded[index] - start, 0.7)
        }
        // Observe every membership event rather than requiring a polling
        // instant to land between the two completion callbacks.
        for _ in 0..<100 {
            if state.active.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(state.active.isEmpty)
        XCTAssertEqual(memberships, [[], [1], [1, 2], [2], []])
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - secondStart, 1.99)
        XCTAssertEqual(counts.body, bodyCount)
        let empty = snapshot(host.view).pngData()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(snapshot(host.view).pngData(), empty)
        XCTAssertEqual(counts.exploded.count, 2)
    }

    func testLiveOverlayChangesPixelsWithoutRebuildingOwner() async throws {
        let state = PremiumFireworks(), counts = Counts()
        let (host, window) = try mount(Harness(state: state, counts: counts))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(80))
        let bodyCount = counts.body
        state.launch()
        try await Task.sleep(for: .milliseconds(250))
        let rising = snapshot(host.view)
        try await Task.sleep(for: .milliseconds(450))
        let bursting = snapshot(host.view)
        XCTAssertNotEqual(rising.pngData(), bursting.pngData())
        XCTAssertEqual(counts.body, bodyCount)
        // drawHierarchy may synchronously wait for the simulator's Metal
        // pipeline. Keep pixel capture out of the separate timing test above.
        for (name, image) in [("fireworks-live-rise", rising), ("fireworks-live-burst", bursting)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testUnmountCancelsPendingHapticAndReleasesState() async throws {
        var state: PremiumFireworks? = PremiumFireworks()
        weak var weakState = state
        let counts = Counts()
        let (host, window) = try mount(Harness(state: try XCTUnwrap(state), counts: counts))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(50))
        state?.launch()
        try await Task.sleep(for: .milliseconds(80))
        host.rootView = AnyView(Color.clear)
        state = nil
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(counts.exploded.isEmpty)
        XCTAssertNil(weakState, "Cancelled animation tasks must not retain the departed page")
    }

    @MainActor private final class Counts {
        var body = 0
        var exploded: [CFTimeInterval] = []
    }
    private struct Harness: View {
        // Same ownership as SettingsPopupOverlay: retain here, observe only
        // in the production drawing overlay below.
        @State var state: PremiumFireworks
        let counts: Counts
        var body: some View {
            counts.body += 1
            return ZStack {
                Color.white
                PremiumFireworksOverlay(state: state, onExploded: { counts.exploded.append(CACurrentMediaTime()) })
            }
        }
    }
    private func mount<V: View>(_ content: V) throws -> (UIHostingController<AnyView>, UIWindow) {
        let host = UIHostingController(rootView: AnyView(content))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 256, height: 384)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        return (host, window)
    }
    private func snapshot(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }
}
