import Combine
import StoreKit
import UIKit

@MainActor
final class PremiumEntitlementStore: ObservableObject {
    static let shared = PremiumEntitlementStore()
    @Published private(set) var entitlement: PremiumEntitlement = .unresolved
    let access: PremiumAccess

    init(access: PremiumAccess = .shared) {
        self.access = access
        entitlement = access.entitlement
    }

    func publish(_ value: PremiumEntitlement) {
        access.replace(with: value)
        if value != entitlement { entitlement = value }
    }
}

/// UI-only renewal details. They never block lifetime entitlement delivery.
struct PremiumRenewal: Equatable {
    enum State: Equatable { case unknown, absent, subscribed, grace, retrying, expired, revoked }
    var state: State = .unknown
    var willAutoRenew: Bool? = nil
    var expiration: Date? = nil
    var renewalDate: Date? = nil
    var graceDeadline: Date? = nil

    var nextRenewalDate: Date? {
        state == .subscribed && willAutoRenew == true ? renewalDate : nil
    }
}

@MainActor
final class StoreKitPurchaseStore: ObservableObject {
    static let shared = StoreKitPurchaseStore()
    enum Operation: Equatable { case idle, purchasing(PremiumProduct), restoring, managing, redeeming }
    @Published private(set) var products: [PremiumProduct: Product] = [:]
    @Published private(set) var loadingProducts = false
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var renewal = PremiumRenewal()
    @Published private(set) var messageKey: String?
    @Published private(set) var productError = false
    @Published private(set) var purchaseCelebration: UInt64 = 0
    // Correlates a later approval with the user's request, not an authoritative
    // pending-order list: Apple sends no transaction when Ask to Buy is declined.
    @Published private(set) var pendingProducts = Set<PremiumProduct>()
    private let entitlementStore: PremiumEntitlementStore
    private var listener: Task<Void, Never>?
    private var unfinishedTask: Task<Void, Never>?
    private var renewalListener: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var grants: [PremiumProduct: PremiumGrant] = [:]
    private var subscriptionGroupID: String?
    private var started = false
    private var hasCompleteSnapshot = false
    private var bootstrapComplete = false
    private var celebratedTransactions = Set<UInt64>()
    private var delivering: [UInt64: Int] = [:]

    init(entitlementStore: PremiumEntitlementStore = .shared) {
        self.entitlementStore = entitlementStore
    }

    func start() {
        guard !started else { return }
        started = true
        bootstrapComplete = false
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.process(result, userPurchase: false)
            }
        }
        // Cancelling renewal changes renewal info without producing a purchase
        // transaction. Listen to Apple's status sequence as well as purchases.
        renewalListener = Task { [weak self] in
            for await status in Product.SubscriptionInfo.Status.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = status.transaction,
                      case .verified = status.renewalInfo,
                      PremiumProduct(rawValue: transaction.productID) == .annual else { continue }
                self?.subscriptionGroupID = transaction.subscriptionGroupID ?? self?.subscriptionGroupID
                if status.state == .subscribed, self?.pendingProducts.contains(.annual) == true {
                    // An approval may first reach us through subscription
                    // status. Deliver its verified transaction through the
                    // same handler instead of waiting for a second stream.
                    // The handler deduplicates a later transaction update.
                    await self?.process(status.transaction, userPurchase: false)
                } else {
                    self?.refresh()
                }
            }
        }
        unfinishedTask = Task { [weak self] in
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }
                await self?.process(result, userPurchase: false)
            }
            guard !Task.isCancelled else { return }
            // Reconcile once after startup recovery has drained so a partial
            // set of unfinished events cannot be mistaken for the full account.
            self?.bootstrapComplete = true
            self?.refresh()
        }
        refresh()
    }

    /// Paired lifecycle for independently owned stores (including StoreKit
    /// integration tests). The app's shared store stays active for its lifetime.
    func stop() async {
        let running = [listener, unfinishedTask, renewalListener, refreshTask, expiryTask].compactMap { $0 }
        revision &+= 1
        listener?.cancel(); listener = nil
        unfinishedTask?.cancel(); unfinishedTask = nil
        renewalListener?.cancel(); renewalListener = nil
        // Drain the current snapshot before another owner starts. The revision
        // prevents this stopped owner from publishing its result.
        refreshTask = nil
        expiryTask?.cancel(); expiryTask = nil
        started = false
        // Wait for an in-flight finish()/snapshot to return before a different
        // owner starts reading the same StoreKit cache.
        for task in running { await task.value }
    }

    func clearMessage() { messageKey = nil }

    func loadProducts() async {
        guard !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let values = try await Product.products(for: PremiumProduct.allCases.map(\.rawValue))
            var loaded: [PremiumProduct: Product] = [:]
            for product in values {
                guard let kind = PremiumProduct(rawValue: product.id),
                      matches(product.type, kind: kind) else { continue }
                if kind == .annual {
                    guard let period = product.subscription?.subscriptionPeriod,
                          period.unit == .year, period.value == 1 else { continue }
                }
                loaded[kind] = product
            }
            products = loaded
            productError = loaded.count != PremiumProduct.allCases.count
            if let group = loaded[.annual]?.subscription?.subscriptionGroupID {
                subscriptionGroupID = group
                refresh()
            }
        } catch {
            productError = true
            // No cached/fabricated price is offered as purchasable after a
            // failed refresh. Existing entitlements are entirely unaffected.
            products = [:]
        }
    }

    func purchase(_ kind: PremiumProduct) async {
        // Block concurrent purchase calls, but allow a new deliberate attempt
        // after .pending. Otherwise a declined request locks this product until
        // restart because there is no decline transaction to clear the marker.
        guard operation == .idle, let product = products[kind] else { return }
        guard entitlementStore.entitlement != .unresolved else {
            messageKey = "iap_confirming"; refresh(); return
        }
        if entitlementStore.access.entitlement == .lifetime { return }
        if kind == .annual, entitlementStore.access.isPro { return }
        operation = .purchasing(kind)
        messageKey = nil
        defer { operation = .idle }
        do {
            switch try await product.purchase() {
            case .success(let result): await process(result, userPurchase: true)
            case .pending:
                pendingProducts.insert(kind)
                messageKey = "iap_pending"
            case .userCancelled: break
            @unknown default: messageKey = "iap_purchase_failed"
            }
        } catch StoreKitError.userCancelled {
            // Some StoreKit failure paths throw cancellation instead of
            // returning PurchaseResult.userCancelled. Both are silent exits.
        } catch { messageKey = "iap_purchase_failed" }
    }

    func restore() async {
        guard operation == .idle else { return }
        operation = .restoring
        messageKey = nil
        defer { operation = .idle }
        do {
            try await AppStore.sync()
            refresh()
            // A transaction arriving during restoration supersedes the scan.
            // Wait for that replacement as well before reporting its result.
            var observedRevision: UInt64
            repeat {
                observedRevision = revision
                await refreshTask?.value
            } while observedRevision != revision
            if entitlementStore.access.isPro { messageKey = "iap_restored" }
            else if entitlementStore.entitlement == .unresolved { messageKey = "iap_confirmation_failed" }
            else { messageKey = "iap_restore_empty" }
        } catch { messageKey = "iap_restore_failed" }
    }

    func manage(in scene: UIWindowScene) async {
        guard operation == .idle else { return }
        operation = .managing
        defer { operation = .idle; refresh() }
        do { try await AppStore.showManageSubscriptions(in: scene) }
        catch { messageKey = "iap_manage_failed" }
    }

    func redeem(in scene: UIWindowScene) async {
        guard operation == .idle else { return }
        operation = .redeeming
        defer { operation = .idle; refresh() }
        do { try await AppStore.presentOfferCodeRedeemSheet(in: scene) }
        catch { messageKey = "iap_redeem_failed" }
    }

    /// Reads StoreKit's device-side entitlements; does not call sync() or wait
    /// for product pricing. New requests supersede snapshots made before them.
    func refresh() {
        guard started else { return }
        revision &+= 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            // Drain one StoreKit snapshot at a time. Cancelling and restarting
            // enumerations for every purchase/status callback needlessly races
            // the device cache; the revision discards stale results instead.
            while !Task.isCancelled, started {
                let generation = revision
                await readEntitlements(generation: generation)
                if generation == revision { break }
            }
            refreshTask = nil
        }
    }

    private func readEntitlements(generation: UInt64) async {
        var observed: [PremiumProduct: PremiumGrant] = [:]
        var unverified = false
        var group = subscriptionGroupID
        for await result in Transaction.currentEntitlements {
            guard !Task.isCancelled else { return }
            guard case .verified(let transaction) = result else { unverified = true; continue }
            guard let grant = grant(for: transaction) else { continue }
            if let previous = observed[grant.product] {
                if grant.mayReplace(previous) { observed[grant.product] = grant }
            } else { observed[grant.product] = grant }
            if grant.product == .annual { group = transaction.subscriptionGroupID ?? group }
        }
        if group == nil, case .verified(let previous) = await Transaction.latest(for: PremiumProduct.annual.rawValue),
           grant(for: previous) != nil {
            // Billing retry/expired subscriptions can be absent from current
            // entitlements. Learn their group without needing product prices;
            // the historical transaction itself does NOT grant access here.
            group = previous.subscriptionGroupID
        }
        guard !Task.isCancelled, revision == generation else { return }
        subscriptionGroupID = group
        let now = Date()
        // Do not revoke still-valid verified access because a new record fails
        // verification. Successful authoritative empty scans still revoke it.
        if unverified {
            messageKey = "iap_confirmation_failed"
            hasCompleteSnapshot = false
            // Deliver verified additions, without interpreting an unverifiable
            // record as proof that a different, still-valid grant disappeared.
            for (product, value) in observed {
                if grants[product].map({ value.mayReplace($0) }) ?? true {
                    grants[product] = preservingGrace(value)
                }
            }
            let resolved = PremiumGrant.resolve(Array(grants.values), at: now)
            entitlementStore.publish(resolved.isPro(at: now) ? resolved : .unresolved)
        } else {
            observed = PremiumGrant.reconcilingSnapshot(observed, previous: grants)
            // A purchase result can precede its appearance in the current
            // entitlement snapshot. While delivering that exact verified
            // transaction, an older/empty scan is not a revocation. Outside
            // delivery, complete snapshots still remove absent entitlements.
            for (product, value) in grants where delivering[value.transactionID, default: 0] > 0 {
                guard PremiumGrant.resolve([value], at: now).isPro(at: now) else { continue }
                if observed[product].map({ !$0.mayReplace(value) }) ?? true {
                    observed[product] = value
                }
            }
            // Retain a previously verified grace deadline until we can read its
            // status; an expired underlying subscription transaction is normal
            // in grace. Never manufacture a new grace period locally.
            if let annual = observed[.annual], let previous = grants[.annual],
               previous.transactionID == annual.transactionID {
                observed[.annual]?.graceDeadline = previous.graceDeadline
            }
            grants = observed
            hasCompleteSnapshot = true
            let hasUnresolvedGrace = observed[.annual].map {
                ($0.expiration ?? .distantPast) <= now && ($0.graceDeadline ?? .distantPast) <= now
            } ?? false
            if hasUnresolvedGrace, observed[.lifetime] == nil {
                entitlementStore.publish(.unresolved)
            } else { publishGrants(allowFree: bootstrapComplete) }
        }
        if let group {
            await readRenewal(group: group, generation: generation)
        } else if !unverified {
            renewal = PremiumRenewal(state: .absent)
        }
        armExpiry()
    }

    private func readRenewal(group: String, generation: UInt64) async {
        do {
            let statuses = try await Product.SubscriptionInfo.status(for: group)
            guard !Task.isCancelled, revision == generation else { return }
            var candidates: [(PremiumGrant, PremiumRenewal)] = []
            for status in statuses {
                guard case .verified(let transaction) = status.transaction,
                      case .verified(let info) = status.renewalInfo,
                      var grant = grant(for: transaction), grant.product == .annual else { continue }
                let state: PremiumRenewal.State
                switch status.state {
                case .subscribed: state = .subscribed
                case .inGracePeriod:
                    state = .grace; grant.graceDeadline = info.gracePeriodExpirationDate
                case .inBillingRetryPeriod: state = .retrying; grant.revoked = true
                case .expired: state = .expired; grant.revoked = true
                case .revoked: state = .revoked; grant.revoked = true
                default: continue
                }
                candidates.append((grant, PremiumRenewal(state: state,
                    willAutoRenew: info.willAutoRenew, expiration: transaction.expirationDate,
                    renewalDate: info.renewalDate,
                    graceDeadline: grant.graceDeadline)))
            }
            if let candidate = candidates.max(by: {
                ($0.0.graceDeadline ?? $0.0.expiration ?? .distantPast)
                    < ($1.0.graceDeadline ?? $1.0.expiration ?? .distantPast)
            }) {
                if grants[.annual].map({ candidate.0.mayReplace($0) }) ?? true {
                    grants[.annual] = candidate.0
                }
                renewal = candidate.1
                publishGrants(allowFree: hasCompleteSnapshot && bootstrapComplete)
            } else if statuses.isEmpty {
                // An empty ancillary status response cannot disprove an
                // annual grant verified by the entitlement scan. In that
                // contradictory state keep renewal management available,
                // particularly after an annual-to-lifetime purchase. Do not
                // infer that auto-renewal is cancelled or extend any access.
                let validAnnual = grants[.annual].map {
                    PremiumGrant.resolve([$0], at: Date()).isPro()
                } ?? false
                renewal = PremiumRenewal(state: validAnnual ? .unknown : .absent)
            } else {
                renewal = PremiumRenewal()
            }
        } catch {
            guard revision == generation else { return }
            renewal = PremiumRenewal()
            // This ancillary failure must not erase verified lifetime/annual.
        }
    }

    private func process(_ result: VerificationResult<Transaction>, userPurchase: Bool) async {
        guard case .verified(let transaction) = result else {
            messageKey = "iap_verification_failed"; return
        }
        guard let transactionGrant = grant(for: transaction) else { return }
        let value = preservingGrace(transactionGrant)
        delivering[value.transactionID, default: 0] += 1
        defer {
            let remaining = delivering[value.transactionID, default: 1] - 1
            delivering[value.transactionID] = remaining > 0 ? remaining : nil
        }
        revision &+= 1
        subscriptionGroupID = transaction.subscriptionGroupID ?? subscriptionGroupID
        // Keep only the current transaction for each product. A late revoked
        // historical transaction must not remove a newer renewed transaction.
        let accepted = grants[value.product].map({ value.mayReplace($0) }) ?? true
        if accepted {
            grants[value.product] = value
            // Startup may deliver an unfinished refund before the other
            // product has been scanned. Never announce free from that subset.
            publishGrants(allowFree: hasCompleteSnapshot && bootstrapComplete)
        }
        let wasPending = pendingProducts.remove(value.product) != nil
        // The update listener may deliver this purchase before purchase()
        // returns, and a scan may already hold a newer signature for the SAME
        // valid transaction. Rejecting its older data must not suppress the
        // user's success event. A newer refund or different transaction still
        // cannot celebrate; event deduplication is independent of grant merging.
        let delivered = grants[value.product].map {
            $0.transactionID == value.transactionID && PremiumGrant.resolve([$0], at: Date()).isPro()
        } ?? false
        if (userPurchase || wasPending), delivered,
           celebratedTransactions.insert(value.transactionID).inserted {
            purchaseCelebration &+= 1
            messageKey = "iap_purchased"
        }
        // The verified benefit is already delivered. A subscription-status
        // request is ancillary and must not keep Apple's transaction unfinished.
        await transaction.finish()
        if started {
            refresh()
            await refreshTask?.value
        }
    }

    private func grant(for transaction: Transaction) -> PremiumGrant? {
        guard let kind = PremiumProduct(rawValue: transaction.productID),
              matches(transaction.productType, kind: kind),
              transaction.appBundleID == Bundle.main.bundleIdentifier else { return nil }
        return PremiumGrant(product: kind, transactionID: transaction.id,
            purchaseDate: transaction.purchaseDate, signedDate: transaction.signedDate,
            expiration: transaction.expirationDate,
            revoked: transaction.revocationDate != nil,
            upgraded: transaction.isUpgraded)
    }

    private func matches(_ type: Product.ProductType, kind: PremiumProduct) -> Bool {
        kind == .annual ? type == .autoRenewable : type == .nonConsumable
    }

    private func preservingGrace(_ value: PremiumGrant) -> PremiumGrant {
        var result = value
        if !value.revoked, !value.upgraded,
           let previous = grants[value.product], previous.transactionID == value.transactionID {
            result.graceDeadline = previous.graceDeadline
        }
        return result
    }

    private func publishGrants(allowFree: Bool = true) {
        let resolved = PremiumGrant.resolve(Array(grants.values), at: Date())
        entitlementStore.publish(resolved.isPro() || allowFree ? resolved : .unresolved)
        armExpiry()
    }

    private func armExpiry() {
        expiryTask?.cancel()
        let dates = grants.values.flatMap { [$0.expiration, $0.graceDeadline].compactMap { $0 } }
        guard let next = dates.filter({ $0 > Date() }).min() else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow))) }
            catch { return }
            self?.refresh()
        }
    }
}
