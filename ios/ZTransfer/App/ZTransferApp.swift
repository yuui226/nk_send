import SwiftUI

@main
struct ZTransferApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("keep_screen_on") private var keepScreenOn = true
    init() {
        ScreenAwakeCoordinator.shared.setPreference(
            UserDefaults.standard.object(forKey: "keep_screen_on") as? Bool ?? true)
        ScreenAwakeCoordinator.shared.setForeground(UIApplication.shared.applicationState == .active)
        // Application-scoped, not owned by a settings/purchase popup.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--simulate-premium-lifetime") {
            PremiumEntitlementStore.shared.simulatePurchase(.lifetime)
        }
        if ProcessInfo.processInfo.arguments.contains("--report-development-premium") {
            let premium = PremiumEntitlementStore.shared
            let product = premium.developmentPurchase?.product?.rawValue ?? "none"
            let usage = FreeUsageStore.shared.snapshot()
            print("[DevelopmentPremium] simulated_product=\(product) is_pro=\(premium.access.isPro) transfers=\(usage.transfers)")
        }
        #endif
        StoreKitPurchaseStore.shared.start()
        PhotoFramePlaceAvailability.shared.start()
        Task { await PhotoLUTStore().pruneSnapshots() }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--gps-gesture-ui-test") {
                GPSGestureAuditHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--filter-gesture-ui-test") {
                FilterGestureAuditHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--gesture-audit-ui-test") {
                EffectsGestureAuditHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--queue-pill-grace-test") {
                QueuePillGraceHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--queue-top-pill-test") {
                QueueTopPillPresentationHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--queue-card-presentation-test") {
                QueueCardPresentationHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--queue-retry-ui-test") {
                QueueRetryInteractionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--queue-swipe-ui-test") {
                QueueSwipeInteractionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--list-admission-ui-test") {
                PhotoListAdmissionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--effects-master-ui-test") {
                PhotoEffectsSettingsHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--remote-tools-ui-test") {
                RemoteToolsInteractionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--photo-preview-ui-test") {
                PhotoPreviewInteractionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("--button-motion-ui-test") {
                ButtonInteractionTestHarness()
            } else {
                RootView()
            }
            #else
            RootView()
            #endif
        }
        .onChange(of: keepScreenOn) { ScreenAwakeCoordinator.shared.setPreference($0) }
        .onChange(of: scenePhase) { phase in
            ScreenAwakeCoordinator.shared.setForeground(phase == .active)
            #if DEBUG
            if phase == .active { PremiumEntitlementStore.shared.refreshDevelopmentPurchase() }
            #endif
        }
    }
}

/// Application preference and temporary batch holds are independent owners.
/// Releasing a hold recomputes current policy instead of restoring a stale snapshot.
@MainActor
final class ScreenAwakeCoordinator {
    static let shared = ScreenAwakeCoordinator { UIApplication.shared.isIdleTimerDisabled = $0 }
    private var preference = false
    private var foreground = false
    private var holds = Set<UUID>()
    private var applied: Bool?
    private let apply: (Bool) -> Void

    init(apply: @escaping (Bool) -> Void) { self.apply = apply }
    func setPreference(_ enabled: Bool) { preference = enabled; update() }
    func setForeground(_ active: Bool) { foreground = active; update() }
    func acquire() -> UUID {
        let id = UUID()
        holds.insert(id)
        update()
        return id
    }
    func release(_ id: UUID) { holds.remove(id); update() }
    private func update() {
        let enabled = foreground && (preference || !holds.isEmpty)
        guard applied != enabled else { return }
        applied = enabled
        apply(enabled)
    }
}
