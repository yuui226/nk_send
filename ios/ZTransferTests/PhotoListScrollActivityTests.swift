import XCTest
import UIKit
@testable import ZTransfer

@MainActor
final class PhotoListScrollActivityTests: XCTestCase {
    func testFlightAdmissionRejectsDuplicateAndMissingSourcesWithoutHoldingCounts() throws {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 500)
        let source = CGRect(x: 10, y: 120, width: 80, height: 80)
        var admissions = PhotoListFlightAdmissions()
        for invalid in [nil, .zero, .null, .infinite, CGRect(x: 0, y: 0, width: 50, height: 50)] as [CGRect?] {
            XCTAssertNil(admissions.admit(source: invalid, viewport: viewport, count: 3))
        }
        XCTAssertNil(admissions.admit(source: source, viewport: viewport, count: 0))
        XCTAssertEqual(admissions.heldCount, 0)
        let first = try XCTUnwrap(admissions.admit(source: source, viewport: viewport, count: 3))
        XCTAssertNil(admissions.admit(source: source, viewport: viewport, count: 1))
        XCTAssertEqual(admissions.heldCount, 3)
        XCTAssertEqual(admissions.finish(first.id), 3)
        XCTAssertNil(admissions.finish(first.id))
        let replacement = try XCTUnwrap(admissions.admit(source: source, viewport: viewport, count: 1))
        XCTAssertNotEqual(replacement.id, first.id)
        XCTAssertNil(admissions.finish(first.id), "Late completion must not release a replacement")
        XCTAssertEqual(admissions.heldCount, 1)
        XCTAssertEqual(admissions.finish(replacement.id), 1)
        XCTAssertEqual(admissions.heldCount, 0)
    }

    func testFlightCancellationReleasesEachBatchOnceAndAllowsReentry() throws {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 500)
        var admissions = PhotoListFlightAdmissions()
        let a = CGRect(x: 10, y: 20, width: 80, height: 80)
        let b = CGRect(x: 110, y: 20, width: 80, height: 80)
        _ = try XCTUnwrap(admissions.admit(source: a, viewport: viewport, count: 4))
        _ = try XCTUnwrap(admissions.admit(source: b, viewport: viewport, count: 2))
        let cancelled = admissions.activeIDs
        let released = cancelled.compactMap { admissions.finish($0) }.reduce(0, +)
        XCTAssertEqual(released, 6)
        XCTAssertTrue(admissions.activeIDs.isEmpty)
        XCTAssertEqual(admissions.heldCount, 0)
        _ = try XCTUnwrap(admissions.admit(source: a, viewport: viewport, count: 1))
        for id in cancelled { XCTAssertNil(admissions.finish(id)) }
        XCTAssertEqual(admissions.heldCount, 1)
    }

    func testCollectionMemberAndEnqueueButtonRetainIndependentGeometry() {
        let collection = CGRect(x: 10, y: 100, width: 90, height: 90)
        let member = CGRect(x: 110, y: 100, width: 90, height: 90)
        let button = CGRect(x: 15, y: 150, width: 32, height: 32)
        let viewport = CGRect(x: 0, y: 80, width: 320, height: 500)
        var bounds = PhotoListCellBoundsPreferenceKey.defaultValue
        PhotoListCellBoundsPreferenceKey.reduce(value: &bounds) { [.burst("42"): collection] }
        PhotoListCellBoundsPreferenceKey.reduce(value: &bounds) { [.photo(42): member] }
        PhotoListCellBoundsPreferenceKey.reduce(value: &bounds) { [.burstEnqueue("42"): button] }
        XCTAssertEqual(bounds.count, 3)
        XCTAssertEqual(visiblePhotoListCellBounds(.burst("42"), bounds: bounds, viewport: viewport), collection)
        XCTAssertEqual(visiblePhotoListCellBounds(.photo(42), bounds: bounds, viewport: viewport), member)
        XCTAssertEqual(visiblePhotoListCellBounds(.burstEnqueue("42"), bounds: bounds, viewport: viewport), button)

        // Lazy-grid preferences are replaced as a snapshot, not accumulated.
        bounds = [.burst("42"): collection, .burstEnqueue("42"): button]
        XCTAssertNil(visiblePhotoListCellBounds(.photo(42), bounds: bounds, viewport: viewport),
                     "Returning to a member must never substitute its collection")
        bounds = [.photo(42): member]
        XCTAssertNil(visiblePhotoListCellBounds(.burst("42"), bounds: bounds, viewport: viewport))
        XCTAssertNil(visiblePhotoListCellBounds(.burstEnqueue("42"), bounds: bounds, viewport: viewport))
    }

    func testCellSourceRejectsOffscreenComposedAndInvalidBounds() {
        let viewport = CGRect(x: 0, y: 100, width: 320, height: 500)
        for frame in [CGRect(x: 0, y: 0, width: 90, height: 90), .zero, .null, .infinite] {
            XCTAssertNil(visiblePhotoListCellBounds(.photo(1), bounds: [.photo(1): frame], viewport: viewport))
        }
        let partial = CGRect(x: 0, y: 90, width: 90, height: 90)
        XCTAssertEqual(visiblePhotoListCellBounds(.photo(1), bounds: [.photo(1): partial], viewport: viewport), partial)
        XCTAssertFalse(photoFrameIsFullyVisible(partial, in: viewport),
                       "A partially visible source is usable, but preview return still needs scrolling")
    }

    func testScrollLayoutCountsHeadersCollectionsAndOnlyDisplayedMembers() {
        let files = (1...4).map { id in
            CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 10,
                       fileName: "\(id).JPG", captureDate: nil, isProtected: false)
        }
        let sections = [PhotoDaySection(day: "a", files: Array(files.prefix(3))),
                        PhotoDaySection(day: "b", files: [files[3]])]
        func layout(expanded: Set<String> = [], collapsed: Set<String> = [],
                    collapsing: String? = nil, keep: Int = 0) -> [String: Int] {
            PhotoListScrollLayout(sections: sections, burstIDs: [1: "burst", 2: "burst"],
                collapseBursts: true, expandedBursts: expanded, collapsedDays: collapsed,
                collapsingDay: collapsing, keepCount: keep).indices()
        }
        XCTAssertEqual(layout(), ["header_a": 0, "burst_burst": 1, "photo_3": 2, "header_b": 3, "photo_4": 4])
        XCTAssertEqual(layout(expanded: ["burst"]), ["header_a": 0, "burst_burst": 1, "photo_1": 2,
            "photo_2": 3, "photo_3": 4, "header_b": 5, "photo_4": 6])
        XCTAssertEqual(layout(collapsed: ["a"]), ["header_a": 0, "header_b": 1, "photo_4": 2])
        XCTAssertEqual(layout(expanded: ["burst"], collapsing: "a", keep: 2),
                       ["header_a": 0, "burst_burst": 1, "photo_1": 2, "header_b": 3, "photo_4": 4])
    }

    func testFirstVisibleUsesLowestItemIndexAcrossColumnsAndPhysicalPixels() {
        let viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
        for columns in 2...4 {
            var frames: [String: CGRect] = [:]
            var indices: [String: Int] = [:]
            for column in 0..<columns {
                let id = "cell\(column)"
                indices[id] = 30 + column
                frames[id] = CGRect(x: column * 90, y: 95, width: 80, height: 80)
            }
            indices["oldHeader"] = 29
            frames["oldHeader"] = CGRect(x: 0, y: 60, width: 400, height: 40)
            frames["unregistered"] = CGRect(x: 0, y: 90, width: 80, height: 80)
            let first = PhotoListBackTopController.firstVisible(frames: frames, indices: indices,
                                                               viewport: viewport, scale: 3)
            XCTAssertEqual(first?.index, 30)
            XCTAssertEqual(first?.offset, 15)
            frames["oldHeader"]?.origin.y = 61
            let header = PhotoListBackTopController.firstVisible(frames: frames, indices: indices,
                                                                viewport: viewport, scale: 3)
            XCTAssertEqual(header?.index, 29)
            XCTAssertEqual(header?.offset, 117)
        }
    }

    func testBackTopControllerRunsIdleTimerAndResetsReturnAndDeparture() async throws {
        let controller = PhotoListBackTopController()
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 500)
        func position(_ y: CGFloat) {
            controller.update(frames: ["cell": CGRect(x: 0, y: y, width: 100, height: 100)],
                              indices: ["cell": 35], viewport: viewport, scale: 2)
        }
        controller.setScrolling(true)
        position(50)
        position(60)
        XCTAssertTrue(controller.isVisible)
        controller.setScrolling(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.isVisible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(controller.isVisible)
        controller.setScrolling(true)
        position(70)
        XCTAssertTrue(controller.isVisible)
        controller.beginReturn()
        position(80)
        XCTAssertFalse(controller.isVisible)
        controller.finishReturn()
        position(90)
        XCTAssertTrue(controller.isVisible)
        controller.setScrolling(false)
        controller.reset()
        XCTAssertFalse(controller.isVisible)
        position(50)
        XCTAssertFalse(controller.isVisible, "Re-entry starts a new direction baseline")
        controller.reset()
    }

    func testBackTopUsesItemThresholdDirectionAndPixelDeadband() {
        var state = PhotoListBackTopState()
        state.update(index: 40, offsetPixels: 100, scrolling: true, now: 0)
        XCTAssertFalse(state.isVisible, "Restoring a deep position alone must not show it")
        state.update(index: 40, offsetPixels: 96, scrolling: true, now: 0)
        XCTAssertFalse(state.isVisible, "Four pixels is inside the deadband")
        state.update(index: 40, offsetPixels: 91, scrolling: true, now: 0)
        XCTAssertTrue(state.isVisible)
        state.update(index: 40, offsetPixels: 96, scrolling: true, now: 0)
        XCTAssertFalse(state.isVisible)
        state.update(index: 30, offsetPixels: 500, scrolling: true, now: 0)
        XCTAssertTrue(state.isVisible, "Crossing rows uses index before intra-row offset")
        state.update(index: 29, offsetPixels: 0, scrolling: true, now: 0)
        XCTAssertFalse(state.isVisible)
    }

    func testBackTopIdleDeadlineResetsOnResumedScrollAndReturnSuppressesDisplay() {
        var state = PhotoListBackTopState()
        state.update(index: 50, offsetPixels: 0, scrolling: true, now: 0)
        state.update(index: 49, offsetPixels: 0, scrolling: false, now: 1)
        XCTAssertEqual(state.hideDeadline, 2.8)
        state.update(index: 49, offsetPixels: 0, scrolling: false, now: 2)
        XCTAssertEqual(state.hideDeadline, 2.8, "Idle layout updates must not extend the timer")
        state.expire(now: 2.79)
        XCTAssertTrue(state.isVisible)
        state.update(index: 49, offsetPixels: 0, scrolling: true, now: 2.8)
        state.expire(now: 3)
        XCTAssertTrue(state.isVisible, "An obsolete deadline must not hide during a new scroll")
        state.update(index: 49, offsetPixels: 0, scrolling: false, now: 4)
        state.expire(now: 5.8)
        XCTAssertFalse(state.isVisible)
        state.update(index: 48, offsetPixels: 0, scrolling: true, now: 6)
        XCTAssertTrue(state.isVisible)
        state.beginReturn()
        state.update(index: 40, offsetPixels: 0, scrolling: true, now: 7)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.hideDeadline)
        state.finishReturn()
        state.update(index: 39, offsetPixels: 0, scrolling: true, now: 8)
        XCTAssertTrue(state.isVisible, "A new upward gesture works after completion or cancellation")
    }

    private final class TestScrollView: UIScrollView {
        var simulatedDragging = false
        var simulatedDeceleration = false
        override var isDragging: Bool { simulatedDragging }
        override var isDecelerating: Bool { simulatedDeceleration }
    }

    func testRealObserverUsesCurrentOffsetAtEightPixelBoundary() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let scroll = TestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset.top = 20
        scroll.contentSize = CGSize(width: 320, height: 2_000)
        window.addSubview(scroll)
        let observer = PhotoListScrollActivity.ObserverView()
        var reported = [Bool]()
        observer.onScroll = { reported.append($0) }
        scroll.addSubview(observer)

        scroll.simulatedDragging = true
        scroll.contentOffset.y = -20 + 7 / window.screen.scale
        XCTAssertEqual(reported.last, true)
        scroll.contentOffset.y = -20 + 8 / window.screen.scale
        XCTAssertEqual(reported.last, false, "The crossing event must not read the previous SwiftUI offset")
        scroll.simulatedDragging = false
        scroll.simulatedDeceleration = true
        scroll.contentOffset.y = 120
        XCTAssertEqual(reported.last, false)
        scroll.contentOffset.y = -20
        XCTAssertEqual(reported.last, true)
        observer.detach()
    }

    func testIdleLayoutChangesDoNotCollapseReminderAndDetachRemovesObservation() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let scroll = TestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 320, height: 2_000)
        window.addSubview(scroll)
        let observer = PhotoListScrollActivity.ObserverView()
        var reported = [Bool]()
        observer.onScroll = { reported.append($0) }
        scroll.addSubview(observer)
        scroll.contentOffset.y = 100
        XCTAssertTrue(reported.isEmpty)
        scroll.simulatedDragging = true
        scroll.contentOffset.y = 120
        XCTAssertEqual(reported, [false])
        observer.detach()
        scroll.contentOffset.y = 140
        XCTAssertEqual(reported, [false])
    }

    func testActivityContinuesThroughQuietDecelerationAndStopsOnce() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let scroll = TestScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: 320, height: 2_000)
        window.addSubview(scroll)
        let observer = PhotoListScrollActivity.ObserverView()
        var activity: [Bool] = []
        observer.onActivityChanged = { activity.append($0) }
        scroll.addSubview(observer)
        defer { observer.detach() }
        scroll.simulatedDragging = true
        scroll.contentOffset.y = 100
        scroll.contentOffset.y = 110
        XCTAssertEqual(activity, [true])
        scroll.simulatedDragging = false
        scroll.simulatedDeceleration = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(activity, [true], "Quiet offsets do not prove deceleration has ended")
        scroll.simulatedDeceleration = false
        for _ in 0..<100 where activity.last != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(activity, [true, false])
        scroll.contentOffset.y = 120
        XCTAssertEqual(activity, [true, false], "Idle layout updates do not start scrolling")
        scroll.simulatedDragging = true
        scroll.contentOffset.y = 130
        XCTAssertEqual(activity, [true, false, true])
        observer.detach()
        scroll.simulatedDragging = false
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(activity, [true, false, true], "Detached observers must not deliver late stop callbacks")
    }
}

extension PhotoListScrollActivityTests {
    func testLargeGridProjectionReusesEntriesAndRebuildsForEveryStructuralInput() {
        let files = (1...5000).map { id in
            CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 1,
                       fileName: "\(id).JPG", captureDate: "20261018T120000", isProtected: false)
        }
        let sections = stride(from: 0, to: files.count, by: 100).map { i in
            PhotoDaySection(day: "day\(i)", files: Array(files[i..<i + 100]))
        }
        let bursts = Dictionary(uniqueKeysWithValues: files.map { ($0.id, "burst\($0.id / 10)") })
        let cache = PhotoListGridCache()
        let initial = PhotoListScrollLayout(sections: sections, burstIDs: bursts, collapseBursts: true,
            expandedBursts: [], collapsedDays: [], collapsingDay: nil, keepCount: 2)
        let first = cache.snapshot(for: initial)
        for _ in 0..<120 {
            let next = cache.snapshot(for: initial)
            XCTAssertEqual(next.indices, first.indices)
        }
        XCTAssertEqual(cache.buildCount, 1)
        for collapsed in [false, true] {
            for expanded in [Set<String>(), ["burst1", "burst2"]] {
                for days in [Set<String>(), ["day0"]] {
                    for collapsing in [nil, "day0"] as [String?] {
                        let input = PhotoListScrollLayout(sections: sections, burstIDs: bursts,
                            collapseBursts: collapsed, expandedBursts: expanded, collapsedDays: days,
                            collapsingDay: collapsing, keepCount: 2)
                        let snapshot = cache.snapshot(for: input)
                        XCTAssertEqual(snapshot.indices, input.indices())
                        for section in sections {
                            XCTAssertEqual(snapshot.entriesByDay[section.day],
                                photoGridEntries(section.files, burstIDByFile: bursts,
                                                 collapse: collapsed, expandedIDs: expanded))
                        }
                    }
                }
            }
        }
        let changed = PhotoListScrollLayout(sections: Array(sections.dropFirst()), burstIDs: [:], collapseBursts: true,
            expandedBursts: [], collapsedDays: [], collapsingDay: nil, keepCount: 0)
        let snapshot = cache.snapshot(for: changed)
        XCTAssertNil(snapshot.entriesByDay["day0"])
        XCTAssertEqual(snapshot.indices, changed.indices())
    }
}
