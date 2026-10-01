import Foundation

/// Product IDs are an app contract. App Store Connect must create these exact
/// IDs before sandbox distribution; prices are never inferred from these IDs.
enum PremiumProduct: String, CaseIterable, Sendable {
    case annual = "com.ztransfer.ios.pro.annual"
    case lifetime = "com.ztransfer.ios.pro.lifetime"
}

enum PremiumEntitlement: Equatable, Sendable {
    case unresolved
    case free
    case annual(until: Date, gracePeriod: Bool)
    case lifetime

    func isPro(at date: Date = Date()) -> Bool {
        switch self {
        case .lifetime: true
        case .annual(let until, _): until > date
        case .unresolved, .free: false
        }
    }

    var deadline: Date? {
        if case .annual(let until, _) = self { return until }
        return nil
    }
}

/// Only the StoreKit adapter creates grants from VERIFIED transactions.
/// Grace dates are accepted only with a verified inGracePeriod status.
struct PremiumGrant: Equatable, Sendable {
    let product: PremiumProduct
    let transactionID: UInt64
    var purchaseDate: Date = .distantPast
    var signedDate: Date = .distantPast
    var expiration: Date?
    var graceDeadline: Date? = nil
    var revoked = false
    var upgraded = false

    /// Transaction IDs are opaque identifiers, not sequence numbers. A replay
    /// may update the same transaction (refund), but cannot replace a renewal
    /// purchased later. Ties between different IDs require an authoritative scan.
    func mayReplace(_ previous: Self) -> Bool {
        if transactionID == previous.transactionID {
            if signedDate != previous.signedDate { return signedDate > previous.signedDate }
            // Equal-signature-time replays must not undo a revocation/upgrade.
            // A genuinely newer verified reversal is still accepted above.
            return (!previous.revoked || revoked) && (!previous.upgraded || upgraded)
        }
        return purchaseDate > previous.purchaseDate
    }

    /// Reconcile only records present in a complete current-account snapshot.
    /// Absence and a different transaction remain authoritative for that scan.
    static func reconcilingSnapshot(_ observed: [PremiumProduct: Self],
                                    previous: [PremiumProduct: Self]) -> [PremiumProduct: Self] {
        var result = observed
        for (product, candidate) in observed {
            guard let known = previous[product],
                  known.transactionID == candidate.transactionID else { continue }
            // Apply the listener's ordering rule to scans too: an older signed
            // copy of the same purchase must not undo a verified refund.
            if !candidate.mayReplace(known) { result[product] = known }
        }
        return result
    }

    static func resolve(_ grants: [Self], at now: Date) -> PremiumEntitlement {
        let eligible = grants.filter { !$0.revoked && !$0.upgraded }
        if eligible.contains(where: { $0.product == .lifetime }) { return .lifetime }
        let annual = eligible.filter { $0.product == .annual }.compactMap { grant -> (Date, Bool)? in
            if let grace = grant.graceDeadline, grace > now { return (grace, true) }
            if let expiry = grant.expiration, expiry > now { return (expiry, false) }
            return nil
        }.max { $0.0 < $1.0 }
        return annual.map { .annual(until: $0.0, gracePeriod: $0.1) } ?? .free
    }
}

/// Synchronous, constant-time read for queue/renderer/recording entry points.
/// This is NOT persisted authorization. UI observation lives in the separate
/// main-actor entitlement store, not in a global purchase-progress publisher.
final class PremiumAccess: @unchecked Sendable {
    static let shared = PremiumAccess()
    private let lock = NSLock()
    private var value: PremiumEntitlement

    init(_ initial: PremiumEntitlement = .unresolved) { value = initial }

    var entitlement: PremiumEntitlement { lock.withLock { value } }
    var isPro: Bool { entitlement.isPro() }
    func replace(with entitlement: PremiumEntitlement) {
        lock.withLock { value = entitlement }
    }
}
