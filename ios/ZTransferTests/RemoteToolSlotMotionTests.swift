import XCTest
import SwiftUI
import Combine
@testable import ZTransfer

final class RemoteToolSlotMotionTests: XCTestCase {
    @MainActor
    func testFixedSlotsKeepReflowOnExitAndRemoveDetachedSlots() {
        let motion = RemoteToolEditorMotion()
        defer { motion.stop() }
        func configure(_ slots: [String: CGRect], editing: Bool) {
            motion.configure(slots: [:], fixedSlots: slots, editing: editing,
                             visible: [], dragging: nil, topLeft: .zero, scale: 3)
        }
        let first = CGRect(x: 42, y: 40, width: 36, height: 36)
        let moved = CGRect(x: 126, y: 80, width: 36, height: 36)
        configure(["manage": first, "rotate": moved], editing: true)
        XCTAssertEqual(motion.fixedPosition("manage"), first.origin)
        XCTAssertFalse(motion.fixedPositions["manage"]!.isRunning)
        configure(["manage": moved, "rotate": first], editing: true)
        XCTAssertEqual(motion.fixedPosition("manage"), first.origin)
        XCTAssertEqual(motion.fixedPositions["manage"]!.target, CGPoint(x: 378, y: 240))
        XCTAssertTrue(motion.fixedPositions["manage"]!.isRunning)
        XCTAssertTrue(motion.states.isEmpty) // Fixed controls never acquire lift or wiggle state.
        configure(["manage": moved, "rotate": first], editing: false)
        XCTAssertEqual(motion.fixedPosition("manage"), first.origin)
        XCTAssertTrue(motion.fixedPositions["manage"]!.isRunning)
        configure(["rotate": first], editing: false)
        XCTAssertNil(motion.fixedPosition("manage"))
    }

    func testEditorHeightFirstMeasurementAndExitAreImmediate() {
        var motion = RemoteToolHeightMotion()
        motion.measure(36, scale: 3)
        XCTAssertNil(motion.height)
        motion.setEditing(true)
        motion.measure(76, scale: 3)
        XCTAssertEqual(motion.height, 76)
        XCTAssertFalse(motion.isRunning)
        motion.measure(116, scale: 3)
        motion.advance(0)
        XCTAssertEqual(motion.height, 76)
        motion.advance(110_000_000)
        XCTAssertEqual(motion.height!, 107, accuracy: 1.0 / 3)
        motion.advance(220_000_000)
        XCTAssertEqual(motion.height, 116)
        motion.setEditing(false)
        XCTAssertNil(motion.height)
        motion.setEditing(true)
        motion.measure(36, scale: 3)
        XCTAssertEqual(motion.height, 36)
        XCTAssertFalse(motion.isRunning)
    }

    func testWiggleDelayReverseAndDragRestart() {
        var slot = RemoteToolSlotMotion(tool: .fps, position: .zero, visible: true)
        slot.configure(position: .zero, editing: true, visible: true, dragging: false)
        slot.advance(0)
        slot.advance(55_000_000)
        XCTAssertEqual(slot.angle, -1.3)
        slot.advance(135_000_000)
        XCTAssertEqual(slot.angle, 0, accuracy: 0.00001)
        slot.advance(215_000_000)
        XCTAssertEqual(slot.angle, 1.3, accuracy: 0.00001)
        slot.advance(295_000_000)
        XCTAssertEqual(slot.angle, 0, accuracy: 0.00001)
        slot.configure(position: CGPoint(x: 80, y: 40), editing: true, visible: true, dragging: true)
        XCTAssertEqual(slot.angle, 0)
        XCTAssertEqual(slot.position.value, CGPoint(x: 80, y: 40))
        slot.advance(300_000_000)
        slot.advance(420_000_000)
        XCTAssertEqual(slot.lift.value, 1.1)
        slot.configure(position: .zero, editing: true, visible: true, dragging: false)
        XCTAssertEqual(slot.angle, -1.3)
        XCTAssertTrue(slot.position.isRunning)
    }

    func testHiddenIconFadesWithoutWigglingAndLeavingEditRetainsPosition() {
        var slot = RemoteToolSlotMotion(tool: .hd, position: .zero, visible: true)
        slot.configure(position: CGPoint(x: 126, y: 40), editing: true, visible: false, dragging: false)
        slot.advance(0)
        XCTAssertEqual(slot.iconOpacity.value, 1)
        XCTAssertEqual(slot.angle, 0)
        slot.advance(180_000_000)
        XCTAssertEqual(slot.iconOpacity.value, 0.38)
        let previous = slot.position.value
        slot.configure(position: CGPoint(x: 42, y: 0), editing: false, visible: false, dragging: false)
        XCTAssertEqual(slot.position.value, previous)
        XCTAssertTrue(slot.position.isRunning)
        XCTAssertFalse(slot.wiggles)
        slot.advance(2_000_000_000)
        XCTAssertEqual(slot.position.value, CGPoint(x: 42, y: 0))
        XCTAssertFalse(slot.position.isRunning)
    }

    func testRecorderExpansionAnimatesNormalSlotsWithoutAnEntryFlight() {
        let initial = CGPoint(x: 42, y: 0)
        var slot = RemoteToolSlotMotion(tool: .grid, position: initial, visible: true)
        slot.configure(position: initial, editing: false, visible: true, dragging: false)
        XCTAssertFalse(slot.needsFrames)
        slot.configure(position: CGPoint(x: 84, y: 0), editing: false, visible: true, dragging: false)
        slot.advance(0)
        XCTAssertEqual(slot.position.value, initial)
        slot.advance(100_000_000)
        XCTAssertGreaterThan(slot.position.value.x, initial.x)
        XCTAssertLessThan(slot.position.value.x, 84)
        XCTAssertFalse(slot.wiggles)
        slot.advance(1_000_000_000)
        XCTAssertEqual(slot.position.value, CGPoint(x: 84, y: 0))
        XCTAssertFalse(slot.needsFrames)
    }

    func testRetargetedPositionDoesNotJumpAndBothAxesFinishTogether() {
        var motion = RemoteToolPositionMotion(.zero)
        motion.setTarget(CGPoint(x: 300, y: 1), snap: false)
        motion.advance(0)
        motion.advance(100_000_000)
        let intermediate = motion.value
        XCTAssertGreaterThan(intermediate.x, 0)
        XCTAssertLessThan(intermediate.x, 300)
        motion.setTarget(CGPoint(x: 42, y: 40), snap: false)
        XCTAssertEqual(motion.value, intermediate)
        motion.advance(2_000_000_000)
        XCTAssertEqual(motion.value, CGPoint(x: 42, y: 40))
        XCTAssertFalse(motion.isRunning)
    }
}


@MainActor
final class RemoteToolbarPerformanceTests: XCTestCase {
    func testWiggleOnlyPublishesChangedSlotAndNeverNotifiesFixedHiddenOrHeight() throws {
        let motion = RemoteToolEditorMotion()
        let slots: [RemoteTool: CGRect] = [.hd: CGRect(x: 0, y: 0, width: 36, height: 36),
                                           .fps: CGRect(x: 42, y: 0, width: 36, height: 36)]
        let fixed = ["manage": CGRect(x: 84, y: 0, width: 36, height: 36)]
        func configure(_ editing: Bool) {
            motion.configure(slots: slots, fixedSlots: fixed, editing: editing,
                             visible: [.hd], dragging: nil, topLeft: .zero, scale: 3)
        }
        configure(false)
        var hd = 0, hidden = 0, fixedChanges = 0, heights = 0
        let subscriptions = [
            motion.presentation(.hd, visible: true).objectWillChange.sink { hd += 1 },
            motion.presentation(.fps, visible: false).objectWillChange.sink { hidden += 1 },
            motion.fixedPresentation("manage").objectWillChange.sink { fixedChanges += 1 },
            motion.heightPresentation.objectWillChange.sink { heights += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() }; motion.stop() }
        for _ in 0..<120 { configure(false); motion.measureHeight(36, editing: false, scale: 3) }
        XCTAssertEqual(hd + hidden + fixedChanges + heights, 0)
        configure(true)
        for frame in 0..<120 { motion.advance(Int64(frame) * 16_666_667) }
        XCTAssertGreaterThan(hd, 100)
        XCTAssertEqual(hidden, 0); XCTAssertEqual(fixedChanges, 0); XCTAssertEqual(heights, 0)
        motion.measureHeight(36, editing: true, scale: 3)
        motion.measureHeight(76, editing: true, scale: 3)
        motion.advance(2_100_000_000); motion.advance(2_210_000_000)
        XCTAssertGreaterThan(try XCTUnwrap(motion.heightPresentation.height), 36)
        XCTAssertLessThan(try XCTUnwrap(motion.heightPresentation.height), 76)
        motion.advance(2_320_000_000)
        XCTAssertEqual(motion.heightPresentation.height, 76)
        configure(false); motion.setActive(true)
        XCTAssertFalse(motion.clockRunning, "No endless clock outside the editor at rest")
        configure(true); XCTAssertTrue(motion.clockRunning)
        motion.stop(); configure(true)
        XCTAssertFalse(motion.clockRunning, "Late layout after disappearance must not restart the clock")
        motion.setActive(true); XCTAssertTrue(motion.clockRunning)
    }

    func testRemovedSlotDropsOldPresentationAndReinsertedSlotStartsAtItsNewBase() {
        let motion = RemoteToolEditorMotion()
        let oldSlot = CGRect(x: 0, y: 0, width: 36, height: 36)
        motion.configure(slots: [.hd: oldSlot], fixedSlots: ["manage": oldSlot], editing: true,
                         visible: [.hd], dragging: .hd, topLeft: CGPoint(x: 40, y: 10), scale: 3)
        let old = motion.presentation(.hd, visible: true)
        let oldFixed = motion.fixedPresentation("manage")
        XCTAssertEqual(old.display.offset, CGSize(width: 40, height: 10))
        motion.configure(slots: [:], editing: false, visible: [], dragging: nil, topLeft: .zero, scale: 3)
        let fresh = motion.presentation(.hd, visible: true)
        let freshFixed = motion.fixedPresentation("manage")
        XCTAssertFalse(fresh === old); XCTAssertFalse(freshFixed === oldFixed)
        XCTAssertEqual(fresh.display.offset, .zero)
        let next = CGRect(x: 84, y: 40, width: 36, height: 36)
        motion.configure(slots: [.hd: next], fixedSlots: ["manage": next], editing: false,
                         visible: [.hd], dragging: nil, topLeft: .zero, scale: 3)
        XCTAssertEqual(fresh.display.offset, .zero)
        XCTAssertEqual(freshFixed.display.offset, .zero)
        XCTAssertFalse(motion.states[.hd]?.needsFrames ?? true)
    }

    func testDragPublishesOnlyBeginEndWhileKeepingEveryPositionAndReorder() throws {
        let suite = "toolbar-drag-performance-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
        let drag = RemoteToolDragState()
        drag.slots = [.hd: CGRect(x: 0, y: 0, width: 36, height: 36)]
        var updates = 0
        let subscription = drag.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(drag.begin(at: CGPoint(x: 18, y: 18), delta: .zero, layout: layout))
        for _ in 0..<120 { drag.moveBy(CGSize(width: 0.05, height: 0.1), layout: layout) }
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(drag.topLeft.x, 6, accuracy: 0.0001)
        XCTAssertEqual(drag.topLeft.y, 12, accuracy: 0.0001)
        drag.end(); drag.end()
        XCTAssertEqual(updates, 2)
    }

    func testHostedSlotAnimatesPixelsWithoutRebuildingContentAndUsesDisplayedHitPosition() async throws {
        let motion = RemoteToolEditorMotion()
        let probe = Probe()
        let slot = CGRect(x: 0, y: 0, width: 36, height: 36)
        motion.configure(slots: [.hd: slot], editing: true, visible: [.hd], dragging: nil, topLeft: .zero, scale: 3)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: SlotHarness(presentation: motion.presentation(.hd, visible: true), probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 160, height: 140)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; motion.stop() }
        try await Task.sleep(for: .milliseconds(80))
        let parentBodies = probe.parent, contentBodies = probe.content
        func snapshot() throws -> Data {
            try XCTUnwrap(UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }.pngData())
        }
        let before = try snapshot()
        for frame in 0..<20 {
            motion.advance(Int64(frame) * 8_000_000)
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertEqual(probe.parent, parentBodies)
        XCTAssertEqual(probe.content, contentBodies)
        XCTAssertNotEqual(try snapshot(), before)
        motion.configure(slots: [.hd: slot], editing: true, visible: [.hd], dragging: .hd,
                         topLeft: CGPoint(x: 25, y: 10), scale: 3)
        XCTAssertEqual(motion.position(.hd), CGPoint(x: 25, y: 10))
        XCTAssertEqual(motion.presentation(.hd, visible: true).display.offset, CGSize(width: 25, height: 10))
        motion.advance(200_000_000); motion.advance(320_000_000)
        XCTAssertEqual(motion.presentation(.hd, visible: true).display.lift, CGFloat(Float(1.1)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.parent, parentBodies)
        XCTAssertEqual(probe.content, contentBodies)
    }

    func testModeClockOnlyPublishesLayerMembershipAndKeepsInterruptedOpacity() {
        let clock = RemoteToolModeClock(movie: false)
        var memberships = 0, photoFrames = 0, movieFrames = 0
        let subscriptions = [clock.objectWillChange.sink { memberships += 1 },
            clock.photoOpacity.objectWillChange.sink { photoFrames += 1 },
            clock.movieOpacity.objectWillChange.sink { movieFrames += 1 }]
        defer { subscriptions.forEach { $0.cancel() }; clock.invalidate() }
        for _ in 0..<120 { clock.setTarget(false) }
        XCTAssertEqual(memberships + photoFrames + movieFrames, 0)
        clock.setTarget(true)
        XCTAssertEqual(memberships, 1)
        for frame in 0...8 { clock.advance(Int64(frame) * 10_000_000) }
        XCTAssertEqual(memberships, 1)
        XCTAssertEqual(clock.movieOpacity.value, 0.7755613, accuracy: 0.00001)
        let before = clock.photoOpacity.value
        clock.setTarget(false)
        XCTAssertEqual(clock.photoOpacity.value, before)
        XCTAssertEqual(memberships, 1)
        clock.advance(1_000_000_000)
        XCTAssertEqual(memberships, 2)
        XCTAssertEqual(clock.modes, [false])
        XCTAssertEqual(clock.photoOpacity.value, 1)
        XCTAssertGreaterThan(photoFrames, 2); XCTAssertGreaterThan(movieFrames, 2)
        XCTAssertFalse(clock.clockRunning)
    }

    func testLiveDisplayClocksAdvanceLeavesAndStopOnDisappearance() async throws {
        let motion = RemoteToolEditorMotion()
        motion.configure(slots: [.hd: CGRect(x: 0, y: 0, width: 36, height: 36)],
                         editing: true, visible: [.hd], dragging: nil, topLeft: .zero, scale: 3)
        let mode = RemoteToolModeClock(movie: false)
        let loop = RemoteCameraToolLoop()
        var frames = 0
        let subscription = motion.presentation(.hd, visible: true).objectWillChange.sink { frames += 1 }
        defer { subscription.cancel(); motion.stop(); mode.invalidate(); loop.stop() }
        motion.setActive(true); mode.setTarget(true); loop.start()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(frames, 1)
        XCTAssertGreaterThan(mode.movieOpacity.value, 0)
        XCTAssertGreaterThan(loop.milliseconds, 0)
        motion.stop(); mode.invalidate(); loop.stop()
        let stopped = frames
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(frames, stopped)
        XCTAssertFalse(motion.clockRunning); XCTAssertFalse(mode.clockRunning); XCTAssertFalse(loop.clockRunning)
    }

    func testActiveClocksReleaseOwnersAndMenuLoopsStopWithoutIdlePublication() {
        var motion: RemoteToolEditorMotion? = RemoteToolEditorMotion()
        weak var weakMotion = motion
        motion?.configure(slots: [.hd: CGRect(x: 0, y: 0, width: 36, height: 36)],
                          editing: true, visible: [.hd], dragging: nil, topLeft: .zero, scale: 3)
        motion?.setActive(true); XCTAssertTrue(motion?.clockRunning == true)
        motion = nil; XCTAssertNil(weakMotion)
        var mode: RemoteToolModeClock? = RemoteToolModeClock(movie: false)
        weak var weakMode = mode
        mode?.setTarget(true); XCTAssertTrue(mode?.clockRunning == true)
        mode = nil; XCTAssertNil(weakMode)
        var loop: RemoteCameraToolLoop? = RemoteCameraToolLoop()
        weak var weakLoop = loop
        var notices = 0
        var subscription = loop?.objectWillChange.sink { notices += 1 }
        for _ in 0..<120 { loop?.stop() }
        XCTAssertEqual(notices, 0)
        loop?.start(); loop?.advance(5); loop?.advance(5.6)
        XCTAssertEqual(loop?.milliseconds ?? 0, 600, accuracy: 0.00001)
        loop?.stop(); XCTAssertFalse(loop?.clockRunning ?? true)
        loop?.start(); loop?.advance(9)
        XCTAssertEqual(loop?.milliseconds, 0)
        subscription?.cancel(); subscription = nil
        loop = nil; XCTAssertNil(weakLoop)
    }

    func testProductionToolbarReordersRenderedControlsAndKeepsPinnedButtonsAndRestoredTools() async throws {
        let suite = "toolbar-rendered-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = RemoteToolLayout(defaults: defaults, movie: false, onHide: { _ in })
        let controls = Dictionary(uniqueKeysWithValues: RemoteTool.regular.map {
            ($0, AnyView(ButtonWitness(id: $0.id).frame(width: 36, height: 36)))
        })
        let trailing = ["manage", "lock", "rotate"].map {
            RemoteFixedToolControl(id: $0, view: AnyView(ButtonWitness(id: $0).frame(width: 36, height: 36)))
        }
        let toolbar = RemoteConfiguredToolbar(layout: layout, editing: false, isActive: true,
            controls: controls, leading: EmptyView(), trailing: trailing, pinnedEndCount: 2,
            fixedRecorder: false, applyHidden: { _ in }).frame(width: 330)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: toolbar)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 300)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        func find(_ id: String, _ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == id && view is UIButton { return view }
            return view.subviews.lazy.compactMap { find(id, $0) }.first
        }
        func center(_ id: String) throws -> CGPoint {
            let button = try XCTUnwrap(find(id, host.view))
            return button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.view)
        }
        let start = try center("hd"), lock = try center("lock"), rotate = try center("rotate")
        layout.move(.hd, to: 5)
        var intermediate: CGPoint?
        for _ in 0..<60 {
            let point = try center("hd")
            if point.x > start.x + 1 && point.x < start.x + 209 { intermediate = point; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(intermediate, "The real view must animate through intermediate slot positions")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(try center("hd").x, start.x + 210, accuracy: 0.5)
        XCTAssertEqual(try center("lock"), lock)
        XCTAssertEqual(try center("rotate"), rotate)
        layout.setVisible(.hd, false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(find("hd", host.view))
        layout.setVisible(.hd, true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(find("hd", host.view))
    }

    private struct ButtonWitness: UIViewRepresentable {
        let id: String
        func makeUIView(context: Context) -> UIButton {
            let view = UIButton(type: .custom)
            view.accessibilityIdentifier = id
            view.setTitle(id, for: .normal)
            view.setTitleColor(.black, for: .normal)
            return view
        }
        func updateUIView(_ view: UIButton, context: Context) {}
    }

    private final class Probe { var parent = 0; var content = 0 }
    private struct SlotHarness: View {
        let presentation: RemoteToolSlotPresentation
        let probe: Probe
        var body: some View {
            let _ = { probe.parent += 1 }()
            SlotContent(probe: probe).modifier(RemoteToolSlotTransform(presentation: presentation))
        }
    }
    private struct SlotContent: View {
        let probe: Probe
        var body: some View {
            let _ = { probe.content += 1 }()
            Text("HD").font(.system(size: 18, weight: .bold)).frame(width: 36, height: 36)
                .background(.blue.opacity(0.2))
        }
    }
}
