import StoreKit
import StoreKitTest
import Combine
import XCTest
@testable import ZTransfer

/// Real StoreKit 2 transactions in Apple's LOCAL test environment, not mocked
/// isPro flags. This suite deliberately does not claim App Store sandbox coverage.
@MainActor
final class StoreKitPurchaseTests: XCTestCase {
    @MainActor private struct Fixture {
        let session: SKTestSession
        let store: StoreKitPurchaseStore
        let entitlements: PremiumEntitlementStore
        func billingDiagnostic() -> String {
            let transactions = session.allTransactions().map {
                "id=\($0.identifier), product=\($0.productIdentifier), state=\($0.state.rawValue), issue=\($0.hasPurchaseIssue), date=\($0.purchaseDate)"
            }
            return "renewal=\(store.renewal), entitlement=\(entitlements.entitlement), transactions=\(transactions)"
        }
        func traceTransactions(_ stage: String) {
            for transaction in session.allTransactions() {
                print("TEST_SESSION stage=\(stage) product=\(transaction.productIdentifier) id=\(transaction.identifier) purchased=\(transaction.purchaseDate) state=\(transaction.state.rawValue) pending=\(transaction.pendingAskToBuyConfirmation) cancelled=\(transaction.cancelDate != nil)")
            }
        }
        func close() async {
            await store.stop()
            session.clearTransactions()
            session.resetToDefaultState()
        }
    }

    private func fixture() async throws -> Fixture {
        // The host App starts its singleton before XCTest. These tests own a
        // separate store, so stop the host listener instead of having two
        // consumers finish the same simulated transaction concurrently.
        await StoreKitPurchaseStore.shared.stop()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ZTransfer", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        // Clearing test history is asynchronous to StoreKit's device cache.
        // Explicitly sync the reset fixture before creating its app store.
        try await AppStore.sync()
        let entitlements = PremiumEntitlementStore(access: PremiumAccess())
        let store = StoreKitPurchaseStore(entitlementStore: entitlements)
        store.start()
        await store.loadProducts()
        try await eventually { entitlements.entitlement == .free }
        let fixture = Fixture(session: session, store: store, entitlements: entitlements)
        addTeardownBlock { await fixture.close() }
        return fixture
    }

    func testConfiguredPricesTypesAndFamilySharing() async throws {
        let f = try await fixture()
        let annual = try XCTUnwrap(f.store.products[.annual])
        let lifetime = try XCTUnwrap(f.store.products[.lifetime])
        XCTAssertEqual(annual.type, .autoRenewable)
        XCTAssertEqual(annual.price, Decimal(string: "39.99"))
        XCTAssertEqual(annual.subscription?.subscriptionPeriod.value, 1)
        XCTAssertEqual(annual.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(lifetime.type, .nonConsumable)
        XCTAssertEqual(lifetime.price, Decimal(string: "99.99"))
        XCTAssertFalse(annual.isFamilyShareable)
        XCTAssertFalse(lifetime.isFamilyShareable)
    }

    /// A real StoreKit event drives the access shared by both editor stores.
    /// This covers the payment-to-business boundary without injecting isPro.
    func testRefundAndExpiryProtectOpenEditorPreferencesInBothScopes() async throws {
        let f = try await fixture()
        await f.store.purchase(.lifetime)
        try await eventually { f.entitlements.entitlement == .lifetime }
        var editors: [PhotoEffectsStore] = []
        for scope in [PhotoEffectsStore.Scope.cameraTransfer, .localPhotos] {
            let suite = "StoreKitEditor.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            let editor = PhotoEffectsStore(defaults: defaults, scope: scope, premiumAccess: f.entitlements.access)
            var saved = editor.settings
            saved.photoFrameEnabled = true
            saved.photoFrameBorderEnabled = true
            saved.watermark.text = "Saved paid signature"
            saved.watermark.sizePercent = 150
            editor.updateFromEditor(saved)
            editors.append(editor)
        }

        for refund in [true, false] {
            if !refund {
                await f.store.purchase(.annual)
                try await eventually {
                    if case .annual = f.entitlements.entitlement { return true }
                    return false
                }
                for editor in editors {
                    XCTAssertEqual(editor.settings.watermark.text, "Saved paid signature")
                    XCTAssertEqual(editor.settings.watermark.sizePercent, 150)
                }
            }
            let saved = editors.map(\.settings)
            let imports = try editors.map { try XCTUnwrap($0.beginWatermarkImageImport()) }
            if refund {
                let transaction = try XCTUnwrap(f.session.allTransactions().last {
                    $0.productIdentifier == PremiumProduct.lifetime.rawValue
                })
                try f.session.refundTransaction(identifier: transaction.identifier)
            } else {
                try f.session.expireSubscription(productIdentifier: PremiumProduct.annual.rawValue)
            }
            try await eventually { f.entitlements.entitlement == .free }
            for index in editors.indices {
                let editor = editors[index]
                var staleDraft = saved[index]
                staleDraft.watermark.text = "Unsaved paid draft"
                staleDraft.watermark.sizePercent = 20
                staleDraft.photoFrameBorderEnabled.toggle()
                editor.updateFromEditor(staleDraft)
                XCTAssertEqual(editor.settings.watermark, saved[index].watermark)
                XCTAssertEqual(editor.settings.photoFrameBorderEnabled, staleDraft.photoFrameBorderEnabled,
                               "Frame changes remain free after losing Pro")
                XCTAssertFalse(editor.finishWatermarkImageImport(generation: imports[index],
                    hash: String(repeating: "a", count: 64)))
                XCTAssertFalse(editor.watermarkImageImporting)
                XCTAssertNil(editor.beginWatermarkImageImport())
                let effective = effectivePhotoEffectsSettings(editor.settings, isPro: f.entitlements.access.isPro)
                XCTAssertEqual(effective.watermark.text, PhotoFrameWatermark.defaultText)
                XCTAssertEqual(effective.watermark.sizePercent, 80)
            }
        }
    }

    func testAnnualThenLifetimeRefundPreservesAnnualAndExpiryReturnsFree() async throws {
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.entitlements.access.isPro && f.store.renewal.willAutoRenew == true }
        await f.store.purchase(.lifetime)
        try await eventually { f.entitlements.entitlement == .lifetime }
        XCTAssertEqual(f.store.purchaseCelebration, 2)
        // Buying lifetime MUST NOT claim to cancel the separate subscription.
        try await eventually { f.store.renewal.willAutoRenew == true }
        let lifetime = try XCTUnwrap(f.session.allTransactions().last { $0.productIdentifier == PremiumProduct.lifetime.rawValue })
        try f.session.refundTransaction(identifier: lifetime.identifier)
        try await eventually {
            if case .annual = f.entitlements.entitlement { return true }
            return false
        }
        try f.session.expireSubscription(productIdentifier: PremiumProduct.annual.rawValue)
        f.store.refresh()
        try await eventually { f.entitlements.entitlement == .free }
    }

    func testPendingPurchaseGrantsNothingUntilApproved() async throws {
        let f = try await fixture()
        f.session.askToBuyEnabled = true
        await f.store.purchase(.lifetime)
        XCTAssertEqual(f.entitlements.entitlement, .free)
        XCTAssertTrue(f.store.pendingProducts.contains(.lifetime))
        let transaction = try XCTUnwrap(f.session.allTransactions().last)
        try f.session.approveAskToBuyTransaction(identifier: transaction.identifier)
        try await eventually { f.entitlements.entitlement == .lifetime }
        try await eventually { f.store.purchaseCelebration == 1 }
        XCTAssertFalse(f.store.pendingProducts.contains(.lifetime))
    }

    func testDeclinedAskToBuyCanPurchaseAgainWithoutRestart() async throws {
        let f = try await fixture()
        f.session.askToBuyEnabled = true
        await f.store.purchase(.lifetime)
        XCTAssertEqual(f.store.operation, .idle)
        XCTAssertEqual(f.store.messageKey, "iap_pending")
        XCTAssertEqual(f.entitlements.entitlement, .free)
        let declined = try XCTUnwrap(f.session.allTransactions().last)
        try f.session.declineAskToBuyTransaction(identifier: declined.identifier)
        // Apple sends no transaction for a declined request. A local pending
        // marker must not prevent the customer's next deliberate attempt.
        XCTAssertEqual(f.store.purchaseCelebration, 0)
        XCTAssertFalse(f.entitlements.access.isPro)
        f.session.askToBuyEnabled = false
        await f.store.purchase(.lifetime)
        XCTAssertEqual(f.store.operation, .idle)
        XCTAssertEqual(f.entitlements.entitlement, .lifetime)
        XCTAssertEqual(f.store.messageKey, "iap_purchased")
        XCTAssertEqual(f.store.purchaseCelebration, 1)
        XCTAssertFalse(f.store.pendingProducts.contains(.lifetime))
    }

    func testPendingAnnualApprovedAfterLifetimeKeepsLifetimeAndRenewalManagement() async throws {
        let f = try await fixture()
        f.traceTransactions("late-annual-fixture")
        f.session.askToBuyEnabled = true
        await f.store.purchase(.annual)
        XCTAssertEqual(f.entitlements.entitlement, .free)
        XCTAssertTrue(f.store.pendingProducts.contains(.annual))
        let pendingAnnual = try XCTUnwrap(f.session.allTransactions().last {
            $0.productIdentifier == PremiumProduct.annual.rawValue
        })
        f.traceTransactions("late-annual-pending")

        f.session.askToBuyEnabled = false
        await f.store.purchase(.lifetime)
        XCTAssertEqual(f.entitlements.entitlement, .lifetime)
        XCTAssertTrue(f.store.pendingProducts.contains(.annual))
        XCTAssertEqual(f.store.purchaseCelebration, 1)
        f.traceTransactions("late-annual-before-approval")
        try f.session.approveAskToBuyTransaction(identifier: pendingAnnual.identifier)
        f.traceTransactions("late-annual-after-approval")
        try await eventually(diagnostic: { "renewal=\(f.store.renewal), pending=\(f.store.pendingProducts)" }) {
            f.store.renewal.willAutoRenew == true && !f.store.pendingProducts.contains(.annual)
        }
        XCTAssertEqual(f.entitlements.entitlement, .lifetime)
        XCTAssertNotNil(f.store.renewal.nextRenewalDate)
        XCTAssertEqual(f.store.purchaseCelebration, 2)

        // Cancelling or refunding the late annual transaction must never
        // remove an independently purchased lifetime entitlement.
        let annual = try XCTUnwrap(f.session.allTransactions().last {
            $0.productIdentifier == PremiumProduct.annual.rawValue
        })
        try f.session.disableAutoRenewForTransaction(identifier: annual.identifier)
        f.store.refresh()
        try await eventually { f.store.renewal.willAutoRenew == false }
        XCTAssertEqual(f.entitlements.entitlement, .lifetime)
        try f.session.refundTransaction(identifier: annual.identifier)
        f.store.refresh()
        try await eventually { f.store.renewal.state == .revoked }
        XCTAssertEqual(f.entitlements.entitlement, .lifetime)
        XCTAssertEqual(f.store.purchaseCelebration, 2)
    }

    func testFreshStoreRecoversFinishedPurchaseWithoutPriceLoad() async throws {
        let f = try await fixture()
        await f.store.purchase(.lifetime)
        try await eventually { f.entitlements.entitlement == .lifetime }
        await f.store.stop()
        let entitlements = PremiumEntitlementStore(access: PremiumAccess())
        let recovered = StoreKitPurchaseStore(entitlementStore: entitlements)
        addTeardownBlock { await recovered.stop() }
        recovered.start()
        try await eventually(diagnostic: { "restored=\(entitlements.entitlement), error=\(recovered.messageKey ?? "nil")" }) {
            entitlements.entitlement == .lifetime
        }
        XCTAssertTrue(recovered.products.isEmpty)
        XCTAssertEqual(recovered.purchaseCelebration, 0)
        await recovered.restore()
        XCTAssertEqual(entitlements.entitlement, .lifetime)
        XCTAssertEqual(recovered.messageKey, "iap_restored")
    }

    func testCancelRenewalKeepsPaidTermAndProductFailureKeepsEntitlement() async throws {
        let f = try await fixture()
        await f.store.purchase(.annual)
        // Verified access is intentionally delivered before ancillary renewal
        // information. Keep the date requirement, but await its own state.
        try await eventually(diagnostic: { "renewal=\(f.store.renewal)" }) {
            f.entitlements.access.isPro && f.store.renewal.nextRenewalDate != nil
        }
        XCTAssertNotNil(f.store.renewal.nextRenewalDate)
        let transaction = try XCTUnwrap(f.session.allTransactions().last)
        try f.session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        f.store.refresh()
        try await eventually(diagnostic: { "renewal=\(f.store.renewal), entitlement=\(f.entitlements.entitlement)" }) {
            f.store.renewal.willAutoRenew == false
        }
        XCTAssertTrue(f.entitlements.access.isPro)
        XCTAssertNil(f.store.renewal.nextRenewalDate)
        if #available(iOS 17.0, *) {
            try await f.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))),
                                                 forAPI: .loadProducts)
            await f.store.loadProducts()
            XCTAssertTrue(f.store.productError)
            XCTAssertTrue(f.store.products.isEmpty)
            XCTAssertTrue(f.entitlements.access.isPro)
        }
    }

    func testExplicitRestoreRecoversFinishedPurchaseWithoutLoadingPrices() async throws {
        let f = try await fixture()
        await f.store.purchase(.lifetime)
        XCTAssertEqual(f.entitlements.entitlement, .lifetime)
        await f.store.stop()

        let entitlements = PremiumEntitlementStore(access: PremiumAccess())
        let recovered = StoreKitPurchaseStore(entitlementStore: entitlements)
        addTeardownBlock { await recovered.stop() }
        recovered.start()
        // This is a distinct user action, not a workaround inserted into the
        // automatic-recovery test. It must run even while that test is failing.
        await recovered.restore()
        XCTAssertEqual(entitlements.entitlement, .lifetime)
        XCTAssertEqual(recovered.messageKey, "iap_restored")
        XCTAssertTrue(recovered.products.isEmpty)
        XCTAssertEqual(recovered.purchaseCelebration, 0)
    }

    func testRestoreNetworkFailurePreservesAnnualButCannotExtendExpiredAccess() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Simulated errors require iOS 17") }
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.store.renewal.state == .subscribed && f.entitlements.access.isPro }
        let purchased = f.entitlements.entitlement
        var observed: [PremiumEntitlement] = []
        let observation = f.entitlements.$entitlement.sink { observed.append($0) }
        defer { observation.cancel() }

        try await f.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))),
                                             forAPI: .appStoreSync)
        await f.store.restore()
        XCTAssertEqual(f.store.messageKey, "iap_restore_failed")
        XCTAssertEqual(f.store.operation, .idle)
        XCTAssertEqual(f.entitlements.entitlement, purchased)
        XCTAssertTrue(observed.allSatisfy { $0 == purchased }, "A network error must not transiently revoke valid access")

        // The expiry comes from StoreKit, not a locally edited isPro flag.
        try f.session.expireSubscription(productIdentifier: PremiumProduct.annual.rawValue)
        f.store.refresh()
        try await eventually { f.entitlements.entitlement == .free }
        XCTAssertFalse(f.entitlements.access.isPro)
        await f.store.restore()
        XCTAssertEqual(f.store.messageKey, "iap_restore_failed")
        XCTAssertFalse(f.entitlements.access.isPro, "Failed synchronization cannot extend the old paid term")
        XCTAssertEqual(f.store.purchaseCelebration, 1)

        try await f.session.setSimulatedError(nil, forAPI: .appStoreSync)
        await f.store.restore()
        XCTAssertEqual(f.store.messageKey, "iap_restore_empty")
        XCTAssertEqual(f.entitlements.entitlement, .free)
    }

    func testRestoreNetworkFailurePreservesVerifiedGraceAndLifetimeRefundFallback() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Simulated errors require iOS 17") }
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.store.renewal.state == .subscribed && f.entitlements.access.isPro }
        f.session.shouldEnterBillingRetryOnRenewal = true
        f.session.billingGracePeriodIsEnabled = true
        try f.session.forceRenewalOfSubscription(productIdentifier: PremiumProduct.annual.rawValue)
        f.store.refresh()
        try await eventually { f.store.renewal.state == .grace }
        let deadline = try XCTUnwrap(f.store.renewal.graceDeadline)
        let grace = PremiumEntitlement.annual(until: deadline, gracePeriod: true)
        XCTAssertEqual(f.entitlements.entitlement, grace)

        var observed: [PremiumEntitlement] = []
        let observation = f.entitlements.$entitlement.sink { observed.append($0) }
        defer { observation.cancel() }
        try await f.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))),
                                             forAPI: .appStoreSync)
        await f.store.restore()
        XCTAssertEqual(f.store.messageKey, "iap_restore_failed")
        XCTAssertEqual(f.entitlements.entitlement, grace, "Reuse only Apple's previously verified grace deadline")

        await f.store.purchase(.lifetime)
        try await eventually { f.entitlements.entitlement == .lifetime }
        let lifetime = try XCTUnwrap(f.session.allTransactions().last {
            $0.productIdentifier == PremiumProduct.lifetime.rawValue
        })
        try f.session.refundTransaction(identifier: lifetime.identifier)
        try await eventually { f.entitlements.entitlement == grace }
        XCTAssertTrue(observed.allSatisfy { $0 == grace || $0 == .lifetime },
                      "Refunding lifetime must not erase the still-valid verified grace period")
        XCTAssertEqual(f.store.purchaseCelebration, 2)

        await f.store.restore()
        XCTAssertEqual(f.store.messageKey, "iap_restore_failed")
        XCTAssertEqual(f.entitlements.entitlement, grace)
        try await f.session.setSimulatedError(nil, forAPI: .appStoreSync)
        await f.store.restore()
        XCTAssertEqual(f.store.messageKey, "iap_restored")
        XCTAssertEqual(f.store.renewal.graceDeadline, deadline)
        XCTAssertEqual(f.entitlements.entitlement, grace)
    }

    /// Characterizes this runtime's empty-response fault, not a thrown-error
    /// path. Baseline/recovery queries prove the empty list isn't no purchase.
    func testSubscriptionStatusFaultReturnsEmptyAndRecovers() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Simulated errors require iOS 17") }
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.store.renewal.state == .subscribed }
        let subscription = try XCTUnwrap(f.store.products[.annual]?.subscription)
        await f.store.stop()
        let baseline = try await Product.SubscriptionInfo.status(for: subscription.subscriptionGroupID)
        print("TEST_NATIVE_GROUP_STATUS_BASELINE count=\(baseline.count)")
        XCTAssertFalse(baseline.isEmpty, "Establish a readable subscription before injecting the fault")
        try await f.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))),
                                             forAPI: .subscriptionStatus)
        let configured = await f.session.simulatedError(forAPI: .subscriptionStatus)
        XCTAssertNotNil(configured)
        let statuses = try await Product.SubscriptionInfo.status(for: subscription.subscriptionGroupID)
        print("TEST_NATIVE_GROUP_STATUS_EMPTY_FAULT count=\(statuses.count)")
        XCTAssertTrue(statuses.isEmpty)
        let productStatuses = try await subscription.status
        print("TEST_NATIVE_PRODUCT_STATUS_EMPTY_FAULT count=\(productStatuses.count)")
        XCTAssertTrue(productStatuses.isEmpty)
        try await f.session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        let restored = try await Product.SubscriptionInfo.status(for: subscription.subscriptionGroupID)
        print("TEST_NATIVE_GROUP_STATUS_AFTER_CLEAR count=\(restored.count)")
        XCTAssertFalse(restored.isEmpty)
    }

    func testEmptyStatusCannotHideAnnualManagementAfterLifetimePurchase() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Simulated errors require iOS 17") }
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.store.renewal.state == .subscribed }
        await f.store.purchase(.lifetime)
        try await eventually { f.entitlements.entitlement == .lifetime && f.store.renewal.state == .subscribed }
        let subscription = try XCTUnwrap(f.store.products[.annual]?.subscription)
        // On this runtime the configured status fault returns [] instead of
        // throwing. Check that precondition explicitly; this exercises empty
        // status reconciliation, not the catch branch or real offline access.
        try await f.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))),
                                             forAPI: .subscriptionStatus)
        let unavailable = try await Product.SubscriptionInfo.status(for: subscription.subscriptionGroupID)
        XCTAssertTrue(unavailable.isEmpty)
        f.store.refresh()
        try await eventually(diagnostic: { "renewal=\(f.store.renewal), entitlement=\(f.entitlements.entitlement)" }) {
            f.store.renewal.state == .unknown
        }
        XCTAssertNil(f.store.renewal.willAutoRenew, "Missing status cannot confirm cancellation")
        let afterFault = f.entitlements.entitlement
        XCTAssertEqual(afterFault, .lifetime)
        if afterFault != .lifetime {
            // Observe only AFTER preserving the failing assertion, so a
            // diagnostic read cannot warm the cache and conceal the failure.
            for transaction in f.session.allTransactions() {
                print("TEST_STATUS_FAULT_SESSION product=\(transaction.productIdentifier) id=\(transaction.identifier) cancelled=\(transaction.cancelDate != nil)")
            }
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result {
                    print("TEST_AFTER_STATUS_FAULT product=\(transaction.productID) id=\(transaction.id) revoked=\(transaction.revocationDate != nil)")
                }
            }
            if case .verified(let transaction) = await Transaction.latest(for: PremiumProduct.lifetime.rawValue) {
                print("TEST_STATUS_FAULT_LATEST_LIFETIME id=\(transaction.id) revoked=\(transaction.revocationDate != nil)")
            } else {
                print("TEST_STATUS_FAULT_LATEST_LIFETIME missingOrUnverified")
            }
        }
        try await f.session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        f.store.refresh()
        try await eventually { f.store.renewal.state == .subscribed && f.store.renewal.willAutoRenew == true }
        XCTAssertEqual(f.entitlements.entitlement, .lifetime)
        XCTAssertEqual(f.store.purchaseCelebration, 2)
    }

    func testCancelledAndFailedPurchaseDoNotRemoveExistingAccess() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Simulated errors require iOS 17") }
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.entitlements.access.isPro }
        try await eventually(diagnostic: { "annual transactions=\(f.session.allTransactions().count)" }) {
            f.session.allTransactions().contains { $0.productIdentifier == PremiumProduct.annual.rawValue }
        }
        try await f.session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await f.store.purchase(.lifetime)
        XCTAssertNil(f.store.messageKey)
        XCTAssertTrue(f.entitlements.access.isPro)
        try await f.session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        await f.store.purchase(.lifetime)
        XCTAssertEqual(f.store.messageKey, "iap_purchase_failed")
        XCTAssertTrue(f.entitlements.access.isPro)
        XCTAssertEqual(f.store.purchaseCelebration, 1)
    }

    func testBillingGraceUsesApplesDeadline() async throws {
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.entitlements.access.isPro }
        try await eventually(diagnostic: { "annual transactions=\(f.session.allTransactions().count)" }) {
            f.session.allTransactions().contains { $0.productIdentifier == PremiumProduct.annual.rawValue }
        }
        f.session.shouldEnterBillingRetryOnRenewal = true
        f.session.billingGracePeriodIsEnabled = true
        try f.session.forceRenewalOfSubscription(productIdentifier: PremiumProduct.annual.rawValue)
        f.store.refresh()
        try await eventually(diagnostic: { "renewal=\(f.store.renewal)" }) { f.store.renewal.state == .grace }
        let deadline = try XCTUnwrap(f.store.renewal.graceDeadline)
        XCTAssertEqual(f.entitlements.entitlement, .annual(until: deadline, gracePeriod: true))
        try await resolveBillingIssue(f)
        try await eventually(diagnostic: { f.billingDiagnostic() }) { f.store.renewal.state == .subscribed }
        guard case .annual(_, let grace) = f.entitlements.entitlement else {
            return XCTFail("Resolving billing during grace must preserve annual access")
        }
        XCTAssertFalse(grace)
        XCTAssertNil(f.store.renewal.graceDeadline)
        XCTAssertNotNil(f.store.renewal.nextRenewalDate)
        XCTAssertEqual(f.store.purchaseCelebration, 1, "Recovered renewal is not a new user purchase")
    }

    func testBillingRetryWithoutGraceLocksUntilAppleRecoversPayment() async throws {
        let f = try await fixture()
        await f.store.purchase(.annual)
        try await eventually { f.entitlements.access.isPro }
        f.session.shouldEnterBillingRetryOnRenewal = true
        f.session.billingGracePeriodIsEnabled = false
        try f.session.forceRenewalOfSubscription(productIdentifier: PremiumProduct.annual.rawValue)
        f.store.refresh()
        try await eventually(diagnostic: { "renewal=\(f.store.renewal), entitlement=\(f.entitlements.entitlement)" }) {
            f.store.renewal.state == .retrying && f.entitlements.entitlement == .free
        }
        XCTAssertNil(f.store.renewal.graceDeadline)
        XCTAssertNil(f.store.renewal.nextRenewalDate)
        try await resolveBillingIssue(f)
        try await eventually {
            f.store.renewal.state == .subscribed && f.entitlements.access.isPro
        }
        XCTAssertEqual(f.store.renewal.willAutoRenew, true)
        XCTAssertNotNil(f.store.renewal.nextRenewalDate)
        XCTAssertEqual(f.store.purchaseCelebration, 1)
    }

    private func resolveBillingIssue(_ f: Fixture) async throws {
        try await eventually(diagnostic: { f.billingDiagnostic() }) {
            f.session.allTransactions().contains {
                $0.productIdentifier == PremiumProduct.annual.rawValue && $0.hasPurchaseIssue
            }
        }
        let transaction = try XCTUnwrap(f.session.allTransactions().last {
            $0.productIdentifier == PremiumProduct.annual.rawValue && $0.hasPurchaseIssue
        })
        // Resolve the existing issue while it is still in billing retry.
        // Turning off the simulator's retry mode first can remove the issue;
        // StoreKitTest documents that resolve then has no effect. Fixture
        // teardown resets the simulation flags after assertions complete.
        try f.session.resolveIssueForTransaction(identifier: transaction.identifier)
        f.store.refresh()
    }

    private func eventually(timeout: TimeInterval = 10,
                            diagnostic: @MainActor () -> String = { "" },
                            file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let settled = condition()
        if !settled {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result {
                    print("TEST_CURRENT_ENTITLEMENT product=\(transaction.productID) id=\(transaction.id) purchased=\(transaction.purchaseDate) signed=\(transaction.signedDate) bundle=\(transaction.appBundleID) revoked=\(transaction.revocationDate != nil)")
                } else { print("TEST_CURRENT_ENTITLEMENT unverified") }
            }
        }
        XCTAssertTrue(settled, "StoreKit state did not settle: \(diagnostic())", file: file, line: line)
        if !settled { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}
