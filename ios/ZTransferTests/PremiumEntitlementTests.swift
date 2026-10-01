import XCTest
@testable import ZTransfer

final class PremiumEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRefundedLifetimeFallsBackToValidAnnual() {
        let annual = PremiumGrant(product: .annual, transactionID: 10, expiration: now.addingTimeInterval(60))
        var lifetime = PremiumGrant(product: .lifetime, transactionID: 11)
        XCTAssertEqual(PremiumGrant.resolve([annual, lifetime], at: now), .lifetime)
        lifetime.revoked = true
        XCTAssertEqual(PremiumGrant.resolve([annual, lifetime], at: now),
                       .annual(until: now.addingTimeInterval(60), gracePeriod: false))
        XCTAssertEqual(PremiumGrant.resolve([annual, lifetime], at: now.addingTimeInterval(60)), .free)
    }

    func testGraceUsesVerifiedDeadlineInsteadOfExpiredTransactionDate() {
        let grant = PremiumGrant(product: .annual, transactionID: 1,
            expiration: now.addingTimeInterval(-60), graceDeadline: now.addingTimeInterval(120))
        XCTAssertEqual(PremiumGrant.resolve([grant], at: now),
                       .annual(until: now.addingTimeInterval(120), gracePeriod: true))
        XCTAssertEqual(PremiumGrant.resolve([grant], at: now.addingTimeInterval(120)), .free)
    }

    func testRevocationAndUpgradedHistoryCannotGrantAccess() {
        let revoked = PremiumGrant(product: .lifetime, transactionID: 1, revoked: true)
        let upgraded = PremiumGrant(product: .annual, transactionID: 2,
            expiration: now.addingTimeInterval(60), upgraded: true)
        XCTAssertEqual(PremiumGrant.resolve([revoked, upgraded], at: now), .free)
        XCTAssertFalse(PremiumEntitlement.unresolved.isPro(at: now))
    }

    func testReplayOrderingUsesPurchaseDateAndAcceptsSameTransactionRefund() {
        let renewed = PremiumGrant(product: .annual, transactionID: 4,
            purchaseDate: now, expiration: now.addingTimeInterval(60))
        let historical = PremiumGrant(product: .annual, transactionID: 900,
            purchaseDate: now.addingTimeInterval(-60), revoked: true)
        XCTAssertFalse(historical.mayReplace(renewed))
        XCTAssertTrue(renewed.mayReplace(historical))
        var refund = renewed
        refund.revoked = true
        XCTAssertTrue(refund.mayReplace(renewed))
        XCTAssertEqual(PremiumGrant.resolve([refund], at: now), .free)
    }

    func testPremiumAccessRechecksTimeEvenBeforeExpiryRefreshFinishes() {
        let source = PremiumAccess(.annual(until: .distantPast, gracePeriod: false))
        XCTAssertFalse(source.isPro)
        source.replace(with: .lifetime)
        XCTAssertTrue(source.isPro)
        source.replace(with: .free)
        XCTAssertFalse(source.isPro)
    }

    func testOlderSameTransactionCannotUndoRefundButNewVerifiedReversalCan() {
        let purchase = PremiumGrant(product: .lifetime, transactionID: 7,
                                    purchaseDate: now, signedDate: now)
        var refund = purchase
        refund.revoked = true
        refund.signedDate = now.addingTimeInterval(10)
        XCTAssertTrue(refund.mayReplace(purchase))
        XCTAssertFalse(purchase.mayReplace(refund))
        var replay = purchase
        replay.signedDate = refund.signedDate
        XCTAssertFalse(replay.mayReplace(refund))
        var reversal = purchase
        reversal.signedDate = now.addingTimeInterval(20)
        XCTAssertTrue(reversal.mayReplace(refund))
    }

    func testStaleSnapshotCannotUndoVerifiedLifetimeRefund() {
        let purchase = PremiumGrant(product: .lifetime, transactionID: 7,
                                    purchaseDate: now, signedDate: now)
        var refund = purchase
        refund.revoked = true
        refund.signedDate = now.addingTimeInterval(10)
        let annual = PremiumGrant(product: .annual, transactionID: 8,
                                  expiration: now.addingTimeInterval(60))
        for replayDate in [purchase.signedDate, refund.signedDate] {
            var replay = purchase
            replay.signedDate = replayDate
            let merged = PremiumGrant.reconcilingSnapshot([.annual: annual, .lifetime: replay],
                                                         previous: [.lifetime: refund])
            XCTAssertEqual(PremiumGrant.resolve(Array(merged.values), at: now),
                           .annual(until: now.addingTimeInterval(60), gracePeriod: false))
        }
    }

    func testSnapshotAcceptsNewerVerifiedRefundAndReversal() {
        let purchase = PremiumGrant(product: .lifetime, transactionID: 7,
                                    purchaseDate: now, signedDate: now)
        var refund = purchase
        refund.revoked = true
        refund.signedDate = now.addingTimeInterval(10)
        let refunded = PremiumGrant.reconcilingSnapshot([.lifetime: refund], previous: [.lifetime: purchase])
        XCTAssertEqual(PremiumGrant.resolve(Array(refunded.values), at: now), .free)
        var reversal = purchase
        reversal.signedDate = now.addingTimeInterval(20)
        let reversed = PremiumGrant.reconcilingSnapshot([.lifetime: reversal], previous: refunded)
        XCTAssertEqual(PremiumGrant.resolve(Array(reversed.values), at: now), .lifetime)
    }

    func testSnapshotAbsenceAndDifferentTransactionDoNotRetainPreviousAccountAccess() {
        let lifetime = PremiumGrant(product: .lifetime, transactionID: 7,
                                    purchaseDate: now, signedDate: now)
        let empty = PremiumGrant.reconcilingSnapshot([:], previous: [.lifetime: lifetime])
        XCTAssertEqual(PremiumGrant.resolve(Array(empty.values), at: now), .free)
        let expiredAnnual = PremiumGrant(product: .annual, transactionID: 1,
            purchaseDate: now.addingTimeInterval(-100), signedDate: now.addingTimeInterval(-90),
            expiration: now.addingTimeInterval(-60))
        let activeAnnual = PremiumGrant(product: .annual, transactionID: 2,
            purchaseDate: now, signedDate: now, expiration: now.addingTimeInterval(60))
        let changed = PremiumGrant.reconcilingSnapshot([.annual: expiredAnnual],
            previous: [.annual: activeAnnual, .lifetime: lifetime])
        XCTAssertEqual(PremiumGrant.resolve(Array(changed.values), at: now), .free)
        XCTAssertEqual(changed[.annual]?.transactionID, 1)
        XCTAssertNil(changed[.lifetime])
    }

    func testSuccessLedgerIsIdempotentAndWarnsOnlyAtFiveAndOne() {
        withLedger { ledger, _ in
            var warnings: [Int] = []
            for _ in 0..<25 {
                let id = UUID()
                if let threshold = ledger.recordTransfer(id: id, isPro: false, at: now) { warnings.append(threshold) }
                XCTAssertNil(ledger.recordTransfer(id: id, isPro: false, at: now))
            }
            XCTAssertEqual(ledger.snapshot(at: now).transfers, 25)
            XCTAssertEqual(warnings, [5, 1])
            ledger.recordTransfer(id: UUID(), isPro: true, at: now)
            XCTAssertEqual(ledger.snapshot(at: now).transfers, 25)
        }
    }

    func testIndependentLedgersSurviveRecreationAndResetByLocalDay() {
        withLedger { ledger, defaults in
            ledger.recordTransfer(id: UUID(), isPro: false, at: now)
            ledger.consumeMonitoring(12.5, isPro: false, at: now)
            ledger.consumeMonitoring(40, isPro: true, at: now)
            let restored = FreeUsageStore(defaults: defaults, calendar: calendar)
            XCTAssertEqual(restored.snapshot(at: now).transfersLeft, 24)
            XCTAssertEqual(restored.snapshot(at: now).monitoringLeft, 167.5)
            let nextDay = now.addingTimeInterval(86_400)
            XCTAssertEqual(restored.snapshot(at: nextDay).transfersLeft, 25)
            XCTAssertEqual(restored.snapshot(at: nextDay).monitoringLeft, 180)
        }
    }

    func testInvalidMonitoringDeltasDoNotCorruptOrExtendTrial() {
        withLedger { ledger, _ in
            for value in [Double.nan, Double.infinity, -4, 0] {
                ledger.consumeMonitoring(value, isPro: false, at: now)
            }
            XCTAssertEqual(ledger.snapshot(at: now).monitoringLeft, 180)
            ledger.consumeMonitoring(200, isPro: false, at: now)
            XCTAssertEqual(ledger.snapshot(at: now).monitoringLeft, 0)
        }
    }

    func testFreeWatermarkIsBrandedWithoutOverwritingSavedCustomization() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = true
        settings.watermark = PhotoFrameWatermark(enabled: false, text: "My photo", sizePercent: 200,
                                                 opacityPercent: 35)
        let snapshot = effectivePhotoEffectsSettings(settings, isPro: false)
        XCTAssertEqual(snapshot.watermark, PhotoFrameWatermark(opacityPercent: 80))
        XCTAssertFalse(settings.watermark.enabled)
        XCTAssertEqual(settings.watermark.text, "My photo")
        XCTAssertEqual(effectivePhotoEffectsSettings(settings, isPro: true).watermark, settings.watermark)
        settings.watermark.text = "A later edit"
        XCTAssertEqual(snapshot.watermark.text, "ZTransfer")
    }

    func testDecorationOffDoesNotAddBrandingAndImagePositionsNormalizeWithoutChangingPreference() {
        var settings = PhotoEffectsSettings()
        settings.photoFrameEnabled = false
        XCTAssertFalse(effectivePhotoEffectsSettings(settings, isPro: false).watermark.enabled)
        settings.photoFrameEnabled = true
        settings.photoFrameBorderEnabled = false
        XCTAssertEqual(effectivePhotoEffectsSettings(settings, isPro: false).watermark.position, .photoBottomCenter)
        let image = PhotoFrameWatermark(content: .image, imageHash: String(repeating: "A", count: 64), position: .left)
        let effective = effectivePhotoFrameWatermark(isPro: true, preference: image)
        XCTAssertEqual(effective.position, .photoBottomCenter)
        XCTAssertEqual(effective.imageHash, String(repeating: "a", count: 64))
        XCTAssertEqual(image.position, .left)
        let invalid = PhotoFrameWatermark(content: .image, imageHash: "bad", position: .left)
        let fallback = effectivePhotoFrameWatermark(isPro: true, preference: invalid)
        XCTAssertEqual(fallback.content, .text)
        XCTAssertEqual(fallback.position, .left)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }

    private func withLedger(_ body: (FreeUsageStore, UserDefaults) -> Void) {
        let name = "PremiumEntitlementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(FreeUsageStore(defaults: defaults, calendar: calendar), defaults)
    }
}
