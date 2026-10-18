import XCTest
import SwiftUI
@testable import ZTransfer

final class RemoteToolModeTransitionTests: XCTestCase {
    func testPreviewHistogramUses180MillisecondsAndKeepsInterruptionContinuity() {
        var transition = RemoteToolModeTransition(movie: false, durationMilliseconds: 180)
        transition.setTarget(true)
        transition.advance(frameNanos: 0)
        transition.advance(frameNanos: 90_000_000)
        XCTAssertEqual(transition.alpha(true), 0.7755613, accuracy: 0.00001)
        let before = transition.alpha(true)
        transition.setTarget(false)
        XCTAssertEqual(transition.alpha(true), before)
        transition.advance(frameNanos: 1_000_000_000)
        XCTAssertEqual(transition.modes, [false])
        transition.setTarget(true)
        transition.advance(frameNanos: 2_000_000_000)
        transition.advance(frameNanos: 2_179_000_000)
        XCTAssertEqual(transition.modes.count, 2)
        transition.advance(frameNanos: 2_180_000_000)
        XCTAssertEqual(transition.modes, [true])
        XCTAssertFalse(transition.isRunning)
    }

    func testInitialModeIsImmediatelyOpaqueWithoutAnimation() {
        for movie in [false, true] {
            let transition = RemoteToolModeTransition(movie: movie)
            XCTAssertEqual(transition.modes, [movie])
            XCTAssertEqual(transition.alpha(movie), 1)
            XCTAssertFalse(transition.isRunning)
        }
    }

    func testModeChangeRetainsBothLayoutsUntilAndroidTweenFinishes() {
        var transition = RemoteToolModeTransition(movie: false)
        transition.setTarget(true)
        transition.advance(frameNanos: 1_000_000_000)
        XCTAssertEqual(transition.modes, [false, true])
        XCTAssertEqual(transition.alpha(false), 1)
        XCTAssertEqual(transition.alpha(true), 0)
        transition.advance(frameNanos: 1_080_000_000)
        // Compose FastOutSlowIn at 0.5, independently pinned expected value.
        XCTAssertEqual(transition.alpha(true), 0.7755613, accuracy: 0.00001)
        XCTAssertEqual(transition.alpha(false), 0.2244387, accuracy: 0.00001)
        transition.advance(frameNanos: 1_159_000_000)
        XCTAssertEqual(transition.modes.count, 2)
        transition.advance(frameNanos: 1_160_000_000)
        XCTAssertEqual(transition.modes, [true])
        XCTAssertFalse(transition.isRunning)
    }

    func testRapidReturnUsesCurrentAlphaAndDoesNotDuplicateOrRemoveActiveLayer() {
        var transition = RemoteToolModeTransition(movie: false)
        transition.setTarget(true)
        transition.advance(frameNanos: 0)
        transition.advance(frameNanos: 80_000_000)
        let photo = transition.alpha(false)
        let movie = transition.alpha(true)
        transition.setTarget(false)
        XCTAssertEqual(transition.alpha(false), photo)
        XCTAssertEqual(transition.alpha(true), movie)
        XCTAssertEqual(transition.modes, [false, true])
        transition.setTarget(false) // Recomposition does not restart the spring.
        transition.advance(frameNanos: 120_000_000)
        XCTAssertGreaterThan(transition.alpha(false), photo)
        transition.advance(frameNanos: 1_000_000_000)
        XCTAssertEqual(transition.modes, [false])
        XCTAssertEqual(transition.alpha(false), 1)
        XCTAssertEqual(transition.alpha(true), 0)
    }
}

@MainActor
final class WorkspaceMonitorTransitionTests: XCTestCase {
    private final class State: ObservableObject { @Published var presented = false }
    private final class Lifetime { var sourceBodies = 0; var monitorAppears = 0; var monitorDisappears = 0; var dismissed = 0 }
    private struct Source: View {
        let lifetime: Lifetime
        var body: some View { let _ = lifetime.sourceBodies += 1; Color.red.ignoresSafeArea() }
    }
    private struct Fixture: View {
        @ObservedObject var state: State
        let lifetime: Lifetime
        var body: some View {
            Source(lifetime: lifetime).workspaceMonitor(isPresented: $state.presented,
                onDismiss: { lifetime.dismissed += 1 }) {
                Color.blue.ignoresSafeArea()
                    .onAppear { lifetime.monitorAppears += 1 }
                    .onDisappear { lifetime.monitorDisappears += 1 }
            }
        }
    }
    func testActualPresentationRetainsPagesUntilExitAndReversalDoesNotRecreateMonitor() async throws {
        let state = State(), lifetime = Lifetime()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Fixture(state: state, lifetime: lifetime))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(80))
        let sourceBodies = lifetime.sourceBodies
        state.presented = true
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(lifetime.monitorAppears, 1); XCTAssertEqual(lifetime.monitorDisappears, 0)
        XCTAssertLessThanOrEqual(lifetime.sourceBodies - sourceBodies, 1, "The 300ms frames must not rebuild the source page")
        state.presented = false
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(lifetime.monitorDisappears, 0)
        state.presented = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(lifetime.monitorAppears, 1); XCTAssertEqual(lifetime.monitorDisappears, 0)
        XCTAssertEqual(lifetime.dismissed, 0)
        state.presented = false
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(lifetime.monitorDisappears, 1); XCTAssertEqual(lifetime.dismissed, 1)
        XCTAssertNil(window.rootViewController?.presentedViewController, "No system bottom full-screen cover")
    }

    func testMonitorIsOnLeftAndUsesAndroidDelayedFadeAndShortTravel() {
        let clock = WorkspaceMonitorClock()
        clock.setPresented(true); clock.advance(0)
        XCTAssertTrue(clock.retained)
        XCTAssertEqual(clock.monitor.travel, -24); XCTAssertEqual(clock.files.travel, 0)
        clock.advance(100_000_000)
        XCTAssertEqual(clock.monitor.alpha, 0)
        XCTAssertGreaterThan(clock.monitor.travel, -24); XCTAssertLessThan(clock.monitor.travel, 0)
        clock.advance(140_000_000)
        XCTAssertEqual(clock.files.alpha, 0)
        XCTAssertGreaterThan(clock.monitor.alpha, 0)
        clock.advance(300_000_000)
        XCTAssertFalse(clock.running); XCTAssertEqual(clock.monitor.alpha, 1)
        XCTAssertEqual(clock.monitor.travel, 0); XCTAssertEqual(clock.files.travel, 24)
        clock.setPresented(false); clock.advance(400_000_000)
        clock.advance(540_000_000)
        XCTAssertTrue(clock.retained); XCTAssertEqual(clock.monitor.alpha, 0)
        XCTAssertGreaterThan(clock.files.alpha, 0)
        clock.advance(700_000_000)
        XCTAssertFalse(clock.retained); XCTAssertFalse(clock.running)
        XCTAssertEqual(clock.files.alpha, 1); XCTAssertEqual(clock.files.travel, 0)
    }
    func testReopeningDuringExitRetainsOwnerAndReleasesClockWhenSettled() {
        var clock: WorkspaceMonitorClock? = WorkspaceMonitorClock()
        weak var weakClock = clock
        clock!.setPresented(true); clock!.advance(0); clock!.advance(300_000_000)
        clock!.setPresented(false); clock!.advance(400_000_000); clock!.advance(460_000_000)
        let offset = clock!.monitor.travel
        clock!.setPresented(true)
        XCTAssertEqual(clock!.monitor.travel, offset)
        XCTAssertTrue(clock!.retained)
        clock!.advance(1_500_000_000)
        XCTAssertFalse(clock!.running); XCTAssertTrue(clock!.retained)
        clock!.setPresented(false); clock = nil
        XCTAssertNil(weakClock)
    }
}
