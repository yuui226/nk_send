import XCTest
import SwiftUI
import UIKit
@testable import ZTransfer

final class QueueTopControlMotionTests: XCTestCase {
    func testApprovedUUIDPhaseUsesStableFoldAndAndroidMixing() {
        let fixtures: [(String, UInt32)] = [("", 0),
            ("00000000-0000-0000-0000-000000000000", 0x3f735bf3),
            ("00112233-4455-6677-8899-AABBCCDDEEFF", 0x3def20ef),
            ("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", 0x3f553fd5)]
        for (seed, expected) in fixtures {
            XCTAssertEqual(Float(liquidProgressStableSeed(seed)).bitPattern, expected)
        }
    }
    func testExecutionExitRetainsSlotUntilBothAnimationsFinishAndReentersFromDisplayedState() {
        var motion = QueueTopPresenceMotion(visible: true, kind: .execution)
        motion.update(false); motion.advance(0)
        XCTAssertTrue(motion.retained); XCTAssertFalse(motion.visible)
        motion.advance(60_000_000)
        XCTAssertGreaterThan(motion.alpha.value, 0); XCTAssertLessThan(motion.alpha.value, 1)
        motion.advance(120_000_000)
        XCTAssertEqual(motion.alpha.value, 0); XCTAssertTrue(motion.retained)
        motion.advance(140_000_000)
        XCTAssertFalse(motion.retained); XCTAssertEqual(motion.scale.value, 0.72)
        motion.update(true); motion.advance(200_000_000)
        XCTAssertEqual(motion.alpha.value, 0)
        motion.advance(360_000_000)
        XCTAssertEqual(motion.alpha.value, 1)
        XCTAssertGreaterThan(motion.scale.value, 1, "400/.5 entry overshoots")
        motion.update(false)
        let before = motion.scale.value
        motion.advance(370_000_000)
        let reverseAlpha = motion.alpha.value, reverseScale = motion.scale.value
        motion.update(true)
        XCTAssertEqual(motion.alpha.value, reverseAlpha)
        XCTAssertEqual(motion.scale.value, reverseScale)
        XCTAssertLessThan(abs(before - reverseScale), 0.1)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.scale.value, 1); XCTAssertFalse(motion.isRunning)
    }

    func testIconIndependentDelaysExitRetentionAndRapidReversal() {
        var motion = QueueExecutionIconMotion(.start)
        motion.update(.pause); motion.advance(0); motion.advance(25_000_000)
        XCTAssertEqual(motion.layers[1].fade.alpha.value, 0)
        XCTAssertEqual(motion.layers[1].scale.value, 0.72)
        motion.advance(35_000_000)
        XCTAssertEqual(motion.layers[1].fade.alpha.value, 0)
        XCTAssertGreaterThan(motion.layers[1].scale.value, 0.72)
        motion.advance(100_000_000)
        XCTAssertEqual(motion.layers[0].fade.alpha.value, 0)
        XCTAssertEqual(motion.layers.count, 2, "Exit scale lasts 120ms")
        motion.advance(120_000_000)
        XCTAssertEqual(motion.layers.map(\.id), [.pause])
        motion.advance(200_000_000)
        XCTAssertFalse(motion.isRunning)
        motion.update(.start); motion.advance(300_000_000); motion.advance(345_000_000)
        let oldAlpha = motion.layers[0].fade.alpha.value
        motion.update(.pause)
        XCTAssertEqual(motion.layers.count, 2)
        XCTAssertEqual(motion.layers[0].fade.alpha.value, oldAlpha)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.layers.map(\.id), [.pause]); XCTAssertFalse(motion.isRunning)
    }

    func testCatchUsesOneTimelineAndPreservesInterruptedValue() {
        var motion = QueueTopCatchMotion()
        motion.trigger(); motion.advance(0); motion.advance(55_000_000)
        let before = motion.scale.value
        motion.trigger()
        XCTAssertEqual(motion.scale.value, before)
        motion.advance(165_000_000)
        XCTAssertEqual(motion.scale.value, 1.18, accuracy: 0.0001)
        motion.advance(365_000_000)
        XCTAssertLessThan(motion.scale.value, 1)
        motion.advance(1_500_000_000)
        XCTAssertEqual(motion.scale.value, 1); XCTAssertFalse(motion.isRunning)
    }

    func testFlightHoldsCannotHideGeneratingOrCompletedBatch() {
        let file = CameraFile(id: 1, storageID: 1, format: 0x3801, size: 10,
            fileName: "1.JPG", captureDate: nil, isProtected: false)
        var item = TransferQueueItem(id: UUID(), file: file)
        XCTAssertTrue(QueuePillTaskSummary(items: [item]).allDownloadsAreInFlight(heldCount: 1))
        item.status = .completed
        XCTAssertFalse(QueuePillTaskSummary(items: [item]).allDownloadsAreInFlight(heldCount: 2))
        item.isGeneratingFrame = true
        let generating = QueuePillTaskSummary(items: [item])
        XCTAssertFalse(generating.allDownloadsAreInFlight(heldCount: 2))
        XCTAssertEqual(generating.displayRemaining(heldCount: 2), 1)
    }

    func testEveryModePairRetainsSurfaceAndSettlesEvenWhenReversed() {
        for from in QueuePillVisualMode.allCases {
            for to in QueuePillVisualMode.allCases where from != to {
                let a = QueuePillPresentation(mode: from, count: 10, speed: 12_000_000)
                let b = QueuePillPresentation(mode: to, count: 9, speed: 4_000_000)
                var motion = QueuePillContentMotion(a)
                motion.update(b); motion.advance(0); motion.advance(60_000_000)
                XCTAssertTrue(motion.layers.contains { $0.presentation == a })
                XCTAssertTrue(motion.layers.contains { $0.presentation == b })
                if from != .icon && to != .icon { XCTAssertEqual(motion.surface.fillAlpha, 1) }
                motion.update(a); motion.advance(2_000_000_000)
                XCTAssertEqual(motion.layers.map(\.presentation), [a])
                XCTAssertFalse(motion.isRunning)
            }
        }
    }
}

@MainActor
final class QueueTopControlLifecycleTests: XCTestCase {
    func testClocksStopAtRestDoNotReplayOldCatchAndAreNotRetainedByDisplayLink() {
        let presence = QueueTopPresenceClock(visible: true, kind: .execution)
        presence.update(true); XCTAssertFalse(presence.isTicking)
        presence.update(false); XCTAssertTrue(presence.isTicking)
        presence.advance(0); presence.advance(1_000_000_000)
        XCTAssertFalse(presence.isTicking)
        let execution = QueueExecutionClock(control: .pause, requested: false, accent: 0xffffaa00)
        execution.update(control: .pause, requested: true, accent: 0xffffaa00)
        execution.advance(0); execution.advance(90_000_000)
        XCTAssertGreaterThan(execution.active, 0); XCTAssertLessThan(execution.active, 1)
        execution.advance(180_000_000)
        XCTAssertEqual(execution.active, 1); XCTAssertFalse(execution.isTicking)
        execution.update(control: nil, requested: false, accent: 0xff0000ff)
        XCTAssertEqual(execution.icons.current, .pause); XCTAssertEqual(execution.active, 1)
        let catchClock = QueueTopCatchClock()
        catchClock.mount(8); catchClock.update(8); XCTAssertFalse(catchClock.isTicking)
        catchClock.update(9); XCTAssertTrue(catchClock.isTicking)
        catchClock.advance(0); catchClock.advance(110_000_000); catchClock.advance(2_000_000_000)
        XCTAssertFalse(catchClock.isTicking)
        catchClock.mount(9); XCTAssertEqual(catchClock.motion.scale.value, 1)
        weak var weakPresence: QueueTopPresenceClock?
        weak var weakExecution: QueueExecutionClock?
        weak var weakCatch: QueueTopCatchClock?
        autoreleasepool {
            let p = QueueTopPresenceClock(visible: false, kind: .pill); weakPresence = p; p.update(true)
            let e = QueueExecutionClock(control: .start, requested: false, accent: 0xff0000ff); weakExecution = e
            e.update(control: .pause, requested: false, accent: 0xffffaa00)
            let c = QueueTopCatchClock(); weakCatch = c; c.mount(0); c.update(1)
        }
        XCTAssertNil(weakPresence); XCTAssertNil(weakExecution); XCTAssertNil(weakCatch)
    }
}

@MainActor
final class QueueTopControlRenderingTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var snapshot = TransferQueueSnapshot(items: [], isTransferring: false, pauseAfterCurrent: false)
        @Published var held = 0
        @Published var preview = false
        @Published var queuePage = false
        @Published var catchNonce = 0
        var rect = CGRect.zero
        var observation: QueuePillObservation?
        var executionObservation: QueueExecutionObservation?
        var executionMounted = false
        var bodyCount = 0
        var anchorUpdates = 0
        var anchor = CGRect.zero
        func set(_ statuses: [TransferStatus], running: Bool, generating: Bool = false) {
            let items = statuses.enumerated().map { index, status in
                var item = TransferQueueItem(id: UUID(), file: CameraFile(id: UInt32(index + 1), storageID: 1,
                    format: 0x3801, size: 10_000_000, fileName: "\(index).JPG", captureDate: nil, isProtected: false),
                    status: status, progress: 0.5, bytesPerSecond: 12_500_000)
                item.isGeneratingFrame = generating
                return item
            }
            snapshot = .init(items: items, isTransferring: running, pauseAfterCurrent: false)
        }
    }
    private struct RectKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue(); if !next.isEmpty { value = next }
        }
    }
    private struct Page: View {
        @ObservedObject var state: State
        var body: some View {
            let _ = { state.bodyCount += 1 }()
            Color.gray.opacity(0.15).overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    QueueTopPresence(visible: state.snapshot.executionControl != nil && !state.preview,
                                     kind: .execution, trailingSpacing: 8) {
                        QueueTopExecutionButton(control: state.snapshot.executionControl,
                            pauseRequested: state.snapshot.pauseAfterCurrent, startEnabled: true) { _ in }
                            .onAppear { state.executionMounted = true }
                            .onDisappear { state.executionMounted = false }
                    }
                    QueueTopPresence(visible: !state.queuePage || !state.snapshot.items.isEmpty, kind: .pill) {
                        QueuePill(snapshot: state.snapshot, activeProgress: nil, heldCount: state.held)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RectKey.self, value: g.frame(in: .global))
                            })
                    }
                }
                .modifier(QueueControlsCatchEffect(trigger: state.catchNonce))
                .padding(.trailing, 16).padding(.top, 20)
            }
            .overlay(alignment: .topTrailing) {
                QueueTopFlightAnchor().padding(.trailing, 16).padding(.top, 20)
            }
            .onPreferenceChange(RectKey.self) { state.rect = $0 }
            .onPreferenceChange(QueuePillObservationKey.self) { state.observation = $0 }
            .onPreferenceChange(QueueExecutionObservationKey.self) { state.executionObservation = $0 }
            .onPreferenceChange(PhotoListQueueTargetPreferenceKey.self) {
                state.anchor = $0; state.anchorUpdates += 1
            }
        }
    }
    func testRealClusterTransitionsInLiquidGlass() async throws { try await verify(.liquidGlass) }
    func testRealClusterTransitionsInPhysicalTheme() async throws { try await verify(.titanium) }
    func testRealClusterTransitionsInDarkPhysicalTheme() async throws { try await verify(.titanium, scheme: .dark) }
    private func verify(_ skin: ZTransferButtonSkin, scheme: ColorScheme = .light) async throws {
        let state = State()
        let suite = "QueueTopControl.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(skin.rawValue, forKey: "skin_preset")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 120)
        let host = UIHostingController(rootView: Page(state: state).ignoresSafeArea().defaultAppStorage(defaults).environment(\.colorScheme, scheme))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); defaults.removePersistentDomain(forName: suite) }
        var pictures: [UIImage] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func capture(_ label: String) {
            pictures.append(UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                (label as NSString).draw(at: CGPoint(x: 12, y: 75), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
            })
        }
        func settle(_ expected: QueuePillVisualMode) async throws {
            try await Task.sleep(for: .milliseconds(650)); host.view.layoutIfNeeded()
            XCTAssertEqual(state.observation?.mode, expected)
            XCTAssertEqual(state.rect.maxX, 377, accuracy: 0.6)
            if let control = state.snapshot.executionControl, !state.preview {
                XCTAssertEqual(state.executionObservation?.control, control)
                XCTAssertEqual(state.executionObservation?.displayed, control)
                XCTAssertEqual(state.executionObservation?.layers, 1)
                XCTAssertEqual(state.executionObservation?.accent, QueueCardAccentAnimator.packed(
                    control == .pause ? ZTransferColors.accentYellow : ZTransferColors.accentBlue, scheme: scheme))
            }
            if expected == .counting { XCTAssertGreaterThan(state.rect.width, 95, "Speed and count must fit after settling") }
            capture(String(describing: expected))
        }
        try await settle(.icon)
        let initialAnchor = state.anchor, anchorUpdates = state.anchorUpdates
        XCTAssertEqual(initialAnchor.maxX, 377, accuracy: 0.6)
        let graceStarted = CACurrentMediaTime()
        state.set([.waiting], running: true)
        try await Task.sleep(for: .milliseconds(100))
        if CACurrentMediaTime() - graceStarted < 0.3 { XCTAssertEqual(state.observation?.mode, .icon) }
        // Waiting count changes do not reset the 350ms deadline.
        state.set([.waiting, .waiting], running: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state.observation?.mode, .counting)
        state.set([.completed], running: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.observation?.mode, .done)
        XCTAssertEqual(state.observation?.completionFill, false, "Skipped-only batch must not celebrate a download")
        capture("skip-only Done")
        state.set([.waiting], running: true)
        try await Task.sleep(for: .milliseconds(30))
        state.set([.cancelled], running: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.observation?.mode, .icon)
        state.set([.waiting, .waiting], running: false); try await settle(.paused)
        XCTAssertTrue(state.executionMounted)
        state.set([.transferring, .waiting], running: true); try await settle(.counting)
        let hideStarted = CACurrentMediaTime()
        state.preview = true
        try await Task.sleep(for: .milliseconds(50))
        if CACurrentMediaTime() - hideStarted < 0.12 {
            XCTAssertTrue(state.executionMounted, "Keep outgoing control through its fade")
        }
        capture("preview fade")
        try await Task.sleep(for: .milliseconds(200)); XCTAssertFalse(state.executionMounted)
        state.preview = false; try await settle(.counting)
        state.catchNonce += 1
        try await Task.sleep(for: .milliseconds(30))
        let parentCount = state.bodyCount
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(state.bodyCount, parentCount, "Catch/progress/width frames cannot rebuild the parent")
        XCTAssertEqual(state.anchor, initialAnchor)
        XCTAssertEqual(state.anchorUpdates, anchorUpdates, "Anchor cannot republish on width/catch frames")
        let lastStarted = CACurrentMediaTime()
        state.set([.transferring], running: true)
        try await Task.sleep(for: .milliseconds(50))
        if CACurrentMediaTime() - lastStarted < 0.12 { XCTAssertTrue(state.executionMounted) }
        capture("last-file fade")
        try await settle(.counting); XCTAssertFalse(state.executionMounted)
        state.held = 2; state.set([.completed], running: false, generating: true)
        try await settle(.generating)
        state.set([.completed], running: false); try await settle(.done)
        // New batch during Done reverses continuously; no delayed old task may collapse it.
        state.held = 0; state.set([.transferring, .waiting], running: true)
        try await settle(.counting)
        try await Task.sleep(for: .milliseconds(1400)); XCTAssertEqual(state.observation?.mode, .counting)
        state.set([.cancelled], running: false); try await settle(.icon)
        state.queuePage = true; state.set([], running: false)
        try await Task.sleep(for: .milliseconds(700)); capture("empty queue hidden")
        state.queuePage = false; try await settle(.icon)
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 393, height: pictures.count * 120), format: format).image { _ in
            for (index, image) in pictures.enumerated() { image.draw(at: CGPoint(x: 0, y: index * 120)) }
        }
        try sheet.pngData()?.write(to: URL(fileURLWithPath: "/tmp/ztransfer-queue-controls-\(skin.rawValue)-\(scheme).png"))
        let attachment = XCTAttachment(image: sheet); attachment.lifetime = .keepAlways; add(attachment)
    }
}
