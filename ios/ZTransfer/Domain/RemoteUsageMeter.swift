import Combine
import Foundation

/// Android RemoteTrialNotice: carry the one-shot message across the actual
/// root-owned monitor route, including a camera-session replacement beneath it.
@MainActor
enum RemoteTrialNotice {
    static var pending = false
    static let returned = Notification.Name("ZTransfer.remoteTrialReturned")
    static func returnedToList() {
        if pending { NotificationCenter.default.post(name: returned, object: nil) }
    }
}

/// RemoteScreen's ready-only daily countdown. UI observes this small object,
/// not the video-frame model. No StoreKit lookup occurs on a tick or frame.
@MainActor
final class RemoteUsageMeter: ObservableObject {
    @Published private(set) var secondsLeft: Int
    @Published private(set) var isPro: Bool
    var onExhausted: (() -> Void)?
    var onLostPremium: (() -> Void)?
    private let access: PremiumAccess
    private let usage: FreeUsageStore
    private let calendar: Calendar
    private var previousEntitlement: PremiumEntitlement
    private var lastTick: TimeInterval?
    private var ready = false
    private var active = true
    private var ended = false
    private var timer: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var scheduledExpiry: Date?
    private var observation: AnyCancellable?

    init(entitlements: PremiumEntitlementStore = .shared, usage: FreeUsageStore = .shared,
         calendar: Calendar = .autoupdatingCurrent) {
        access = entitlements.access
        self.usage = usage
        self.calendar = calendar
        previousEntitlement = access.entitlement
        isPro = access.isPro
        secondsLeft = Int(ceil(usage.snapshot().monitoringLeft))
        observation = entitlements.$entitlement.dropFirst().sink { [weak self] value in
            guard let self else { return }
            // Account for the preceding mode before accepting the new grant.
            tick()
            previousEntitlement = value
            updateDisplay()
            reconcileTimer()
        }
    }

    func markReady() {
        guard !ready, !ended else { return }
        ready = true
        updateDisplay()
        reconcileTimer()
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        tick()
        active = value
        lastTick = nil
        reconcileTimer()
    }

    func stop() {
        tick()
        ready = false
        lastTick = nil
        timer?.cancel()
        timer = nil
        expiryTask?.cancel()
        expiryTask = nil
        scheduledExpiry = nil
    }

    // Injectable samples exercise clock/day/entitlement boundaries without
    // sleeping or needing a camera. Production supplies monotonic uptime.
    func tick(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        defer { previousEntitlement = access.entitlement }
        guard ready, active, !ended else { updateDisplay(now: now); return }
        if let previous = lastTick {
            let elapsed = max(0, uptime - previous)
            var charge = elapsed
            switch previousEntitlement {
            case .lifetime: charge = 0
            case .annual(let until, _): charge = min(elapsed, max(0, now.timeIntervalSince(until)))
            case .free, .unresolved: break
            }
            // A tick can cross midnight. Attribute its two portions to their
            // respective natural days; wall-clock jumps cannot invent elapsed
            // use because the interval length always comes from uptime.
            if charge > 0 {
                let start = now.addingTimeInterval(-charge)
                let midnight = calendar.startOfDay(for: now)
                if start < midnight {
                    usage.consumeMonitoring(midnight.timeIntervalSince(start), isPro: false,
                                            at: midnight.addingTimeInterval(-0.001))
                    charge = now.timeIntervalSince(midnight)
                }
                usage.consumeMonitoring(charge, isPro: false, at: now)
            }
        }
        lastTick = uptime
        updateDisplay(now: now)
    }

    private func updateDisplay(now: Date = Date()) {
        let nextPro = access.entitlement.isPro(at: now)
        let lost = isPro && !nextPro
        if isPro != nextPro { isPro = nextPro }
        let left = Int(ceil(usage.snapshot(at: now).monitoringLeft))
        if secondsLeft != left { secondsLeft = left }
        if lost { onLostPremium?() }
        if ready, active, !nextPro, left == 0, !ended {
            ended = true
            timer?.cancel()
            timer = nil
            onExhausted?()
        }
    }

    private func reconcileTimer() {
        reconcileExpiry()
        guard ready, active, !ended, !isPro else {
            timer?.cancel(); timer = nil; lastTick = nil
            return
        }
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                tick()
            }
        }
    }

    private func reconcileExpiry() {
        // Paid monitoring has no per-second timer. Recheck only its verified
        // deadline so a slow StoreKit refresh cannot postpone recording's
        // safety callback. Inactive monitoring must still finish a recording,
        // but does not consume free time until it becomes active again.
        let deadline = ready && !ended && isPro ? access.entitlement.deadline : nil
        guard deadline != scheduledExpiry else { return }
        expiryTask?.cancel()
        expiryTask = nil
        scheduledExpiry = deadline
        guard let deadline else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard let self, scheduledExpiry == deadline else { return }
            expiryTask = nil
            scheduledExpiry = nil
            tick()
            reconcileTimer()
        }
    }

    deinit { timer?.cancel(); expiryTask?.cancel() }
}
