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
    func testMonitorOwnerForwardsControlsButNotFramesAndReleasesSubscriptions() async throws {
        let suite = "monitor-owner-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RemoteToolPreferences(defaults: defaults)
        var owner: RemoteViewLifetime? = RemoteViewLifetime(
            camera: DisconnectedRemoteCamera(isUSB: true), session: nil,
            tools: preferences, defaults: defaults,
            entitlements: PremiumEntitlementStore(access: PremiumAccess(.lifetime)),
            freeUsage: FreeUsageStore(defaults: defaults), onTransportLost: nil)
        weak var weakOwner = owner
        weak var weakLUT = owner?.lut
        weak var weakReview = owner?.review
        let model = try XCTUnwrap(owner?.model)
        XCTAssertTrue(owner?.tools === preferences)
        XCTAssertEqual(model.state.session, .idle, "Creating UI ownership must not start the camera")
        var notices = 0
        var hdBeforeChange: [Bool] = []
        let observation = owner?.objectWillChange.sink {
            notices += 1
            hdBeforeChange.append(model.hdLiveView)
        }
        model.setHDLiveView(true)
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(hdBeforeChange, [false], "Control changes must notify before mutation, as @Published did")
        XCTAssertTrue(model.hdLiveView)
        preferences.hd.toggle()
        XCTAssertEqual(notices, 2)
        for _ in 0..<120 { model.frameUpdates.invalidate() }
        XCTAssertEqual(notices, 2, "Decoded frames must still update only the viewfinder")
        owner = nil
        XCTAssertNil(weakOwner); XCTAssertNil(weakLUT); XCTAssertNil(weakReview)
        preferences.hd.toggle(); model.setHDLiveView(false)
        XCTAssertEqual(notices, 2, "A retained child must not keep the old page observation alive")
        observation?.cancel()
        await model.stopAndWait()
    }

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
        window.rootViewController = UIHostingController(rootView: Fixture(state: state, lifetime: lifetime).environment(\.scenePhase, .active))
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
        let clock = WorkspacePageClock(side: .left, keepsSource: true)
        clock.setPresented(true); clock.advance(0)
        XCTAssertTrue(clock.retained)
        XCTAssertEqual(clock.destination.travel, -24); XCTAssertEqual(clock.source.travel, 0)
        clock.advance(100_000_000)
        XCTAssertEqual(clock.destination.alpha, 0)
        XCTAssertGreaterThan(clock.destination.travel, -24); XCTAssertLessThan(clock.destination.travel, 0)
        clock.advance(140_000_000)
        XCTAssertEqual(clock.source.alpha, 0)
        XCTAssertGreaterThan(clock.destination.alpha, 0)
        clock.advance(300_000_000)
        XCTAssertFalse(clock.running); XCTAssertEqual(clock.destination.alpha, 1)
        XCTAssertEqual(clock.destination.travel, 0); XCTAssertEqual(clock.source.travel, 24)
        clock.setPresented(false); clock.advance(400_000_000)
        clock.advance(540_000_000)
        XCTAssertTrue(clock.retained); XCTAssertEqual(clock.destination.alpha, 0)
        XCTAssertGreaterThan(clock.source.alpha, 0)
        clock.advance(700_000_000)
        XCTAssertFalse(clock.retained); XCTAssertFalse(clock.running)
        XCTAssertEqual(clock.source.alpha, 1); XCTAssertEqual(clock.source.travel, 0)
    }
    func testReopeningDuringExitRetainsOwnerAndReleasesClockWhenSettled() {
        var clock: WorkspacePageClock? = WorkspacePageClock(side: .left, keepsSource: true)
        weak var weakClock = clock
        clock!.setPresented(true); clock!.advance(0); clock!.advance(300_000_000)
        clock!.setPresented(false); clock!.advance(400_000_000); clock!.advance(460_000_000)
        let offset = clock!.destination.travel
        clock!.setPresented(true)
        XCTAssertEqual(clock!.destination.travel, offset)
        XCTAssertTrue(clock!.retained)
        clock!.advance(1_500_000_000)
        XCTAssertFalse(clock!.running); XCTAssertTrue(clock!.retained)
        clock!.setPresented(false); clock = nil
        XCTAssertNil(weakClock)
    }
}


@MainActor
final class WorkspacePageTransitionTests: XCTestCase {
    func testQueueAndMonitorShareTimingWithOppositeDirectionsAndStationaryHeader() {
        for side in [WorkspacePageClock.DestinationSide.left, .right] {
            let clock = WorkspacePageClock(side: side)
            clock.setPresented(true); clock.stop(); clock.advance(0)
            XCTAssertEqual(clock.pages, [false, true])
            XCTAssertEqual(clock.destination.travel, side.rawValue * 24)
            clock.advance(100_000_000)
            XCTAssertEqual(clock.destination.alpha, 0)
            XCTAssertEqual(clock.header.alpha, 0)
            clock.advance(140_000_000)
            XCTAssertEqual(clock.source.alpha, 0)
            XCTAssertGreaterThan(clock.destination.alpha, 0)
            XCTAssertEqual(clock.destination.alpha, clock.header.alpha)
            XCTAssertEqual(clock.header.travel, 0)
            clock.advance(300_000_000)
            XCTAssertEqual(clock.pages, [true])
            XCTAssertFalse(clock.transitioning)
            XCTAssertEqual(clock.destination.travel, 0)
            XCTAssertEqual(clock.destination.alpha, 1)
            clock.setPresented(false); clock.stop(); clock.advance(400_000_000)
            clock.advance(480_000_000)
            XCTAssertEqual(clock.header.alpha, 0)
            XCTAssertGreaterThan(clock.destination.alpha, 0)
            XCTAssertEqual(clock.source.alpha, 0)
            clock.advance(700_000_000)
            XCTAssertEqual(clock.pages, [false]); XCTAssertFalse(clock.running)
            XCTAssertEqual(clock.source.travel, 0); XCTAssertEqual(clock.source.alpha, 1)
        }
    }

    func testRepeatedReversalPreservesDisplayedValuesAndReleasesOnlyAtRest() {
        let clock = WorkspacePageClock(side: .right)
        clock.setPresented(true); clock.stop(); clock.advance(0); clock.advance(160_000_000)
        for index in 0..<8 {
            let source = clock.source.sample, destination = clock.destination.sample
            let target = index % 2 != 0
            clock.setPresented(target); clock.stop()
            XCTAssertEqual(clock.source.sample, source)
            XCTAssertEqual(clock.destination.sample, destination)
            XCTAssertEqual(clock.pages, [false, true])
            clock.advance(Int64(200 + index * 40) * 1_000_000)
            XCTAssertTrue((0...1).contains(clock.source.alpha))
            XCTAssertTrue((0...1).contains(clock.destination.alpha))
        }
        clock.advance(2_000_000_000)
        XCTAssertEqual(clock.pages, [true]); XCTAssertFalse(clock.running)
        XCTAssertFalse(clock.transitioning)
    }

    func testRestoredPageIsImmediateAndBackgroundSettlesWithoutReplayOrClockLeak() {
        let clock = WorkspacePageClock(side: .right)
        clock.mount(presented: true)
        XCTAssertEqual(clock.pages, [true]); XCTAssertEqual(clock.header.alpha, 1)
        XCTAssertFalse(clock.running)
        clock.setPresented(false); clock.advance(0); clock.advance(60_000_000)
        XCTAssertTrue(clock.running)
        clock.setActive(false)
        XCTAssertEqual(clock.pages, [false]); XCTAssertEqual(clock.source.alpha, 1)
        XCTAssertFalse(clock.running); XCTAssertFalse(clock.transitioning)
        clock.setPresented(true)
        XCTAssertEqual(clock.pages, [true]); XCTAssertFalse(clock.running)
        clock.setActive(true); clock.mount(presented: true)
        XCTAssertFalse(clock.running)
        var temporary: WorkspacePageClock? = WorkspacePageClock(side: .right)
        weak var weakClock = temporary
        temporary?.setPresented(true); temporary = nil
        XCTAssertNil(weakClock)
    }

    private final class Counts { var source = 0; var destination = 0; var parent = 0 }
    private struct Page: View {
        let color: Color
        let counts: Counts
        let destination: Bool
        var body: some View {
            let _ = destination ? (counts.destination += 1) : (counts.source += 1)
            color.ignoresSafeArea()
        }
    }
    private struct Fixture: View {
        @ObservedObject var clock: WorkspacePageClock
        let counts: Counts
        var body: some View {
            let _ = counts.parent += 1
            ZStack {
                Color.white.ignoresSafeArea()
                if clock.pages.contains(false) {
                    Page(color: Color(.sRGB, red: 1, green: 0, blue: 0), counts: counts, destination: false)
                        .modifier(WorkspacePageEffect(frame: clock.source))
                }
                if clock.pages.contains(true) {
                    Page(color: Color(.sRGB, red: 0, green: 0, blue: 1), counts: counts, destination: true)
                        .modifier(WorkspacePageEffect(frame: clock.destination))
                }
            }
        }
    }

    func testActualRenderedFramesFadeFullyAndDoNotRebuildParentsAtFrameFrequency() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let clock = WorkspacePageClock(side: .right), counts = Counts()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Fixture(clock: clock, counts: counts))
        window.makeKeyAndVisible()
        defer { clock.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(60))
        clock.setPresented(true); clock.stop(); clock.advance(0)
        try await Task.sleep(for: .milliseconds(30))
        let before = (counts.parent, counts.source, counts.destination)
        for millis in stride(from: 10, through: 290, by: 10) {
            clock.advance(Int64(millis) * 1_000_000)
            try await Task.sleep(for: .milliseconds(4))
            if [100, 140, 200].contains(millis) {
                let pixel = try capture(window, name: "workspace-queue-\(millis)ms")
                if millis == 100 {
                    XCTAssertGreaterThan(pixel[0], pixel[1], "Outgoing source still has its final fade frames")
                } else {
                    XCTAssertEqual(Int(pixel[0]), Int(pixel[1]), accuracy: 3, "No red source remains after 140ms")
                    XCTAssertGreaterThan(pixel[2], pixel[0])
                }
            }
        }
        XCTAssertEqual(counts.parent, before.0)
        XCTAssertEqual(counts.source, before.1)
        XCTAssertEqual(counts.destination, before.2)
        clock.advance(300_000_000)
        try await Task.sleep(for: .milliseconds(30))
        let pixel = try capture(window, name: "workspace-queue-settled")
        XCTAssertLessThan(pixel[0], 5); XCTAssertLessThan(pixel[1], 5); XCTAssertGreaterThan(pixel[2], 250)
    }

    private func capture(_ window: UIWindow, name: String) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: -window.bounds.midX, y: -window.bounds.midY,
                                   width: window.bounds.width, height: window.bounds.height))
        return pixel
    }
}
