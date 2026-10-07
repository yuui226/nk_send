import XCTest
@testable import ZTransfer

@MainActor
final class RemoteEntryIntroLifecycleTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "RemoteEntryIntroLifecycleTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        try await body(preferences)
    }

    func testClickDuringInitialDelayCancelsCurrentAndFutureEntries() async {
        await withPreferences { preferences in
            let controller = RemoteEntryIntroController(preferences: preferences)
            var waits = [UInt64]()
            await controller.run(sleep: { duration in
                waits.append(duration)
                controller.markUsed()
            })
            XCTAssertEqual(waits, [800_000_000])
            XCTAssertFalse(controller.expanded)
            XCTAssertFalse(controller.handledForEntry)
            XCTAssertEqual(preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), 0)
            let restored = RemoteEntryIntroController(preferences: preferences)
            await restored.run(sleep: { _ in XCTFail("A used entry must never schedule another reminder") })
        }
    }

    func testCountOccursAtExpansionAndOnlyOnceForThisEntry() async {
        await withPreferences { preferences in
            preferences.set(19, forKey: RemoteEntryIntroPolicy.playCountKey)
            let controller = RemoteEntryIntroController(preferences: preferences)
            var waits = [UInt64]()
            await controller.run(sleep: { duration in
                waits.append(duration)
                if duration == 800_000_000 {
                    XCTAssertFalse(controller.expanded)
                    XCTAssertEqual(preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), 19)
                } else {
                    XCTAssertEqual(duration, 4_000_000_000)
                    XCTAssertTrue(controller.expanded)
                    XCTAssertEqual(preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), 20)
                }
            })
            XCTAssertEqual(waits, [800_000_000, 4_000_000_000])
            XCTAssertFalse(controller.expanded)
            await controller.run(sleep: { _ in XCTFail("Returning to the same entry cannot replay") })
            let restored = RemoteEntryIntroController(preferences: preferences)
            await restored.run(sleep: { _ in XCTFail("The twentieth reminder exhausts the campaign") })
        }
    }

    func testCancellationBeforeExpansionDoesNotCountOrConsumeEntry() async {
        await withPreferences { preferences in
            let controller = RemoteEntryIntroController(preferences: preferences)
            await controller.run(sleep: { _ in throw CancellationError() })
            XCTAssertFalse(controller.handledForEntry)
            XCTAssertFalse(controller.expanded)
            XCTAssertEqual(preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), 0)
            await controller.run(sleep: { _ in })
            XCTAssertTrue(controller.handledForEntry)
            XCTAssertEqual(preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), 1)
        }
    }

    func testDisappearanceDuringHoldClearsExpansionWithoutReplaying() async {
        await withPreferences { preferences in
            let controller = RemoteEntryIntroController(preferences: preferences)
            await controller.run(sleep: { duration in
                if duration == 4_000_000_000 {
                    XCTAssertTrue(controller.expanded)
                    throw CancellationError()
                }
            })
            XCTAssertFalse(controller.expanded)
            XCTAssertTrue(controller.handledForEntry)
            XCTAssertEqual(preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), 1)
            await controller.run(sleep: { _ in XCTFail("Returning cannot leave or reopen the reminder") })
        }
    }

    func testScrollingCollapsesOnlyCurrentReminderAndClickEndsCampaign() async {
        await withPreferences { preferences in
            let controller = RemoteEntryIntroController(preferences: preferences)
            await controller.run(sleep: { duration in
                if duration == 4_000_000_000 {
                    controller.collapse()
                    XCTAssertFalse(controller.expanded)
                    XCTAssertFalse(preferences.bool(forKey: RemoteEntryIntroPolicy.usedKey))
                }
            })
            let next = RemoteEntryIntroController(preferences: preferences)
            await next.run(sleep: { duration in
                if duration == 4_000_000_000 {
                    XCTAssertTrue(next.expanded)
                    next.markUsed()
                    XCTAssertFalse(next.expanded)
                }
            })
            XCTAssertEqual(preferences.integer(forKey: RemoteEntryIntroPolicy.playCountKey), 2)
            XCTAssertTrue(preferences.bool(forKey: RemoteEntryIntroPolicy.usedKey))
        }
    }
}
