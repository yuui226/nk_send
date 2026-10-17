import XCTest
@testable import ZTransfer

final class RemoteParameterWheelTests: XCTestCase {
    private let iso: [UInt64] = [100, 200, 400, 800, 1600, 3200]
    private func config(_ current: UInt64, values: [UInt64]? = nil, writable: Bool = true,
                        auto: Bool? = nil) -> RemoteParameterWheel.Configuration {
        .init(descriptor: .init(property: .iso, writable: writable, current: current, values: values ?? iso),
              autoEnabled: auto, hasAutoControl: auto != nil)
    }

    func testNearestPhysicalAnchorAndEnumDirection() {
        let negative = UInt64(bitPattern: -1000)
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .exposureCompensation,
            values: [negative, 0, 1000], current: UInt64(bitPattern: -800)), 0)
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .iso, values: iso, current: 300), 1) // first tie
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .iso, values: [], current: 400), -1)
        let shutter: [UInt64] = [0xFFFF_FFFF, 1 << 16 | 30, 1 << 16 | 125, 1 << 16 | 1000]
        XCTAssertEqual(RemoteExposureParameters.anchorIndex(for: .nikonShutter, values: shutter, current: 1 << 16 | 100), 2)
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .nikonShutter, values: shutter), 1)
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .fNumber, values: [280, 400, 560]), -1)
        XCTAssertEqual(RemoteExposureParameters.downStepSign(for: .iso, values: iso.reversed()), -1)
    }

    func testNonEnumAnchorDisplaysTrueValueAndCrossingRequestsDelta() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(300))
        wheel.advance(0); wheel.advance(180_000_000)
        XCTAssertEqual(wheel.rows.first { $0.index == 1 }?.value, 300)
        wheel.beginDrag()
        XCTAssertEqual(wheel.position.value, 1)
        XCTAssertNil(wheel.drag(by: 8))
        XCTAssertEqual(wheel.drag(by: 2), 1)
        XCTAssertEqual(wheel.drag(by: 36), 2)
    }

    func testRubberBandHasBoundedDebtAndReversalRespondsImmediately() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(3200)); wheel.beginDrag()
        XCTAssertNil(wheel.drag(by: 10000))
        XCTAssertEqual(wheel.position.value, 5.45, accuracy: 0.00001)
        XCTAssertNil(wheel.drag(by: -9))
        XCTAssertEqual(wheel.position.value, 5.3, accuracy: 0.00001)
        XCTAssertEqual(wheel.drag(by: -36), -1)
        XCTAssertEqual(wheel.position.value, 4)
        XCTAssertEqual(wheel.drag(by: -10000), -4)
        XCTAssertEqual(wheel.position.value, -0.45, accuracy: 0.00001)
        XCTAssertNil(wheel.drag(by: 9))
        XCTAssertEqual(wheel.position.value, -0.3, accuracy: 0.00001)
    }

    func testDomainShrinkPreservesGestureWithoutLargeCompensatingStep() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(3200)); wheel.beginDrag()
        wheel.configure(config(200, values: [100, 200]))
        XCTAssertTrue(wheel.dragging)
        XCTAssertNil(wheel.drag(by: 1))
        XCTAssertEqual(wheel.drag(by: -19), -1)
        wheel.configure(config(100, values: []))
        XCTAssertFalse(wheel.dragging)
        XCTAssertNil(wheel.drag(by: 18))
    }

    func testCancelAndReleaseAlignLatestExternalValueWithoutInertia() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(400)); wheel.beginDrag()
        XCTAssertEqual(wheel.drag(by: 27), 2)
        // Camera write failed/physical dial changed while finger remained down.
        wheel.configure(config(200))
        XCTAssertTrue(wheel.dragging)
        XCTAssertEqual(wheel.position.value, 3.5)
        wheel.endDrag()
        XCTAssertEqual(wheel.position.target, 1)
        wheel.advance(0); wheel.advance(180_000_000)
        XCTAssertEqual(wheel.position.value, 1)
        XCTAssertFalse(wheel.position.isRunning)
    }

    func testLargeExternalJumpSnapsAndSmallJumpUses180msCurve() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(3200))
        XCTAssertEqual(wheel.position.value, 5)
        XCTAssertFalse(wheel.position.isRunning)
        wheel.configure(config(800))
        wheel.advance(0); wheel.advance(90_000_000)
        XCTAssertEqual(wheel.position.value, 5 - 2 * ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
        // Catching an in-flight wheel restarts from actual camera anchor.
        wheel.beginDrag()
        XCTAssertEqual(wheel.position.value, 3)
        XCTAssertFalse(wheel.position.isRunning)
    }

    func testReturningToDisplayedAnchorCancelsPendingExternalAnimation() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(100))
        wheel.configure(config(200))
        XCTAssertTrue(wheel.position.isRunning)
        wheel.configure(config(100)) // returns before the animation's first frame
        XCTAssertFalse(wheel.position.isRunning)
        wheel.advance(1_000_000_000)
        XCTAssertEqual(wheel.position.value, 0)
    }

    func testWritableDirectionAndAutoKeyChangesCancelGesture() {
        for next in [config(400, writable: false), config(400, values: iso.reversed()), config(400, auto: false)] {
            var wheel = RemoteParameterWheel()
            wheel.configure(config(400)); wheel.beginDrag(); _ = wheel.drag(by: 10)
            wheel.configure(next)
            XCTAssertFalse(wheel.dragging)
            XCTAssertEqual(wheel.position.target, Float(next.anchor))
        }
        var wheel = RemoteParameterWheel()
        wheel.configure(config(400, auto: true)); wheel.beginDrag()
        XCTAssertFalse(wheel.dragging)
        XCTAssertFalse(wheel.showsDragHint)
    }

    func testRowDepthAndNeighborFadeFollowDragAndSnap() {
        var wheel = RemoteParameterWheel()
        wheel.configure(config(400)); wheel.beginDrag()
        wheel.advance(0); wheel.advance(150_000_000)
        XCTAssertEqual(wheel.neighbors.value, 1)
        let neighbor = wheel.rows.first { $0.index == 3 }!
        XCTAssertEqual(neighbor.offset, -18)
        XCTAssertEqual(neighbor.alpha, 0.38, accuracy: 0.00001)
        XCTAssertEqual(neighbor.scale, 0.85, accuracy: 0.00001)
        _ = wheel.drag(by: 6)
        wheel.endDrag()
        wheel.advance(200_000_000); wheel.advance(380_000_000)
        XCTAssertFalse(wheel.position.isRunning)
        wheel.advance(530_000_000)
        XCTAssertEqual(wheel.neighbors.value, 0)
        XCTAssertFalse(wheel.needsFrames)
        XCTAssertEqual(wheel.rows.filter { $0.alpha > 0 }.map(\.index), [2])
    }

    func testShortDomainsStillDragButDoNotShowDecorativeHint() {
        // ReleaseCommitWheelTest's >3 rule governs only ParamTile's hint.
        for count in [2, 3, 4] {
            var wheel = RemoteParameterWheel()
            wheel.configure(config(100, values: Array(iso.prefix(count))))
            XCTAssertEqual(wheel.showsDragHint, count > 3)
            wheel.beginDrag()
            XCTAssertEqual(wheel.drag(by: 18), 1)
        }
    }

    func testLoadingPulseReverses900msAndStopsAfterDescriptorArrives() {
        var wheel = RemoteParameterWheel()
        wheel.advance(0); wheel.advance(900_000_000)
        XCTAssertEqual(wheel.loadingAlpha, 0.55, accuracy: 0.00001)
        wheel.advance(1_350_000_000)
        XCTAssertEqual(wheel.loadingAlpha, 0.25 + 0.3 * ZTransferAndroidMotion.fastOutSlowIn(0.5), accuracy: 0.00001)
        wheel.advance(1_800_000_000)
        XCTAssertEqual(wheel.loadingAlpha, 0.25, accuracy: 0.00001)
        wheel.configure(config(100))
        XCTAssertFalse(wheel.needsFrames)
    }

    func testCompactGeometryAndMonitorFormattingMatchAndroid() {
        let compact = RemoteParameterTileGeometry(width: 88, height: 42)
        XCTAssertEqual(compact.valueFontSize, 14)
        XCTAssertEqual(compact.valueLineHeight, 16)
        XCTAssertEqual(compact.labelTop, 2)
        XCTAssertEqual(compact.autoBadgeWidth, 32)
        XCTAssertEqual(compact.autoBadgeHeight, 17)
        XCTAssertEqual(compact.autoBadgeFontSize, 7)
        let regular = RemoteParameterTileGeometry(width: 180, height: 54)
        XCTAssertEqual(regular.valueFontSize, 16)
        XCTAssertEqual(regular.autoBadgeWidth, 44)
        XCTAssertEqual(regular.autoBadgeHeight, 22)
        XCTAssertEqual(regular.autoBadgeFontSize, 9)
        XCTAssertTrue(regular.isAutoTouch(CGPoint(x: 136, y: 30)))
        XCTAssertFalse(regular.isAutoTouch(CGPoint(x: 135, y: 30)))
        XCTAssertEqual(RemoteExposureParameters.monitorFormat(.iso, raw: 400), "400")
        XCTAssertEqual(RemoteExposureParameters.monitorFormat(.movieExposureCompensation, raw: UInt64(bitPattern: -1000)), "-1.0")
        XCTAssertEqual(RemoteExposureParameters.monitorFormat(.fNumber, raw: 280), "f/2.8")
    }

    func testTouchConsumesOnlyVerticalSlopAndNeverTapsAfterDragOrCancel() {
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 54)
        var input = RemoteParameterTouch()
        input.down(CGPoint(x: 170, y: 10)) // AUTO region
        XCTAssertEqual(input.move(CGPoint(x: 170, y: 18), bounds: bounds, writable: true), [.begin, .delta(0)])
        XCTAssertEqual(input.move(CGPoint(x: 170, y: 20), bounds: bounds, writable: true), [.delta(2)])
        XCTAssertEqual(input.move(CGPoint(x: 170, y: 25), bounds: bounds, writable: true), [.delta(5)])
        XCTAssertEqual(input.up(CGPoint(x: 170, y: 25), bounds: bounds), [.end])
        input.down(CGPoint(x: 170, y: 10))
        XCTAssertEqual(input.up(CGPoint(x: 170, y: 10), bounds: bounds), [.tap(CGPoint(x: 170, y: 10))])
        input.down(CGPoint(x: 170, y: 10))
        _ = input.move(CGPoint(x: 170, y: 25), bounds: bounds, writable: true)
        XCTAssertEqual(input.cancel(), [.end])
        XCTAssertEqual(input.up(CGPoint(x: 170, y: 25), bounds: bounds), [])
    }

    @MainActor
    func testActualInputRoutesAutoHitRegionBusyStateAndWholeCardDrag() {
        let view = RemoteParameterInput.InputView(frame: CGRect(x: 0, y: 0, width: 180, height: 54))
        var opened = 0, toggled = 0, began = 0
        func configure(busy: Bool, auto: Bool) {
            view.configure(.init(configuration: config(400, auto: auto), autoBusy: busy,
                identifier: "iso", label: "ISO", value: "400", onOpenList: { opened += 1 },
                onAutoToggle: { toggled += 1 }, onBegin: { began += 1 }, onDrag: { _ in }, onEnd: {}))
        }
        configure(busy: false, auto: false)
        view.deliver([.tap(CGPoint(x: 170, y: 10))])
        view.deliver([.tap(CGPoint(x: 90, y: 30))])
        view.deliver([.begin, .delta(18), .end])
        XCTAssertEqual(toggled, 1); XCTAssertEqual(opened, 1); XCTAssertEqual(began, 1)
        configure(busy: true, auto: false)
        view.deliver([.tap(CGPoint(x: 170, y: 10))])
        XCTAssertEqual(toggled, 1)
        configure(busy: false, auto: true)
        view.deliver([.tap(CGPoint(x: 90, y: 30))])
        XCTAssertEqual(opened, 1)
    }

    func testPointerHandoffRetainsSlopAndAvoidsJumpBetweenFingers() {
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 54)
        var input = RemoteParameterTouch()
        input.down(CGPoint(x: 20, y: 10))
        XCTAssertEqual(input.move(CGPoint(x: 20, y: 16), bounds: bounds, writable: true), [])
        input.handOff(to: CGPoint(x: 100, y: 30))
        XCTAssertEqual(input.move(CGPoint(x: 100, y: 34), bounds: bounds, writable: true), [.begin, .delta(2)])
        input.handOff(to: CGPoint(x: 10, y: 10))
        XCTAssertEqual(input.move(CGPoint(x: 10, y: 13), bounds: bounds, writable: true), [.delta(3)])
        XCTAssertEqual(input.up(CGPoint(x: 10, y: 13), bounds: bounds), [.end])
    }
}
