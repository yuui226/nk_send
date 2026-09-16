import SwiftUI

struct FilterChip: View {
    let label: String?
    let selected: Bool
    var systemImage: String? = nil
    var burstIcon = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if burstIcon { BurstGlyph() }
                else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                if let label {
                    Text(label).zTransferText(size: ZTransferMetrics.caption, weight: selected ? .semibold : .regular)
                }
            }
            .foregroundStyle(selected ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
            .frame(maxWidth: .infinity).frame(minHeight: 38)
            .background(selected ? ZTransferColors.accentBlue.opacity(0.13) : Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? ZTransferColors.accentBlue.opacity(0.32) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(label).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
            HStack(spacing: 8) {
                DetentWheel(label: AppLocalized.resource("date_year"), options: years, selected: year, optionLabel: String.init, onCommit: { date = clamped(year: $0, month: month, day: day) }, rowHeight: 26)
                DetentWheel(label: AppLocalized.resource("date_month"), options: Array(1...12), selected: month, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = clamped(year: year, month: $0, day: day) }, rowHeight: 26)
                DetentWheel(label: AppLocalized.resource("date_day"), options: days, selected: day, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = clamped(year: year, month: month, day: $0) }, rowHeight: 26)
            }
        }
    }
    private func clamped(year: Int, month: Int, day: Int) -> Date {
        let maxDay = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1))!)!.count
        return calendar.date(from: DateComponents(year: year, month: month, day: min(day, maxDay)))!
    }
}
