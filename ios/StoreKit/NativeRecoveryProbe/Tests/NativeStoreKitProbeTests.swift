import StoreKit
import StoreKitTest
import XCTest

@MainActor final class NativeStoreKitProbeTests: XCTestCase {
    func testFinishedPurchaseWithContinuousNativeListener() async throws {
        try await verifyNativeRecovery(synchronizeFixture: true)
    }

    func testFinishedPurchaseWithoutFixtureSynchronization() async throws {
        try await verifyNativeRecovery(synchronizeFixture: false)
    }

    func testPurchaseIsVisibleBeforeFinishingTransaction() async throws {
        try await verifyNativeRecovery(synchronizeFixture: true, finishBeforeScan: false)
    }

    func testFinishedPurchaseIsVisibleInProductScopedEntitlements() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Product-scoped sequence requires iOS 18.4") }
        try await verifyNativeRecovery(synchronizeFixture: true, productScoped: true)
    }

    func testAnnualAndLifetimeRemainVisibleWithoutStatusFault() async throws {
        try await verifyTwoProducts(statusFault: false)
    }

    func testAnnualAndLifetimeRemainVisibleWithStatusFault() async throws {
        try await verifyTwoProducts(statusFault: true)
    }

    func testLifetimeAfterEstablishedAnnualWithoutStatusFault() async throws {
        try await verifyTwoProducts(statusFault: false, establishAnnual: true)
    }

    func testLifetimeAfterEstablishedAnnualWithStatusFault() async throws {
        try await verifyTwoProducts(statusFault: true, establishAnnual: true)
    }

    private func verifyTwoProducts(statusFault: Bool, establishAnnual: Bool = false) async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Fault injection requires iOS 17") }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ZTransfer", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        try await AppStore.sync()
        let listener = Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    print("NATIVE_PAIR update product=\(transaction.productID) id=\(transaction.id)")
                } else {
                    print("NATIVE_PAIR update UNVERIFIED")
                }
            }
        }
        addTeardownBlock {
            listener.cancel()
            await listener.value
            session.clearTransactions()
            session.resetToDefaultState()
        }
        let annualID = "com.ztransfer.ios.pro.annual"
        let lifetimeID = "com.ztransfer.ios.pro.lifetime"
        let products = try await Product.products(for: [annualID, lifetimeID])
        let annual = try XCTUnwrap(products.first { $0.id == annualID })
        let lifetime = try XCTUnwrap(products.first { $0.id == lifetimeID })
        let group = try XCTUnwrap(annual.subscription?.subscriptionGroupID)
        for product in [annual, lifetime] {
            guard case .success(.verified(let transaction)) = try await product.purchase() else {
                return XCTFail("Native purchase did not verify: \(product.id)")
            }
            print("NATIVE_PAIR purchased product=\(transaction.productID) id=\(transaction.id) bundle=\(transaction.appBundleID)")
            await transaction.finish()
            if product.id == annualID {
                let statuses = try await Product.SubscriptionInfo.status(for: group)
                print("NATIVE_PAIR annual status count=\(statuses.count)")
                if establishAnnual {
                    // Match the main regression's already-readable annual
                    // prerequisite BEFORE buying lifetime. There is still
                    // no wait between lifetime finish and its first scan.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                    var ready = statuses.contains { $0.state == .subscribed }
                    while !ready, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                        let updated = try await Product.SubscriptionInfo.status(for: group)
                        ready = updated.contains { $0.state == .subscribed }
                    }
                    XCTAssertTrue(ready, "Annual prerequisite never became readable")
                    guard ready else { return }
                    print("NATIVE_PAIR annual established BEFORE lifetime purchase")
                }
            }
        }
        if statusFault {
            try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))),
                                                forAPI: .subscriptionStatus)
            let statuses = try await Product.SubscriptionInfo.status(for: group)
            print("NATIVE_PAIR fault status count=\(statuses.count)")
        }
        let first = await nativeProducts(label: "first fault=\(statusFault)")
        XCTAssertTrue(first.contains(annualID), "Annual must survive the independent lifetime purchase")
        XCTAssertTrue(first.contains(lifetimeID), "Finished lifetime purchase must remain in current entitlements")
        // Diagnostics happen only after preserving both strict assertions.
        for transaction in session.allTransactions() {
            print("NATIVE_PAIR history product=\(transaction.productIdentifier) id=\(transaction.identifier) cancelled=\(transaction.cancelDate != nil)")
        }
        await nativeLatest(lifetimeID, label: "immediate")
        try await Task.sleep(for: .seconds(1))
        _ = await nativeProducts(label: "later fault=\(statusFault)")
        await nativeLatest(lifetimeID, label: "later")
        if statusFault {
            try await session.setSimulatedError(nil, forAPI: .subscriptionStatus)
            _ = await nativeProducts(label: "cleared")
            await nativeLatest(lifetimeID, label: "cleared")
        }
    }

    private func nativeProducts(label: String) async -> Set<String> {
        var products = Set<String>()
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                products.insert(transaction.productID)
                print("NATIVE_PAIR \(label) verified product=\(transaction.productID) id=\(transaction.id) revoked=\(transaction.revocationDate != nil)")
            case .unverified(let transaction, let error):
                print("NATIVE_PAIR \(label) UNVERIFIED product=\(transaction.productID) error=\(error)")
            }
        }
        print("NATIVE_PAIR \(label) products=\(products.sorted())")
        return products
    }

    private func nativeLatest(_ productID: String, label: String) async {
        switch await Transaction.latest(for: productID) {
        case .verified(let transaction):
            print("NATIVE_PAIR latest \(label) verified id=\(transaction.id) revoked=\(transaction.revocationDate != nil)")
        case .unverified(let transaction, let error):
            print("NATIVE_PAIR latest \(label) UNVERIFIED id=\(transaction.id) error=\(error)")
        case nil:
            print("NATIVE_PAIR latest \(label) NIL")
        }
    }

    private func verifyNativeRecovery(synchronizeFixture: Bool, finishBeforeScan: Bool = true,
                                      productScoped: Bool = false) async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ZTransfer", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        if synchronizeFixture { try await AppStore.sync() }
        let listener = Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    print("NATIVE update \(transaction.id) at \(Date().timeIntervalSince1970)")
                }
            }
        }
        addTeardownBlock {
            listener.cancel()
            await listener.value
            session.clearTransactions()
            session.resetToDefaultState()
        }
        // Product loading yields to the listener task before purchase.
        let products = try await Product.products(for: ["com.ztransfer.ios.pro.lifetime"])
        let product = try XCTUnwrap(products.first)
        let purchase = try await product.purchase()
        guard case .success(.verified(let transaction)) = purchase else {
            XCTFail("No verified purchase: \(purchase)"); return
        }
        print("NATIVE purchased \(transaction.id) type=\(transaction.productType) bundle=\(transaction.appBundleID) at \(Date().timeIntervalSince1970)")
        if finishBeforeScan { await transaction.finish() }
        print("NATIVE boundary finished=\(finishBeforeScan) scoped=\(productScoped) at \(Date().timeIntervalSince1970), history=\(session.allTransactions().map(\.identifier))")
        var ids: [UInt64] = []
        if productScoped, #available(iOS 18.4, *) {
            // Read this API first; do not warm the cache via a full scan.
            for await entitlement in Transaction.currentEntitlements(for: product.id) {
                if case .verified(let value) = entitlement { ids.append(value.id) }
            }
        } else {
            for await entitlement in Transaction.currentEntitlements {
                if case .verified(let value) = entitlement { ids.append(value.id) }
            }
        }
        print("NATIVE first scan \(ids) at \(Date().timeIntervalSince1970)")
        XCTAssertTrue(ids.contains(transaction.id), "Native query did not return the verified non-consumable; finished=\(finishBeforeScan), scoped=\(productScoped)")
        if !finishBeforeScan { await transaction.finish() }
        // Diagnostic observation after the assertion has already failed. This
        // delay must never turn the initial recovery failure into a pass.
        try await Task.sleep(for: .seconds(1))
        var laterIDs: [UInt64] = []
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let value) = entitlement { laterIDs.append(value.id) }
        }
        print("NATIVE later scan \(laterIDs) at \(Date().timeIntervalSince1970)")
    }
}
