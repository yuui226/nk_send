import XCTest
import SwiftUI
import UIKit
@testable import ZTransfer

final class NativeAttentionMotionTests: XCTestCase {
    func testCardWaveKeepsAndroidPeriodAmplitudeAndOppositePhase() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let usb = NativeAttentionConfiguration(kind: .card(offset: 0), origin: origin, enabled: true, paused: false)
        let wifi = NativeAttentionConfiguration(kind: .card(offset: 0.5), origin: origin, enabled: true, paused: false)
        XCTAssertEqual(usb.scale(at: origin), 1, accuracy: 1e-12)
        XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(2.4 * 0.38)), 1.04, accuracy: 1e-12)
        XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(2.4 * 0.82)), 1, accuracy: 1e-12)
        for i in 0...288 {
            let t = Double(i) / 120
            XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(t)),
                           usb.scale(at: origin.addingTimeInterval(t + 2.4)), accuracy: 1e-12)
            XCTAssertEqual(wifi.scale(at: origin.addingTimeInterval(t)),
                           usb.scale(at: origin.addingTimeInterval(t + 1.2)), accuracy: 1e-12)
            XCTAssertEqual(usb.scale(at: origin.addingTimeInterval(t), intensity: 0), 1)
        }
    }

    func testGPSAmbientPreservesBothCyclesAndStaticExpandedState() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        for enabled in [false, true] {
            var pulse = NativeAmbientPulse(origin: origin, minimum: enabled ? 0.075 : 0.050,
                maximum: enabled ? 0.160 : 0.145, halfPeriod: enabled ? 2.4 : 2.8,
                restingOpacity: enabled ? 0.105 : 0.070, breathing: true, paused: false)
            XCTAssertEqual(pulse.opacity(at: origin), pulse.minimum, accuracy: 1e-12)
            XCTAssertEqual(pulse.opacity(at: origin.addingTimeInterval(pulse.halfPeriod)), pulse.maximum, accuracy: 1e-12)
            XCTAssertEqual(pulse.opacity(at: origin.addingTimeInterval(pulse.halfPeriod * 2)), pulse.minimum, accuracy: 1e-12)
            pulse.breathing = false
            XCTAssertEqual(pulse.opacity(at: origin.addingTimeInterval(1)), pulse.restingOpacity)
        }
    }

    @MainActor
    func testCardFadeCanReverseAndKeepsWindowCoordinatesAndClickTarget() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let controller = UIViewController(); window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true }
        let view = NativeAttentionHostView(frame: CGRect(x: 30, y: 80, width: 160, height: 240))
        var reported: CGRect?
        view.onWindowFrameChange = { reported = $0 }
        controller.view.addSubview(view)
        view.setNeedsLayout(); view.layoutIfNeeded()
        let button = UIButton(frame: CGRect(x: 20, y: 40, width: 60, height: 40))
        var clicks = 0
        button.addAction(UIAction { _ in clicks += 1 }, for: .touchUpInside)
        view.host.rootView = AnyView(ZStack(alignment: .topLeading) {
            Color.clear
            HostedTestButton(button: button).frame(width: 60, height: 40).offset(x: 20, y: 40)
        })
        view.host.view.setNeedsLayout()
        view.host.view.layoutIfNeeded()
        let origin = Date().addingTimeInterval(-2.4 * 0.38)
        var config = NativeAttentionConfiguration(kind: .card(offset: 0), origin: origin, enabled: true, paused: true,
                                                   frozenDate: origin.addingTimeInterval(2.4 * 0.38))
        view.configure(config)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = CGPoint(x: center.x + (50 - center.x) * 1.04,
                            y: center.y + (60 - center.y) * 1.04)
        let hit = view.hitTest(point, with: nil)
        XCTAssertTrue(hit === button)
        (hit as? UIButton)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(clicks, 1)
        await Task.yield()
        XCTAssertEqual(reported, CGRect(x: 30, y: 80, width: 160, height: 240))
        config.paused = false; config.frozenDate = nil; view.configure(config)
        config.enabled = false; view.configure(config)
        let fade = try XCTUnwrap(view.motionView.layer.animation(forKey: "attention.fade") as? CAKeyframeAnimation)
        XCTAssertEqual(fade.duration, 0.32, accuracy: 0.01)
        XCTAssertNil(view.motionView.layer.animation(forKey: "attention.loop"))
        config.enabled = true; view.configure(config)
        XCTAssertNotNil(view.motionView.layer.animation(forKey: "attention.loop"))
        view.removeFromSuperview()
        XCTAssertTrue((view.motionView.layer.animationKeys() ?? []).isEmpty)
    }

    @MainActor
    func testNativeCardLoopSurvivesItsDelayedStart() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = UIViewController(); window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let initial = NativeAttentionHostView(frame: CGRect(x: 0, y: 0, width: 150, height: 200))
        let resumed = NativeAttentionHostView(frame: CGRect(x: 160, y: 0, width: 150, height: 200))
        for view in [initial, resumed] { window.rootViewController!.view.addSubview(view) }
        var config = NativeAttentionConfiguration(kind: .card(offset: 0), origin: Date(), enabled: true, paused: false)
        initial.configure(config)
        config.enabled = false; resumed.configure(config)
        config.enabled = true; resumed.configure(config)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNotNil(initial.motionView.layer.animation(forKey: "attention.loop"), "initial")
        XCTAssertNotNil(resumed.motionView.layer.animation(forKey: "attention.loop"), "resumed")
    }

    @MainActor
    func testAmbientLayerStopsOffWindowAndUsesNativeInfiniteClock() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = UIViewController(); window.isHidden = false
        defer { window.isHidden = true }
        let view = NativeAmbientFillView(frame: CGRect(x: 0, y: 0, width: 150, height: 50))
        window.rootViewController!.view.addSubview(view)
        var pulse = NativeAmbientPulse(origin: Date(), minimum: 0.05, maximum: 0.145, halfPeriod: 2.8,
                                       restingOpacity: 0.07, breathing: true, paused: false)
        view.configure(color: .blue, radius: 20, pulse: pulse)
        let animation = try XCTUnwrap(view.layer.animation(forKey: "ambient.opacity") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, 2.8)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertEqual(animation.repeatCount, .infinity)
        pulse.breathing = false
        view.configure(color: .blue, radius: 20, pulse: pulse)
        XCTAssertNil(view.layer.animation(forKey: "ambient.opacity"))
        XCTAssertEqual(view.layer.opacity, 0.07, accuracy: 1e-6)
        pulse.breathing = true
        view.configure(color: .blue, radius: 20, pulse: pulse)
        view.removeFromSuperview()
        XCTAssertNil(view.layer.animation(forKey: "ambient.opacity"))
    }
}

private struct HostedTestButton: UIViewRepresentable {
    let button: UIButton
    func makeUIView(context: Context) -> UIButton { button }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}

@MainActor
final class ConnectionTimelinePerformanceTests: XCTestCase {
    private final class Input: ObservableObject {
        @Published var start: Date?
        @Published var phase: ScenePhase = .active
        init(start: Date?) { self.start = start }
    }
    private final class Frames {
        var values: [Double] = []
        var count: Int { values.count }
        var latest: Double { values.last ?? -1 }
    }
    private struct Harness: View {
        @ObservedObject var input: Input
        let duration: Double
        let frames: Frames
        var body: some View {
            ConnectionAnimationTimeline(start: input.start, duration: duration) { elapsed in
                let _ = frames.values.append(elapsed)
                Rectangle().fill(Color.red).opacity(1 - elapsed / (duration * 1_000))
            }
            .environment(\.scenePhase, input.phase)
        }
    }

    private func mount(_ input: Input, duration: Double, frames: Frames) -> (UIWindow, UIHostingController<Harness>) {
        let host = UIHostingController(rootView: Harness(input: input, duration: duration, frames: frames))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 160, height: 100))
        window.rootViewController = host; window.isHidden = false
        host.view.layoutIfNeeded()
        return (window, host)
    }

    func testBothProductionStagesStopAtTheirExactEndpointWithoutLosingFrames() async throws {
        for duration in [0.62, 1.38] {
            let input = Input(start: nil), frames = Frames()
            let (window, host) = mount(input, duration: duration, frames: frames)
            defer { window.isHidden = true; window.rootViewController = nil; _ = host }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(frames.latest, 0)
            let idle = frames.count
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(frames.count, idle)
            input.start = Date()
            for _ in 0..<200 {
                if frames.latest == duration * 1_000 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(frames.values.contains { $0 > 0 && $0 < duration * 1_000 })
            XCTAssertEqual(frames.latest, duration * 1_000)
            try await Task.sleep(for: .milliseconds(40))
            let settled = frames.count
            try await Task.sleep(for: .milliseconds(140))
            XCTAssertEqual(frames.count, settled, "A finished stage must not keep updating at display cadence")
        }
    }

    func testReplacementAndForegroundResumeUseNewAbsoluteEpochAndUnmountCancelsClock() async throws {
        let input = Input(start: Date()), frames = Frames()
        var mounted: (UIWindow, UIHostingController<Harness>)? = mount(input, duration: 0.62, frames: frames)
        weak var weakHost = mounted?.1
        try await Task.sleep(for: .milliseconds(200))
        let replacement = Date()
        input.start = replacement
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertLessThan(frames.latest, 200)
        input.phase = .background
        try await Task.sleep(for: .milliseconds(40))
        let paused = frames.count
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertEqual(frames.count, paused)
        input.phase = .active
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(frames.latest, 140, "Resume must catch up, not restart the scene")
        // Cross the original deadline while the replacement is still live.
        let untilOldDeadline = max(0, 0.47 - Date().timeIntervalSince(replacement))
        try await Task.sleep(for: .seconds(untilOldDeadline))
        XCTAssertLessThan(frames.latest, 620, "The cancelled old deadline cannot finish a new epoch")
        input.start = nil
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(frames.latest, 0)
        input.start = Date()
        try await Task.sleep(for: .milliseconds(30))
        mounted?.0.isHidden = true
        mounted?.0.rootViewController = nil
        mounted = nil
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(weakHost)
        let removed = frames.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.count, removed)
    }
}


@MainActor
final class GPSPresentationPerformanceTests: XCTestCase {
    private final class Input: ObservableObject {
        @Published var active = false
        @Published var phase: ScenePhase = .active
        @Published var date = Date().addingTimeInterval(-27)
    }
    private final class Frames {
        var parent = 0
        var values: [String] = []
    }
    private struct Harness: View {
        @ObservedObject var input: Input
        let frames: Frames
        var body: some View {
            let _ = frames.parent += 1
            GPSCountdownScope(lastSentAt: input.date, frequency: .thirtySeconds, active: input.active) { text in
                let _ = frames.values.append(text)
                Text(text)
            }.environment(\.scenePhase, input.phase)
        }
    }

    func testActualCountdownTicksOnlyItsLeafAndSleepsWhenHiddenBackgroundedOrExpired() async throws {
        let input = Input(), frames = Frames()
        var host: UIHostingController<Harness>? = UIHostingController(rootView: Harness(input: input, frames: frames))
        weak var weakHost = host
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host!.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let hidden = frames.values.count
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(frames.values.count, hidden)
        input.active = true
        try await Task.sleep(for: .milliseconds(100))
        let parent = frames.parent, started = frames.values.count
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertGreaterThan(frames.values.count, started)
        XCTAssertEqual(frames.parent, parent)
        input.phase = .background
        try await Task.sleep(for: .milliseconds(100))
        let background = frames.values.count
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(frames.values.count, background)
        input.phase = .active
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.values.last, "0:00")
        let expired = frames.values.count
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(frames.values.count, expired)
        input.date = Date()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.values.last, "0:30")
        let renewed = frames.values.count
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertGreaterThan(frames.values.count, renewed)
        XCTAssertEqual(frames.values.last, "0:29")
        input.active = false
        try await Task.sleep(for: .milliseconds(100))
        let closed = frames.values.count
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(frames.values.count, closed)
        window.isHidden = true; window.rootViewController = nil; host = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakHost)
    }

    func testEntryProjectionCoversEveryStatusAndLastSentTextReusesFormatting() {
        let statuses: [GPSStatus] = [.off, .starting, .searching, .needsCamera, .connecting, .pairing,
            .cameraConfirm, .pairingSuccess, .connected, .writing, .waitingFix, .ready, .apUnavailable, .error]
        for enabled in [false, true] {
            for status in statuses {
                let value = GPSEntryPresentation.Snapshot(GPSState(enabled: enabled, status: status))
                XCTAssertEqual(value.enabled, enabled)
                let expected: GPSEntryPresentation.Snapshot.Accent
                if !enabled || status == .off { expected = .waiting }
                else if [.pairingSuccess, .connected, .writing, .waitingFix, .ready].contains(status) { expected = .connected }
                else if [.apUnavailable, .error].contains(status) { expected = .error }
                else { expected = .blue }
                XCTAssertEqual(value.accent, expected)
            }
        }
        let formatter = GPSLastSentText()
        XCTAssertEqual(formatter.text(for: nil), "--:--:--")
        for _ in 0..<120 { XCTAssertEqual(formatter.text(for: Date(timeIntervalSince1970: 0)), "08:00:00") }
        XCTAssertEqual(formatter.formatCount, 1)
        XCTAssertEqual(formatter.text(for: Date(timeIntervalSince1970: 3661)), "09:01:01")
        XCTAssertEqual(formatter.formatCount, 2)
        XCTAssertEqual(formatter.text(for: nil), "--:--:--")
    }

    func testCountdownScheduleKeepsSecondCadenceAndFinalZeroFrame() {
        let start = Date(timeIntervalSince1970: 0)
        let actual = Array(GPSCountdownSchedule(active: true, end: start.addingTimeInterval(2.2))
            .entries(from: start, mode: .normal))
        XCTAssertEqual(actual, [0, 1, 2, 3].map { start.addingTimeInterval($0) })
        for schedule in [GPSCountdownSchedule(active: false, end: start.addingTimeInterval(3)),
                         GPSCountdownSchedule(active: true, end: nil),
                         GPSCountdownSchedule(active: true, end: start.addingTimeInterval(-1))] {
            XCTAssertEqual(Array(schedule.entries(from: start, mode: .normal)), [start])
        }
    }
}


@MainActor
final class SettingsAttentionPerformanceTests: XCTestCase {
    private final class Input: ObservableObject { @Published var active = false }
    private final class Frames {
        var parent = 0
        var content = 0
        var values: [CGFloat] = []
    }
    private struct CountedContent: View {
        let frames: Frames
        var body: some View {
            let _ = frames.content += 1
            Text("Transfer directory and controls").frame(width: 240, height: 80)
        }
    }
    private struct Harness: View {
        @ObservedObject var input: Input
        let frames: Frames
        var body: some View {
            let _ = frames.parent += 1
            var card = SettingsDirectoryAttentionCard(borderColor: .orange, active: input.active) {
                CountedContent(frames: frames)
            }
            card.didRender = { frames.values.append($0) }
            return card
        }
    }

    func testDirectoryPromptKeepsFormAndControlsStaticAndCancelsOnReplacementOrRemoval() async throws {
        let input = Input(), frames = Frames()
        var host: UIHostingController<Harness>? = UIHostingController(rootView: Harness(input: input, frames: frames))
        weak var weakHost = host
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host!.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.values.last, 0)
        input.active = true
        try await Task.sleep(for: .milliseconds(100))
        let parent = frames.parent, content = frames.content
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(frames.values.last, 0.55)
        XCTAssertTrue(frames.values.contains(1))
        XCTAssertTrue(frames.values.contains(0.32))
        XCTAssertEqual(frames.parent, parent)
        XCTAssertEqual(frames.content, content)
        let settled = frames.values.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(frames.values.count, settled)
        input.active = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(frames.values.last, 0)
        input.active = true
        try await Task.sleep(for: .milliseconds(80))
        input.active = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(frames.values.last, 0, "The canceled prompt must not restore its old target")
        input.active = true
        try await Task.sleep(for: .milliseconds(60))
        window.isHidden = true; window.rootViewController = nil; host = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakHost)
        let removed = frames.values.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(frames.values.count, removed)
    }
}


@MainActor
final class PhotoFilterPresentationPerformanceTests: XCTestCase {
    @MainActor
    private final class Input: ObservableObject {
        @Published var visible = true
        @Published var enabled = true
        @Published var phase: ScenePhase = .active
        let progress = PhotoRatingProgress(PhotoRatingScan(loading: true, total: 200))
    }
    private final class Frames {
        var parent = 0
        var popup = 0
        var labels: [String] = []
    }
    private struct ChipHarness: View {
        @ObservedObject var input: Input
        let frames: Frames
        var body: some View {
            let _ = frames.parent += 1
            var chip = PhotoRatingProgressChip(progress: input.progress, enabled: input.enabled,
                                               visible: input.visible, action: {})
            chip.didRender = { frames.labels.append($0) }
            return chip.environment(\.scenePhase, input.phase)
        }
    }
    private struct AnchorKey: PreferenceKey {
        static var defaultValue: Anchor<CGRect>? { nil }
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = nextValue() ?? value
        }
    }
    private struct PopupHarness: View {
        @ObservedObject var input: Input
        let frames: Frames
        var body: some View {
            Color.clear.frame(width: 44, height: 44)
                .anchorPreference(key: AnchorKey.self, value: .bounds) { $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .overlayPreferenceValue(AnchorKey.self) { anchor in
                    if let anchor {
                        var popup = PhotoFilterPopupOverlay(isPresented: $input.visible, anchor: anchor,
                            initial: PhotoFilterState(ratingEnabled: true),
                            availableExtensions: [".jpg", ".nef", ".mp4"], availableStorageSlots: [1, 2],
                            suggestedDate: "20261018", ratingProgress: input.progress, onChange: { _ in })
                        let _ = popup.didRender = { frames.popup += 1 }
                        popup
                    }
                }
                .environment(\.scenePhase, input.phase)
        }
    }
    private func window<Content: View>(_ content: Content) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        window.rootViewController!.view.layoutIfNeeded()
        return window
    }
    private func descendants<T: UIView>(_ view: UIView, _: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
    }

    func testProgressUpdatesOnlyChipAndNativePulseKeepsIdentityAndLifecycle() async throws {
        let input = Input(), frames = Frames()
        let window = try window(ChipHarness(input: input, frames: frames))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(150))
        let native = try XCTUnwrap(descendants(window, NativeAttentionHostView.self).first)
        weak var weakNative = native
        let loop = try XCTUnwrap(native.motionView.layer.animation(forKey: "attention.loop") as? CABasicAnimation)
        XCTAssertEqual(loop.duration, 0.9)
        XCTAssertEqual(loop.fromValue as? Double, 0.72)
        XCTAssertEqual(loop.toValue as? Double, 1)
        XCTAssertTrue(loop.autoreverses)
        XCTAssertEqual(loop.repeatCount, .infinity)
        let initialAlpha = try XCTUnwrap(native.motionView.layer.presentation()?.opacity)
        let parent = frames.parent
        for i in 1...120 {
            input.progress.update(PhotoRatingScan(loading: true, completed: i, total: 200))
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.parent, parent)
        XCTAssertEqual(frames.labels.last, "120/200")
        XCTAssertTrue(descendants(window, NativeAttentionHostView.self).first === native)
        XCTAssertEqual(native.motionView.layer.animation(forKey: "attention.loop")?.beginTime, loop.beginTime)
        let rendered = frames.labels.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(frames.labels.count, rendered, "CA opacity must not evaluate SwiftUI bodies per frame")
        XCTAssertNotEqual(native.motionView.layer.presentation()?.opacity, initialAlpha)
        XCTAssertNotNil(native.hitTest(CGPoint(x: 40, y: 17), with: nil))
        input.visible = false
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNil(native.motionView.layer.animation(forKey: "attention.loop"))
        input.visible = true
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNotNil(native.motionView.layer.animation(forKey: "attention.loop"))
        input.phase = .background
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNil(native.motionView.layer.animation(forKey: "attention.loop"))
        input.phase = .active
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNotNil(native.motionView.layer.animation(forKey: "attention.loop"))
        input.enabled = false
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNil(native.motionView.layer.animation(forKey: "attention.loop"))
        XCTAssertEqual(native.motionView.layer.opacity, 1)
        XCTAssertEqual(frames.labels.last, AppLocalized.resource("filter_rating_off"))
        input.enabled = true
        input.progress.update(PhotoRatingScan(loading: false, total: 3, waitingForRange: true))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(frames.labels.last, "0/3")
        input.progress.update(PhotoRatingScan(loading: true, completed: 5, total: 3))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(frames.labels.last, "3/3")
        input.progress.update(PhotoRatingScan(completed: 3, total: 3, complete: true))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(frames.labels.last, AppLocalized.resource("filter_rating_on"))
        XCTAssertNil(native.motionView.layer.animation(forKey: "attention.loop"))
        window.isHidden = true; window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakNative?.window)
        XCTAssertNil(weakNative?.motionView.layer.animation(forKey: "attention.loop"))
    }

    func testFullPopupProgressDoesNotRemeasureAndCloseReopenKeepsSameHost() async throws {
        let input = Input(), frames = Frames()
        let window = try window(PopupHarness(input: input, frames: frames))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(650))
        var panel: GeniePopupHostView? = try XCTUnwrap(descendants(window, GeniePopupHostView.self).first)
        weak var weakPanel = panel
        let native = try XCTUnwrap(descendants(window, NativeAttentionHostView.self).first)
        let size = panel!.bounds.size, rendered = frames.popup
        XCTAssertEqual(size.width, 271, accuracy: 1)
        XCTAssertGreaterThan(size.height, 150)
        XCTAssertLessThan(size.height, 450)
        for i in 1...120 {
            input.progress.update(PhotoRatingScan(loading: true, completed: i, total: 200))
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(frames.popup, rendered)
        XCTAssertEqual(panel!.bounds.size, size)
        input.visible = false
        try await Task.sleep(for: .milliseconds(80))
        input.visible = true
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(descendants(window, GeniePopupHostView.self).first === panel)
        XCTAssertNotNil(native.motionView.layer.animation(forKey: "attention.loop"))
        input.visible = false
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(native.motionView.layer.animation(forKey: "attention.loop"))
        input.visible = true
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNotNil(native.motionView.layer.animation(forKey: "attention.loop"))
        window.isHidden = true; window.rootViewController = nil; panel = nil
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(weakPanel)
    }

    func testProgressProjectionIgnoresDictionaryOnlyChangesAndRetainsEveryStatus() {
        let progress = PhotoRatingProgress()
        var updates = 0
        let observation = progress.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        for i in 0..<120 {
            progress.update(PhotoRatingScan(values: [UInt32(i): .known(i % 5)], complete: i % 2 == 0))
        }
        XCTAssertEqual(updates, 0)
        for scan in [PhotoRatingScan(total: 4, waitingForRange: true),
                     PhotoRatingScan(loading: true, completed: 1, total: 4),
                     PhotoRatingScan(loading: true, completed: 2, total: 4),
                     PhotoRatingScan(completed: 4, total: 4, complete: true)] {
            progress.update(scan)
            XCTAssertEqual(progress.snapshot, PhotoRatingProgress.Snapshot(scan))
        }
        XCTAssertEqual(updates, 4)
    }
}

@MainActor
final class PhotoListSignalPerformanceTests: XCTestCase {
    private final class Frames { var parent = 0; var content = 0 }
    private struct Content: View {
        let frames: Frames
        var body: some View {
            let _ = frames.content += 1
            Color.blue.frame(width: 80, height: 40)
        }
    }
    private struct Harness: View {
        let clock: PhotoListSignalAttentionClock
        let frames: Frames
        var body: some View {
            let _ = frames.parent += 1
            Content(frames: frames).modifier(PhotoListSignalAttention(clock: clock))
        }
    }
    func testSignalFramesStayInLeafAndIdleOwnerReleases() async throws {
        let frames = Frames()
        var clock: PhotoListSignalAttentionClock? = PhotoListSignalAttentionClock()
        weak var weakClock = clock
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 200)
        window.rootViewController = UIHostingController(rootView: Harness(clock: clock!, frames: frames))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        let parent = frames.parent, content = frames.content
        var updates = 0
        let observation = clock!.objectWillChange.sink { updates += 1 }
        for _ in 0..<120 { clock!.stop() }
        XCTAssertEqual(updates, 0)
        clock!.trigger()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(clock!.motion.scale.value, 1)
        let displayed = clock!.motion.scale.value
        clock!.trigger()
        XCTAssertEqual(clock!.motion.scale.value, displayed)
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(clock!.motion.scale.value, 1)
        XCTAssertGreaterThan(updates, 1)
        XCTAssertEqual(frames.parent, parent)
        XCTAssertEqual(frames.content, content)
        let finished = updates
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(updates, finished)
        observation.cancel()
        clock!.trigger()
        window.isHidden = true; window.rootViewController = nil; clock = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakClock, "Display link must not retain its owner after the last view leaves")
    }
}


@MainActor
final class SharedDisplayLinkLifecycleTests: XCTestCase {
    private let palette: [UInt32] = [0xFFFFB74D, 0xFFE0E0E0, 0xFFB0B0B0]

    func testAllSixActiveVisualOwnersReleaseWithoutDisappear() async throws {
        // No explicit stop: an interrupted hierarchy may lose its last owner
        // while iOS has suspended frames. Releasing it cannot await a tick.
        func check<Owner: AnyObject>(_ create: () -> Owner, start: (Owner) -> Void,
                                     file: StaticString = #filePath, line: UInt = #line) {
            var owner: Owner? = create()
            weak var released = owner
            start(owner!)
            owner = nil
            XCTAssertNil(released, "The run loop must not own the visual model", file: file, line: line)
        }
        for _ in 0..<20 {
            check({ RemoteHorizonClock(roll: 10, pitch: 0) }) { $0.update(roll: 0, pitch: 10) }
            check({ PhotoEffectsSwitchClock() }) {
                $0.update(checked: false, palette: palette)
                $0.update(checked: true, palette: palette)
            }
            check({ RemoteDockMotionDriver() }) { $0.setOpen(true) }
            check({ QueueFabVisibilityAnimator(visible: false) }) { $0.setVisible(true) }
            check({ QueueCardAccentAnimator() }) { $0.mount(0xFF000000); $0.update(0xFFFFFFFF) }
            check({ TransferPillResponseAnimator(responding: false) }) {
                $0.measureWidth(80, scale: 3); $0.measureWidth(160, scale: 3); $0.update(true)
            }
        }
        // Exercise orphan targets on the real main run loop as well.
        try await Task.sleep(for: .milliseconds(100))
    }

    func testDuplicateInputsKeepNotificationsQuietAndStoppedTargetsResume() async throws {
        let toggle = PhotoEffectsSwitchClock(), dock = RemoteDockMotionDriver()
        let fab = QueueFabVisibilityAnimator(visible: false)
        toggle.update(checked: false, palette: palette)
        var switchUpdates = 0, dockUpdates = 0, fabUpdates = 0
        let observations = [toggle.objectWillChange.sink { switchUpdates += 1 },
                            dock.objectWillChange.sink { dockUpdates += 1 },
                            fab.objectWillChange.sink { fabUpdates += 1 }]
        defer { observations.forEach { $0.cancel() }; toggle.stop(); dock.stop(); fab.stop() }
        for _ in 0..<120 {
            toggle.update(checked: false, palette: palette); dock.setOpen(false); fab.setVisible(false)
        }
        XCTAssertEqual(switchUpdates, 0); XCTAssertEqual(dockUpdates, 0); XCTAssertEqual(fabUpdates, 0)
        toggle.update(checked: true, palette: palette); dock.setOpen(true); fab.setVisible(true)
        XCTAssertEqual(switchUpdates, 1); XCTAssertEqual(dockUpdates, 1); XCTAssertEqual(fabUpdates, 1)
        for _ in 0..<120 {
            toggle.update(checked: true, palette: palette); dock.setOpen(true); fab.setVisible(true)
        }
        XCTAssertEqual(switchUpdates, 1); XCTAssertEqual(dockUpdates, 1); XCTAssertEqual(fabUpdates, 1)
        try await Task.sleep(for: .milliseconds(70))
        toggle.stop(); dock.stop()
        let switchPosition = toggle.motion!.position.value, dockPosition = dock.state.progress
        let stoppedSwitch = switchUpdates, stoppedDock = dockUpdates
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(switchUpdates, stoppedSwitch); XCTAssertEqual(dockUpdates, stoppedDock)
        toggle.update(checked: true, palette: palette); dock.setOpen(true)
        XCTAssertEqual(toggle.motion!.position.value, switchPosition)
        XCTAssertEqual(dock.state.progress, dockPosition)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(toggle.motion!.isRunning); XCTAssertEqual(toggle.motion!.position.value, 1)
        XCTAssertFalse(dock.state.animation.isRunning); XCTAssertEqual(dock.state.progress, 1)
        XCTAssertFalse(fab.motion.isRunning); XCTAssertTrue(fab.motion.retained)
        let completed = [switchUpdates, dockUpdates, fabUpdates]
        for _ in 0..<120 {
            toggle.update(checked: true, palette: palette); dock.setOpen(true); fab.setVisible(true)
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual([switchUpdates, dockUpdates, fabUpdates], completed)
    }

    func testPackedColorOnlyPublishesChangesAndKeepsRestartAndFinalColor() async throws {
        let animator = QueueCardAccentAnimator()
        var values: [UInt32?] = []
        let observation = animator.$value.dropFirst().sink { values.append($0) }
        defer { observation.cancel(); animator.stop() }
        animator.mount(0xFF000000)
        for _ in 0..<120 { animator.mount(0xFF000000); animator.update(0xFF000000) }
        XCTAssertEqual(values, [0xFF000000])
        animator.update(0xFF010101)
        try await Task.sleep(for: .milliseconds(60))
        animator.stop()
        let stopped = values
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(values, stopped)
        animator.update(0xFF010101)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(animator.value, 0xFF010101)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 != $1 },
                      "Packed color quantization must not notify identical visible frames")
        let settled = values
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(values, settled)
    }
}

@MainActor final class TipGuideTests: XCTestCase {
    func testOneSectionAndDelayedRevealNeverRetargetsAfterCollapseOrSwitch() {
        var state = TipGuideState(first: "first")
        XCTAssertEqual(state.expanded, "first"); XCTAssertNil(state.reveal)
        state.toggle("second"); XCTAssertEqual(state.expanded, "second"); XCTAssertEqual(state.reveal, "second")
        state.toggle("third"); state.revealed("second")
        XCTAssertEqual(state.expanded, "third"); XCTAssertEqual(state.reveal, "third")
        state.toggle("third"); XCTAssertNil(state.expanded); XCTAssertNil(state.reveal)
        state.toggle("first"); state.revealed("first")
        XCTAssertEqual(state.expanded, "first"); XCTAssertNil(state.reveal)
    }
    func testSettingsConditionsAndBothEffectsScopesKeepAndroidSectionsAndAppleExceptions() {
        for pro in [false, true] {
            for effects in [false, true] {
                for management in [false, true] {
                    let sections = TipGuides.settings(showEffects: effects, isPro: pro, showManagement: management)
                    let keys = sections.flatMap(\.items).map(\.textKey)
                    XCTAssertEqual(sections.count, effects ? 5 : 4)
                    XCTAssertEqual(sections.contains { $0.id == "settings_help_effects" }, effects)
                    XCTAssertEqual(keys.contains("settings_help_pro"), !pro)
                    XCTAssertEqual(keys.contains("iap_renewal_terms"), management)
                    XCTAssertFalse(keys.contains("settings_help_switch_device")); XCTAssertFalse(keys.contains("settings_help_update"))
                }
            }
        }
        let local = TipGuides.effects(local: true), transfer = TipGuides.effects(local: false)
        XCTAssertEqual(local.map(\.id), transfer.map(\.id))
        XCTAssertEqual(local.dropFirst().flatMap(\.items).map(\.textKey), transfer.dropFirst().flatMap(\.items).map(\.textKey))
        XCTAssertTrue(local[0].items.contains { $0.textKey == "local_photo_ios_save_hint" })
        XCTAssertEqual(transfer[0].items.map(\.textKey), ["photo_effects_info_description", "photo_effects_gesture_hint"])
        let tools = TipGuides.monitor.flatMap(\.items).compactMap(\.tool)
        XCTAssertEqual(tools.count, 19); XCTAssertEqual(Set(tools).count, 19)
        XCTAssertEqual(TipGuides.monitor.count, 5)
    }
    func testGuideClampsBelowTriggerAtNarrowPhoneAndLargeViewport() {
        for host in [CGSize(width: 320, height: 568), .init(width: 393, height: 852), .init(width: 1024, height: 1366)] {
            let anchor = CGRect(x: 260, y: 80, width: 36, height: 36)
            let limit = TipGuidePlacement.limits(host: host, anchor: anchor, bottomInset: 34)
            XCTAssertEqual(limit.width, min(420, host.width - 36))
            XCTAssertLessThanOrEqual(limit.height, 560)
            XCTAssertLessThanOrEqual(anchor.maxY + 8 + limit.height + 34 + 18, host.height)
        }
    }
    func testRevealUsesMinimumDistanceAndOnlyRunsForObscuredHeading() throws {
        XCTAssertEqual(TipGuideRevealCoordinator.distance(offset: 10, size: 48, container: 200), 0)
        XCTAssertEqual(TipGuideRevealCoordinator.distance(offset: -10, size: 300, container: 200), 0)
        XCTAssertEqual(TipGuideRevealCoordinator.distance(offset: -10, size: 48, container: 200), -10)
        XCTAssertEqual(TipGuideRevealCoordinator.distance(offset: 180, size: 48, container: 200), 28)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 300, height: 1000); controller.view.addSubview(scroll)
        let heading = UIView(frame: CGRect(x: 0, y: 700, width: 300, height: 48)); scroll.addSubview(heading)
        let owner = TipGuideRevealCoordinator(); owner.register(heading, id: "target")
        owner.reveal("target"); XCTAssertTrue(owner.clockRunning)
        owner.advance(0); owner.advance(80_000_000)
        XCTAssertGreaterThan(scroll.contentOffset.y, 0); XCTAssertLessThan(scroll.contentOffset.y, 548)
        for n in 6...120 { owner.advance(Int64(n) * 16_666_667) }
        XCTAssertEqual(scroll.contentOffset.y, 548, accuracy: 0.01); XCTAssertFalse(owner.clockRunning)
        owner.reveal("target"); XCTAssertFalse(owner.clockRunning)
        scroll.setContentOffset(.zero, animated: false); owner.reveal("target"); XCTAssertTrue(owner.clockRunning)
        owner.stop(); XCTAssertFalse(owner.clockRunning)
        owner.advance(3_000_000_000); XCTAssertEqual(scroll.contentOffset.y, 0)
    }

    func testActualGuideScrollKeepsHeaderFixedAndModalRegionReleases() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let long = TipGuides.effects(local: true)
        var host: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(
            TipGuideContent(titleKey: "photo_effects_info_title", sections: long, close: {})
                .frame(width: 357, height: 280).background(PopupDragBoundary())
                .frame(width: 393, height: 852, alignment: .top)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(120)); host?.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let root = try XCTUnwrap(host?.view)
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? UIScrollView }.first)
        let rect = scroll.convert(scroll.bounds, to: window)
        XCTAssertGreaterThanOrEqual(rect.minY, 40); XCTAssertLessThanOrEqual(rect.height, 236)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let marker = try XCTUnwrap(descendants(root).compactMap { $0 as? PopupDragBoundaryView }.first)
        XCTAssertGreaterThan(marker.bounds.width, 0); XCTAssertGreaterThan(marker.bounds.height, 0)
        XCTAssertNotNil(marker.window)
        XCTAssertTrue(PopupDragBoundaryView.contains(CGPoint(x: 196, y: 100), in: window))
        XCTAssertTrue(PopupDragBoundaryView.contains(CGPoint(x: marker.bounds.midX, y: marker.bounds.midY), in: marker))
        XCTAssertFalse(PopupDragBoundaryView.contains(CGPoint(x: 196, y: 700), in: window))
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        root.layoutIfNeeded()
        XCTAssertEqual(scroll.convert(scroll.bounds, to: window).minY, rect.minY, accuracy: 0.1)
        let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in root.drawHierarchy(in: root.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "grouped-help-fixed-header"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-guide.png"))
        window.rootViewController = nil; host = nil
        await Task.yield()
        XCTAssertFalse(PopupDragBoundaryView.contains(CGPoint(x: 196, y: 100), in: window))
    }
}
