import SwiftUI

struct PhotoFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: PhotoFilterState
    let onApply: (PhotoFilterState) -> Void
    let availableExtensions: [String]
    let availableStorageSlots: [UInt32]
    @State private var enabledExtensions: Set<String>
    @State private var protectedOnly = false
    @State private var burstOnly = false
    @State private var untransferredOnly = false
    @State private var storageSlot: UInt32? = nil
    @State private var editingDate = false
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var selectedDateRange: PhotoDateRange?

    init(initial: PhotoFilterState, availableExtensions: [String] = [".jpg", ".nef", ".mp4"], availableStorageSlots: [UInt32] = [1, 2], onApply: @escaping (PhotoFilterState) -> Void) {
        self.initial = initial; self.onApply = onApply
        let extensions = availableExtensions.map { $0.lowercased() }
        self.availableExtensions = extensions
        self.availableStorageSlots = availableStorageSlots
        _enabledExtensions = State(initialValue: initial.extensions ?? Set(extensions))
        _protectedOnly = State(initialValue: initial.protectedOnly)
        _burstOnly = State(initialValue: initial.burstOnly)
        _untransferredOnly = State(initialValue: initial.untransferredOnly)
        _storageSlot = State(initialValue: initial.storageSlot)
        let fallback = Calendar.current.startOfDay(for: Date())
        let start = Self.date(from: initial.dateRange?.start) ?? fallback
        let end = Self.date(from: initial.dateRange?.end) ?? start
        _startDate = State(initialValue: start)
        _endDate = State(initialValue: end)
        _selectedDateRange = State(initialValue: initial.dateRange)
    }

    var body: some View {
        NavigationStack {
            Group {
                if editingDate { dateEditor } else { filterForm }
            }
            .animation(ZTransferMotion.standard, value: editingDate)
            .navigationTitle(editingDate ? "日期范围" : "筛选").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editingDate ? "返回" : "清除") {
                        if editingDate { editingDate = false } else { onApply(PhotoFilterState()); dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        if editingDate { applyDate(); editingDate = false } else { apply(); dismiss() }
                    }
                }
            }
        }
    }

    private var filterForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                filterSectionTitle("文件类型")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(5, max(1, availableExtensions.count + 1))), spacing: 8) {
                    FilterChip(label: "全部", selected: enabledExtensions.count == availableExtensions.count) {
                        enabledExtensions = Set(availableExtensions)
                    }
                    ForEach(availableExtensions, id: \.self) { ext in
                        FilterChip(label: extLabel(ext), selected: enabledExtensions.contains(ext)) {
                            if enabledExtensions.contains(ext) { enabledExtensions.remove(ext) } else { enabledExtensions.insert(ext) }
                        }
                    }
                }
                filterDivider
                filterSectionTitle("状态")
                HStack(spacing: 8) {
                    FilterChip(label: "保护", selected: protectedOnly) { protectedOnly.toggle() }
                    FilterChip(label: "连拍", selected: burstOnly) { burstOnly.toggle() }
                    FilterChip(label: "未传", selected: untransferredOnly) { untransferredOnly.toggle() }
                }
                if !availableStorageSlots.isEmpty {
                    filterDivider
                    filterSectionTitle("存储卡")
                    HStack(spacing: 8) {
                        ForEach(availableStorageSlots, id: \.self) { slot in
                            FilterChip(label: "卡 \(slot)", selected: storageSlot == slot) {
                                storageSlot = storageSlot == slot ? nil : slot
                            }
                        }
                    }
                }
                filterDivider
                filterSectionTitle("拍摄日期")
                HStack(spacing: 8) {
                    FilterChip(label: selectedDateRange == nil ? "日期" : dateRangeText, selected: selectedDateRange != nil) { editingDate = true }
                    if selectedDateRange != nil { FilterChip(label: "×", selected: false) { selectedDateRange = nil }.frame(width: 38) }
                }
            }
            .padding(14)
        }
    }

    private func filterSectionTitle(_ text: String) -> some View {
        Text(text).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
            .foregroundStyle(ZTransferColors.secondaryText).padding(.bottom, 8)
    }

    private var filterDivider: some View {
        Rectangle().fill(ZTransferColors.secondaryText.opacity(0.16)).frame(height: 1).padding(.vertical, 13)
    }

    private var dateEditor: some View {
        let calendar = Calendar.current
        let years = Array(1990...max(1990, calendar.component(.year, from: Date()) + 1))
        return VStack(spacing: 18) {
            DateEndpointEditor(label: "开始", date: $startDate, years: years)
            DateEndpointEditor(label: "结束", date: $endDate, years: years)
            Spacer()
        }
        .padding(16)
    }

    private var dateRangeText: String {
        let f = DateFormatter(); f.dateFormat = "yy/MM/dd"
        return "\(f.string(from: startDate))–\(f.string(from: endDate))"
    }

    private func apply() {
        onApply(PhotoFilterState(extensions: enabledExtensions.count == availableExtensions.count ? nil : enabledExtensions, protectedOnly: protectedOnly, burstOnly: burstOnly, untransferredOnly: untransferredOnly, storageSlot: storageSlot, dateRange: selectedDateRange))
    }

    private func applyDate() {
        let cal = Calendar.current
        let a = cal.startOfDay(for: min(startDate, endDate))
        let b = cal.startOfDay(for: max(startDate, endDate))
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        selectedDateRange = PhotoDateRange(start: f.string(from: a), end: f.string(from: b))
    }

    private static func date(from value: String?) -> Date? {
        guard let value, value.count >= 8 else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.date(from: String(value.prefix(8)))
    }

    private func extLabel(_ ext: String) -> String {
        ext.dropFirst().uppercased()
    }
}

private struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).zTransferText(size: ZTransferMetrics.caption, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                .frame(maxWidth: .infinity).frame(minHeight: 38)
                .background(selected ? ZTransferColors.accentBlue.opacity(0.13) : Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? ZTransferColors.accentBlue.opacity(0.32) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

private struct DateEndpointEditor: View {
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
                DetentWheel(label: "年", options: years, selected: year, optionLabel: String.init, onCommit: { date = clamped(year: $0, month: month, day: day) }, rowHeight: 26)
                DetentWheel(label: "月", options: Array(1...12), selected: month, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = clamped(year: year, month: $0, day: day) }, rowHeight: 26)
                DetentWheel(label: "日", options: days, selected: day, optionLabel: { String(format: "%02d", $0) }, onCommit: { date = clamped(year: year, month: month, day: $0) }, rowHeight: 26)
            }
        }
    }
    private func clamped(year: Int, month: Int, day: Int) -> Date {
        let maxDay = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month, day: 1))!)!.count
        return calendar.date(from: DateComponents(year: year, month: month, day: min(day, maxDay)))!
    }
}
