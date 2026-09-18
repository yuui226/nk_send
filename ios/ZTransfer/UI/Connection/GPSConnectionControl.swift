import SwiftUI
import CoreLocation
import UIKit

struct GPSConnectionControl: View {
    private let headerHeight: CGFloat = 50
    private let panelGap: CGFloat = 10
    private let preferredPanelWidth: CGFloat = 280
    @ObservedObject var coordinator: GPSCoordinator
    @Binding var expanded: Bool
    @State private var panelMounted = false
    @State private var panelProgress: CGFloat = 0
    @State private var headerWidth: CGFloat = 1
    @State private var showHelp = false
    @State private var ambientHigh = false

    private var entryError: Bool {
        coordinator.state.enabled &&
            (coordinator.state.status == .apUnavailable || coordinator.state.status == .error)
    }

    private var entryAccent: Color {
        entryError ? ZTransferColors.statusError : ZTransferColors.accentBlue
    }

    private var statusAccent: Color {
        guard coordinator.state.enabled else { return ZTransferColors.statusWaiting }
        switch coordinator.state.status {
        case .off:
            return ZTransferColors.statusWaiting
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready:
            return ZTransferColors.statusConnected
        case .apUnavailable, .error:
            return ZTransferColors.statusError
        default:
            return ZTransferColors.accentBlue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let active = coordinator.state.enabled
            let breathing = !expanded && !entryError
            let ambientAlpha: CGFloat = entryError ? 0 : (
                breathing
                    ? (active
                        ? (ambientHigh ? 0.160 : 0.075)
                        : (ambientHigh ? 0.145 : 0.050))
                    : (active ? 0.105 : 0.070)
            )
            // Android uses ReleaseCommitWheel for this boolean control. Using
            // the shared wheel preserves tap-to-toggle, long-press diagnostics,
            // detent feedback and the same disabled/active material treatment.
            DetentWheel(
                label: "",
                options: [false, true],
                selected: expanded,
                optionLabel: { _ in AppLocalized.resource("gps_auto_write") },
                onCommit: { next in
                    setExpanded(next)
                },
                wheelHeight: headerHeight,
                cornerRadius: 20,
                optionFontSize: 18,
                optionFontWeight: .bold,
                accentColor: statusAccent,
                emphasized: expanded || active,
                showEmphasisBorder: false,
                showDragHint: false,
                onLongClick: {
                    UIPasteboard.general.string = gpsDiagnosticsSnapshot()
                },
                ambientEffectColor: entryAccent,
                ambientEffectAlpha: ambientAlpha
            )
            .onAppear { updateAmbientPulse() }
            .onChange(of: active) { _ in updateAmbientPulse() }
            .onChange(of: expanded) { _ in updateAmbientPulse() }
            .onChange(of: entryError) { _ in updateAmbientPulse() }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .allowsHitTesting(false)
                    .preference(key: GPSHeaderWidthPreferenceKey.self,
                                value: proxy.size.width)
            }
        }
        .onPreferenceChange(GPSHeaderWidthPreferenceKey.self) { width in
            if width > 0 { headerWidth = width }
        }
        .overlay(alignment: .topLeading) {
            if panelMounted {
                // Reuse the exact native genie host used by the Z settings
                // popup. The GPS wheel is expressed in the panel's local
                // coordinates so expansion and collapse return to the same
                // physical control instead of fading toward a generic edge.
                GeniePopupPanel(
                    content: GPSInlinePanel(coordinator: coordinator, showHelp: $showHelp),
                    targetProgress: panelProgress,
                    anchor: panelSourceAnchor,
                    panelOrigin: .zero,
                    viewport: UIScreen.main.bounds.size,
                    onCollapsed: {
                        if !expanded { panelMounted = false }
                    }
                )
                // Android uses a 250dp overflow detail and keeps a 10dp gap
                // below the 50dp header without remeasuring either card.
                .frame(width: min(preferredPanelWidth, UIScreen.main.bounds.width - 28))
                // An overlay inherits the header's 50pt height proposal.
                // Opt out vertically before applying the visual offset;
                // padding here used to leave Genie with a zero-height proposal,
                // so its live content overflowed upward over the GPS button.
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: headerHeight + panelGap)
            }
        }
        .zIndex(panelMounted ? 2 : 0)
    }

    private var panelSourceAnchor: CGRect {
        GeniePopupMotion.attachmentAnchor(
            for: CGRect(
                x: 0,
                y: -panelGap - headerHeight,
                width: headerWidth,
                height: headerHeight
            ),
            cornerRadius: 20
        )
    }

    private func setExpanded(_ next: Bool) {
        guard next != expanded || (next && !panelMounted) else { return }
        expanded = next
        if next {
            panelMounted = true
            panelProgress = 0
            // Mount and measure the live panel before starting the same mesh
            // transition used by Settings. This avoids a provisional-height
            // flash on the first expansion.
            DispatchQueue.main.async {
                guard expanded, panelMounted else { return }
                panelProgress = 1
            }
        } else {
            showHelp = false
            panelProgress = 0
        }
    }

    private func updateAmbientPulse() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { ambientHigh = false }
        guard !expanded, !entryError else { return }
        let active = coordinator.state.enabled
        DispatchQueue.main.async {
            guard !expanded, !entryError else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: active ? 2.4 : 2.8)
                .repeatForever(autoreverses: true)) {
                ambientHigh = true
            }
        }
    }
}

private struct GPSHeaderWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct GPSHelpAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

@MainActor
private func gpsDiagnosticsSnapshot() -> String {
    GPSDiagnostics.snapshot()
}

private struct GPSInlinePanel: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @ObservedObject var coordinator: GPSCoordinator
    @Binding var showHelp: Bool
    @State private var showingReset = false
    @State private var holdPressed = false
    @State private var holdConsumedTap = false
    @State private var holdCompleted = false
    @State private var sessionEstablished = false
    @State private var placeBubbleCoordinates: (latitude: Double, longitude: Double)?
    @State private var placeBubbleRequestID = 0
    @State private var previousStatusRank = 0
    @State private var statusTransitionDirection = 1
    @State private var helpAnchor: CGRect = .zero
    private var statusLabel: String {
        switch coordinator.state.status {
        case .off: return AppLocalized.resource("gps_enable")
        case .starting, .searching: return AppLocalized.resource("gps_searching")
        case .needsCamera: return AppLocalized.resource("gps_need_camera")
        case .connecting: return AppLocalized.resource("gps_connecting")
        case .pairing: return AppLocalized.resource("gps_pairing")
        case .cameraConfirm: return AppLocalized.resource("gps_camera_confirm")
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready: return AppLocalized.resource("gps_hold_to_disable")
        case .apUnavailable: return AppLocalized.resource("gps_ap_unavailable")
        case .error: return AppLocalized.resource("gps_retry")
        }
    }

    private var hasCoordinates: Bool {
        coordinator.state.latitude != nil && coordinator.state.longitude != nil
    }

    private var showConnectionSteps: Bool {
        guard !sessionEstablished else { return false }
        switch coordinator.state.status {
        case .off, .starting, .searching, .needsCamera, .connecting, .pairing, .cameraConfirm, .error:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if showConnectionSteps {
                    connectionGuide
                } else if hasCoordinates {
                    locationContent
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .id(showConnectionSteps ? "guide" : (hasCoordinates ? "location" : "empty"))
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                GeometryReader { geometry in
                    // Android uses weights 0.82 / 0.86 / 1.18 with two 8dp
                    // gaps. Keep those proportions instead of fixing the
                    // leading control to 44pt, which made the panel diverge
                    // on narrow phones.
                    let unit = max(0, geometry.size.width - 16) / 2.86
                    let leadingWidth = unit * 0.82
                    let frequencyWidth = unit * 0.86
                    let actionWidth = unit * 1.18
                    HStack(spacing: 8) {
                        leadingControl(width: leadingWidth, now: context.date)
                            .frame(width: leadingWidth)
                        frequencyControl(width: frequencyWidth, now: context.date)
                            .frame(width: frequencyWidth)
                        statusControl(width: actionWidth)
                            .frame(width: actionWidth)
                    }
                    .animation(
                        .timingCurve(0.4, 0, 0.2, 1, duration: 0.18),
                        value: coordinator.state.enabled
                    )
                    .animation(
                        .timingCurve(0.4, 0, 0.2, 1, duration: 0.18),
                        value: requiresHoldToDisable
                    )
                }
            }
            .frame(height: 42)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        // A live system blur and its rasterized animation snapshot resolve the
        // backdrop at different moments. Swapping them at the final frame used
        // to look like an extra grey mask flashing over the GPS panel. The
        // shared panel surface is visually stable in both representations, so
        // the handoff needs neither a second overlay nor a material crossfade.
        .background(ZTransferGlassSurface(cornerRadius: 24, kind: .panel))
        .coordinateSpace(name: "gps-inline-panel")
        .onPreferenceChange(GPSHelpAnchorPreferenceKey.self) { helpAnchor = $0 }
        .overlay {
            if showHelp {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showHelp = false }
                    AdaptiveTipPanel(anchor: helpAnchor, maxWidth: 244, gap: 8) {
                        gpsHelpBubble
                    }
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .alert(AppLocalized.resource("gps_clear_pairing_title"), isPresented: $showingReset) {
            Button(AppLocalized.resource("cancel"), role: .cancel) {}
            Button(AppLocalized.resource("gps_clear_pairing"), role: .destructive) { coordinator.clearPairing() }
        } message: {
            Text(AppLocalized.resource("gps_clear_pairing_message"))
        }
        .onAppear { updateSessionEvidence() }
        .onAppear { previousStatusRank = statusRank }
        .onDisappear { ZTransferHaptics.shared.cancelProgressiveHold() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { ZTransferHaptics.shared.cancelProgressiveHold() }
        }
        .onChange(of: hapticsEnabled) { enabled in
            if !enabled { ZTransferHaptics.shared.cancelProgressiveHold() }
        }
        .onChange(of: requiresHoldToDisable) { required in
            if !required { ZTransferHaptics.shared.cancelProgressiveHold() }
        }
        .onChange(of: coordinator.state.status) { _ in updateSessionEvidence() }
        .onChange(of: statusRank) { newRank in
            statusTransitionDirection = newRank >= previousStatusRank ? 1 : -1
            previousStatusRank = newRank
        }
        .onChange(of: coordinator.state.latitude) { _ in
            placeBubbleCoordinates = nil
            placeBubbleRequestID &+= 1
            coordinator.cancelPlaceLookup()
            updateSessionEvidence()
        }
        .onChange(of: coordinator.state.longitude) { _ in
            placeBubbleCoordinates = nil
            placeBubbleRequestID &+= 1
            coordinator.cancelPlaceLookup()
            updateSessionEvidence()
        }
        .onChange(of: coordinator.state.enabled) { enabled in
            if !enabled {
                sessionEstablished = false
                showHelp = false
                placeBubbleCoordinates = nil
                placeBubbleRequestID &+= 1
                coordinator.cancelPlaceLookup()
            } else {
                updateSessionEvidence()
            }
        }
        .animation(.easeInOut(duration: 0.24), value: showConnectionSteps)
        .animation(.easeInOut(duration: 0.24), value: hasCoordinates)
        .animation(.easeInOut(duration: 0.17), value: coordinator.placeLookupState)
        .animation(.easeInOut(duration: 0.18), value: showHelp)
        .task(id: placeBubbleTaskKey) {
            guard let requested = placeBubbleCoordinates else { return }
            if coordinator.placeLookupState.status == .success,
               let name = coordinator.placeLookupState.placeName {
                let coordinates = "\(formatCoordinate(requested.latitude, latitude: true)), \(formatCoordinate(requested.longitude, latitude: false))"
                UIPasteboard.general.string = "\(name)\n\(coordinates)"
            }
            let delay: UInt64
            switch coordinator.placeLookupState.status {
            case .success: delay = 2_200_000_000
            case .error: delay = 1_800_000_000
            case .idle, .loading: delay = 8_000_000_000
            }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            placeBubbleCoordinates = nil
        }
    }

    private var placeBubbleTaskKey: String {
        let name = coordinator.placeLookupState.placeName ?? ""
        return "\(placeBubbleRequestID)-\(coordinator.placeLookupState.status.rawValue)-\(name)"
    }

    private func updateSessionEvidence() {
        guard coordinator.state.enabled else {
            sessionEstablished = false
            return
        }
        if hasCoordinates {
            sessionEstablished = true
            return
        }
        switch coordinator.state.status {
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready:
            sessionEstablished = true
        default:
            break
        }
    }

    private var connectionGuide: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 10) {
                gpsPreparationRow(icon: "iphone", title: AppLocalized.resource("gps_phone_label"), detail: AppLocalized.resource("gps_phone_ready"))
                gpsPreparationRow(icon: "camera.fill", title: AppLocalized.resource("gps_camera_label"), detail: AppLocalized.resource("gps_camera_ready"), status: coordinator.bluetooth.hasSavedPairing ? AppLocalized.resource("gps_paired_badge") : nil)
                if !coordinator.bluetooth.hasSavedPairing {
                    HStack(spacing: 6) {
                        Text(AppLocalized.resource("gps_first_pairing_label"))
                            .zTransferText(size: 12, weight: .bold)
                            .foregroundStyle(ZTransferColors.accentBlue)
                        Text(AppLocalized.resource("gps_first_pairing_path"))
                            .zTransferText(size: 11)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ZTransferColors.accentBlue.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ZTransferColors.accentBlue.opacity(0.20)))
                }
            }
            .padding(.trailing, 36)
            if !coordinator.state.enabled {
                TipLightbulbButton(
                    attention: !coordinator.connectionHelpViewed, size: 30,
                    accessibilityLabel: AppLocalized.resource("gps_auto_write"),
                    embeddedInPanel: true
                ) {
                    coordinator.markConnectionHelpViewed()
                    showHelp = true
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: GPSHelpAnchorPreferenceKey.self,
                            value: proxy.frame(in: .named("gps-inline-panel"))
                        )
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private var gpsHelpBubble: some View {
        TipBubbleSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalized.resource("gps_detail_description"))
                    .zTransferText(size: 14, weight: .semibold)
                Text(AppLocalized.resource("gps_help_intro"))
                    .zTransferText(size: 12, weight: .bold)
                    .foregroundStyle(ZTransferColors.accentOrange)
                Text(AppLocalized.resource("gps_help_battery") + "\n" + AppLocalized.resource("gps_help_multitask"))
                    .zTransferText(size: 12)
                Text(AppLocalized.resource("gps_help_accuracy_note"))
                    .zTransferText(size: 12)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
        }
    }

    private var locationContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                coordinateSurface(text: formatCoordinate(coordinator.state.latitude, latitude: true), tint: ZTransferColors.accentBlue)
                    .onTapGesture { copyAndLookup() }
                coordinateSurface(text: formatCoordinate(coordinator.state.longitude, latitude: false), tint: ZTransferColors.accentOrange)
                    .onTapGesture { copyAndLookup() }
            }
            Text(AppLocalized.formattedResource("gps_altitude_value", ["%1$d": "\(Int((coordinator.state.altitudeMeters ?? 0).rounded()))"]))
                .zTransferText(size: 15, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(ZTransferColors.accentBlue.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ZTransferColors.accentBlue.opacity(0.20)))
            if placeBubbleCoordinates != nil && coordinator.placeLookupState.status == .loading {
                placeBubble(AppLocalized.resource("gps_place_loading"), loading: true)
            } else if placeBubbleCoordinates != nil && coordinator.placeLookupState.status == .success,
                      let name = coordinator.placeLookupState.placeName {
                placeBubble(name, loading: false)
            } else if placeBubbleCoordinates != nil && coordinator.placeLookupState.status == .error {
                placeBubble(AppLocalized.resource("gps_place_unavailable"), loading: false)
            }
        }
        .padding(.top, 8)
    }

    private func coordinateSurface(text: String, tint: Color) -> some View {
        Text(text)
            .zTransferText(size: 15, weight: .semibold)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tint.opacity(0.20)))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    @ViewBuilder
    private func placeBubble(_ text: String, loading: Bool) -> some View {
        HStack(spacing: 8) {
            if loading { ProgressView().tint(ZTransferColors.accentBlue) }
            Text(text).zTransferText(size: 12, weight: .medium)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(ZTransferColors.secondaryText.opacity(0.16)))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func copyAndLookup() {
        guard let latitude = coordinator.state.latitude, let longitude = coordinator.state.longitude else { return }
        UIPasteboard.general.string = "\(formatCoordinate(latitude, latitude: true)), \(formatCoordinate(longitude, latitude: false))"
        placeBubbleCoordinates = (latitude, longitude)
        placeBubbleRequestID &+= 1
        coordinator.lookupPlaceName(latitude: latitude, longitude: longitude)
    }

    private func formatCoordinate(_ value: Double?, latitude: Bool) -> String {
        guard let value else { return "--" }
        let hemisphere: String
        if latitude { hemisphere = value < 0 ? "S" : "N" } else { hemisphere = value < 0 ? "W" : "E" }
        return String(format: "%.5f°%@", abs(value), hemisphere)
    }

    @ViewBuilder
    private func gpsPreparationRow(icon: String, title: String, detail: String, status: String? = nil) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ZTransferColors.accentBlue)
                .frame(width: 30, height: 30)
                .background(ZTransferColors.accentBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).zTransferText(size: 12, weight: .bold).foregroundStyle(ZTransferColors.secondaryText)
                    if let status { Text(status).zTransferText(size: 10, weight: .medium).foregroundStyle(ZTransferColors.accentBlue) }
                }
                Text(detail).zTransferText(size: 14, weight: .medium)
            }
            Spacer(minLength: 0)
        }
    }

    private var requiresHoldToDisable: Bool {
        switch coordinator.state.status {
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready: return coordinator.state.enabled
        default: return false
        }
    }

    @ViewBuilder
    private func leadingControl(width: CGFloat, now: Date) -> some View {
        if !coordinator.state.enabled {
            Button { showingReset = true } label: {
                Image(systemName: "link.slash")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14, panel: true))
            .disabled(!coordinator.bluetooth.hasSavedPairing)
            .opacity(coordinator.bluetooth.hasSavedPairing ? 1 : 0.42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if requiresHoldToDisable {
            let value = coordinator.state.lastSentAt.map { date in
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
                return formatter.string(from: date)
            } ?? "--:--:--"
            DetentWheel(label: "", options: [value], selected: value,
                        optionLabel: { $0 }, onCommit: { _ in }, rowHeight: 16,
                        wheelHeight: 42, readOnly: true, cornerRadius: 14,
                        optionFontSize: 13, accentColor: ZTransferColors.accentBlue,
                        emphasized: coordinator.state.lastSentAt != nil,
                        showEmphasisBorder: false)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            Color.clear
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func frequencyControl(width: CGFloat, now: Date) -> some View {
        if requiresHoldToDisable {
            let remaining = coordinator.state.lastSentAt.map {
                max(0, Int(ceil(Double(coordinator.frequency.rawValue) - now.timeIntervalSince($0))))
            }
            let text = remaining.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "--:--"
            DetentWheel(label: "", options: [text], selected: text,
                        optionLabel: { $0 }, onCommit: { _ in }, rowHeight: 16,
                        wheelHeight: 42, readOnly: true, cornerRadius: 14,
                        optionFontSize: 13, accentColor: ZTransferColors.statusConnected,
                        emphasized: true, showEmphasisBorder: false)
        } else if !coordinator.state.enabled {
            DetentWheel(label: AppLocalized.resource("gps_update_frequency_label"),
                        options: GPSUpdateFrequency.allCases, selected: coordinator.frequency,
                        optionLabel: { $0.title }, onCommit: coordinator.setFrequency,
                        rowHeight: 16, wheelHeight: 42, enabled: true,
                        cornerRadius: 14, optionFontSize: 13,
                        accentColor: ZTransferColors.accentBlue, onDetent: {})
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            Color.clear
                .transition(.opacity)
        }
    }

    private func statusControl(width: CGFloat) -> some View {
        Button {
            guard !requiresHoldToDisable, !holdConsumedTap else { return }
            ZTransferHaptics.shared.tick()
            if !coordinator.state.enabled { coordinator.setEnabled(true) }
            else if coordinator.state.status == .error {
                switch coordinator.locationAuthorizationStatus {
                case .denied, .restricted:
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settings)
                    }
                default:
                    coordinator.retry()
                }
            }
            else if !requiresHoldToDisable && coordinator.state.status != .apUnavailable { coordinator.setEnabled(false) }
        } label: {
            ZStack {
                Text(statusLabel)
                    .id(statusLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ZTransferColors.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: statusTransitionDirection > 0 ? .bottom : .top)
                            .combined(with: .opacity),
                        removal: .move(edge: statusTransitionDirection > 0 ? .top : .bottom)
                            .combined(with: .opacity)
                    ))
            }
            // Keep the material and both transition frames at the Android
            // button's real 42pt size. Previously only the outer Button was
            // stretched, so the glass stayed at the text's intrinsic height
            // and an outgoing label could render beyond the rounded capsule.
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(ZTransferGlassButtonStyle(
            cornerRadius: 14,
            panel: true,
            disabledAlpha: 1
        ))
        // Android's GpsStatusButton gives a held-to-disable press a short
        // foreground glow (90ms in, 170ms out) while the 800ms progressive
        // hold is running. Keep the glow inside the button so it never
        // changes the measured width or the neighbouring wheel's layout.
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .fill(ZTransferColors.primaryText.opacity(0.055 * (holdPressed ? 1 : 0)))
                .allowsHitTesting(false)
        }
        .onLongPressGesture(
            minimumDuration: 0.8,
            maximumDistance: 24,
            pressing: { pressing in
                if pressing {
                    holdConsumedTap = requiresHoldToDisable
                    holdCompleted = false
                    guard requiresHoldToDisable else { return }
                    ZTransferHaptics.shared.startProgressiveHold()
                } else {
                    if !holdCompleted { ZTransferHaptics.shared.cancelProgressiveHold() }
                    // Suppress only the synthetic tap emitted by this long
                    // press. Reset on the next run-loop so a later tap on the
                    // newly displayed “开启GPS” state remains usable.
                    DispatchQueue.main.async { holdConsumedTap = false }
                }
                withAnimation(.easeInOut(duration: pressing ? 0.09 : 0.17)) {
                    holdPressed = pressing
                }
            },
            perform: {
                guard requiresHoldToDisable else { return }
                holdCompleted = true
                ZTransferHaptics.shared.completeProgressiveHold()
                withAnimation(.easeInOut(duration: 0.17)) { holdPressed = false }
                coordinator.setEnabled(false)
            }
        )
        .animation(.easeInOut(duration: 0.22), value: statusLabel)
    }

    private var statusRank: Int {
        switch coordinator.state.status {
        case .off: return 0
        case .starting, .searching: return 1
        case .connecting: return 2
        case .pairing: return 3
        case .cameraConfirm: return 4
        case .pairingSuccess, .connected, .writing, .waitingFix, .ready: return 5
        case .needsCamera: return 6
        case .apUnavailable: return 7
        case .error: return 8
        }
    }
}
