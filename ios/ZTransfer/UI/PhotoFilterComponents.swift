import SwiftUI

/// Progress is a leaf observation; scan updates must not remeasure the popup,
/// recreate date drafts or touch the other filter controls. Retains the existing
/// iOS linear 900 ms / reverse pulse (Android uses FastOutSlowIn; see P06 ledger).
@MainActor
struct PhotoRatingProgressChip: View {
    @ObservedObject var progress: PhotoRatingProgress
    let enabled: Bool
    let visible: Bool
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var origin = Date()
    #if DEBUG
    var didRender: ((String) -> Void)? = nil
    #endif

    private var breathing: Bool { enabled && progress.snapshot.loading }
    var body: some View {
        let value = progress.snapshot
        let label = !enabled ? AppLocalized.resource("filter_rating_off")
            : value.waitingForRange ? "0/\(value.total)"
            : value.loading ? "\(min(value.completed, value.total))/\(value.total)"
            : AppLocalized.resource("filter_rating_on")
        let accent = !enabled ? ZTransferColors.accentBlue
            : value.waitingForRange ? ZTransferColors.accentYellow
            : value.loading ? ZTransferColors.accentBlue : ZTransferColors.statusConnected
        #if DEBUG
        let _ = didRender?(label)
        #endif
        NativeAttentionHost(configuration: NativeAttentionConfiguration(
            kind: .opacityPulse(minimum: 0.72, maximum: 1, halfPeriod: 0.9),
            origin: origin, enabled: breathing, paused: !visible || scenePhase != .active
        )) {
            FilterChip(label: label, selected: enabled, accentColor: accent, minHeight: 34,
                       cornerLabel: AppLocalized.resource("filter_rating_enabled"),
                       onLongPress: enabled ? {
                           UIPasteboard.general.string = PhotoRatingDiagnostics.snapshot()
                       } : nil, action: action)
                .accessibilityLabel(AppLocalized.resource("filter_rating_enabled"))
        }
        .frame(width: 81, height: 34)
        .onChange(of: breathing) { if $0 { origin = Date() } }
    }
}

struct FilterChip: View {
    let label: String?
    let selected: Bool
    var systemImage: String? = nil
    var burstIcon = false
    var accentColor: Color = ZTransferColors.accentBlue
    var minHeight: CGFloat = 34
    var cornerLabel: String? = nil
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        let icon: ((Color) -> AnyView)? = {
            guard burstIcon || systemImage != nil else { return nil }
            return { tint in
                if burstIcon {
                    return AnyView(BurstGlyph(size: 13).foregroundStyle(tint))
                }
                return AnyView(Image(systemName: systemImage!)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint))
            }
        }()
        return DetentWheel(
            label: cornerLabel ?? "",
            options: [label ?? ""],
            selected: label ?? "",
            optionLabel: { $0 },
            onCommit: { _ in },
            wheelHeight: minHeight,
            enabled: true,
            cornerRadius: 10,
            optionFontSize: 12,
            optionFontWeight: selected ? .semibold : .medium,
            optionTextColor: selected ? accentColor : ZTransferColors.secondaryText,
            accentColor: accentColor,
            emphasized: selected,
            showEmphasisBorder: true,
            showDragHint: false,
            onActivated: action,
            onLongClick: onLongPress,
            centerIcon: icon
        )
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text(label ?? ""))
    }
}

struct DateEndpointEditor: View {
    let label: String
    @Binding var date: Date
    let years: [Int]
    private let dates = PhotoFilterDates()
    private var calendar: Calendar { dates.calendar }
    var body: some View {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let days = Array(1...calendar.range(of: .day, in: .month, for: date)!.count)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                Spacer(minLength: 0)
                Text(dates.shortDate(date))
                    .zTransferText(size: ZTransferMetrics.caption)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            GeometryReader { geometry in
                let available = max(0, geometry.size.width - 16)
                let unit = available / 3.3
                HStack(spacing: 8) {
                    DetentWheel(label: AppLocalized.resource("date_year"), options: years, selected: year, optionLabel: String.init, onCommit: { date = dates.clamped(year: $0, month: month, day: day) }, rowHeight: 18, wheelHeight: 50)
                        .frame(width: unit * 1.3)
                    DetentWheel(label: AppLocalized.resource("date_month"), options: Array(1...12), selected: month, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = dates.clamped(year: year, month: $0, day: day) }, rowHeight: 18, wheelHeight: 50)
                        .frame(width: unit)
                    DetentWheel(label: AppLocalized.resource("date_day"), options: days, selected: day, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = dates.clamped(year: year, month: month, day: $0) }, rowHeight: 18, wheelHeight: 50)
                        .frame(width: unit)
                }
            }
            .frame(height: 50)
        }
    }
}
