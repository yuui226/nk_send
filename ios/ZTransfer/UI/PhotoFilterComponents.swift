import SwiftUI

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
    private let calendar = Calendar.current
    var body: some View {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let days = Array(1...calendar.range(of: .day, in: .month, for: date)!.count)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                Spacer(minLength: 0)
                Text(Self.shortDate(date))
                    .zTransferText(size: ZTransferMetrics.caption)
                    .foregroundStyle(ZTransferColors.secondaryText)
            }
            GeometryReader { geometry in
                let available = max(0, geometry.size.width - 16)
                let unit = available / 3.3
                HStack(spacing: 8) {
                    DetentWheel(label: AppLocalized.resource("date_year"), options: years, selected: year, optionLabel: String.init, onCommit: { date = clamped(year: $0, month: month, day: day) }, rowHeight: 18, wheelHeight: 50)
                        .frame(width: unit * 1.3)
                    DetentWheel(label: AppLocalized.resource("date_month"), options: Array(1...12), selected: month, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = clamped(year: year, month: $0, day: day) }, rowHeight: 18, wheelHeight: 50)
                        .frame(width: unit)
                    DetentWheel(label: AppLocalized.resource("date_day"), options: days, selected: day, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = clamped(year: year, month: month, day: $0) }, rowHeight: 18, wheelHeight: 50)
                        .frame(width: unit)
                }
            }
            .frame(height: 50)
        }
    }
    private func clamped(year: Int, month: Int, day: Int) -> Date {
        let maxDay = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1))!)!.count
        return calendar.date(from: DateComponents(year: year, month: month, day: min(day, maxDay)))!
    }

    private static func shortDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d/%02d/%02d", (components.year ?? 0) % 100,
                      components.month ?? 0, components.day ?? 0)
    }
}
