import SwiftUI
import Combine
import CoreLocation
import UIKit

struct GPSConnectionControl: View {
    private let headerHeight: CGFloat = 50
    private let panelGap: CGFloat = 10
    private let preferredPanelWidth: CGFloat = 280
    let coordinator: GPSCoordinator
    @StateObject private var entry: GPSEntryPresentation
    @Binding var expanded: Bool
    @Binding var showingResetPairing: Bool
    /// Page space below this control, measured by ConnectionPage's layout.
    let availableHeight: CGFloat
    @State private var showHelp = false
    @State private var ambientOrigin = Date()
    @Environment(\.scenePhase) private var scenePhase
    @State private var hintText: String?
    @State private var panelVisible = false
    #if DEBUG
    var didRender: (() -> Void)?
    #endif

    init(coordinator: GPSCoordinator, expanded: Binding<Bool>, showingResetPairing: Binding<Bool>,
         availableHeight: CGFloat) {
        self.coordinator = coordinator
        _entry = StateObject(wrappedValue: GPSEntryPresentation(coordinator))
        _expanded = expanded
        _showingResetPairing = showingResetPairing
        self.availableHeight = availableHeight
        _panelVisible = State(initialValue: expanded.wrappedValue)
    }

    private var entryError: Bool { entry.snapshot.accent == .error }
    private var entryAccent: Color { entryError ? ZTransferColors.statusError : ZTransferColors.accentBlue }
    private var statusAccent: Color {
        switch entry.snapshot.accent {
        case .waiting: return ZTransferColors.statusWaiting
        case .connected: return ZTransferColors.statusConnected
        case .error: return ZTransferColors.statusError
        case .blue: return ZTransferColors.accentBlue
        }
    }

    var body: some View {
        #if DEBUG
        let _ = didRender?()
        #endif
        VStack(alignment: .leading, spacing: 0) {
            let active = entry.snapshot.enabled
            let breathing = !expanded && !entryError
            let ambientPulse = NativeAmbientPulse(origin: ambientOrigin,
                minimum: active ? 0.075 : 0.050, maximum: active ? 0.160 : 0.145,
                halfPeriod: active ? 2.4 : 2.8,
                restingOpacity: entryError ? 0 : (active ? 0.105 : 0.070),
                breathing: breathing, paused: scenePhase != .active)
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
                    hintText = AppLocalized.resource("code_copied")
                },
                ambientEffectColor: entryAccent,
                ambientEffectPulse: ambientPulse,
                followsButtonSkin: true,
                prominentPressFeedback: true
            )
            .onAppear {
                updateAmbientPulse()
            }
            .onChange(of: active) { _ in updateAmbientPulse() }
            .onChange(of: expanded) { next in
                if next { panelVisible = true }
                updateAmbientPulse()
            }
            .onChange(of: entryError) { _ in updateAmbientPulse() }
        }
        .geniePopupAnchor(.gps)
        .accessibilityIdentifier("popup-trigger-gps")
        .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
            if let anchor = anchors[.gps] {
                GeometryReader { proxy in
                    let button = proxy[anchor]
                    let panelWidth = min(preferredPanelWidth, UIScreen.main.bounds.width - 28)
                    let panelTop = button.maxY + panelGap
                    let source = GeniePopupMotion.attachmentAnchor(
                        for: button, cornerRadius: 20
                    ).offsetBy(dx: -button.minX, dy: -panelTop)
                    GeniePopupPanel(
                        content: GPSInlinePanel(
                            coordinator: coordinator,
                            countdownActive: expanded || panelVisible,
                            showHelp: $showHelp,
                            showingResetPairing: $showingResetPairing,
                            hintText: $hintText,
                            helpViewportHeight: max(1, availableHeight - panelTop)
                        ),
                        trigger: .gps,
                        targetProgress: expanded ? 1 : 0,
                        anchorX: source.midX / panelWidth,
                        anchorWidth: source.width / panelWidth,
                        anchorGap: -source.maxY,
                        onSettled: { progress in
                            if progress == 0 && !expanded && panelVisible { panelVisible = false }
                        }
                    )
                    .frame(width: panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: button.minX, y: panelTop)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hintText {
                Text(hintText)
                    .zTransferText(size: 11, weight: .medium)
                    .foregroundStyle(ZTransferColors.accentBlue)
                    .offset(y: headerHeight + 5)
                    .transition(.opacity)
            }
        }
        .zIndex(expanded || panelVisible ? 2 : 0)
        .task(id: hintText) {
            guard hintText != nil else { return }
            try? await Task.sleep(for: .milliseconds(1_800))
            guard !Task.isCancelled else { return }
            hintText = nil
        }
    }

    private func setExpanded(_ next: Bool) {
        guard next != expanded else { return }
        expanded = next
        if !next {
            showHelp = false
        }
    }

    private func updateAmbientPulse() {
        ambientOrigin = Date()
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
    let countdownActive: Bool
    @StateObject private var lastSentText = GPSLastSentText()
    @Binding var showHelp: Bool
    @Binding var showingResetPairing: Bool
    @Binding var hintText: String?
    let helpViewportHeight: CGFloat
    @State private var holdPressed = false
    @State private var holdConsumedTap = false
    @State private var holdCompleted = false
    @GestureState private var statusHoldActive = false
    @State private var sessionEstablished = false
    @State private var placeBubbleCoordinates: (latitude: Double, longitude: Double)?
    @State private var placeBubbleRequestID = 0
    @State private var previousStatusRank = 0
    @State private var statusTransitionDirection = 1
    @State private var updateBurstID = 0
    @State private var updateBurstProgress: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
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
            controlRow()
                .frame(height: 42)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        // Keep the embedded panel surface stable while the shared live-content
        // transition changes its outline and scale.
        .background(ZTransferGlassSurface(cornerRadius: 24, kind: .panel))
        .coordinateSpace(name: "gps-inline-panel")
        .overlayPreferenceValue(TipPopupAnchorPreferenceKey.self) { anchors in
            TipPopupLayer(isPresented: showHelp) {
                if let anchor = anchors[.gps] {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showHelp = false }
                        AdaptiveTipPanel(anchor: anchor, maxWidth: 244, gap: 8,
                                         availableHeight: helpViewportHeight) {
                            gpsHelpBubble
                        }
                    }
                    .zIndex(3)
                }
            }
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
        .onChange(of: coordinator.state.status) { status in
            if status == .writing { updateBurstID &+= 1 }
        }
        .onChange(of: coordinator.state.message) { message in
            guard coordinator.state.status == .error, let message else { return }
            if message == AppLocalized.resource("gps_permission_required") ||
                message == AppLocalized.resource("gps_bluetooth_required") {
                hintText = message
            }
        }
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
        .task(id: updateBurstID) {
            guard updateBurstID > 0 else { return }
            updateBurstProgress = 0
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.085)) {
                updateBurstProgress = 1
            }
            try? await Task.sleep(for: .milliseconds(85))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.36)) {
                updateBurstProgress = 0
            }
        }
        .task(id: placeBubbleTaskKey) {
            guard let requested = placeBubbleCoordinates else { return }
            if coordinator.placeLookupState.status == .success,
               let name = coordinator.placeLookupState.placeName {
                UIPasteboard.general.string = GPSCoordinateFormat.clipboard(
                    latitude: requested.latitude, longitude: requested.longitude, placeName: name
                )
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
                // The bulb only overlaps the two preparation rows. Keep its
                // 36pt reservation local to those rows so the first-pairing
                // instruction below can use the panel's full content width,
                // matching Android and avoiding a two-character orphan line.
                VStack(alignment: .leading, spacing: 10) {
                    gpsPreparationRow(icon: "iphone", title: AppLocalized.resource("gps_phone_label"), detail: AppLocalized.resource("gps_phone_ready"))
                    gpsPreparationRow(icon: "camera.fill", title: AppLocalized.resource("gps_camera_label"), detail: AppLocalized.resource("gps_camera_ready"), status: coordinator.bluetooth.hasSavedPairing ? AppLocalized.resource("gps_paired_badge") : nil)
                }
                .padding(.trailing, 36)
                if !coordinator.bluetooth.hasSavedPairing {
                    HStack(spacing: 6) {
                        Text(AppLocalized.resource("gps_first_pairing_label"))
                            .zTransferText(size: 12, weight: .bold)
                            .foregroundStyle(ZTransferColors.accentBlue)
                        Text(AppLocalized.resource("gps_first_pairing_path"))
                            .zTransferText(size: 10)
                            .lineSpacing(3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ZTransferColors.accentBlue.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ZTransferColors.accentBlue.opacity(0.20)))
                }
            }
            TipLightbulbButton(
                attention: !coordinator.connectionHelpViewed && !coordinator.state.enabled,
                size: 30,
                accessibilityLabel: AppLocalized.resource("gps_auto_write"),
                embeddedInPanel: true
            ) {
                guard !coordinator.state.enabled else { return }
                coordinator.markConnectionHelpViewed()
                showHelp = true
            }
            .opacity(coordinator.state.enabled ? 0 : 1)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.14),
                       value: coordinator.state.enabled)
            .scaleEffect(coordinator.state.enabled ? 0.92 : 1)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16),
                       value: coordinator.state.enabled)
            .allowsHitTesting(!coordinator.state.enabled)
            .tipPopupAnchor(.gps)
        }
        .padding(.top, 12)
    }

    private var gpsHelpBubble: some View {
        TipBubbleContent {
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
            .overlay(alignment: .top) {
                if let bubble = placeBubblePresentation {
                    placeBubble(bubble.text, loading: bubble.loading)
                        .frame(maxWidth: 270)
                        .offset(y: 50)
                        .zIndex(2)
                }
            }
            .zIndex(2)
            Text(AppLocalized.formattedResource("gps_altitude_value", ["%1$d": "\(Int((coordinator.state.altitudeMeters ?? 0).rounded()))"]))
                .zTransferText(size: 15, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(ZTransferColors.statusConnected.opacity(detailFillOpacity), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ZTransferColors.statusConnected.opacity(detailBorderOpacity)))
        }
        .padding(.top, 8)
    }

    private var detailFillOpacity: Double { colorScheme == .dark ? 0.10 : 0.065 }
    private var detailBorderOpacity: Double { colorScheme == .dark ? 0.28 : 0.20 }

    private var placeBubblePresentation: (text: String, loading: Bool)? {
        guard placeBubbleCoordinates != nil else { return nil }
        switch coordinator.placeLookupState.status {
        case .idle, .loading:
            return (AppLocalized.resource("gps_place_loading"), true)
        case .success:
            guard let name = coordinator.placeLookupState.placeName else { return nil }
            return (name, false)
        case .error:
            return (AppLocalized.resource("gps_place_unavailable"), false)
        }
    }

    private func coordinateSurface(text: String, tint: Color) -> some View {
        Text(text)
            .zTransferText(size: 15, weight: .semibold)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(tint.opacity(detailFillOpacity), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tint.opacity(detailBorderOpacity)))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    @ViewBuilder
    private func placeBubble(_ text: String, loading: Bool) -> some View {
        HStack(spacing: 8) {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(ZTransferColors.accentBlue)
                    .frame(width: 19, height: 19)
            }
            Text(text)
                .zTransferText(size: 14, weight: loading ? .regular : .medium)
                .lineLimit(8)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 270, alignment: .leading)
        .background(ZTransferGlassSurface(cornerRadius: 20, kind: .panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1))
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .offset(y: 8))
        ))
    }

    private func copyAndLookup() {
        guard let latitude = coordinator.state.latitude, let longitude = coordinator.state.longitude else { return }
        UIPasteboard.general.string = GPSCoordinateFormat.clipboard(latitude: latitude, longitude: longitude)
        placeBubbleCoordinates = (latitude, longitude)
        placeBubbleRequestID &+= 1
        coordinator.lookupPlaceName(latitude: latitude, longitude: longitude)
    }

    private func formatCoordinate(_ value: Double?, latitude: Bool) -> String {
        GPSCoordinateFormat.value(value, latitude: latitude) ?? "--"
    }

    @ViewBuilder
    private func gpsPreparationRow(icon: String, title: String, detail: String, status: String? = nil) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ZTransferColors.accentBlue)
                .frame(width: 30, height: 30)
                .background(ZTransferColors.accentBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).zTransferText(size: 12, weight: .bold).foregroundStyle(ZTransferColors.secondaryText)
                    if let status {
                        Text(status)
                            .zTransferText(size: 9, weight: .medium)
                            .foregroundStyle(ZTransferColors.accentBlue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                ZTransferColors.accentBlue.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay(Capsule().stroke(
                                ZTransferColors.accentBlue.opacity(0.18),
                                lineWidth: 1
                            ))
                    }
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

    private func controlRow() -> some View {
        GeometryReader { geometry in
            // Android uses weights 0.82 / 0.86 / 1.18 with two 8dp gaps.
            let unit = max(0, geometry.size.width - 16) / 2.86
            let leadingWidth = unit * 0.82
            let frequencyWidth = unit * 0.86
            let actionWidth = unit * 1.18
            HStack(spacing: 8) {
                leadingControl()
                    .frame(width: leadingWidth)
                frequencyControl()
                    .frame(width: frequencyWidth)
                statusControl()
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

    @ViewBuilder
    private func leadingControl() -> some View {
        if !coordinator.state.enabled {
            Button { showingResetPairing = true } label: {
                ConnectionPairingIcon(kind: .unlink)
                    .frame(width: 18, height: 18)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14, panel: true))
            .disabled(!coordinator.bluetooth.hasSavedPairing)
            .opacity(coordinator.bluetooth.hasSavedPairing ? 1 : 0.42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if requiresHoldToDisable {
            let value = lastSentText.text(for: coordinator.state.lastSentAt)
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
    private func frequencyControl() -> some View {
        if requiresHoldToDisable {
            GPSCountdownScope(lastSentAt: coordinator.state.lastSentAt,
                              frequency: coordinator.frequency, active: countdownActive) { text in
                DetentWheel(label: "", options: [text], selected: text,
                            optionLabel: { $0 }, onCommit: { _ in }, rowHeight: 16,
                            wheelHeight: 42, readOnly: true, cornerRadius: 14,
                            optionFontSize: 13, accentColor: ZTransferColors.statusConnected,
                            emphasized: true, showEmphasisBorder: false,
                            ambientEffectColor: ZTransferColors.statusConnected,
                            ambientEffectAlpha: 0.18 * updateBurstProgress)
            }
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

    private func statusControl() -> some View {
        Button {
            guard !requiresHoldToDisable, !holdConsumedTap else { return }
            ZTransferHaptics.shared.tick()
            if !coordinator.state.enabled { coordinator.setEnabled(true) }
            else if coordinator.state.status == .error {
                let message = coordinator.state.message ?? ""
                let needsSettings = message == AppLocalized.resource("gps_bluetooth_required") ||
                    message == AppLocalized.resource("gps_permission_required") ||
                    !CLLocationManager.locationServicesEnabled()
                if needsSettings {
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settings)
                    }
                } else {
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
        .accessibilityIdentifier("gps-status-control")
        // Android's GpsStatusButton gives a held-to-disable press a short
        // foreground glow (90ms in, 170ms out) while the 800ms progressive
        // hold is running. Keep the glow inside the button so it never
        // changes the measured width or the neighbouring wheel's layout.
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .fill(ZTransferColors.primaryText.opacity(0.055 * (holdPressed ? 1 : 0)))
                .allowsHitTesting(false)
        }
        // Android GpsStatusButton puts the hold surface above its button.
        // A normal-priority long press competes with the native Button and
        // can lose recognition. Claim only the states that require holding.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.8, maximumDistance: 24)
                .updating($statusHoldActive) { _, active, _ in active = true }
                .onEnded { completed in
                    guard completed, requiresHoldToDisable else { return }
                    holdConsumedTap = true
                    holdCompleted = true
                    ZTransferHaptics.shared.completeProgressiveHold()
                    withAnimation(.easeInOut(duration: 0.17)) { holdPressed = false }
                    coordinator.setEnabled(false)
                },
            including: requiresHoldToDisable ? .all : .subviews
        )
        .onChange(of: statusHoldActive) { pressing in
            if pressing {
                holdConsumedTap = requiresHoldToDisable
                holdCompleted = false
                guard requiresHoldToDisable else { return }
                ZTransferHaptics.shared.startProgressiveHold()
            } else {
                if !holdCompleted { ZTransferHaptics.shared.cancelProgressiveHold() }
                DispatchQueue.main.async { holdConsumedTap = false }
            }
            withAnimation(.easeInOut(duration: pressing ? 0.09 : 0.17)) { holdPressed = pressing }
        }
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


/// The entry uses only enabled and its status color. Coordinates, BLE names,
/// frequency and place-query results remain owned/observed by the detail panel.
@MainActor
final class GPSEntryPresentation: ObservableObject {
    struct Snapshot: Equatable {
        enum Accent { case waiting, connected, error, blue }
        let enabled: Bool
        let accent: Accent
        init(_ state: GPSState) {
            enabled = state.enabled
            if !enabled { accent = .waiting; return }
            switch state.status {
            case .off: accent = .waiting
            case .pairingSuccess, .connected, .writing, .waitingFix, .ready: accent = .connected
            case .apUnavailable, .error: accent = .error
            default: accent = .blue
            }
        }
    }
    @Published private(set) var snapshot: Snapshot
    private var observation: AnyCancellable?
    init(_ coordinator: GPSCoordinator) {
        snapshot = Snapshot(coordinator.state)
        observation = coordinator.$state.map(Snapshot.init).removeDuplicates().sink { [weak self] next in
            if self?.snapshot != next { self?.snapshot = next }
        }
    }
}

/// Android remembers HH:mm:ss by lastSentAt. All callers are main-actor UI;
/// one formatter and one last value avoid allocation on every location update.
@MainActor
final class GPSLastSentText: ObservableObject {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()
    private var previous: Date?
    private var value = "--:--:--"
    #if DEBUG
    private(set) var formatCount = 0
    #endif
    func text(for date: Date?) -> String {
        guard previous != date else { return value }
        previous = date
        if let date {
            #if DEBUG
            formatCount += 1
            #endif
            value = formatter.string(from: date)
        }
        else { value = "--:--:--" }
        return value
    }
}

struct GPSCountdownSchedule: TimelineSchedule {
    let active: Bool
    let end: Date?
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard active, let end else { return AnySequence(CollectionOfOne(startDate)) }
        // Include the first zero frame, then sleep until a new successful
        // write changes the deadline. Keep the existing one-second cadence.
        return AnySequence {
            var next: Date? = startDate
            return AnyIterator<Date> {
                guard let current = next else { return nil }
                next = current < end ? current.addingTimeInterval(1) : nil
                return current
            }
        }
    }
}

/// Only countdown digits tick. The last-sent wheel, status/hold button and
/// location panel keep their identity and do not rebuild once per second.
struct GPSCountdownScope<Content: View>: View {
    let lastSentAt: Date?
    let frequency: GPSUpdateFrequency
    let active: Bool
    @ViewBuilder let content: (String) -> Content
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(GPSCountdownSchedule(active: active && scenePhase == .active,
            end: lastSentAt?.addingTimeInterval(Double(frequency.rawValue)))) { context in
            let remaining = lastSentAt.map {
                max(0, Int(ceil(Double(frequency.rawValue) - context.date.timeIntervalSince($0))))
            }
            content(remaining.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "--:--")
        }
    }
}
