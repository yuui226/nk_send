import XCTest
import SwiftUI
import Combine
@testable import ZTransfer

final class RemoteRecorderTests: XCTestCase {
    func testActionGatesKeepStopAvailableAndSavedFinalizingButtonsInert() {
        for enabled in [false, true] {
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .recording, enabled: enabled), .stop)
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .paused, enabled: enabled), .stop)
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .saved, enabled: enabled), .none)
            XCTAssertEqual(RemoteRecorderAction.resolve(phase: .finalizing, enabled: enabled), .none)
        }
        XCTAssertEqual(RemoteRecorderAction.resolve(phase: .idle, enabled: false), .lockedHint)
        XCTAssertEqual(RemoteRecorderAction.resolve(phase: .idle, enabled: true), .start)
    }

    func testInitialStateAndWidthTargetsMatchBothOrientations() {
        for compact in [false, true] {
            for phase in [RemoteLocalRecordingPhase.idle, .recording, .paused, .finalizing, .saved] {
                let motion = RemoteRecorderMotion(.init(phase: phase, compactSaved: compact), density: 3)
                let expected: Float = phase == .saved ? (compact ? 36 : 88) : phase == .idle ? 36 : 70
                XCTAssertEqual(motion.layoutWidth.value, expected)
                XCTAssertEqual(motion.surfaceWidth.value, expected)
                XCTAssertFalse(motion.needsFrames)
                XCTAssertEqual(motion.savedLabel.retained, phase == .saved && !compact)
                XCTAssertEqual(motion.timer.retained, phase == .recording || phase == .paused)
            }
        }
    }

    func testRecordingWidthUsesBouncySpringAndPauseUses150msTween() {
        var motion = RemoteRecorderMotion(.init(phase: .idle, compactSaved: false), density: 3)
        motion.configure(.init(phase: .recording, compactSaved: false))
        motion.advance(0); motion.advance(150_000_000)
        XCTAssertEqual(motion.pauseAlpha.value, 1)
        let expected = ZTransferAndroidMotion.underdampedSpring(stiffness: 400, dampingRatio: 0.5)
            .animationSample(at: 150_000_000, from: 36, to: 70, velocity: 0).value
        XCTAssertEqual(motion.layoutWidth.value, expected, accuracy: 0.00001)
        XCTAssertEqual(motion.surfaceWidth.value, motion.layoutWidth.value)
        motion.configure(.init(phase: .paused, compactSaved: false))
        XCTAssertEqual(motion.timer.alpha.value, 1)
        XCTAssertEqual(motion.timer.visible, true)
        motion.advance(2_000_000_000)
        XCTAssertFalse(motion.needsFrames)
    }

    func testSavedLabelStartsAfter60msAndIconsKeepOutgoingUntilItsExitCompletes() {
        var motion = RemoteRecorderMotion(.init(phase: .finalizing, compactSaved: false), density: 3)
        motion.configure(.init(phase: .saved, compactSaved: false))
        XCTAssertEqual(motion.icons.count, 2)
        XCTAssertEqual(motion.icons[true]?.scale.value, 0.52)
        motion.advance(0); motion.advance(60_000_000)
        XCTAssertEqual(motion.savedLabel.alpha.value, 0)
        motion.advance(90_000_000)
        XCTAssertEqual(motion.icons[false]?.alpha.value, 0)
        XCTAssertNotNil(motion.icons[false], "The outgoing scale still has 20ms remaining")
        motion.advance(110_000_000)
        XCTAssertNil(motion.icons[false])
        motion.advance(160_000_000)
        XCTAssertEqual(motion.savedLabel.alpha.value, ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
        motion.advance(260_000_000)
        XCTAssertEqual(motion.savedLabel.alpha.value, 1)
    }

    func testFinalizingHidesPauseAndTimerWithoutCollapsingTheCapsule() {
        var motion = RemoteRecorderMotion(.init(phase: .recording, compactSaved: false), density: 3)
        motion.configure(.init(phase: .finalizing, compactSaved: false))
        XCTAssertEqual(motion.layoutWidth.target, 70)
        XCTAssertTrue(motion.timer.retained)
        motion.advance(0); motion.advance(120_000_000)
        XCTAssertEqual(motion.timer.alpha.value, 0)
        XCTAssertTrue(motion.timer.retained)
        motion.advance(130_000_000)
        XCTAssertEqual(motion.timer.scale.value, 0.9)
        XCTAssertEqual(motion.timer.slide.value, 13, "54 physical pixels / 4, integer division")
        XCTAssertFalse(motion.timer.retained)
        motion.advance(150_000_000)
        XCTAssertEqual(motion.pauseAlpha.value, 0)
    }

    func testCompactSavedKeepsCheckAndHidesLabelWhileWidthContinuesFromDisplayedValue() {
        var motion = RemoteRecorderMotion(.init(phase: .saved, compactSaved: false), density: 2)
        motion.configure(.init(phase: .saved, compactSaved: true))
        XCTAssertEqual(motion.layoutWidth.value, 88)
        XCTAssertEqual(motion.layoutWidth.target, 36)
        XCTAssertEqual(motion.icons.count, 1)
        motion.advance(0); motion.advance(120_000_000)
        XCTAssertFalse(motion.savedLabel.retained)
        XCTAssertTrue(motion.icons[true]!.retained)
        let displayed = motion.layoutWidth.value
        motion.configure(.init(phase: .saved, compactSaved: false))
        XCTAssertEqual(motion.layoutWidth.value, displayed)
        XCTAssertEqual(motion.layoutWidth.target, 88)
    }

    func testHintInterruptedFadeReversesFromCurrentValueAndCanReenterAfterDisposal() {
        var hint = RemoteRecorderVisibility(.lockedHint)
        hint.setVisible(true); hint.advance(0); hint.advance(80_000_000)
        let displayed = hint.alpha.value
        hint.setVisible(false)
        XCTAssertEqual(hint.alpha.value, displayed)
        hint.advance(2_000_000_000)
        XCTAssertFalse(hint.retained)
        hint.setVisible(true)
        XCTAssertEqual(hint.alpha.value, 0)
        XCTAssertEqual(hint.scale.value, 0.86)
        hint.advance(3_000_000_000); hint.advance(3_180_000_000)
        XCTAssertEqual(hint.alpha.value, 1)
        XCTAssertEqual(hint.scale.value, 1)
    }
    @MainActor
    func testRepeatedLockedTapRestartsDeadlineAndDisappearanceDiscardsHint() async throws {
        let controller = RemoteRecorderController(.init(phase: .idle, compactSaved: false), density: 3)
        defer { controller.stop() }
        controller.showLockedHint()
        try await Task.sleep(for: .milliseconds(1000))
        controller.showLockedHint()
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(controller.motion.lockedHint.visible, "The first task must not hide the second tap's hint")
        controller.stop()
        XCTAssertFalse(controller.motion.lockedHint.retained)
        XCTAssertFalse(controller.motion.needsFrames)
        controller.activate()
        controller.showLockedHint()
        try await Task.sleep(for: .milliseconds(1850))
        XCTAssertFalse(controller.motion.lockedHint.visible)
    }

}

@MainActor
final class RemoteCapturePerformanceTests: XCTestCase {
    private func shutter() -> RemoteShutterController {
        RemoteShutterController(configuration: .init(enabled: true, capturing: false,
            focusing: false, recording: false, diameter: 76))
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testRepeatedConfigurationAndIdleFramesDoNotPublish() {
        let shutter = shutter()
        let recorder = RemoteRecorderController(.init(phase: .idle, compactSaved: false), density: 3)
        defer { shutter.stop(); recorder.stop() }
        var shutterUpdates = 0, recorderUpdates = 0
        let a = shutter.objectWillChange.sink { shutterUpdates += 1 }
        let b = recorder.objectWillChange.sink { recorderUpdates += 1 }
        defer { a.cancel(); b.cancel() }
        for n in 0..<120 {
            shutter.configure(shutter.configuration)
            shutter.advance(Int64(n) * 16_666_667)
            recorder.configure(recorder.motion.configuration)
            recorder.advance(Int64(n) * 16_666_667)
        }
        XCTAssertEqual(shutterUpdates, 0)
        XCTAssertEqual(recorderUpdates, 0)
        XCTAssertFalse(shutter.clockRunning)
        XCTAssertFalse(recorder.clockRunning)
        var config = shutter.configuration; config.recording = true
        shutter.configure(config)
        recorder.configure(.init(phase: .recording, compactSaved: false))
        shutter.advance(2_000_000_000); recorder.advance(2_000_000_000)
        shutter.advance(2_080_000_000); recorder.advance(2_080_000_000)
        XCTAssertGreaterThan(shutterUpdates, 0)
        XCTAssertGreaterThan(recorderUpdates, 0)
        let counts = (shutterUpdates, recorderUpdates)
        for _ in 0..<120 { shutter.advance(2_080_000_000); recorder.advance(2_080_000_000) }
        XCTAssertEqual(shutterUpdates, counts.0)
        XCTAssertEqual(recorderUpdates, counts.1)
        XCTAssertLessThan(shutter.display.size, 60)
        XCTAssertGreaterThan(shutter.display.size, 28)
        XCTAssertGreaterThan(recorder.display.surfaceWidth, 36)
    }

    func testActualFrameClocksStopAndOffscreenConfigurationCannotRestartThem() async throws {
        let shutter = shutter()
        let recorder = RemoteRecorderController(.init(phase: .idle, compactSaved: false), density: 3)
        defer { shutter.stop(); recorder.stop() }
        var config = shutter.configuration; config.recording = true
        shutter.configure(config)
        recorder.configure(.init(phase: .recording, compactSaved: false))
        try await waitFor { shutter.display.size < 60 && recorder.display.surfaceWidth > 36 }
        XCTAssertTrue(shutter.clockRunning)
        XCTAssertTrue(recorder.clockRunning)
        shutter.stop(); recorder.stop()
        config.recording = false
        shutter.configure(config)
        recorder.configure(.init(phase: .saved, compactSaved: false))
        let before = (shutter.display, recorder.display)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(shutter.display, before.0)
        XCTAssertEqual(recorder.display, before.1)
        XCTAssertFalse(shutter.clockRunning)
        XCTAssertFalse(recorder.clockRunning)
        shutter.activate(); recorder.activate()
        try await waitFor { !shutter.clockRunning && !recorder.clockRunning }
        XCTAssertEqual(shutter.display.size, 60, accuracy: 0.00001)
        XCTAssertEqual(recorder.display.surfaceWidth, 88)
        XCTAssertEqual(recorder.display.savedLabel.alpha, 1)
    }

    func testRunningClocksDoNotRetainTheirControllers() {
        weak var weakShutter: RemoteShutterController?
        weak var weakRecorder: RemoteRecorderController?
        do {
            let controller = shutter()
            weakShutter = controller
            var config = controller.configuration; config.focusing = true
            controller.configure(config)
            XCTAssertTrue(controller.clockRunning)
            let recorder = RemoteRecorderController(.init(phase: .idle, compactSaved: false), density: 3)
            weakRecorder = recorder
            recorder.configure(.init(phase: .recording, compactSaved: false))
            XCTAssertTrue(recorder.clockRunning)
        }
        XCTAssertNil(weakShutter)
        XCTAssertNil(weakRecorder)
    }

    func testHostedControlsAnimateAndElapsedLabelsUpdateWithoutRebuildingParent() async throws {
        let state = Controls()
        let counts = Counts()
        let host = UIHostingController(rootView: CaptureHarness(state: state, counts: counts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 420)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(120))
        let initial = snapshot(window)
        state.phase = .recording
        state.capture = .recording
        try await Task.sleep(for: .milliseconds(40))
        let intermediate = snapshot(window)
        let bodies = counts.parent
        try await Task.sleep(for: .milliseconds(900))
        let settled = snapshot(window)
        XCTAssertNotEqual(initial, intermediate)
        XCTAssertNotEqual(intermediate, settled, "The real controls must continue drawing after their parent stops updating")
        XCTAssertEqual(counts.parent, bodies)
        let beforeElapsed = snapshot(window)
        var cameraEvents = 0, localEvents = 0
        let a = state.camera.objectWillChange.sink { cameraEvents += 1 }
        let b = state.local.objectWillChange.sink { localEvents += 1 }
        defer { a.cancel(); b.cancel() }
        for _ in 0..<120 { state.camera.set(0); state.local.set(0) }
        XCTAssertEqual(cameraEvents, 0); XCTAssertEqual(localEvents, 0)
        state.camera.set(65); state.local.set(125)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(beforeElapsed, snapshot(window))
        XCTAssertEqual(counts.parent, bodies)
        XCTAssertEqual(cameraEvents, 1); XCTAssertEqual(localEvents, 1)
        XCTAssertEqual(state.camera.seconds, 65); XCTAssertEqual(state.local.seconds, 125)
        state.phase = .paused
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(settled, snapshot(window))
        try XCTUnwrap(snapshot(window)).write(to: URL(fileURLWithPath: "/tmp/ztransfer-p24-recording-controls.png"))
    }

    private func snapshot(_ window: UIWindow) -> Data? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.pngData()
    }
    @MainActor
    private final class Controls: ObservableObject {
        @Published var phase: RemoteLocalRecordingPhase = .idle
        @Published var capture: RemoteCapturePhase = .idle
        let camera = RemoteRecordingElapsed()
        let local = RemoteRecordingElapsed()
    }
    private final class Counts { var parent = 0 }
    private struct CaptureHarness: View {
        @ObservedObject var state: Controls
        let counts: Counts
        var body: some View {
            counts.parent += 1
            return VStack(spacing: 64) {
                RemoteRecordingElapsedText(elapsed: state.camera)
                RemoteShutterButton(capture: state.capture, movieMode: true, enabled: true, focusing: false,
                    onQuickTap: {}, onFocusStart: {}, onRelease: { _ in })
                RemoteRecorderBar(phase: state.phase, elapsed: state.local, enabled: true, compactSaved: false,
                    onStart: {}, onPauseResume: {}, onStop: {})
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray)
        }
    }
}
