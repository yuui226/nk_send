import XCTest
@testable import ZTransfer

@MainActor
final class HapticsTests: XCTestCase {
    func testPreferenceGatesActionsButThePreferenceToggleStillTicks() {
        let defaults = UserDefaults(suiteName: "ztransfer-haptics-test-gate")!
        defaults.removePersistentDomain(forName: "ztransfer-haptics-test-gate")
        var events: [HapticFeedbackEvent] = []
        let haptics = ZTransferHaptics(defaults: defaults) { events.append($0) }

        haptics.tick()
        haptics.longPress()
        haptics.success()
        haptics.failure()
        XCTAssertEqual(events, [.tick, .longPress, .success, .failure])

        events.removeAll()
        defaults.set(false, forKey: HapticPreference.key)
        haptics.tick()
        haptics.longPress()
        haptics.success()
        haptics.failure()
        XCTAssertTrue(events.isEmpty)
        haptics.tick(isPreferenceToggle: true)
        XCTAssertEqual(events, [.tick])
    }

    func testProgressiveHoldHasStartCancelAndCompletionWithoutDuplicateEvents() {
        let defaults = UserDefaults(suiteName: "ztransfer-haptics-test-hold")!
        defaults.removePersistentDomain(forName: "ztransfer-haptics-test-hold")
        var events: [HapticFeedbackEvent] = []
        let haptics = ZTransferHaptics(defaults: defaults) { events.append($0) }

        haptics.startProgressiveHold()
        haptics.cancelProgressiveHold()
        haptics.cancelProgressiveHold()
        haptics.startProgressiveHold()
        haptics.completeProgressiveHold()
        haptics.completeProgressiveHold()

        XCTAssertEqual(events, [.holdStarted, .holdCancelled, .holdStarted, .holdCompleted])
    }

    func testProgressivePulseStartsAndSilenceMatchAndroid() {
        XCTAssertEqual(ProgressiveHoldHapticPattern.durationMilliseconds, 800)
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses.count, 10)
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses.first?.startMilliseconds, 0)
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses.last?.startMilliseconds, 725)
        XCTAssertEqual(
            ProgressiveHoldHapticPattern.pulses.last.map { $0.startMilliseconds + $0.durationMilliseconds },
            737
        )
        XCTAssertEqual(
            ProgressiveHoldHapticPattern.durationMilliseconds -
                (ProgressiveHoldHapticPattern.pulses.last!.startMilliseconds +
                 ProgressiveHoldHapticPattern.pulses.last!.durationMilliseconds),
            63
        )
    }
}
