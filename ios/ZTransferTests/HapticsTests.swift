import XCTest
import CoreHaptics
import UIKit
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
        second.trigger { actions += 1; firstHaptics.play(.selection); secondHaptics.play(.preview) }
        second.trigger { XCTFail("Completed hold cannot trigger twice") }
        second.end()
        XCTAssertEqual(secondEvents, [.holdStarted, .holdCompleted])
        first.end()
        firstHaptics.play(.selection)
        XCTAssertEqual(firstEvents.last, .feedback(.selection), "Next independent tap is not suppressed")
        defaults.set(false, forKey: HapticPreference.key)
        first.begin(durationMilliseconds: 450)
        first.trigger { actions += 1 }
        first.end()
        XCTAssertEqual(firstEvents, [.holdStarted, .holdCancelled, .feedback(.selection)])
        XCTAssertEqual(actions, 2, "Disabling haptics must not disable the action")
    }

    func testPreferenceGatesEverySemanticButOnlyItsOwnToggleCanConfirmWhileOff() {
        let defaults = UserDefaults(suiteName: "ztransfer-haptics-test-gate")!
        defaults.removePersistentDomain(forName: "ztransfer-haptics-test-gate")
        var events: [HapticFeedbackEvent] = []
        let haptics = ZTransferHaptics(defaults: defaults) { events.append($0) }

        for feedback in HapticFeedback.allCases { haptics.play(feedback) }
        XCTAssertEqual(events, HapticFeedback.allCases.map(HapticFeedbackEvent.feedback))

        events.removeAll()
        defaults.set(false, forKey: HapticPreference.key)
        for feedback in HapticFeedback.allCases { haptics.play(feedback) }
        haptics.play(.enqueue, isPreferenceToggle: true)
        XCTAssertTrue(events.isEmpty)
        haptics.play(.toggle, isPreferenceToggle: true)
        XCTAssertEqual(events, [.feedback(.toggle)])
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

    func testNativeHoldIsBoundedProgressiveAndLeavesRoomForConfirmation() {
        for duration in [1, 200, 250, 300, 450, 500, 800, 1500] {
            let pulses = ProgressiveHoldHapticPattern.pulses(durationMilliseconds: duration)
            XCTAssertTrue((2...8).contains(pulses.count))
            XCTAssertEqual(pulses.first?.time, 0)
            for (previous, next) in zip(pulses, pulses.dropFirst()) {
                XCTAssertGreaterThan(next.time, previous.time)
                XCTAssertGreaterThan(next.intensity, previous.intensity)
                XCTAssertGreaterThan(next.sharpness, previous.sharpness)
            }
            XCTAssertLessThanOrEqual(pulses.last!.time, Double(duration) / 1_000 * 0.86 + 0.000001)
            XCTAssertTrue(pulses.allSatisfy { (0...1).contains($0.intensity) && (0...1).contains($0.sharpness) })
        }
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses(durationMilliseconds: 250).count, 3)
        XCTAssertEqual(ProgressiveHoldHapticPattern.pulses(durationMilliseconds: 800).count, 8)
    }

    func testLongPressConfirmationSuppressesSynchronousCallbacksAcrossInstancesOnly() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var events: [HapticFeedbackEvent] = []
        let source = ZTransferHaptics(defaults: defaults) { events.append($0) }
        let action = ZTransferHaptics(defaults: defaults) { events.append($0) }
        source.startProgressiveHold(durationMilliseconds: 300)
        source.completeLongPress {
            action.play(.selection); action.play(.preview)
            action.completeLongPress { source.play(.selection) }
            action.play(.selection); action.play(.connectionReady); action.play(.failure)
        }
        action.play(.selection) // later AF result is not suppressed
        XCTAssertEqual(events, [.holdStarted, .holdCompleted, .feedback(.connectionReady), .feedback(.failure), .feedback(.selection)])
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

    func testSharedRendererRejectsOldControlCancellationAndLateCompletion() {
        var played: [HapticFeedback] = []
        let renderer = NativeHapticRenderer(supportsHaptics: false, isActive: { true }, systemOutput: { played.append($0) })
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = ZTransferHaptics(defaults: defaults, renderer: renderer)
        let second = ZTransferHaptics(defaults: defaults, renderer: renderer)
        first.startProgressiveHold(durationMilliseconds: 800)
        let oldOwner = renderer.holdOwner
        second.startProgressiveHold(durationMilliseconds: 300)
        let currentOwner = renderer.holdOwner
        XCTAssertNotEqual(oldOwner, currentOwner)
        first.completeProgressiveHold()
        first.cancelProgressiveHold()
        XCTAssertEqual(renderer.holdOwner, currentOwner)
        XCTAssertFalse(played.contains(.holdConfirmed))
        second.completeProgressiveHold()
        second.completeProgressiveHold()
        XCTAssertNil(renderer.holdOwner)
        XCTAssertEqual(played.filter { $0 == .holdConfirmed }.count, 1)
    }

    func testBackgroundDropsHoldAndNeverReplaysOnForeground() {
        var active = true
        var played: [HapticFeedback] = []
        let renderer = NativeHapticRenderer(supportsHaptics: false, isActive: { active }, systemOutput: { played.append($0) })
        let haptics = ZTransferHaptics(defaults: UserDefaults(suiteName: UUID().uuidString)!, renderer: renderer)
        haptics.startProgressiveHold()
        active = false
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(renderer.holdOwner)
        let count = played.count
        haptics.completeLongPress { haptics.play(.enqueue) }
        haptics.play(.transferComplete)
        haptics.startProgressiveHold()
        XCTAssertEqual(played.count, count)
        XCTAssertNil(renderer.holdOwner)
        active = true
        haptics.completeProgressiveHold()
        XCTAssertEqual(played.count, count, "A cancelled/background hold must not confirm after returning")
        haptics.play(.enqueue)
        XCTAssertEqual(played.last, .enqueue)
    }

    func testPreferenceNotificationImmediatelyStopsCurrentOwnerIncludingBackgroundWriters() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let renderer = NativeHapticRenderer(supportsHaptics: false, isActive: { true }, systemOutput: { _ in })
        let haptics = ZTransferHaptics(defaults: defaults, renderer: renderer)
        haptics.startProgressiveHold()
        defaults.set(false, forKey: HapticPreference.key)
        await Task.detached {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }.value
        await Task.yield()
        XCTAssertNil(renderer.holdOwner)
        defaults.set(true, forKey: HapticPreference.key)
        XCTAssertNil(renderer.holdOwner, "Turning the switch back on cannot replay an interrupted gesture")
    }

    func testResultPatternsAreDistinctShortAndAcceptedByCoreHaptics() throws {
        var patterns: [[HapticPulse]] = []
        for feedback in [HapticFeedback.connectionReady, .transferComplete] {
            guard case let .success(pulses) = feedback.rendering else { return XCTFail("Expected a result pattern") }
            XCTAssertLessThanOrEqual(pulses.count, 3)
            XCTAssertLessThanOrEqual(pulses.last!.time, 0.2)
            patterns.append(pulses)
        }
        XCTAssertNotEqual(patterns[0], patterns[1])
        patterns += [250, 300, 450, 500, 800].map { ProgressiveHoldHapticPattern.pulses(durationMilliseconds: $0) }
        for pulses in patterns {
            let native = try CHHapticPattern(events: pulses.map {
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    .init(parameterID: .hapticIntensity, value: $0.intensity),
                    .init(parameterID: .hapticSharpness, value: $0.sharpness),
                ], relativeTime: $0.time)
            }, parameters: [])
            XCTAssertLessThan(native.duration, 1)
        }
        XCTAssertNotEqual(HapticFeedback.selection.rendering, HapticFeedback.enqueue.rendering)
        XCTAssertNotEqual(HapticFeedback.focusStarted.rendering, HapticFeedback.focusLocked.rendering)
        XCTAssertNotEqual(HapticFeedback.focusLocked.rendering, HapticFeedback.shutter.rendering)
    }

}
