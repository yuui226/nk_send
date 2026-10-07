import XCTest
@testable import ZTransfer

/// Mirrors RemoteEntryIntroPolicyTest.kt and the persisted V2 campaign contract.
final class RemoteEntryIntroPolicyTests: XCTestCase {
    @MainActor
    func testRemoteEntryOpacityUsesFinalAndroidTokensRatherThanStaleComment() {
        XCTAssertEqual(ZTransferFrostedButtonSurface.baseAlpha(dark: true, boost: 0.35), 0.48, accuracy: 0.000001)
        XCTAssertEqual(ZTransferFrostedButtonSurface.baseAlpha(dark: false, boost: 0.35), 0.753, accuracy: 0.000001)
        XCTAssertEqual(ZTransferFrostedButtonSurface.baseAlpha(dark: true, boost: -1), 0.20)
        XCTAssertEqual(ZTransferFrostedButtonSurface.baseAlpha(dark: false, boost: 2), 1)
    }

    func testClickPermanentlyOverridesEveryRemainingReminder() {
        for count in [-1, 0, 1, 19, 20, 100] {
            XCTAssertFalse(isRemoteEntryIntroEligible(playCount: count, entryUsed: true))
            XCTAssertEqual(RemoteEntryIntroPolicy.recordedPlayCount(count, entryUsed: true), count)
        }
        XCTAssertTrue(isRemoteEntryIntroEligible(playCount: 19, entryUsed: false))
        XCTAssertFalse(isRemoteEntryIntroEligible(playCount: 20, entryUsed: false))
    }

    func testReminderStopsAfterTwentyActualStarts() {
        for count in [-1, 0, 19] {
            XCTAssertTrue(isRemoteEntryIntroEligible(playCount: count))
        }
        for count in [20, 21, Int.max] {
            XCTAssertFalse(isRemoteEntryIntroEligible(playCount: count))
            XCTAssertEqual(RemoteEntryIntroPolicy.recordedPlayCount(count, entryUsed: false), count)
        }
        XCTAssertEqual(RemoteEntryIntroPolicy.recordedPlayCount(-1, entryUsed: false), 1)
        XCTAssertEqual(RemoteEntryIntroPolicy.recordedPlayCount(19, entryUsed: false), 20)
    }

    func testCampaignUsesFreshV2KeysAndAndroidDelays() {
        XCTAssertEqual(RemoteEntryIntroPolicy.playCountKey, "remote_entry_intro_v2_play_count")
        XCTAssertEqual(RemoteEntryIntroPolicy.usedKey, "remote_entry_intro_v2_used")
        XCTAssertEqual(RemoteEntryIntroPolicy.delayNanoseconds, 800_000_000)
        XCTAssertEqual(RemoteEntryIntroPolicy.holdNanoseconds, 4_000_000_000)
    }

    func testRevealEndpointsAndMidpointFollowAndroidArc() {
        let hidden = RemoteEntryRevealValues(progress: 0)
        XCTAssertEqual(hidden.x, -48)
        XCTAssertEqual(hidden.y, 0)
        XCTAssertEqual(hidden.scale, 0.88)
        XCTAssertEqual(hidden.rotation, -3.5)
        let middle = RemoteEntryRevealValues(progress: 0.5)
        XCTAssertEqual(middle.x, -24)
        XCTAssertEqual(middle.y, -6)
        XCTAssertEqual(middle.scale, 0.94, accuracy: 0.000001)
        XCTAssertEqual(middle.rotation, -0.5)
        let shown = RemoteEntryRevealValues(progress: 1)
        XCTAssertEqual(shown.x, 0)
        XCTAssertEqual(shown.y, 0, accuracy: 0.000001)
        XCTAssertEqual(shown.scale, 1)
        XCTAssertEqual(shown.rotation, 0, accuracy: 0.000001)
    }

    func testSpringOvershootIsBoundedWhileArcStaysAtItsEndpoint() {
        let low = RemoteEntryRevealValues(progress: -100)
        XCTAssertEqual(low.x, -53.76, accuracy: 0.000001)
        XCTAssertEqual(low.scale, 0.8656, accuracy: 0.000001)
        XCTAssertEqual(low.rotation, -3.5)
        let high = RemoteEntryRevealValues(progress: 100)
        XCTAssertEqual(high.x, 5.76, accuracy: 0.000001)
        XCTAssertEqual(high.scale, 1.0144, accuracy: 0.000001)
        XCTAssertEqual(high.rotation, 0, accuracy: 0.000001)
    }
}
