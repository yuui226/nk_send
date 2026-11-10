import StoreKit
import SwiftUI

/// Keep StoreKit observation inside the small header subtree. Purchase and
/// renewal updates must not invalidate the entire settings/photo hierarchy.
struct PremiumSettingsActions: View {
    @ObservedObject private var access = PremiumEntitlementStore.shared
    @ObservedObject private var purchases = StoreKitPurchaseStore.shared
    let motionPaused: Bool
    let onShowPremium: () -> Void
    let onPlayFireworks: () -> Void
    private var showManagement: Bool { Self.showsManagement(access: access, purchases: purchases) }
    static func managementTitleKey(for entitlement: PremiumEntitlement) -> String {
        // A lifetime owner can still have a previous annual subscription to
        // cancel; never imply that lifetime access itself needs renewing.
        entitlement == .lifetime ? "iap_manage" : "renew_action"
    }
    static func showsManagement(access: PremiumEntitlementStore, purchases: StoreKitPurchaseStore) -> Bool {
        #if DEBUG
        // Simulated ownership needs no separate settings management button.
        if access.developmentPurchase != nil { return false }
        #endif
        if case .annual = access.entitlement { return true }
        guard access.entitlement == .lifetime else { return false }
        switch purchases.renewal.state {
        case .unknown, .subscribed, .grace, .retrying: return true
        case .absent, .expired, .revoked: return false
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            if showManagement {
                // Lifetime owners retain the management route as well: their
                // former annual renewal may still be active or unconfirmed.
                Button(AppLocalized.resource(Self.managementTitleKey(for: access.entitlement)), action: onShowPremium)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ZTransferColors.accentBlue)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(ZTransferGlassSurface(cornerRadius: 14, kind: .button))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("premium-settings-renewal")
            }
            ProBadgeButton(label: badgeLabel,
                           motionPaused: motionPaused) {
                if access.entitlement.isPro() { onPlayFireworks() }
                else { onShowPremium() }
            }
        }
    }

    private var badgeLabel: String {
        #if DEBUG
        if access.developmentPurchase != nil { return "Pro" }
        #endif
        return AppLocalized.resource(access.entitlement == .unresolved
            ? "iap_confirming" : (access.entitlement.isPro() ? "pro_label" : "unlock_pro"))
    }
}

enum AppLegalDocument: String, CaseIterable, Hashable, Sendable {
    case privacy, terms

    var configurationKey: String {
        self == .privacy ? "ZTransferPrivacyPolicyURL" : "ZTransferTermsOfUseURL"
    }

    func titleKey(compact: Bool) -> String {
        compact ? "settings_\(rawValue)" : "iap_\(rawValue)"
    }
}

/// Settings uses the published HTTPS destinations from the bundle.
/// Missing configuration remains disabled until the public pages are connected;
/// neither membership nor the purchase panel is a prerequisite for reading them.
struct AppLegalLinksConfiguration: Equatable, Sendable {
    private let destinations: [AppLegalDocument: URL]

    init(infoDictionary: [String: Any]) {
        destinations = Dictionary(uniqueKeysWithValues: AppLegalDocument.allCases.compactMap { document -> (AppLegalDocument, URL)? in
            guard let raw = infoDictionary[document.configurationKey] as? String,
                  raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let components = URLComponents(string: raw),
                  components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  let url = components.url else { return nil }
            return (document, url)
        })
    }

    func url(for document: AppLegalDocument) -> URL? { destinations[document] }

    @MainActor
    func open(_ document: AppLegalDocument, using openURL: OpenURLAction) {
        guard let url = url(for: document) else { return }
        openURL(url)
    }
}

private struct AppLegalLinksConfigurationKey: EnvironmentKey {
    static let defaultValue = AppLegalLinksConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:])
}

extension EnvironmentValues {
    var appLegalLinksConfiguration: AppLegalLinksConfiguration {
        get { self[AppLegalLinksConfigurationKey.self] }
        set { self[AppLegalLinksConfigurationKey.self] = newValue }
    }
}

struct AppLegalLinks: View {
    @Environment(\.appLegalLinksConfiguration) private var configuration
    @Environment(\.openURL) private var openURL
    var compactLabels = false
    var compactSpacing = false

    var body: some View {
        HStack(spacing: compactSpacing ? 2 : 8) {
            ForEach(AppLegalDocument.allCases, id: \.self) { document in
                link(document)
                    .disabled(configuration.url(for: document) == nil)
                    .accessibilityIdentifier("legal-link-\(document.rawValue)")
            }
        }
    }

    @ViewBuilder
    private func link(_ document: AppLegalDocument) -> some View {
        let button = Button {
            configuration.open(document, using: openURL)
        } label: {
            Text(AppLocalized.resource(document.titleKey(compact: compactLabels)))
                .font(.system(size: compactLabels ? ZTransferMetrics.caption : 11,
                              weight: compactLabels ? .semibold : .regular))
                .foregroundStyle(compactLabels ? ZTransferColors.primaryText : ZTransferColors.secondaryText)
                .padding(.horizontal, compactLabels ? (compactSpacing ? 4 : 10) : 0)
                .frame(minHeight: compactLabels ? 28 : nil)
        }
        if compactLabels {
            button.buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14, panel: true))
        } else {
            button.buttonStyle(.plain)
        }
    }
}

/// LicenseDialogs.kt: comparison table, two plan cards, gold CTA, secondary
/// actions. StoreKit replaces Android's activation/payment-server screens.
struct PremiumPurchaseView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = StoreKitPurchaseStore.shared
    @ObservedObject private var access = PremiumEntitlementStore.shared
    @State private var selected: PremiumProduct = .annual
    @State private var scene: UIWindowScene?
    @State private var confirmLifetime = false
    let onClose: () -> Void
    let onCelebrate: () -> Void

    private var busy: Bool { store.operation != .idle }
    private var isLifetime: Bool { access.entitlement == .lifetime }
    private var isAnnualSubscriber: Bool {
        if case .annual = access.entitlement { return true }
        return false
    }
    private var hasAnnual: Bool {
        switch store.renewal.state {
        case .subscribed, .grace, .retrying: true
        default: if case .annual = access.entitlement { true } else { false }
        }
    }
    private var needsRenewalManagement: Bool {
        hasAnnual || (isLifetime && store.renewal.state == .unknown)
    }
    private var needsCancellationReminder: Bool {
        needsRenewalManagement && store.renewal.willAutoRenew != false
    }
    // Android LicenseDialogs.formatSubDate uses yyyy-MM-dd in every language.
    private static let subscriptionDateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DialogBackdrop(onDismiss: onClose)
                ContentSizedDialogLayout {
                    header.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
                    purchaseContent(width: min(420, proxy.size.width - 48), measuring: true)
                        .hidden().allowsHitTesting(false).accessibilityHidden(true)
                    ScrollView(.vertical, showsIndicators: false) {
                        purchaseContent(width: min(420, proxy.size.width - 48), measuring: false)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("premium-purchase-panel")
                // Measure content once per layout pass; only short screens scroll.
                // The close button stays outside the viewport and always reachable.
                .frame(maxWidth: 420)
                .background(ZTransferGlassSurface(cornerRadius: 22, kind: .panel)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .frame(maxHeight: max(1, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom - 32))
                .padding(.horizontal, 24)
                .androidDialogSurface()
            }
        }
        .background(PurchaseSceneReader { scene = $0 }.frame(width: 0, height: 0))
        .task {
            store.clearMessage()
            store.refresh()
            await store.loadProducts()
        }
        .onChange(of: store.purchaseCelebration) { _ in
            // A lifetime buyer with an annual subscription keeps the management
            // action visible; all other successful purchases close and celebrate.
            onCelebrate()
            if !isLifetime || !needsCancellationReminder { onClose() }
        }
        .alert(AppLocalized.resource("plan_lifetime"), isPresented: $confirmLifetime) {
            Button(AppLocalized.resource("iap_continue")) {
                // Automatic recovery can complete while confirmation is open.
                guard canPurchase else { return }
                Task { await store.purchase(.lifetime) }
            }
            Button(AppLocalized.resource("cancel"), role: .cancel) {}
        } message: { Text(AppLocalized.resource("iap_lifetime_notice")) }
    }

    // TestFlight and App Store use the same product.purchase() entry point.
    // StoreKit selects the environment; no in-app test purchase controls.
    private func purchaseContent(width: CGFloat, measuring: Bool) -> some View {
        VStack(spacing: 12) {
            // Billing retry without grace removes Pro access, but
            // the verified payment problem still needs to be shown.
            if isAnnualSubscriber {
                HStack(spacing: 12) {
                    entitlementStatus
                    managementAction(compact: true)
                }
            } else if access.entitlement != .free || hasAnnual { entitlementStatus }
            if !isLifetime && !isAnnualSubscriber {
                // Android RenewDialog omits the new-customer comparison.
                // On iOS annual access renews through Apple: the user's
                // renewal panel offers neither a duplicate annual charge nor
                // a lifetime upgrade. Once access expires, both plans return.
                comparison(width: width - 36)
                VStack(spacing: 10) {
                    plan(.annual)
                    plan(.lifetime)
                }
                // This describes the annual option regardless of selection.
                // Switching plans changes neither the text nor its layout.
                Text(AppLocalized.resource("iap_annual_disclosure"))
                    .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProBadgeButton(label: purchaseLabel(for: selected), big: true,
                               enabled: canPurchase, motionPaused: busy || measuring,
                               animatesLabelChanges: true) {
                    if selected == .lifetime, needsCancellationReminder { confirmLifetime = true }
                    else { Task { await store.purchase(selected) } }
                }
                .accessibilityIdentifier("premium-purchase-action")
            }
            if store.productError, !isLifetime && !isAnnualSubscriber {
                Text(AppLocalized.resource("iap_prices_failed"))
                    .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                action("iap_retry") { Task { await store.loadProducts() } }
            }
            if let message = store.messageKey {
                Text(AppLocalized.resource(message)).font(.system(size: 13))
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            if needsRenewalManagement {
                if isLifetime, store.renewal.willAutoRenew != false {
                    notice("iap_lifetime_followup")
                }
            }
            // Recovery is a fallback for missing access, not an action an
            // already-unlocked customer needs. Keep secondary actions in one
            // row, restore on the left whenever both actions are applicable.
            if !access.entitlement.isPro() || (needsRenewalManagement && !isAnnualSubscriber) {
                HStack(spacing: 10) {
                    if !access.entitlement.isPro() {
                        action("iap_restore") { Task { await store.restore() } }
                            .accessibilityIdentifier("premium-restore")
                    }
                    if needsRenewalManagement && !isAnnualSubscriber {
                        managementAction(compact: false)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "seal.fill").font(.system(size: 24))
                .foregroundStyle(ZTransferColors.accentYellow)
                .frame(width: 42, height: 42)
                .background(ZTransferColors.accentYellow.opacity(0.16), in: Circle())
            Text(AppLocalized.resource(isAnnualSubscriber ? "renew_action" : "pro_version"))
                .font(.system(size: 22, weight: .bold))
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
                    .frame(width: 32, height: 32)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }.buttonStyle(ZTransferGlassButtonStyle.iconControl(cornerRadius: 12))
                .accessibilityLabel(AppLocalized.resource("cd_close"))
                .accessibilityIdentifier("premium-close")
        }.foregroundStyle(ZTransferColors.primaryText)
    }

    private var entitlementStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch access.entitlement {
            case .unresolved: Text(AppLocalized.resource("iap_confirming"))
            case .lifetime: Text(AppLocalized.resource("plan_lifetime"))
            case .annual(let until, let grace):
                if store.renewal.nextRenewalDate == nil {
                    subscriptionDate("iap_valid_until", until)
                }
                if grace { Text(AppLocalized.resource("iap_grace")) }
            case .free: EmptyView()
            }
            if hasAnnual {
                if let date = store.renewal.nextRenewalDate {
                    subscriptionDate("iap_renews_on", date)
                }
                if store.renewal.state == .retrying { Text(AppLocalized.resource("iap_billing_retry")) }
            }
        }.font(.system(size: 13)).foregroundStyle(ZTransferColors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subscriptionDate(_ key: String, _ date: Date) -> some View {
        Text(AppLocalized.formattedResource(key, ["%1$s": Self.subscriptionDateFormatter.string(from: date)]))
    }

    private func comparison(width: CGFloat) -> some View {
        // Android LicenseDialogs: one width calculation shared by every row.
        let compact = width < 300
        let horizontalPadding: CGFloat = compact ? 8 : 14
        let columnWidth = min(64, max(46, (width - horizontalPadding * 2) * 0.24))
        func row(_ label: String, _ free: String, _ annual: String, _ lifetime: String,
                 value: String = "", header: Bool = false) -> some View {
            let duration = label == "compare_duration"
            return HStack(spacing: 0) {
                Text(AppLocalized.resource(label))
                    .fontWeight(header ? .semibold : .regular)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(ZTransferColors.primaryText)
                Text(AppLocalized.formattedResource(free, ["%1$d": value]))
                    // Keep short values together (including English Supported
                    // and 400 MB each); descriptive labels may use two lines.
                    .lineLimit(free == "compare_watermark_free" || free == "duration_free" ? 2 : 1)
                    .minimumScaleFactor(0.7)
                    .frame(width: columnWidth).foregroundStyle(ZTransferColors.secondaryText)
                Text(AppLocalized.resource(annual))
                    .fontWeight(header ? .bold : (duration ? .semibold : .heavy))
                    // Keep Android's shared column widths; fit the iOS bold
                    // glyphs without splitting short tier values mid-word.
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 2)
                    .frame(width: columnWidth)
                    .foregroundStyle(header ? ZTransferColors.accentYellow :
                        (duration ? ZTransferColors.primaryText : ZTransferColors.statusConnected))
                Text(AppLocalized.resource(lifetime))
                    .fontWeight(header ? .bold : .heavy)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 2)
                    .frame(width: columnWidth)
                    .foregroundStyle(header || duration ? ZTransferColors.accentYellow : ZTransferColors.statusConnected)
            }.font(.system(size: header ? (compact ? 11 : 12) : (compact ? 12 : 14)))
                .multilineTextAlignment(.center)
                .padding(.vertical, header ? 0 : (compact ? 5 : 7))
        }
        return VStack(spacing: 0) {
            row("tier_feature", "tier_free", "tier_annual", "tier_lifetime", header: true)
            Divider().padding(.top, 6)
            row("compare_transfer", "compare_transfer_free", "compare_unlimited", "compare_unlimited", value: "25")
            row("compare_filesize", "compare_filesize_free", "compare_unlimited", "compare_unlimited", value: "400")
            row("compare_remote", "compare_remote_free", "compare_unlimited", "compare_unlimited", value: "3")
            row("compare_generate_effect_image", "compare_available", "compare_available", "compare_available")
            row("compare_effect_filters", "compare_available", "compare_available", "compare_available")
            row("compare_effect_frames", "compare_available", "compare_available", "compare_available")
            row("compare_effect_watermark", "compare_watermark_free", "compare_watermark_pro", "compare_watermark_pro")
            row("compare_duration", "duration_free", "iap_annual_period", "duration_lifetime")
        }.padding(.horizontal, horizontalPadding).padding(.vertical, 10)
            .background(ZTransferColors.primaryText.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.10), lineWidth: 1))
    }

    private func plan(_ kind: PremiumProduct) -> some View {
        let product = store.products[kind]
        let enabled = product != nil && !(kind == .annual && access.entitlement.isPro())
        return Button { selected = kind } label: {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: "circle").opacity(selected == kind ? 0 : 1)
                    Image(systemName: "checkmark.circle.fill").opacity(selected == kind ? 1 : 0)
                }.font(.system(size: 20)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalized.resource(kind == .annual ? "plan_annual" : "plan_lifetime"))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(ZTransferColors.primaryText)
                    if let product, kind == .annual {
                        Text(AppLocalized.formattedResource("pro_price_per_month", [
                            "%1$s": (product.price / 12).formatted(product.priceFormatStyle)
                        ])).font(.system(size: 11)).foregroundStyle(ZTransferColors.secondaryText)
                    } else if product == nil {
                        Text(AppLocalized.resource(store.loadingProducts ? "iap_loading" : "plan_unavailable"))
                            .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                    } else {
                        Text(AppLocalized.resource("duration_lifetime")).font(.system(size: 12))
                    }
                }
                Spacer(minLength: 0)
                if let product { Text(product.displayPrice).font(.system(size: 22, weight: .bold)) }
            }.foregroundStyle(ZTransferColors.accentYellow)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background((selected == kind && enabled ? ZTransferColors.accentYellow : ZTransferColors.primaryText)
                    .opacity(selected == kind && enabled ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                    selected == kind && enabled ? ZTransferColors.accentYellow : ZTransferColors.secondaryText.opacity(0.2),
                    lineWidth: selected == kind && enabled ? 2 : 1))
                .animation(PremiumPlanMotion.selection, value: selected == kind)
        }.buttonStyle(.plain).disabled(!enabled || busy)
            .accessibilityAddTraits(selected == kind ? [.isSelected] : [])
            .accessibilityIdentifier(kind == .annual ? "premium-plan-annual" : "premium-plan-lifetime")
    }

    private var canPurchase: Bool {
        !busy && store.products[selected] != nil && !isLifetime && !isAnnualSubscriber
            && access.entitlement != .unresolved
    }
    private func purchaseLabel(for kind: PremiumProduct) -> String {
        guard let product = store.products[kind] else { return AppLocalized.resource("plan_unavailable") }
        return AppLocalized.formattedResource(kind == .annual ? "iap_annual_cta" : "buy_lifetime_cta",
                                             ["%1$s": product.displayPrice])
    }
    private func notice(_ key: String) -> some View {
        Text(AppLocalized.resource(key)).font(.system(size: 12))
            .foregroundStyle(ZTransferColors.primaryText).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZTransferColors.accentYellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private func managementAction(compact: Bool) -> some View {
        action("iap_manage", fillsWidth: !compact) {
            guard let scene else { return }
            Task { await store.manage(in: scene) }
        }.disabled(scene == nil)
            .accessibilityIdentifier("premium-manage")
    }
    private func action(_ key: String, fillsWidth: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(AppLocalized.resource(key)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ZTransferColors.accentBlue)
                .lineLimit(1).fixedSize(horizontal: !fillsWidth, vertical: false)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .padding(.horizontal, 10).padding(.vertical, 10)
                .background(ZTransferGlassSurface(cornerRadius: 12, kind: .button))
        }.buttonStyle(.plain).disabled(busy)
    }
}

/// User-requested iOS refinement (2026-11-06): finite local crossfade, no
/// selection-driven parent resizing or continuously observed animation clock.
enum PremiumPlanMotion {
    static var selection: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: 0.18) }
}

/// Use the presenting window, including on iPad with more than one app scene.
private struct PurchaseSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene?) -> Void
    func makeUIView(context: Context) -> SceneView { SceneView(onScene: onScene) }
    func updateUIView(_ uiView: SceneView, context: Context) { uiView.onScene = onScene }
    final class SceneView: UIView {
        var onScene: (UIWindowScene?) -> Void
        init(onScene: @escaping (UIWindowScene?) -> Void) {
            self.onScene = onScene
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let scene = window?.windowScene
            DispatchQueue.main.async { [weak self] in self?.onScene(scene) }
        }
    }
}

/// Android ProBadgeButton: 2,600 ms linear sweep from -1 to +2, same gold
/// colors and 28/48 pt sizing. Only this small layer redraws for the sheen.
struct ProBadgeButton: View {
    let label: String
    var big = false
    var enabled = true
    var motionPaused = false
    var animatesLabelChanges = false
    let action: () -> Void
    @State private var origin = Date()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Button(action: action) {
            HStack(spacing: big ? 6 : 4) {
                Image(systemName: "seal.fill").font(.system(size: big ? 19 : 15))
                    .accessibilityHidden(true)
                if animatesLabelChanges {
                    labelText(label)
                        .contentTransition(.opacity)
                        .animation(PremiumPlanMotion.selection, value: label)
                } else { labelText(label) }
            }
            .foregroundStyle(Color(red: 74 / 255, green: 50 / 255, blue: 22 / 255))
            .padding(.horizontal, 12).frame(maxWidth: big ? .infinity : nil)
            .frame(minHeight: big ? 48 : 28)
            .background {
                GeometryReader { _ in
                    LinearGradient(colors: [Color(red: 1, green: 224 / 255, blue: 130 / 255),
                                            Color(red: 240 / 255, green: 169 / 255, blue: 59 / 255)],
                                   startPoint: .top, endPoint: .bottom)
                    ProBadgeSheen(origin: origin.timeIntervalSinceReferenceDate,
                        paused: motionPaused || !enabled || scenePhase != .active)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }.clipShape(RoundedRectangle(cornerRadius: big ? 16 : 14))
            }
            .background(RoundedRectangle(cornerRadius: big ? 16 : 14)
                .fill(Color.black.opacity(0.1)).shadow(color: .black.opacity(0.15), radius: 4, y: 2))
            .opacity(enabled ? 1 : 0.5)
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(label)
    }

    private func labelText(_ text: String) -> some View {
        Text(text).font(.system(size: big ? 14 : 12, weight: .bold))
            .lineLimit(big ? 2 : 1)
    }
}

/// SettingsScreen.ProBadgeButton moves one full-width band from -1w to +2w
/// in 2,600 ms. Core Animation translates that retained layer; SwiftUI and the
/// gradient raster do not run a per-frame update. Pausing keeps the visible band,
/// while reentry resumes at the same wall-clock phase as the previous Timeline.
struct ProBadgeSheen: UIViewRepresentable {
    let origin: TimeInterval
    let paused: Bool
    func makeUIView(context: Context) -> ProBadgeSheenView { ProBadgeSheenView() }
    func updateUIView(_ view: ProBadgeSheenView, context: Context) { view.configure(origin: origin, paused: paused) }
    static func dismantleUIView(_ view: ProBadgeSheenView, coordinator: ()) { view.stop() }
}

final class ProBadgeSheenView: UIView {
    private let band = CAGradientLayer()
    private let now: () -> TimeInterval
    private var origin: TimeInterval?
    private var paused = true
    private var pausedPhase: Double?
    private var lastSize = CGSize.zero
    private var stopped = false
    private static let animationKey = "pro-sheen"
    var isAnimating: Bool { band.animation(forKey: Self.animationKey) != nil }

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        let gold = UIColor(red: 1, green: 229.0 / 255, blue: 160.0 / 255, alpha: 1)
        // Canvas interpolates the premultiplied color. CAGradientLayer's
        // transparent endpoints must retain gold RGB or the sweep turns gray.
        band.colors = [gold.withAlphaComponent(0).cgColor,
                       gold.withAlphaComponent(0.65).cgColor,
                       gold.withAlphaComponent(0).cgColor]
        band.locations = [0, 0.5, 1]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(band)
    }
    required init?(coder: NSCoder) { nil }

    func configure(origin: TimeInterval, paused: Bool) {
        guard self.origin != origin || self.paused != paused || stopped else { return }
        self.origin = origin
        self.paused = paused
        pausedPhase = paused ? (now() - origin).truncatingRemainder(dividingBy: 2.6) / 2.6 : nil
        stopped = false
        updateBand()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        updateBand()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBand()
    }
    func stop() {
        stopped = true
        band.removeAnimation(forKey: Self.animationKey)
    }
    private func updateBand() {
        guard let origin, bounds.width > 0, bounds.height > 0 else { return }
        let duration = 2.6
        let phase = pausedPhase ?? (now() - origin).truncatingRemainder(dividingBy: duration) / duration
        let width = bounds.width
        // Keep both the model position and the animated path in the same fixed
        // local bounds; the native band never changes the button's hit frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.removeAnimation(forKey: Self.animationKey)
        band.bounds = CGRect(origin: .zero, size: bounds.size)
        band.position = CGPoint(x: width * (-0.5 + phase * 3), y: bounds.height / 2)
        band.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        if !paused, !stopped, window != nil {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = -0.5 * width
            animation.toValue = 2.5 * width
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) - phase * duration
            band.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }
}
