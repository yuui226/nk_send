import SwiftUI
import UIKit
import XCTest
@testable import ZTransfer

final class QueueAppearanceKeyMapTests: XCTestCase {
    func testFirstLayoutAndEmptyListResetDoNotFadeHistory() {
        let old = UUID(), new = UUID()
        var map = QueueAppearanceKeyMap()
        map.prepare([old]); XCTAssertFalse(map.shouldAppear(old))
        map.measured(visibleIDs: [old]); XCTAssertFalse(map.shouldAppear(old))
        map.prepare([new, old]); XCTAssertTrue(map.shouldAppear(new)); XCTAssertFalse(map.shouldAppear(old))
        map.measured(visibleIDs: [new]); XCTAssertFalse(map.shouldAppear(new))
        map.prepare([]); map.measured(visibleIDs: [])
        map.prepare([new]); XCTAssertFalse(map.shouldAppear(new))
    }

    func testPreviousNearestRangeSeparatesOrdinaryScrollAndFarJump() {
        let ids = (0..<600).map { _ in UUID() }
        var map = QueueAppearanceKeyMap(); map.prepare(ids)
        map.measured(visibleIDs: [ids[0]])
        // Header index 0, keys 1..<130. This is the previous measurement,
        // not a cache of every task that ever appeared on this page.
        XCTAssertFalse(map.shouldAppear(ids[128])); XCTAssertTrue(map.shouldAppear(ids[129]))
        XCTAssertTrue(map.shouldAppear(ids[300]))
        map.measured(visibleIDs: [ids[300]])
        XCTAssertTrue(map.shouldAppear(ids[198])); XCTAssertFalse(map.shouldAppear(ids[199]))
        XCTAssertFalse(map.shouldAppear(ids[428])); XCTAssertTrue(map.shouldAppear(ids[429]))
        XCTAssertTrue(map.shouldAppear(ids[0]))
        map.measured(visibleIDs: [ids[301]])
        XCTAssertFalse(map.shouldAppear(ids[300]))
    }

    func testInsertionReplacementAndReorderUseKeysWithoutResettingThePreviousMap() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var map = QueueAppearanceKeyMap(); map.prepare([a, b]); map.measured(visibleIDs: [a])
        map.prepare([c, b, a]); XCTAssertTrue(map.shouldAppear(c))
        map.prepare([d, c, a, b]); XCTAssertTrue(map.shouldAppear(c)); XCTAssertTrue(map.shouldAppear(d))
        XCTAssertFalse(map.shouldAppear(a)); XCTAssertFalse(map.shouldAppear(b))
        map.measured(visibleIDs: [d]); map.prepare([b, a, c, d])
        for id in [a,b,c,d] { XCTAssertFalse(map.shouldAppear(id)) }
        map.prepare([a,b]); map.measured(visibleIDs: [a]); map.prepare([c,a,b])
        XCTAssertTrue(map.shouldAppear(c)); XCTAssertFalse(map.shouldAppear(UUID()))
    }
}

@MainActor
final class QueueItemAppearanceTests: XCTestCase {
    func testFiniteFadeUses180msFastOutSlowInAndDoesNotRestart() {
        let clock = QueueItemAppearanceClock(automaticFrames: false)
        clock.appear(animated: true); XCTAssertEqual(clock.opacity, 0)
        clock.advance(1_000_000_000); clock.advance(1_090_000_000)
        XCTAssertEqual(clock.opacity, 0.775561, accuracy: 0.00001)
        clock.appear(animated: true)
        XCTAssertEqual(clock.opacity, 0.775561, accuracy: 0.00001)
        clock.advance(1_179_000_000); XCTAssertTrue(clock.isRunning)
        clock.advance(1_180_000_000); XCTAssertEqual(clock.opacity, 1); XCTAssertFalse(clock.isRunning)
    }

    func testLeavingOrBackgroundingFinishesWithoutReplayAndDoesNotRetainOwner() {
        var clock: QueueItemAppearanceClock? = QueueItemAppearanceClock()
        weak var weakClock = clock
        clock?.appear(animated: true); clock?.advance(0); clock?.advance(40_000_000)
        clock?.finish(); XCTAssertEqual(clock?.opacity, 1); XCTAssertFalse(clock!.isRunning)
        clock?.advance(90_000_000); XCTAssertEqual(clock?.opacity, 1)
        clock?.appear(animated: false); XCTAssertFalse(clock!.isRunning)
        clock?.appear(animated: true); clock = nil; XCTAssertNil(weakClock)
    }

    func testLeavingDiscardsThePendingLayoutCheckpoint() async throws {
        let old = UUID(), new = UUID(), later = UUID()
        let tracker = QueueItemAppearanceTracker(), removal = QueueRemovalCoordinator()
        tracker.prepare([old], removal: removal); tracker.measured()
        tracker.leave(); tracker.prepare([new], removal: removal)
        try await Task.sleep(for: .milliseconds(20))
        tracker.prepare([later, new], removal: removal)
        XCTAssertFalse(tracker.shouldAppear(later), "The departed page cannot commit the new page's initial key map")
        tracker.leave()
    }

    func testOldLayoutCannotConsumeAnInsertionBeforeItsOwnLayout() async throws {
        let old = UUID(), new = UUID()
        let tracker = QueueItemAppearanceTracker(), removal = QueueRemovalCoordinator()
        tracker.prepare([old], removal: removal); tracker.measured()
        try await Task.sleep(for: .milliseconds(20))
        tracker.measured() // A scroll/layout callback still waiting on main.
        tracker.prepare([new, old], removal: removal)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(tracker.shouldAppear(new), "A stale layout must not mark an unpresented insertion as history")
        tracker.measured()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(tracker.shouldAppear(new)); tracker.leave()
    }
}

@MainActor
final class QueueItemAppearanceLayoutTests: XCTestCase {
    @MainActor private final class Source: ObservableObject {
        @Published var ids = [UUID(), UUID(), UUID()]
        @Published var active = true
        var clocks: [UUID: QueueItemAppearanceClock] = [:]
        func clock(_ id: UUID) -> QueueItemAppearanceClock {
            if let clock = clocks[id] { return clock }
            let clock = QueueItemAppearanceClock(automaticFrames: false); clocks[id] = clock; return clock
        }
    }
    private struct Host: View {
        @ObservedObject var source: Source
        let tracker: QueueItemAppearanceTracker
        let removal: QueueRemovalCoordinator
        var body: some View {
            tracker.prepare(source.ids, removal: removal)
            return ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 8)
                    ForEach(source.ids, id: \.self) { id in
                        Color.black.frame(height: 64)
                            .background(QueueRemovalAnchor(id: id, value: removal.value(for: id), coordinator: removal))
                            .modifier(QueueItemPlacement())
                            .modifier(QueueItemAppearance(id: id, tracker: tracker, clock: source.clock(id)))
                    }
                }
                .coordinateSpace(name: QueueItemPlacement.coordinateSpace)
                .background(QueueAppearanceCheckpoint(tracker: tracker))
            }
            .frame(width: 240, height: 160).background(Color.white)
            .environment(\.scenePhase, source.active ? .active : .background)
        }
    }

    func testRealLayoutCheckpointFadesOnlyInsertedRowAndBackgroundStopsItsClock() async throws {
        let source = Source(), tracker = QueueItemAppearanceTracker(), removal = QueueRemovalCoordinator()
        let window = try host(source, tracker, removal)
        try await settle(window)
        for id in source.ids {
            XCTAssertEqual(source.clock(id).opacity, 1); XCTAssertFalse(source.clock(id).isRunning)
            XCTAssertFalse(tracker.shouldAppear(id))
        }
        let inserted = UUID(); source.ids.insert(inserted, at: 0)
        try await settle(window)
        let clock = source.clock(inserted)
        XCTAssertTrue(clock.isRunning); XCTAssertEqual(clock.opacity, 0)
        XCTAssertFalse(tracker.shouldAppear(inserted), "The new layout has now committed")
        for id in source.ids.dropFirst() { XCTAssertEqual(source.clock(id).opacity, 1); XCTAssertFalse(source.clock(id).isRunning) }
        // Hold only appearance at its first frame. Placement is an independent
        // spring: let the old black card move out from under this pixel first.
        try await Task.sleep(for: .milliseconds(400)); window.layoutIfNeeded()
        let marker = try XCTUnwrap(markers(window).first { $0.id == inserted })
        let point = marker.convert(CGPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: window)
        let initial = try capture(window, "hidden"); XCTAssertGreaterThan(try red(initial, at: point), 0.98)
        clock.advance(0); clock.advance(90_000_000); try await settle(window)
        let middle = try capture(window, "middle")
        XCTAssertEqual(try red(middle, at: point), 1 - clock.opacity, accuracy: 0.015)
        source.active = false; try await settle(window)
        XCTAssertFalse(clock.isRunning); XCTAssertEqual(clock.opacity, 1)
        let settled = try capture(window, "settled"); XCTAssertLessThan(try red(settled, at: point), 0.02)
        source.active = true; try await settle(window); XCTAssertFalse(clock.isRunning)
    }

    func testOffscreenInsertionAndScrollingBackDoNotReplayAppearance() async throws {
        let source = Source(), tracker = QueueItemAppearanceTracker(), removal = QueueRemovalCoordinator()
        source.ids = (0..<60).map { _ in UUID() }
        let first = source.ids[0]
        let window = try host(source, tracker, removal)
        try await settle(window)
        XCTAssertLessThan(source.clocks.count, source.ids.count, "Exercise real lazy materialization")
        let tail = UUID(); source.ids.append(tail); try await settle(window)
        XCTAssertFalse(tracker.shouldAppear(tail))
        try await scroll(to: tail, end: true, in: window)
        XCTAssertEqual(source.clock(tail).opacity, 1); XCTAssertFalse(source.clock(tail).isRunning)

        let head = UUID(); source.ids.insert(head, at: 0); try await settle(window)
        XCTAssertFalse(tracker.shouldAppear(head))
        try await scroll(to: head, end: false, in: window)
        for id in [head, first] { XCTAssertEqual(source.clock(id).opacity, 1); XCTAssertFalse(source.clock(id).isRunning) }
    }

    private func host(_ source: Source, _ tracker: QueueItemAppearanceTracker,
                      _ removal: QueueRemovalCoordinator) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 240, height: 200)
        window.rootViewController = UIHostingController(rootView: Host(source: source, tracker: tracker, removal: removal))
        window.backgroundColor = .white; window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            source.clocks.values.forEach { $0.finish() }; tracker.leave(); removal.leave()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        return window
    }
    private func descendantScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap(descendantScroll).first
    }
    private func scroll(to id: UUID, end: Bool, in window: UIWindow) async throws {
        let scroll = try XCTUnwrap(descendantScroll(window))
        let deadline = ContinuousClock.now + .seconds(3)
        while !markers(window).contains(where: { $0.id == id && $0.visibleOffset != nil }) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Scroll did not materialize row; end=\(end) offset=\(scroll.contentOffset) size=\(scroll.contentSize)")
                throw CocoaError(.coderInvalidValue)
            }
            // LazyVStack corrects its estimated content size as distant rows
            // materialize. Follow the corrected bottom, like continued drag.
            scroll.setContentOffset(CGPoint(x: 0, y: end ? max(0, scroll.contentSize.height - scroll.bounds.height) : 0), animated: false)
            try await settle(window)
        }
    }

    private func settle(_ window: UIWindow) async throws {
        try await Task.sleep(for: .milliseconds(50)); window.layoutIfNeeded()
    }
    private func markers(_ view: UIView) -> [QueueRemovalAnchor.Marker] {
        (view as? QueueRemovalAnchor.Marker).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    private func capture(_ window: UIWindow, _ name: String) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("queue-appearance-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: path); print("QUEUE_APPEARANCE_IMAGE \(path.path)")
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }
    private func red(_ image: UIImage, at point: CGPoint) throws -> CGFloat {
        let pixel = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: floor(point.x * image.scale),
            y: floor(point.y * image.scale), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return CGFloat(bytes[0]) / 255
    }
}
