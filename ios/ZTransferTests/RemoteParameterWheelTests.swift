import XCTest
import SwiftUI
import Combine
@testable import ZTransfer

final class RemoteParameterWheelTests: XCTestCase {
    private let iso: [UInt64] = [100, 200, 400, 800, 1600, 3200]
    private func config(_ current: UInt64, values: [UInt64]? = nil, writable: Bool = true,
                        auto: Bool? = nil) -> RemoteParameterWheel.Configuration {
        .init(descriptor: .init(property: .iso, writable: writable, current: current, values: values ?? iso),
              autoEnabled: auto, hasAutoControl: auto != nil)
    }

    func testNearestPhysicalAnchorAndEnumDirection() {
        let negative = UInt64(bitPattern: -1000)
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .exposureCompensation,
            values: [negative, 0, 1000], current: UInt64(bitPattern: -800)), 0)
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .iso, values: iso, current: 300), 1) // first tie
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .iso, values: [], current: 400), -1)
        let shutter: [UInt64] = [0xFFFF_FFFF, 1 << 16 | 30, 1 << 16 | 125, 1 << 16 | 1000]
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .nikonShutter, values: shutter, current: 1 << 16 | 100), 2)
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .nikonShutter, values: shutter), 1)
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .fNumber, values: [280, 400, 560]), -1)
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .iso, values: iso.reversed()), -1)
    }

    func testNonEnumAnchorDisplaysTrueValueAndCrossingRequestsDelta() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(300))
        wheel.advance(0); wheel.advance(180_000_000)
        XCTAssertEqual(wheel.rows.first { $0.index == 1 }?.value, 300)
        wheel.beginDrag()
        XCTAssertEqual(wheel.position.value, 1)
        XCTAssertNil(wheel.drag(by: 8))
        XCTAssertEqual(wheel.drag(by: 2), 1)
        XCTAssertEqual(wheel.drag(by: 36), 2)
    }

    func testRubberBandHasBoundedDebtAndReversalRespondsImmediately() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(3200)); wheel.beginDrag()
        XCTAssertNil(wheel.drag(by: 10000))
        XCTAssertEqual(wheel.position.value, 5.45, accuracy: 0.00001)
        XCTAssertNil(wheel.drag(by: -9))
        XCTAssertEqual(wheel.position.value, 5.3, accuracy: 0.00001)
        XCTAssertEqual(wheel.drag(by: -36), -1)
        XCTAssertEqual(wheel.position.value, 4)
        XCTAssertEqual(wheel.drag(by: -10000), -4)
        XCTAssertEqual(wheel.position.value, -0.45, accuracy: 0.00001)
        XCTAssertNil(wheel.drag(by: 9))
        XCTAssertEqual(wheel.position.value, -0.3, accuracy: 0.00001)
    }

    func testDomainShrinkPreservesGestureWithoutLargeCompensatingStep() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(3200)); wheel.beginDrag()
        wheel.configure(config(200, values: [100, 200]))
        XCTAssertTrue(wheel.dragging)
        XCTAssertNil(wheel.drag(by: 1))
        XCTAssertEqual(wheel.drag(by: -19), -1)
        wheel.configure(config(100, values: []))
        XCTAssertFalse(wheel.dragging)
        XCTAssertNil(wheel.drag(by: 18))
    }

    func testCancelAndReleaseAlignLatestExternalValueWithoutInertia() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(400)); wheel.beginDrag()
        XCTAssertEqual(wheel.drag(by: 27), 2)
        // Camera write failed/physical dial changed while finger remained down.
        wheel.configure(config(200))
        XCTAssertTrue(wheel.dragging)
        XCTAssertEqual(wheel.position.value, 3.5)
        wheel.endDrag()
        XCTAssertEqual(wheel.position.target, 1)
        wheel.advance(0); wheel.advance(180_000_000)
        XCTAssertEqual(wheel.position.value, 1)
        XCTAssertFalse(wheel.position.isRunning)
    }

    func testLargeExternalJumpSnapsAndSmallJumpUses180msCurve() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(3200))
        XCTAssertEqual(wheel.position.value, 5)
        XCTAssertFalse(wheel.position.isRunning)
        wheel.configure(config(800))
        wheel.advance(0); wheel.advance(90_000_000)
        XCTAssertEqual(wheel.position.value, 5 - 2 * ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
        // Catching an in-flight wheel restarts from actual camera anchor.
        wheel.beginDrag()
        XCTAssertEqual(wheel.position.value, 3)
        XCTAssertFalse(wheel.position.isRunning)
    }

    func testReturningToDisplayedAnchorCancelsPendingExternalAnimation() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(100))
        wheel.configure(config(200))
        XCTAssertTrue(wheel.position.isRunning)
        wheel.configure(config(100)) // returns before the animation's first frame
        XCTAssertFalse(wheel.position.isRunning)
        wheel.advance(1_000_000_000)
        XCTAssertEqual(wheel.position.value, 0)
    }

    func testWritableDirectionAndAutoKeyChangesCancelGesture() {
        for next in [config(400, writable: false), config(400, values: iso.reversed()), config(400, auto: false)] {
            var wheel = RemoteParameterWheel()
            wheel.configure(config(400)); wheel.beginDrag(); _ = wheel.drag(by: 10)
            wheel.configure(next)
            XCTAssertFalse(wheel.dragging)
            XCTAssertEqual(wheel.position.target, Float(next.anchor))
        }
        var wheel = RemoteParameterWheel()
        wheel.configure(config(400, auto: true)); wheel.beginDrag()
        XCTAssertFalse(wheel.dragging)
        XCTAssertFalse(wheel.showsDragHint)
    }

    func testRowDepthAndNeighborFadeFollowDragAndSnap() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(400)); wheel.beginDrag()
        wheel.advance(0); wheel.advance(150_000_000)
        XCTAssertEqual(wheel.neighbors.value, 1)
        let neighbor = wheel.rows.first { $0.index == 3 }!
        XCTAssertEqual(neighbor.offset, -18)
        XCTAssertEqual(neighbor.alpha, 0.38, accuracy: 0.00001)
        XCTAssertEqual(neighbor.scale, 0.85, accuracy: 0.00001)
        _ = wheel.drag(by: 6)
        wheel.endDrag()
        wheel.advance(200_000_000); wheel.advance(380_000_000)
        XCTAssertFalse(wheel.position.isRunning)
        wheel.advance(530_000_000)
        XCTAssertEqual(wheel.neighbors.value, 0)
        XCTAssertFalse(wheel.needsFrames)
        XCTAssertEqual(wheel.rows.filter { $0.alpha > 0 }.map(\.index), [2])
    }

    func testShortDomainsStillDragButDoNotShowDecorativeHint() {
        // ReleaseCommitWheelTest's >3 rule governs only ParamTile's hint.
        for count in [2, 3, 4] {
            var wheel = RemoteParameterWheel()
            wheel.configure(config(100, values: Array(iso.prefix(count))))
            XCTAssertEqual(wheel.showsDragHint, count > 3)
            wheel.beginDrag()
            XCTAssertEqual(wheel.drag(by: 18), 1)
        }
    }

    func testCompactGeometryAndMonitorFormattingMatchAndroid() {
        let compact = RemoteParameterTileGeometry(width: 88, height: 42)
        XCTAssertEqual(compact.valueFontSize, 14)
        XCTAssertEqual(compact.valueLineHeight, 16)
        XCTAssertEqual(compact.labelTop, 2)
        XCTAssertEqual(compact.autoBadgeWidth, 32)
        XCTAssertEqual(compact.autoBadgeHeight, 17)
        XCTAssertEqual(compact.autoBadgeFontSize, 7)
        let regular = RemoteParameterTileGeometry(width: 180, height: 54)
        XCTAssertEqual(regular.valueFontSize, 16)
        XCTAssertEqual(regular.autoBadgeWidth, 44)
        XCTAssertEqual(regular.autoBadgeHeight, 22)
        XCTAssertEqual(regular.autoBadgeFontSize, 9)
        XCTAssertTrue(regular.isAutoTouch(CGPoint(x: 136, y: 30)))
        XCTAssertFalse(regular.isAutoTouch(CGPoint(x: 135, y: 30)))
        XCTAssertEqual(RemoteExposureParameters.monitorFormat(.iso, raw: 400), "400")
        XCTAssertEqual(RemoteExposureParameters.monitorFormat(.movieExposureCompensation, raw: UInt64(bitPattern: -1000)), "-1.0")
        XCTAssertEqual(RemoteExposureParameters.monitorFormat(.fNumber, raw: 280), "f/2.8")
    }

    func testTouchConsumesOnlyVerticalSlopAndNeverTapsAfterDragOrCancel() {
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 54)
        var input = RemoteParameterTouch()
        input.down(CGPoint(x: 170, y: 10)) // AUTO region
        XCTAssertEqual(input.move(CGPoint(x: 170, y: 18), bounds: bounds, writable: true), [.begin, .delta(0)])
        XCTAssertEqual(input.move(CGPoint(x: 170, y: 20), bounds: bounds, writable: true), [.delta(2)])
        XCTAssertEqual(input.move(CGPoint(x: 170, y: 25), bounds: bounds, writable: true), [.delta(5)])
        XCTAssertEqual(input.up(CGPoint(x: 170, y: 25), bounds: bounds), [.end])
        input.down(CGPoint(x: 170, y: 10))
        XCTAssertEqual(input.up(CGPoint(x: 170, y: 10), bounds: bounds), [.tap(CGPoint(x: 170, y: 10))])
        input.down(CGPoint(x: 170, y: 10))
        _ = input.move(CGPoint(x: 170, y: 25), bounds: bounds, writable: true)
        XCTAssertEqual(input.cancel(), [.end])
        XCTAssertEqual(input.up(CGPoint(x: 170, y: 25), bounds: bounds), [])
    }

    @MainActor
    func testActualInputRoutesAutoHitRegionBusyStateAndWholeCardDrag() {
        let view = RemoteParameterInput.InputView(frame: CGRect(x: 0, y: 0, width: 180, height: 54))
        var opened = 0, toggled = 0, began = 0
        func configure(busy: Bool, auto: Bool) {
            view.configure(.init(configuration: config(400, auto: auto), autoBusy: busy,
                identifier: "iso", label: "ISO", value: "400", onOpenList: { opened += 1 },
                onAutoToggle: { toggled += 1 }, onBegin: { began += 1 }, onDrag: { _ in }, onEnd: {}))
        }
        configure(busy: false, auto: false)
        view.deliver([.tap(CGPoint(x: 170, y: 10))])
        view.deliver([.tap(CGPoint(x: 90, y: 30))])
        view.deliver([.begin, .delta(18), .end])
        XCTAssertEqual(toggled, 1); XCTAssertEqual(opened, 1); XCTAssertEqual(began, 1)
        configure(busy: true, auto: false)
        view.deliver([.tap(CGPoint(x: 170, y: 10))])
        XCTAssertEqual(toggled, 1)
        configure(busy: false, auto: true)
        view.deliver([.tap(CGPoint(x: 90, y: 30))])
        XCTAssertEqual(opened, 1)
    }

    func testPointerHandoffRetainsSlopAndAvoidsJumpBetweenFingers() {
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 54)
        var input = RemoteParameterTouch()
        input.down(CGPoint(x: 20, y: 10))
        XCTAssertEqual(input.move(CGPoint(x: 20, y: 16), bounds: bounds, writable: true), [])
        input.handOff(to: CGPoint(x: 100, y: 30))
        XCTAssertEqual(input.move(CGPoint(x: 100, y: 34), bounds: bounds, writable: true), [.begin, .delta(2)])
        input.handOff(to: CGPoint(x: 10, y: 10))
        XCTAssertEqual(input.move(CGPoint(x: 10, y: 13), bounds: bounds, writable: true), [.delta(3)])
        XCTAssertEqual(input.up(CGPoint(x: 10, y: 13), bounds: bounds), [.end])
    }
}


@MainActor
final class RemoteParameterPerformanceTests: XCTestCase {
    func testStableConfigurationAndDisplayFramesDoNotRepeatFormattingOrPublishIdleState() {
        var formats = 0
        let cache = RemoteParameterPresentationCache { property, value in
            formats += 1
            return RemoteExposureParameters.monitorFormat(property, raw: value)
        }
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 400,
            values: [100, 200, 400, 800, 1600, 3200])
        let driver = RemoteParameterWheelDriver()
        let config = cache.configuration(descriptor: descriptor, autoEnabled: nil, hasAutoControl: false)
        driver.configure(config)
        driver.advance(0); driver.advance(180_000_000); driver.advance(330_000_000)
        var notifications = 0
        let subscription = driver.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        for frame in 0..<120 {
            driver.configure(cache.configuration(descriptor: descriptor, autoEnabled: nil, hasAutoControl: false))
            driver.advance(400_000_000 + Int64(frame) * 16_666_667)
            for row in driver.display.rows { _ = cache.label(.iso, value: row.value) }
        }
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(formats, 5)
        driver.begin()
        XCTAssertEqual(driver.drag(18), 1, "Crossing must still emit before finger release")
        XCTAssertTrue(driver.display.dragging)
        let before = notifications
        _ = driver.drag(0)
        XCTAssertEqual(notifications, before)
        XCTAssertEqual(cache.label(.iso, value: 300), "300", "Non-enumerated physical value remains literal")
        XCTAssertEqual(cache.label(.fNumber, value: 300), "f/3.0", "Property changes invalidate labels")
    }

    func testClockStopsAtRestAndOffscreenAndDoesNotRetainOwner() throws {
        var driver: RemoteParameterWheelDriver? = RemoteParameterWheelDriver()
        weak var weakDriver = driver
        driver?.setActive(true)
        XCTAssertFalse(try XCTUnwrap(driver).clockRunning, "Loading pulse belongs to the native glyph, not a SwiftUI frame clock")
        var notifications = 0
        let subscription = driver?.objectWillChange.sink { notifications += 1 }
        for frame in 0..<240 { driver?.advance(Int64(frame) * 16_666_667) }
        XCTAssertEqual(notifications, 0, "Waiting for the camera must not redraw the tile every frame")
        subscription?.cancel()
        let descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 100, values: [100, 200])
        driver?.configure(.init(descriptor: descriptor))
        XCTAssertFalse(try XCTUnwrap(driver).clockRunning)
        driver?.begin(); XCTAssertTrue(try XCTUnwrap(driver).clockRunning)
        driver?.setActive(false)
        XCTAssertFalse(try XCTUnwrap(driver).clockRunning)
        XCTAssertFalse(try XCTUnwrap(driver).display.dragging)
        driver?.configure(.init()) // late offscreen descriptor updates must not restart a timer
        XCTAssertFalse(try XCTUnwrap(driver).clockRunning)
        driver?.setActive(true)
        // A preceding drag still owns its finite 150ms neighbor fade. Let
        // that finish; the absent descriptor must not start an infinite clock.
        driver?.advance(4_000_000_000); driver?.advance(4_330_000_000)
        XCTAssertFalse(try XCTUnwrap(driver).clockRunning)
        driver = nil
        XCTAssertNil(weakDriver, "CADisplayLink must not own its driver")
    }

    func testLoadingGlyphKeepsAndroidCurveWithoutFramePublishingAndStopsOffscreen() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let mounted = RemoteParameterLoadingLabel(frame: CGRect(x: 30, y: 80, width: 30, height: 20))
        mounted.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
        window.rootViewController?.view.addSubview(mounted)
        mounted.setActive(true)
        let loop = try XCTUnwrap(mounted.layer.animation(forKey: "parameter.loading") as? CABasicAnimation)
        XCTAssertEqual(loop.fromValue as? Double, 0.25); XCTAssertEqual(loop.toValue as? Double, 0.55)
        XCTAssertEqual(loop.duration, 0.9); XCTAssertTrue(loop.autoreverses); XCTAssertEqual(loop.repeatCount, .infinity)
        for (index, expected) in [(1, [Float](arrayLiteral: 0.4, 0)), (2, [Float](arrayLiteral: 0.2, 1))] {
            var point: [Float] = [0, 0]
            loop.timingFunction?.getControlPoint(at: index, values: &point)
            XCTAssertEqual(point, expected)
        }
        // The actual render-server presentation must move through both halves
        // of the original curve; checking animation metadata alone is insufficient.
        var samples: [Float] = []
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(100))
            let actual = try XCTUnwrap(mounted.layer.presentation()).opacity
            let elapsed = mounted.layer.convertTime(CACurrentMediaTime(), from: nil) - loop.beginTime
            let phase = elapsed.truncatingRemainder(dividingBy: 1.8)
            let progress = Float(phase <= 0.9 ? phase / 0.9 : (1.8 - phase) / 0.9)
            let expected = 0.25 + 0.30 * ZTransferAndroidMotion.fastOutSlowIn(progress)
            XCTAssertEqual(actual, expected, accuracy: 0.03)
            samples.append(actual)
            mounted.setActive(true)
            XCTAssertEqual(mounted.layer.animation(forKey: "parameter.loading")?.beginTime, loop.beginTime,
                           "Unrelated parameter updates must not restart the pulse")
        }
        XCTAssertGreaterThan(try XCTUnwrap(samples.max()) - XCTUnwrap(samples.min()), 0.20)
        mounted.setActive(false)
        XCTAssertNil(mounted.layer.animation(forKey: "parameter.loading"))
        mounted.setActive(true)
        XCTAssertNotNil(mounted.layer.animation(forKey: "parameter.loading"))
        mounted.removeFromSuperview()
        XCTAssertNil(mounted.layer.animation(forKey: "parameter.loading"))
        weak var released: RemoteParameterLoadingLabel?
        do {
            let detached = RemoteParameterLoadingLabel()
            released = detached
            window.rootViewController?.view.addSubview(detached)
            detached.setActive(true)
            detached.removeFromSuperview()
        }
        try await Task.sleep(for: .milliseconds(80)) // UIKit commits removal before releasing the view.
        XCTAssertNil(released)
    }

    func testProductionLoadingTileKeepsParentStableAndRemovesPulseForReadyAutoAndBackground() async throws {
        let state = LoadingState()
        let probe = TileProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: LoadingHarness(state: state, probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 140)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        weak var first = try XCTUnwrap(find(RemoteParameterLoadingLabel.self, in: host.view))
        XCTAssertNotNil(first?.layer.animation(forKey: "parameter.loading"))
        let bodies = probe.bodies
        try await Task.sleep(for: .milliseconds(950))
        XCTAssertEqual(probe.bodies, bodies, "Loading opacity must not rebuild the tile's parent")
        state.phase = .background
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(first?.layer.animation(forKey: "parameter.loading"))
        state.phase = .active
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(first?.layer.animation(forKey: "parameter.loading"))
        state.descriptor = .init(property: .iso, writable: false, current: 400, values: [100, 200, 400])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(find(RemoteParameterLoadingLabel.self, in: host.view))
        XCTAssertNil(first)
        let input = try XCTUnwrap(find(RemoteParameterInput.InputView.self, in: host.view))
        let value = try XCTUnwrap((input.accessibilityElements as? [UIAccessibilityElement])?.first)
        XCTAssertEqual(value.accessibilityValue, "400")
        state.auto = true; state.descriptor = nil
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(find(RemoteParameterLoadingLabel.self, in: host.view), "AUTO's unknown ISO remains static")
        state.auto = false
        try await Task.sleep(for: .milliseconds(80))
        let restarted = try XCTUnwrap(find(RemoteParameterLoadingLabel.self, in: host.view))
        let loop = try XCTUnwrap(restarted.layer.animation(forKey: "parameter.loading"))
        XCTAssertLessThan(restarted.layer.convertTime(CACurrentMediaTime(), from: nil) - loop.beginTime, 0.3,
                          "A newly unloaded parameter starts a new pulse, not the removed glyph's phase")
    }

    func testNativeLoadingGlyphMatchesOriginalTextAtBothSizesAndThemes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: AnyView(Color.clear))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func pixels(saveAs name: String) throws -> Data {
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
            let cg = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return Data(bytes)
        }
        for dark in [false, true] {
            for compact in [false, true] {
                let size: CGFloat = compact ? 14 : 16
                let line: CGFloat = compact ? 16 : 20
                let scheme: ColorScheme = dark ? .dark : .light
                host.rootView = AnyView(Text("—")
                    .font(.system(size: size, weight: .semibold, design: .monospaced))
                    .lineLimit(1).fixedSize().frame(height: line)
                    .foregroundStyle(ZTransferColors.secondaryText.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ZTransferColors.background).environment(\.colorScheme, scheme))
                try await Task.sleep(for: .milliseconds(80))
                let reference = try pixels(saveAs: "ztransfer-loading-reference-\(dark)-\(compact)")
                let rgba = [UInt8](reference)
                let glyphPixels = stride(from: 0, to: rgba.count, by: 4).filter { offset in
                    abs(Int(rgba[offset]) - Int(rgba[0])) > 3 || abs(Int(rgba[offset + 1]) - Int(rgba[1])) > 3
                }.count
                XCTAssertGreaterThan(glyphPixels, 12, "Reference must contain visible glyph pixels, not two blank snapshots")
                host.rootView = AnyView(RemoteParameterInput(configuration: .init(), autoBusy: false,
                    identifier: "loading-reference", label: "ISO", value: "—", onOpenList: {},
                    onAutoToggle: nil, onBegin: {}, onDrag: { _ in }, onEnd: {})
                    .frame(width: 180, height: compact ? 42 : 54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ZTransferColors.background)
                    .environment(\.scenePhase, .background).environment(\.colorScheme, scheme))
                try await Task.sleep(for: .milliseconds(80))
                let native = try XCTUnwrap(find(RemoteParameterLoadingLabel.self, in: host.view))
                native.layer.opacity = 0.4
                CATransaction.flush()
                let actual = try pixels(saveAs: "ztransfer-loading-native-\(dark)-\(compact)")
                XCTAssertEqual(actual.count, reference.count)
                // Native layer opacity and SwiftUI foreground alpha round a
                // few antialiased edge samples differently (one 8-bit level).
                // Geometry, solid glyph and background pixels must still match;
                // a shifted/blurred/wrong-color glyph exceeds this bound.
                let largestDelta = zip(actual, reference).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(largestDelta, 1, "Loading glyph: compact=\(compact), dark=\(dark)")
            }
        }
    }

    func testMenuCacheRetainsLabelsAndMeasuredWidthAcrossSelectionAndScaleChanges() {
        let cache = RemoteParameterMenuCache()
        var descriptor = RemotePropertyDescriptor(property: .iso, writable: true, current: 400,
            values: Array(0..<10_000).map(UInt64.init))
        var formats = 0, measures = 0
        func resolve(_ scale: CGFloat) -> RemoteParameterMenuCache.Catalog {
            cache.resolve(descriptor: descriptor, scale: scale, format: { property, value in
                formats += 1; return RemoteExposureParameters.monitorFormat(property, raw: value)
            }, measure: { label, scale in measures += 1; return CGFloat(label.count) * 9 / scale })
        }
        let initial = resolve(2)
        XCTAssertEqual(formats, 10_000); XCTAssertEqual(measures, 10_000)
        for value in 0..<120 { descriptor.current = UInt64(value); XCTAssertTrue(resolve(2) === initial) }
        XCTAssertEqual(formats, 10_000); XCTAssertEqual(measures, 10_000)
        let scaled = resolve(3)
        XCTAssertFalse(scaled === initial)
        XCTAssertEqual(formats, 10_000); XCTAssertEqual(measures, 20_000)
        descriptor = .init(property: .iso, writable: true, current: 100, values: [100, 200])
        XCTAssertEqual(resolve(3).labels, [100: "100", 200: "200"])
        XCTAssertEqual(formats, 10_002)
    }

    func testHostedParameterMenuIsBoundedPositionsMinusThreeAndKeepsPositionOnCurrentUpdates() async throws {
        let state = MenuState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MenuHarness(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(450))
        let table = try XCTUnwrap(find(UITableView.self, in: host.view))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 3_000)
        XCTAssertLessThan(table.visibleCells.count, 25)
        let first = IndexPath(row: 2_497, section: 0)
        XCTAssertEqual(table.indexPathsForVisibleRows?.min(), first)
        XCTAssertEqual(table.rectForRow(at: first).minY - table.contentOffset.y, 0, accuracy: 1)
        let cell = try XCTUnwrap(table.cellForRow(at: first))
        let reference = ImageRenderer(content: RemoteParameterChoice(value: 2_497, label: "2497",
            selected: false, closing: false) {}.frame(width: table.bounds.width))
        let expected = try XCTUnwrap(reference.uiImage)
        XCTAssertEqual(cell.bounds.height, expected.size.height, accuracy: 0.001)
        table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y + 85), animated: false)
        try await Task.sleep(for: .milliseconds(50))
        let anchor = try XCTUnwrap(table.indexPathsForVisibleRows?.min())
        let y = table.rectForRow(at: anchor).minY - table.contentOffset.y
        state.current = 2_510
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(table.indexPathsForVisibleRows?.min(), anchor)
        XCTAssertEqual(table.rectForRow(at: anchor).minY - table.contentOffset.y, y, accuracy: 1)
        state.count = 2; state.current = 0
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
        XCTAssertEqual(table.bounds.height, expected.size.height * 2, accuracy: 1,
            "Short domain wraps its two rows without a tall empty scroll area")
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p20-short-menu.png"))
    }

    func testProductionTileDragAnimatesPixelsWithoutRebuildingParentOrLosingDetents() async throws {
        let probe = TileProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: TileHarness(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 140)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(420))
        let input = try XCTUnwrap(find(RemoteParameterInput.InputView.self, in: host.view))
        let beforeBodies = probe.bodies
        func screenshot() -> Data? {
            UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }.pngData()
        }
        let before = try XCTUnwrap(screenshot())
        input.deliver([.begin])
        for _ in 0..<20 {
            input.deliver([.delta(0.75)])
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertEqual(probe.steps, [1])
        XCTAssertEqual(probe.bodies, beforeBodies)
        XCTAssertNotEqual(try XCTUnwrap(screenshot()), before, "Real wheel pixels must move")
        input.deliver([.end])
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(probe.bodies, beforeBodies)
        XCTAssertEqual(probe.steps, [1], "Release must not write a second value")
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    private final class MenuState: ObservableObject {
        @Published var current: UInt64 = 2_500
        @Published var count = 3_000
    }
    private struct MenuHarness: View {
        @ObservedObject var state: MenuState
        var body: some View {
            RemoteParameterPanel(field: .iso,
                descriptor: .init(property: .iso, writable: true, current: state.current,
                                  values: Array(0..<state.count).map(UInt64.init)),
                anchor: CGRect(x: 100, y: 40, width: 120, height: 54),
                hostSize: CGSize(width: 320, height: 600), landscape: false,
                onSelect: { state.current = $0 }, onDismiss: {})
        }
    }
    private final class TileProbe { var bodies = 0; var steps: [Int] = [] }
    private final class LoadingState: ObservableObject {
        @Published var descriptor: RemotePropertyDescriptor?
        @Published var auto: Bool? = nil
        @Published var phase: ScenePhase = .active
    }
    private struct LoadingHarness: View {
        @ObservedObject var state: LoadingState
        let probe: TileProbe
        var body: some View {
            let _ = { probe.bodies += 1 }()
            RemoteExposureTile(field: .iso, descriptor: state.descriptor,
                onOpenList: {}, onStep: { probe.steps.append($0) },
                autoEnabled: state.auto, autoToggle: {})
                .frame(width: 180, height: 54).environment(\.scenePhase, state.phase)
        }
    }
    private struct TileHarness: View {
        let probe: TileProbe
        var body: some View {
            let _ = { probe.bodies += 1 }()
            RemoteExposureTile(field: .iso,
                descriptor: .init(property: .iso, writable: true, current: 400, values: [100, 200, 400, 800, 1600, 3200]),
                onOpenList: {}, onStep: { probe.steps.append($0) })
                .frame(width: 180, height: 54)
        }
    }
}
