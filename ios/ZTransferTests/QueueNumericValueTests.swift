import Combine
import XCTest
@testable import ZTransfer

final class QueueNumericValueTests: XCTestCase {
    func testAndroidNumericParserVectorsAndPlaceIdentity() throws {
        let before = try XCTUnwrap(queueNumericLabel("42.1 MB/s")), after = try XCTUnwrap(queueNumericLabel("42.3 MB/s"))
        XCTAssertEqual(before.digit(1), after.digit(1)); XCTAssertEqual(before.digit(0), after.digit(0))
        XCTAssertNotEqual(before.digit(-1), after.digit(-1)); XCTAssertEqual(before.suffix, after.suffix)
        let short = try XCTUnwrap(queueNumericLabel("9.2 MB/s")), long = try XCTUnwrap(queueNumericLabel("109.2 MB/s"))
        XCTAssertEqual(short.digit(0), long.digit(0)); XCTAssertEqual(short.digit(-1), long.digit(-1))
        XCTAssertEqual(short.digit(1), ""); XCTAssertEqual(long.digit(1), "0"); XCTAssertEqual(long.digit(2), "1")
        XCTAssertEqual(queueNumericLabel("0"), .init(integer: "0", fraction: "", separator: "", suffix: ""))
        XCTAssertEqual(queueNumericLabel("120"), .init(integer: "120", fraction: "", separator: "", suffix: ""))
        XCTAssertNotEqual(queueNumericLabel("1023.9 KB/s")?.suffix, queueNumericLabel("1.0 MB/s")?.suffix)
        XCTAssertEqual(queueNumericLabel("42,3 MB/s"), .init(integer: "42", fraction: "3", separator: ",", suffix: " MB/s"))
        XCTAssertEqual(queueNumericLabel("٤٢٫٣ MB/s"), .init(integer: "٤٢", fraction: "٣", separator: "٫", suffix: " MB/s"))
        for text in ["", "—", "1.2.3 MB/s", "1. MB/s", "-1", "²", "𝟙"] { XCTAssertNil(queueNumericLabel(text), text) }
    }

    func testOnlyChangedPlaceRollsWithAndroid180160120Timings() throws {
        var state = QueueNumericValueMotion(text: "42.1 MB/s", value: 421, heightPixels: 60)
        state.update(text: "42.3 MB/s", value: 423)
        state.advance(0)
        let initial = try group(state, " MB/s")
        for place in [1, 0, Int.min] {
            let slot = try XCTUnwrap(initial.digits[place])
            XCTAssertEqual(slot.layers.count, 1); XCTAssertFalse(slot.isRunning)
            XCTAssertEqual(slot.layers[0].motion.displayedOffsetPixels, 0); XCTAssertEqual(slot.layers[0].motion.fade.alpha.value, 1)
        }
        XCTAssertEqual(initial.digits[-1]?.layers.map(\.key), ["1", "3"])
        XCTAssertEqual(initial.digits[-1]?.layers.last?.motion.displayedOffsetPixels, -30)
        state.advance(90_000_000)
        let at90 = try XCTUnwrap(group(state, " MB/s").digits[-1])
        XCTAssertEqual(at90.layers.last!.motion.offset.value, -6.733161, accuracy: 0.0001)
        XCTAssertEqual(at90.layers.last!.motion.displayedOffsetPixels, -7)
        state.advance(120_000_000)
        let old = try XCTUnwrap(group(state, " MB/s").digits[-1]?.layers.first)
        XCTAssertEqual(old.motion.fade.alpha.value, 0); XCTAssertTrue(old.motion.offset.isRunning)
        XCTAssertFalse(old.motion.exitFinished)
        state.advance(160_000_000)
        XCTAssertEqual(try group(state, " MB/s").digits[-1]?.layers.last?.motion.fade.alpha.value, 1)
        state.advance(180_000_000)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(try group(state, " MB/s").digits[-1]?.layers.map(\.key), ["3"])
    }

    func testSameFormattedLabelDoesNotChangeDirectionBaselineOrRestartMotion() throws {
        var state = QueueNumericValueMotion(text: "9.8 MB/s", value: 9800, heightPixels: 40)
        state.update(text: "9.9 MB/s", value: 9900); state.advance(0); state.advance(50_000_000)
        var unchanged = state
        state.update(text: "9.9 MB/s", value: 9999)
        XCTAssertEqual(state.target.value, 9900)
        state.advance(90_000_000); unchanged.advance(90_000_000)
        XCTAssertEqual(try group(state, " MB/s").digits[-1]?.layers.last?.motion.offset.value,
                       try group(unchanged, " MB/s").digits[-1]?.layers.last?.motion.offset.value)
        state.update(text: "9.9 MB/s", value: 9999, animate: false)
        XCTAssertFalse(state.isRunning); XCTAssertEqual(state.target.value, 9900)
    }

    func testLeadingAndFractionPlacesKeepIdentityAndDepartAtZeroTargetWidth() throws {
        var state = QueueNumericValueMotion(text: "9.2 MB/s", value: 92, heightPixels: 40)
        state.update(text: "109.2 MB/s", value: 1092); state.advance(0)
        let growing = try group(state, " MB/s")
        XCTAssertEqual(growing.places, [2, 1, 0, Int.min, -1])
        XCTAssertEqual(growing.digits[0]?.layers.map(\.key), ["9"])
        XCTAssertEqual(growing.digits[-1]?.layers.map(\.key), ["2"])
        state.advance(30_000_000); state.update(text: "9 MB/s", value: 90)
        let shrinking = try group(state, " MB/s")
        XCTAssertEqual(shrinking.places, [2, 1, 0, Int.min, -1])
        for place in [2, 1, Int.min, -1] { XCTAssertEqual(shrinking.digits[place]?.current, "") }
        state.advance(3_000_000_000)
        let settled = try group(state, " MB/s")
        XCTAssertEqual(settled.places, [0]); XCTAssertEqual(Set(settled.digits.keys), [0])
        XCTAssertFalse(state.isRunning)
    }

    func testInterrupted99To100To9ReusesDepartingDigitsWithoutJumping() throws {
        var state = QueueNumericValueMotion(text: "99", value: 99, heightPixels: 61)
        state.update(text: "100", value: 100); state.advance(0); state.advance(50_000_000)
        let previous = try XCTUnwrap(group(state, "").digits[0]?.layers.first { $0.key == "9" })
        state.update(text: "9", value: 9)
        let reused = try XCTUnwrap(group(state, "").digits[0]?.layers.first { $0.key == "9" })
        XCTAssertEqual(reused.motion.offset.value, previous.motion.displayedOffsetPixels)
        XCTAssertEqual(reused.motion.fade.alpha.value, previous.motion.fade.alpha.value)
        XCTAssertEqual(reused.motion.offset.velocity, previous.motion.offset.velocity)
        XCTAssertEqual(try group(state, "").digits[0]?.layers.map(\.key), ["9", "0"])
        state.advance(3_000_000_000)
        XCTAssertEqual(try group(state, "").places, [0])
        XCTAssertEqual(try group(state, "").digits[0]?.layers.map(\.key), ["9"])
        XCTAssertFalse(state.isRunning)
    }

    func testUnchangedInFlightDigitIsRetargetedWhenParentSnapshotChanges() throws {
        var state = QueueNumericValueMotion(text: "18", value: 18, heightPixels: 60)
        state.update(text: "19", value: 19); state.advance(0); state.advance(50_000_000)
        let before = try XCTUnwrap(group(state, "").digits[0]?.layers.last)
        state.update(text: "29", value: 29)
        let restarted = try XCTUnwrap(group(state, "").digits[0]?.layers.last)
        XCTAssertEqual(restarted.motion.offset.value, before.motion.displayedOffsetPixels)
        XCTAssertEqual(restarted.motion.offset.velocity, before.motion.offset.velocity)
        state.advance(70_000_000)
        let actual = try XCTUnwrap(group(state, "").digits[0]?.layers.last)
        let start = Double(before.motion.displayedOffsetPixels), velocity = Double(before.motion.offset.velocity)
        let r = sqrt(1500.0), time = 0.02
        let expected = (start + (velocity + r * start) * time) * exp(-r * time)
        XCTAssertEqual(Double(actual.motion.offset.value), expected, accuracy: 0.0001)
    }

    func testUnitChangeRetainsWholeOldLabelAndReversalReusesItsLayer() throws {
        var state = QueueNumericValueMotion(text: "1023.9 KB/s", value: 1_048_000, heightPixels: 40)
        state.update(text: "1.0 MB/s", value: 1_049_000); state.advance(0); state.advance(50_000_000)
        XCTAssertEqual(state.outer.layers.map(\.key), [" KB/s", " MB/s"])
        XCTAssertEqual(state.groups[" KB/s"]?.snapshot.text, "1023.9 KB/s")
        let old = state.outer.layers[0].motion
        state.update(text: "1023.8 KB/s", value: 1_047_000)
        XCTAssertEqual(state.outer.layers[0].motion.offset.value, old.displayedOffsetPixels)
        XCTAssertEqual(state.outer.layers[0].motion.fade.alpha.value, old.fade.alpha.value)
        XCTAssertEqual(state.outer.layers.map(\.key), [" KB/s", " MB/s"])
        state.advance(3_000_000_000)
        XCTAssertEqual(state.outer.layers.map(\.key), [" KB/s"])
        XCTAssertEqual(Set(state.groups.keys), [" KB/s"])
        XCTAssertFalse(state.isRunning)
    }

    func testFallbackAndSuffixIdentityCollisionNeverLoseTheNumericGroup() throws {
        var state = QueueNumericValueMotion(text: "—", value: 0, heightPixels: 40)
        state.update(text: "1.2.3", value: 123); state.advance(0)
        XCTAssertEqual(state.outer.layers.map(\.key), ["—", "1.2.3"])
        state.update(text: "", value: 0, animate: false)
        state.update(text: "12", value: 12); state.advance(0)
        XCTAssertEqual(state.outer.layers.map(\.key), [""])
        XCTAssertEqual(try group(state, "").places, [1, 0])
        XCTAssertEqual(try group(state, "").digits[1]?.current, "1")
    }

    func testNumericOrderingConversionSaturatesLikeAndroid() {
        XCTAssertEqual(queueNumericValue(.nan), 0); XCTAssertEqual(queueNumericValue(.infinity), .max)
        XCTAssertEqual(queueNumericValue(-.infinity), .min)
        XCTAssertEqual(queueNumericValue(123.99), 123); XCTAssertEqual(queueNumericValue(-123.99), -123)
    }
    private func group(_ state: QueueNumericValueMotion, _ key: String) throws -> QueueNumericValueMotion.Group {
        try XCTUnwrap(state.groups[key])
    }
}

@MainActor
final class QueueNumericValueClockTests: XCTestCase {
    func testChangesStartWithoutGeometryAndUseIntegerHalfLineHeight() throws {
        let clock = QueueNumericValueClock(text: "10", value: 10, height: 20)
        defer { clock.unmount() }
        clock.update(text: "9", value: 9)
        XCTAssertTrue(clock.motion.isRunning); XCTAssertTrue(clock.clockRunning)
        XCTAssertEqual(clock.motion.groups[""]?.digits[0]?.layers.map(\.key), ["0", "9"])
        XCTAssertEqual(clock.motion.groups[""]?.digits[0]?.layers.last?.motion.displayedOffsetPixels, 10)
        clock.advance(0); clock.advance(180_000_000)
        XCTAssertFalse(clock.clockRunning); XCTAssertFalse(clock.motion.isRunning)
        clock.measure(height: 20, scale: 3)
        clock.update(text: "12", value: 12)
        XCTAssertEqual(clock.motion.groups[""]?.digits[0]?.layers.last?.motion.displayedOffsetPixels, -30)
    }
    func testSameTextPublishesNothingAndUnmountOrHiddenInputStopsClock() {
        let clock = QueueNumericValueClock(text: "1.0 MB/s", value: 1000, height: 14)
        var publications = 0
        let observer = clock.objectWillChange.sink { publications += 1 }
        clock.update(text: "1.0 MB/s", value: 1001)
        XCTAssertEqual(publications, 0)
        clock.update(text: "1.1 MB/s", value: 1100); XCTAssertTrue(clock.clockRunning)
        clock.update(text: "1.1 MB/s", value: 1199, animate: false)
        XCTAssertFalse(clock.clockRunning); XCTAssertFalse(clock.motion.isRunning)
        XCTAssertEqual(clock.motion.target.value, 1100)
        clock.update(text: "1.2 MB/s", value: 1200); clock.unmount()
        XCTAssertFalse(clock.clockRunning); XCTAssertFalse(clock.motion.isRunning)
        clock.update(text: "2.0 MB/s", value: 2000)
        XCTAssertFalse(clock.clockRunning); XCTAssertEqual(clock.motion.target.text, "2.0 MB/s")
        observer.cancel()
    }
    func testRemountUsesLatestValueAndDoesNotReplayHiddenChanges() {
        let clock = QueueNumericValueClock(text: "100", value: 100, height: 20)
        clock.measure(height: 20, scale: 3); clock.update(text: "99", value: 99); clock.unmount()
        clock.update(text: "8", value: 8); clock.mount(text: "8", value: 8, height: 20, scale: 2)
        XCTAssertFalse(clock.motion.isRunning); XCTAssertEqual(clock.motion.groups[""]?.digits[0]?.layers.map(\.key), ["8"])
        clock.update(text: "7", value: 7)
        XCTAssertEqual(clock.motion.groups[""]?.digits[0]?.layers.last?.motion.displayedOffsetPixels, 20)
        clock.unmount()
        weak var released: QueueNumericValueClock?
        do {
            let transient = QueueNumericValueClock(text: "9", value: 9, height: 20)
            released = transient; transient.update(text: "8", value: 8)
        }
        XCTAssertNil(released)
    }
}
