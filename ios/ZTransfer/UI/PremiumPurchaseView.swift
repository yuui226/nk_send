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
    private var showManagement: Bool {
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
                Button(AppLocalized.resource("iap_manage"), action: onShowPremium)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ZTransferColors.accentBlue)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(ZTransferGlassSurface(cornerRadius: 14, kind: .button))
                    .buttonStyle(.plain)
            }
            ProBadgeButton(label: AppLocalized.resource(access.entitlement == .unresolved
                           ? "iap_confirming" : (access.entitlement.isPro() ? "pro_label" : "unlock_pro")),
                           motionPaused: motionPaused) {
                if access.entitlement.isPro() { onPlayFireworks() }
                else { onShowPremium() }
            }
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
    @State private var copiedSupport = false
    let onClose: () -> Void
    let onCelebrate: () -> Void

    private var busy: Bool { store.operation != .idle }
    private var isLifetime: Bool { access.entitlement == .lifetime }
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
                Color.black.opacity(0.32).ignoresSafeArea().onTapGesture { onClose() }
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        // Billing retry without grace removes Pro access, but
                        // the verified payment problem still needs to be shown.
                        if access.entitlement != .free || hasAnnual { entitlementStatus }
                        if !isLifetime {
                            comparison(width: min(420, proxy.size.width - 48) - 40)
                            VStack(spacing: 10) {
                                plan(.annual)
                                plan(.lifetime)
                            }
                            Text(AppLocalized.resource("iap_account_hint"))
                                .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if selected == .lifetime, needsCancellationReminder {
                                notice("iap_lifetime_notice")
                            }
                            if selected == .annual {
                                Text(AppLocalized.resource("iap_renewal_terms"))
                                    .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                            }
                            ProBadgeButton(label: purchaseLabel, big: true,
                                           enabled: canPurchase, motionPaused: busy) {
                                if selected == .lifetime, needsCancellationReminder { confirmLifetime = true }
                                else { Task { await store.purchase(selected) } }
                            }
                        }
                        if store.loadingProducts { ProgressView().accessibilityLabel(AppLocalized.resource("iap_loading")) }
                        if store.productError, !isLifetime {
                            Text(AppLocalized.resource("iap_prices_failed"))
                                .font(.system(size: 12)).foregroundStyle(ZTransferColors.secondaryText)
                            action("iap_retry") { Task { await store.loadProducts() } }
                        }
                        if let message = store.messageKey {
                            Text(AppLocalized.resource(message)).font(.system(size: 13))
                                .foregroundStyle(ZTransferColors.secondaryText)
                        }
                        if busy { ProgressView() }
                        if needsRenewalManagement {
                            if isLifetime, store.renewal.willAutoRenew != false {
                                notice("iap_lifetime_followup")
                            }
                            action("iap_manage") {
                                guard let scene else { return }
                                Task { await store.manage(in: scene) }
                            }.disabled(scene == nil)
                        }
                        HStack(spacing: 10) {
                            action("iap_restore") { Task { await store.restore() } }
                            action("iap_redeem") {
                                guard let scene else { return }
                                Task { await store.redeem(in: scene) }
                            }.disabled(scene == nil)
                        }
                        if #unavailable(iOS 16.3) {
                            Text(AppLocalized.resource("iap_redeem_version")).font(.system(size: 11))
                        }
                        action("feedback") {
                            UIPasteboard.general.string = "953000922"
                            copiedSupport = true
                        }
                        legalLinks
                    }
                    .padding(20)
                }
                .accessibilityIdentifier("premium-purchase-panel")
                // Let the scroll viewport honor the screen's height proposal.
                // fixedSize(vertical: true) puts the header outside small screens.
                .frame(maxWidth: 420)
                .frame(maxHeight: max(1, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom - 32))
                .background(ZTransferGlassSurface(cornerRadius: 22, kind: .panel)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 24)
            }
        }
        .background(PurchaseSceneReader { scene = $0 }.frame(width: 0, height: 0))
        .task {
            if access.entitlement.isPro() { selected = .lifetime }
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
            Button(AppLocalized.resource("iap_continue")) { Task { await store.purchase(.lifetime) } }
            Button(AppLocalized.resource("cancel"), role: .cancel) {}
        } message: { Text(AppLocalized.resource("iap_lifetime_notice")) }
        .alert(AppLocalized.formattedResource("feedback_qq_copied", ["%1$s": "953000922"]),
               isPresented: $copiedSupport) {
            Button(AppLocalized.resource("cd_close"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "seal.fill").font(.system(size: 24))
                .foregroundStyle(ZTransferColors.accentYellow)
                .frame(width: 42, height: 42)
                .background(ZTransferColors.accentYellow.opacity(0.16), in: Circle())
            Text(AppLocalized.resource("pro_version")).font(.system(size: 22, weight: .bold))
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }.buttonStyle(.plain).accessibilityLabel(AppLocalized.resource("cd_close"))
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
                Text(AppLocalized.resource(store.renewal.willAutoRenew.map {
                    $0 ? "iap_renewal_on" : "iap_renewal_off"
                } ?? "iap_renewal_unknown"))
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
                    .frame(width: columnWidth).foregroundStyle(ZTransferColors.secondaryText)
                Text(AppLocalized.resource(annual))
                    .fontWeight(header ? .bold : (duration ? .semibold : .heavy))
                    // Keep Android's shared column widths; fit the iOS bold
                    // glyphs without splitting short tier values mid-word.
                    .lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 2)
                    .frame(width: columnWidth)
                    .foregroundStyle(header ? ZTransferColors.accentYellow :
                        (duration ? ZTransferColors.primaryText : ZTransferColors.statusConnected))
                Text(AppLocalized.resource(lifetime))
                    .fontWeight(header ? .bold : .heavy)
                    .lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 2)
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
            row("compare_on_device_recording", "compare_unavailable", "compare_available", "compare_available")
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
                Image(systemName: selected == kind ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
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
        }.buttonStyle(.plain).disabled(!enabled || busy)
            .accessibilityAddTraits(selected == kind ? [.isSelected] : [])
    }

    private var canPurchase: Bool {
        !busy && store.products[selected] != nil && !isLifetime && access.entitlement != .unresolved
            && !(selected == .annual && access.entitlement.isPro())
    }
    private var purchaseLabel: String {
        guard let product = store.products[selected] else { return AppLocalized.resource("plan_unavailable") }
        return AppLocalized.formattedResource(selected == .annual ? "iap_annual_cta" : "buy_lifetime_cta",
                                             ["%1$s": product.displayPrice])
    }
    private func notice(_ key: String) -> some View {
        Text(AppLocalized.resource(key)).font(.system(size: 12))
            .foregroundStyle(ZTransferColors.primaryText).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZTransferColors.accentYellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private func action(_ key: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(AppLocalized.resource(key)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ZTransferColors.accentBlue)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(ZTransferGlassSurface(cornerRadius: 12, kind: .button))
        }.buttonStyle(.plain).disabled(busy)
    }
    private var legalLinks: some View {
        HStack {
            // Publication URLs remain an explicit release configuration, not
            // invented destinations. Their absence is tracked in the ledger.
            if let url = legalURL("ZTransferPrivacyPolicyURL") {
                Link(AppLocalized.resource("iap_privacy"), destination: url)
            }
            if let url = legalURL("ZTransferTermsOfUseURL") {
                Link(AppLocalized.resource("iap_terms"), destination: url)
            }
        }.font(.system(size: 11)).foregroundStyle(ZTransferColors.secondaryText)
    }
    private func legalURL(_ key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
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
    let action: () -> Void
    @State private var origin = Date()
    var body: some View {
        Button(action: action) {
            HStack(spacing: big ? 6 : 4) {
                Image(systemName: "seal.fill").font(.system(size: big ? 19 : 15))
                    .accessibilityHidden(true)
                Text(label).font(.system(size: big ? 14 : 12, weight: .bold))
                    .lineLimit(big ? 2 : 1)
            }
            .foregroundStyle(Color(red: 74 / 255, green: 50 / 255, blue: 22 / 255))
            .padding(.horizontal, 12).frame(maxWidth: big ? .infinity : nil)
            .frame(minHeight: big ? 48 : 28)
            .background {
                GeometryReader { proxy in
                    LinearGradient(colors: [Color(red: 1, green: 224 / 255, blue: 130 / 255),
                                            Color(red: 240 / 255, green: 169 / 255, blue: 59 / 255)],
                                   startPoint: .top, endPoint: .bottom)
                    TimelineView(.animation(paused: motionPaused || !enabled)) { context in
                        let phase = context.date.timeIntervalSince(origin).truncatingRemainder(dividingBy: 2.6) / 2.6
                        // Draw the moving band inside fixed bounds. Offsetting
                        // a SwiftUI gradient view expands the button's reported
                        // accessibility frame as the sheen travels offscreen.
                        Canvas { graphics, size in
                            graphics.clip(to: Path(CGRect(origin: .zero, size: size)))
                            let x = size.width * (-1 + phase * 3)
                            let band = CGRect(x: x, y: 0, width: size.width, height: size.height)
                            graphics.fill(Path(band), with: .linearGradient(
                                Gradient(colors: [.clear,
                                    Color(red: 1, green: 229 / 255, blue: 160 / 255).opacity(0.65), .clear]),
                                startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + size.width, y: 0)))
                        }
                    }.accessibilityHidden(true)
                }.clipShape(RoundedRectangle(cornerRadius: big ? 16 : 14))
            }
            .background(RoundedRectangle(cornerRadius: big ? 16 : 14)
                .fill(Color.black.opacity(0.1)).shadow(color: .black.opacity(0.15), radius: 4, y: 2))
            .opacity(enabled ? 1 : 0.5)
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(label)
    }
}
