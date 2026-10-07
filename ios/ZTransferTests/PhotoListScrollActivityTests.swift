import XCTest
import UIKit
@testable import ZTransfer

@MainActor
final class PhotoListScrollActivityTests: XCTestCase {
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
}
