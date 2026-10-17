import XCTest
@testable import ZTransfer

@MainActor
final class HapticsTests: XCTestCase {
    func testControlOwnedLongPressCompletesCancelsAndDoesNotSuppressNextAction() {
        let suite = "long-press-owner-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var firstEvents: [HapticFeedbackEvent] = [], secondEvents: [HapticFeedbackEvent] = []
        let firstHaptics = ZTransferHaptics(defaults: defaults) { firstEvents.append($0) }
        let secondHaptics = ZTransferHaptics(defaults: defaults) { secondEvents.append($0) }
        let first = ZTransferLongPressFeedback(haptics: firstHaptics)
        let second = ZTransferLongPressFeedback(haptics: secondHaptics)
        first.begin(durationMilliseconds: 450)
        first.begin(durationMilliseconds: 450)
        second.begin(durationMilliseconds: 450)
        first.cancel()
        first.begin(durationMilliseconds: 450)
        first.trigger { XCTFail("Cancelled hold cannot trigger") }
        XCTAssertEqual(firstEvents, [.holdStarted, .holdCancelled])
        XCTAssertEqual(secondEvents, [.holdStarted])
        var actions = 0
        second.trigger { actions += 1; firstHaptics.tick(); secondHaptics.longPress() }
        second.trigger { XCTFail("Completed hold cannot trigger twice") }
        second.end()
        XCTAssertEqual(secondEvents, [.holdStarted, .holdCompleted])
        first.end()
        firstHaptics.tick()
        XCTAssertEqual(firstEvents.last, .tick, "Next independent tap is not suppressed")
        defaults.set(false, forKey: HapticPreference.key)
        first.begin(durationMilliseconds: 450)
        first.trigger { actions += 1 }
        first.end()
        XCTAssertEqual(firstEvents, [.holdStarted, .holdCancelled, .tick])
        XCTAssertEqual(actions, 2, "Disabling haptics must not disable the action")
    }

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
    func testAndroidScaledDurationsKeepAllPulsesAndFinalQuietGap() {
        for duration in [300, 400, 500, 800, 1000, 1500] {
            let pulses = ProgressiveHoldHapticPattern.pulses(durationMilliseconds: duration)
            XCTAssertEqual(pulses.count, 10)
            XCTAssertEqual(pulses.first?.startMilliseconds, 0)
            XCTAssertTrue(pulses.allSatisfy { $0.durationMilliseconds > 0 })
            for (previous, next) in zip(pulses, pulses.dropFirst()) {
                XCTAssertGreaterThan(next.startMilliseconds, previous.startMilliseconds + previous.durationMilliseconds)
            }
            let last = pulses.last!
            XCTAssertGreaterThanOrEqual(Double(duration - last.startMilliseconds - last.durationMilliseconds), Double(duration) * 0.07)
        }
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses(durationMilliseconds: 800), ProgressiveHoldHapticPattern.pulses)
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses(durationMilliseconds: 300).map(\.startMilliseconds),
                       [0, 45, 86, 123, 157, 187, 213, 236, 255, 271])
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses(durationMilliseconds: 300).map(\.durationMilliseconds),
                       [3, 3, 3, 4, 4, 4, 4, 4, 4, 5])
    }

    func testLongPressConfirmationSuppressesSynchronousCallbacksAcrossInstancesOnly() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var events: [HapticFeedbackEvent] = []
        let source = ZTransferHaptics(defaults: defaults) { events.append($0) }
        let action = ZTransferHaptics(defaults: defaults) { events.append($0) }
        source.startProgressiveHold(durationMilliseconds: 300)
        source.completeLongPress {
            action.tick(); action.longPress()
            action.completeLongPress { source.tick() }
            action.tick(); action.success(); action.failure()
        }
        action.tick() // later AF result is not suppressed
        XCTAssertEqual(events, [.holdStarted, .holdCompleted, .success, .failure, .tick])
    }

    func testDisablingHapticsDuringHoldCancelsMotorButStillPerformsAction() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var events: [HapticFeedbackEvent] = []
        let haptics = ZTransferHaptics(defaults: defaults) { events.append($0) }
        haptics.startProgressiveHold(durationMilliseconds: 300)
        defaults.set(false, forKey: HapticPreference.key)
        var performed = false
        haptics.completeLongPress { performed = true }
        XCTAssertTrue(performed)
        XCTAssertEqual(events, [.holdStarted, .holdCancelled])
    }

}
