import SwiftUI
import CoreLocation
import UIKit

struct GPSConnectionControl: View {
    @ObservedObject var coordinator: GPSCoordinator
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation) { context in
                let active = coordinator.state.enabled
                let period = active ? 2.4 : 2.8
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let ambientAlpha = active
                    ? 0.075 + 0.085 * CGFloat((sin(phase * 2 * .pi) + 1) / 2)
                    : 0.050 + 0.095 * CGFloat((sin(phase * 2 * .pi) + 1) / 2)
                // Android uses ReleaseCommitWheel for this boolean control. Using
                // the shared wheel preserves tap-to-toggle, long-press diagnostics,
                // detent feedback and the same disabled/active material treatment.
                DetentWheel(
                    label: "",
                    options: [false, true],
                    selected: expanded,
                    optionLabel: { _ in AppLocalized.resource("gps_auto_write") },
                    onCommit: { next in
                        let animation: Animation = next
                            ? .easeInOut(duration: 0.26).delay(0.025)
                            : .easeInOut(duration: 0.22).delay(0.02)
                        withAnimation(animation) { expanded = next }
                    },
                    wheelHeight: 50,
                    cornerRadius: 20,
                    optionFontSize: 18,
                    optionFontWeight: .bold,
                    accentColor: active ? ZTransferColors.accentBlue : ZTransferColors.secondaryText,
                    emphasized: expanded || active,
                    showEmphasisBorder: false,
                    showDragHint: false,
                    onLongClick: {
                        UIPasteboard.general.string = gpsDiagnosticsSnapshot(coordinator)
                    },
                    ambientEffectColor: active ? ZTransferColors.accentBlue : ZTransferColors.background,
                    ambientEffectAlpha: ambientAlpha,
                )
            }
        }
        .overlay(alignment: .topLeading) {
            if expanded {
                GPSInlinePanel(coordinator: coordinator)
                    // HomeScreen.kt uses GPS_DETAIL_PANEL_WIDTH = 250.dp and
                    // deliberately places it in an overflow layer. Overlay
                    // keeps the two connection cards at their measured width.
                    .frame(width: 250)
                    .padding(.top, 60)
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: 0.965, anchor: .topLeading))
                            .combined(with: .move(edge: .top)),
                        removal: .opacity
                            .combined(with: .scale(scale: 0.975, anchor: .topLeading))
                            .combined(with: .move(edge: .top))
                    ))
            }
        }
        // Android GpsDetailOverflowLayer uses 260ms enter/220ms exit motion;
        // keep the panel mounted in the overlay so the neighbouring card is
        // never remeasured during either direction.
        .animation(expanded
            ? .easeInOut(duration: 0.26).delay(0.025)
            : .easeInOut(duration: 0.22).delay(0.02), value: expanded)
    }
}

@MainActor
private func gpsDiagnosticsSnapshot(_ coordinator: GPSCoordinator) -> String {
    let state = coordinator.state
    let latitude = state.latitude.map { String($0) } ?? "-"
    let longitude = state.longitude.map { String($0) } ?? "-"
    let altitude = state.altitudeMeters.map { String($0) } ?? "-"
    let accuracy = state.accuracyMeters.map { String($0) } ?? "-"
    return [
        "status=\(state.status.rawValue)",
        "enabled=\(state.enabled)",
        "camera=\(state.cameraName ?? "-")",
        "latitude=\(latitude)",
        "longitude=\(longitude)",
        "altitude=\(altitude)",
        "accuracy=\(accuracy)",
        "message=\(state.message ?? "-")",
    ].joined(separator: "\n")
}

private struct GPSInlinePanel: View {
    @ObservedObject var coordinator: GPSCoordinator
    @State private var showingReset = false
    @State private var holdCompleted = false
    @State private var sessionEstablished = false
    @State private var showHelp = false
    @State private var placeState = GPSPlaceState.idle

    private enum GPSPlaceState: Equatable {
        case idle
        case loading
        case success(String)
        case error
    }

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
                }
            }
            .frame(height: 42)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 1))
        .alert(AppLocalized.resource("gps_clear_pairing_title"), isPresented: $showingReset) {
            Button(AppLocalized.resource("cancel"), role: .cancel) {}
            Button(AppLocalized.resource("gps_clear_pairing"), role: .destructive) { coordinator.clearPairing() }
        } message: {
            Text(AppLocalized.resource("gps_clear_pairing_message"))
        }
        .onAppear { updateSessionEvidence() }
        .onChange(of: coordinator.state.status) { _ in updateSessionEvidence() }
        .onChange(of: coordinator.state.latitude) { _ in
            placeState = .idle
            coordinator.cancelPlaceLookup()
            updateSessionEvidence()
        }
        .onChange(of: coordinator.state.longitude) { _ in
            placeState = .idle
            coordinator.cancelPlaceLookup()
            updateSessionEvidence()
        }
        .onChange(of: coordinator.state.enabled) { enabled in
            if !enabled {
                sessionEstablished = false
                placeState = .idle
                showHelp = false
                coordinator.cancelPlaceLookup()
            } else {
                updateSessionEvidence()
            }
        }
        .animation(.easeInOut(duration: 0.24), value: showConnectionSteps)
        .animation(.easeInOut(duration: 0.24), value: hasCoordinates)
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
                Button { showHelp = true } label: {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ZTransferColors.accentOrange)
                        .frame(width: 30, height: 30)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ZTransferColors.secondaryText.opacity(0.14)))
                        .scaleEffect(coordinator.connectionHelpViewed ? 1 : 1.06)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHelp, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
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
                    .padding(14)
                    .frame(width: 244)
                }
                .onChange(of: showHelp) { isPresented in
                    if isPresented { coordinator.markConnectionHelpViewed() }
                }
            }
        }
        .padding(.top, 12)
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
            if case .loading = placeState {
                placeBubble(AppLocalized.resource("gps_place_loading"), loading: true)
            } else if case .success(let name) = placeState {
                placeBubble(name, loading: false)
            } else if case .error = placeState {
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
        placeState = .loading
        coordinator.lookupPlaceName(latitude: latitude, longitude: longitude) { name in
            if let name {
                withAnimation(.easeInOut(duration: 0.17)) { placeState = .success(name) }
            } else {
                withAnimation(.easeInOut(duration: 0.17)) { placeState = .error }
            }
        }
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
                    .frame(maxWidth: .infinity).frame(height: 42)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
            .disabled(!coordinator.bluetooth.hasSavedPairing)
            .opacity(coordinator.bluetooth.hasSavedPairing ? 1 : 0.42)
        } else if requiresHoldToDisable {
            let value = coordinator.state.lastSentAt.map { date in
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                return formatter.string(from: date)
            } ?? "--:--:--"
            DetentWheel(label: "", options: [value], selected: value,
                        optionLabel: { $0 }, onCommit: { _ in }, rowHeight: 16,
                        wheelHeight: 42, readOnly: true, cornerRadius: 14,
                        optionFontSize: 13, accentColor: ZTransferColors.accentBlue,
                        emphasized: coordinator.state.lastSentAt != nil,
                        showEmphasisBorder: false)
        } else {
            Color.clear
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
        } else {
            DetentWheel(label: AppLocalized.resource("gps_update_frequency_label"),
                        options: GPSUpdateFrequency.allCases, selected: coordinator.frequency,
                        optionLabel: { $0.title }, onCommit: coordinator.setFrequency,
                        rowHeight: 16, wheelHeight: 42, enabled: !coordinator.state.enabled,
                        cornerRadius: 14, optionFontSize: 13,
                        accentColor: ZTransferColors.accentBlue)
        }
    }

    private func statusControl(width: CGFloat) -> some View {
        Button(statusLabel) {
            if holdCompleted { holdCompleted = false; return }
            if !coordinator.state.enabled { coordinator.setEnabled(true) }
            else if coordinator.state.status == .error { coordinator.retry() }
            else if !requiresHoldToDisable && coordinator.state.status != .apUnavailable { coordinator.setEnabled(false) }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(ZTransferColors.primaryText)
        .frame(maxWidth: .infinity).frame(height: 42)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ZTransferColors.secondaryText.opacity(0.15)))
        .onLongPressGesture(minimumDuration: 0.7) {
            if coordinator.state.enabled {
                holdCompleted = true
                coordinator.setEnabled(false)
            }
        }
    }
}
