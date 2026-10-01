import Foundation

/// Android LicenseManager: separate natural-day ledgers, success-only original
/// transfers, 400 MiB, and 180 seconds of ready live view. No StoreKit calls.
final class FreeUsageStore: @unchecked Sendable {
    static let shared = FreeUsageStore()
    static let transferLimit = 25
    static let maximumFileBytes: UInt64 = 400 * 1024 * 1024
    static let monitoringLimit: TimeInterval = 180
    static let changed = Notification.Name("ZTransfer.freeUsageChanged")

    struct Snapshot: Equatable, Sendable {
        let transfers: Int
        let monitoringSeconds: TimeInterval
        var transfersLeft: Int { max(0, FreeUsageStore.transferLimit - transfers) }
        var monitoringLeft: TimeInterval { max(0, FreeUsageStore.monitoringLimit - monitoringSeconds) }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let prefix = "premium.freeUsage."
    // Queue tasks are in-memory in both platforms; IDs prevent duplicate
    // callbacks for this process, without building a permanent order database.
    private var countedTransfers = Set<UUID>()

    init(defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func snapshot(at date: Date = Date()) -> Snapshot {
        lock.withLock { read(at: date) }
    }

    /// Returns a threshold notification only after a counted successful file.
    /// Upgrading or refunding never clears the day's ledger or emits warnings.
    @discardableResult
    func recordTransfer(id: UUID, isPro: Bool, at date: Date = Date()) -> Int? {
        let threshold: Int? = lock.withLock {
            guard countedTransfers.insert(id).inserted, !isPro else { return nil }
            let day = dayKey(date)
            let used = read(at: date).transfers + 1
            defaults.set(day, forKey: prefix + "transferDay")
            defaults.set(used, forKey: prefix + "transfers")
            let left = max(0, Self.transferLimit - used)
            guard left == 5 || left == 1 else { return nil }
            let key = prefix + "notified.\(left)"
            guard defaults.string(forKey: key) != day else { return nil }
            defaults.set(day, forKey: key)
            return left
        }
        if !isPro { notify(threshold: threshold) }
        return threshold
    }

    /// Called every second of actual monitoring and at its final partial tick.
    /// The caller splits intervals at entitlement/day boundaries; elapsed time
    /// comes from a monotonic clock, never subtracting user-adjustable dates.
    func consumeMonitoring(_ seconds: TimeInterval, isPro: Bool, at date: Date = Date()) {
        guard !isPro, seconds.isFinite, seconds > 0 else { return }
        lock.withLock {
            let used = min(Self.monitoringLimit, read(at: date).monitoringSeconds + seconds)
            defaults.set(dayKey(date), forKey: prefix + "monitoringDay")
            defaults.set(used, forKey: prefix + "monitoringSeconds")
        }
        // Deliberately no global per-second UI notification. The monitoring
        // view model owns its countdown; photo grids need not redraw each tick.
    }

    private func read(at date: Date) -> Snapshot {
        let day = dayKey(date)
        return Snapshot(
            transfers: defaults.string(forKey: prefix + "transferDay") == day
                ? max(0, defaults.integer(forKey: prefix + "transfers")) : 0,
            monitoringSeconds: defaults.string(forKey: prefix + "monitoringDay") == day
                ? max(0, defaults.double(forKey: prefix + "monitoringSeconds")) : 0)
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(parts.era ?? 0)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private func notify(threshold: Int?) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changed, object: self,
                                             userInfo: threshold.map { ["threshold": $0] })
        }
    }
}
