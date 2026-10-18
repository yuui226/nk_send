import XCTest
import SwiftUI
import Combine
@testable import ZTransfer

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
        defer { shutter.stop() }
        var shutterUpdates = 0
        let a = shutter.objectWillChange.sink { shutterUpdates += 1 }
        defer { a.cancel() }
        for n in 0..<120 {
            shutter.configure(shutter.configuration)
            shutter.advance(Int64(n) * 16_666_667)
        }
        XCTAssertEqual(shutterUpdates, 0)
        XCTAssertFalse(shutter.clockRunning)
        var config = shutter.configuration; config.recording = true
        shutter.configure(config)
        shutter.advance(2_000_000_000)
        shutter.advance(2_080_000_000)
        XCTAssertGreaterThan(shutterUpdates, 0)
        let counts = shutterUpdates
        for _ in 0..<120 { shutter.advance(2_080_000_000) }
        XCTAssertEqual(shutterUpdates, counts)
        XCTAssertLessThan(shutter.display.size, 60)
        XCTAssertGreaterThan(shutter.display.size, 28)
    }

    func testActualFrameClocksStopAndOffscreenConfigurationCannotRestartThem() async throws {
        let shutter = shutter()
        defer { shutter.stop() }
        var config = shutter.configuration; config.recording = true
        shutter.configure(config)
        try await waitFor { shutter.display.size < 60 }
        XCTAssertTrue(shutter.clockRunning)
        shutter.stop()
        config.recording = false
        shutter.configure(config)
        let before = shutter.display
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(shutter.display, before)
        XCTAssertFalse(shutter.clockRunning)
        shutter.activate()
        try await waitFor { !shutter.clockRunning }
        XCTAssertEqual(shutter.display.size, 60, accuracy: 0.00001)
    }

    func testRunningClocksDoNotRetainTheirControllers() {
        weak var weakShutter: RemoteShutterController?
        do {
            let controller = shutter()
            weakShutter = controller
            var config = controller.configuration; config.focusing = true
            controller.configure(config)
            XCTAssertTrue(controller.clockRunning)
        }
        XCTAssertNil(weakShutter)
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
        var cameraEvents = 0
        let a = state.camera.objectWillChange.sink { cameraEvents += 1 }
        defer { a.cancel() }
        for _ in 0..<120 { state.camera.set(0) }
        XCTAssertEqual(cameraEvents, 0)
        state.camera.set(65)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(beforeElapsed, snapshot(window))
        XCTAssertEqual(counts.parent, bodies)
        XCTAssertEqual(cameraEvents, 1)
        XCTAssertEqual(state.camera.seconds, 65)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(settled, snapshot(window))
        try XCTUnwrap(snapshot(window)).write(to: URL(fileURLWithPath: "/tmp/ztransfer-1018-camera-capture-controls.png"))
    }

    private func snapshot(_ window: UIWindow) -> Data? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.pngData()
    }
    @MainActor
    private final class Controls: ObservableObject {
        @Published var capture: RemoteCapturePhase = .idle
        let camera = RemoteRecordingElapsed()
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
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray)
        }
    }
}
