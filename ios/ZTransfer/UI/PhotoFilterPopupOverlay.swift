import SwiftUI

/// Android FileListScreen.FilterOverlay equivalent.  The filter editor is an
/// anchored, non-dimming popup; every chip commits immediately and the date
/// editor is a second page inside the same popup rather than a system sheet.
@MainActor
struct PhotoFilterPopupOverlay: View {
    @Binding var isPresented: Bool
    let anchor: Anchor<CGRect>
    let initial: PhotoFilterState
    let availableExtensions: [String]
    let availableStorageSlots: [UInt32]
    let suggestedDate: String?
    let onChange: (PhotoFilterState) -> Void

    @State private var working: PhotoFilterState
    @State private var editingDate = false
    @State private var startDate: Date
    @State private var endDate: Date

    init(isPresented: Binding<Bool>, anchor: Anchor<CGRect>,
         initial: PhotoFilterState,
         availableExtensions: [String], availableStorageSlots: [UInt32],
         suggestedDate: String?, onChange: @escaping (PhotoFilterState) -> Void) {
        _isPresented = isPresented
        self.anchor = anchor
        self.initial = initial
        self.availableExtensions = availableExtensions.map { $0.lowercased() }
        self.availableStorageSlots = availableStorageSlots
        self.suggestedDate = suggestedDate
        self.onChange = onChange
        _working = State(initialValue: initial)
        let fallback = Calendar.current.startOfDay(for: Date())
        let initialDate = Self.date(from: initial.dateRange?.end)
            ?? Self.date(from: suggestedDate)
            ?? fallback
        _startDate = State(initialValue: Self.date(from: initial.dateRange?.start) ?? initialDate)
        _endDate = State(initialValue: Self.date(from: initial.dateRange?.end) ?? initialDate)
    }

    var body: some View {
        GeometryReader { proxy in
            let localAnchor = proxy[anchor]
            let width = min(340, max(1, proxy.size.width - 24))
            // Android FilterOverlay: final panel is 8pt below the actual
            // trigger, with only its horizontal placement clamped on screen.
            let left = min(max(localAnchor.minX, 12),
                           max(12, proxy.size.width - width - 12))
            let top = localAnchor.maxY + 8
            let sourceAnchor = GeniePopupMotion.attachmentAnchor(
                for: localAnchor, cornerRadius: 22
            )
            let unitAnchorX = (sourceAnchor.midX - left) / width
            ZStack(alignment: .topLeading) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                // This shell is intentionally permanent. Presentation state
                // drives only visual progress, so a late close completion can
                // never destroy a panel that has already been reopened.
                GeniePopupPanel(
                    content: panelContent(width: width),
                    trigger: .filter,
                    targetProgress: isPresented ? 1 : 0,
                    anchorX: unitAnchorX,
                    anchorWidth: sourceAnchor.width / width,
                    anchorGap: top - localAnchor.maxY
                )
                .frame(width: width, alignment: .top)
                .padding(.leading, left)
                .padding(.top, top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(isPresented)
        }
        .ignoresSafeArea()
        .zIndex(150)
        .onAppear {
            if isPresented { resetDraft() }
        }
        .onChange(of: isPresented) { presented in
            if presented { resetDraft() }
        }
    }

    @ViewBuilder
    private func panelContent(width: CGFloat) -> some View {
        Group {
            if editingDate {
                dateEditor
                    .transition(.opacity.combined(with: .offset(x: 12)))
            } else {
                filterForm
                    .transition(.opacity.combined(with: .offset(x: -12)))
            }
        }
        .frame(width: max(1, width - 28))
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(ZTransferGlassSurface(cornerRadius: 16, kind: .panel))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: editingDate)
    }

    private var filterForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Android reuses FilterMark in both the toolbar and popup.
                // Keep one iOS vector too; the system circled glyph had a
                // different silhouette and visual center.
                PhotoListFilterIcon(active: false, color: ZTransferColors.accentBlue)
                    .frame(width: 18, height: 18)
                Text(AppLocalized.resource("filter_title"))
                    .zTransferTypography(.titleMedium, weight: .semibold)
                    .foregroundStyle(ZTransferColors.primaryText)
            }
            .padding(.bottom, 14)

            section(AppLocalized.resource("filter_section_file_type"))
            VStack(spacing: 8) {
                ForEach(fileTypeRows.indices, id: \.self) { rowIndex in
                    let row = fileTypeRows[rowIndex]
                    HStack(spacing: 8) {
                        ForEach(0..<fileTypeColumnCount, id: \.self) { columnIndex in
                            Group {
                                if columnIndex < row.count {
                                    fileTypeChip(row[columnIndex])
                                } else {
                                    Color.clear.frame(minHeight: 38)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            divider
            section(AppLocalized.resource("filter_section_status"))
            HStack(spacing: 8) {
                FilterChip(label: AppLocalized.resource("filter_protected"), selected: working.protectedOnly, systemImage: "key.fill") { commit(working.togglingProtected()) }
                FilterChip(label: AppLocalized.resource("burst_label"), selected: working.burstOnly, burstIcon: true) { commit(working.togglingBurst()) }
                FilterChip(label: AppLocalized.resource("filter_untransferred"), selected: working.untransferredOnly, systemImage: "arrow.down.to.line") { commit(working.togglingUntransferred()) }
            }
            if !availableStorageSlots.isEmpty {
                divider
                section(AppLocalized.resource("filter_section_storage"))
                HStack(spacing: 8) {
                    ForEach(availableStorageSlots, id: \.self) { slot in
                        FilterChip(label: AppLocalized.formattedResource("filter_storage_slot", ["%1$d": String(slot)]),
                                   selected: isPhotoStorageSlotSelected(working.storageSlot, slot: slot)) {
                            commit(working.withStorageSlot(toggledPhotoStorageSlot(
                                working.storageSlot,
                                toggled: slot,
                                available: availableStorageSlots
                            )))
                        }
                    }
                }
            }
            divider
            section(AppLocalized.resource("filter_section_date"))
            HStack(spacing: 8) {
                FilterChip(label: working.dateRange.map(formatRange) ?? AppLocalized.resource("filter_date"), selected: working.dateRange != nil) {
                    editingDate = true
                }
                if working.dateRange != nil {
                    FilterChip(label: nil, selected: false, systemImage: "xmark") { commit(working.withDateRange(nil)) }
                        .frame(width: 38)
                }
            }
        }
    }

    private var dateEditor: some View {
        let calendar = Calendar.current
        let years = Array(1990...max(1990, calendar.component(.year, from: Date()) + 1))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { editingDate = false } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }.buttonStyle(.plain)
                Text(AppLocalized.resource("date_range"))
                    .zTransferTypography(.titleMedium, weight: .semibold)
                Spacer(minLength: 0)
            }
            DateEndpointEditor(label: AppLocalized.resource("date_start"), date: $startDate, years: years)
            DateEndpointEditor(label: AppLocalized.resource("date_end"), date: $endDate, years: years)
            HStack(spacing: 8) {
                Button(AppLocalized.resource("clear")) {
                    commit(working.withDateRange(nil)); editingDate = false
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 11, panel: true))
                .frame(maxWidth: .infinity, minHeight: 40)
                Button(AppLocalized.resource("done")) {
                    let cal = Calendar.current
                    let a = cal.startOfDay(for: min(startDate, endDate))
                    let b = cal.startOfDay(for: max(startDate, endDate))
                    commit(working.withDateRange(PhotoDateRange(
                        start: Self.dateKey(from: a), end: Self.dateKey(from: b)
                    )))
                    editingDate = false
                }
                .buttonStyle(ZTransferGlassButtonStyle(
                    cornerRadius: 11,
                    panel: true,
                    active: true,
                    activeColor: ZTransferColors.accentBlue
                ))
                .frame(maxWidth: .infinity, minHeight: 40)
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
            .foregroundStyle(ZTransferColors.secondaryText)
            .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle().fill(ZTransferColors.secondaryText.opacity(0.16)).frame(height: 1).padding(.vertical, 13)
    }

    private var fileTypeColumnCount: Int {
        min(5, max(1, availableExtensions.count + 1))
    }

    private var fileTypeRows: [[String?]] {
        let choices: [String?] = [nil] + availableExtensions.map(Optional.some)
        return stride(from: 0, to: choices.count, by: fileTypeColumnCount).map {
            Array(choices[$0..<min($0 + fileTypeColumnCount, choices.count)])
        }
    }

    @ViewBuilder
    private func fileTypeChip(_ extensionValue: String?) -> some View {
        if let ext = extensionValue {
            FilterChip(
                label: ext.dropFirst().uppercased(),
                selected: working.extensions?.contains(ext) ?? true
            ) {
                var selected = working.extensions ?? Set(availableExtensions)
                if selected.contains(ext) { selected.remove(ext) } else { selected.insert(ext) }
                commit(working.withExtensions(
                    selected.count == availableExtensions.count || selected.isEmpty ? nil : selected
                ))
            }
        } else {
            FilterChip(
                label: AppLocalized.resource("filter_all"),
                selected: working.extensions == nil
            ) {
                commit(working.withExtensions(nil))
            }
        }
    }

    private func commit(_ next: PhotoFilterState) {
        guard next != working else { return }
        working = next
        onChange(next)
    }

    private func formatRange(_ range: PhotoDateRange) -> String {
        // Android's compactDateRangeLabel is yy/MM/dd (including the year).
        func short(_ value: String) -> String {
            guard value.count >= 8 else { return value }
            let year = String(value.prefix(4)).suffix(2)
            let month = String(value.dropFirst(4).prefix(2))
            let day = String(value.dropFirst(6).prefix(2))
            return "\(year)/\(month)/\(day)"
        }
        let start = short(range.start)
        let end = short(range.end)
        return start == end ? start : "\(start)–\(end)"
    }

    private func close() {
        isPresented = false
    }

    private func resetDraft() {
        working = initial
        editingDate = false
        let fallback = Calendar.current.startOfDay(for: Date())
        let initialDate = Self.date(from: initial.dateRange?.end)
            ?? Self.date(from: suggestedDate)
            ?? fallback
        startDate = Self.date(from: initial.dateRange?.start) ?? initialDate
        endDate = Self.date(from: initial.dateRange?.end) ?? initialDate
    }

    private static func date(from value: String?) -> Date? {
        guard let value, value.count >= 8,
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.dropFirst(6).prefix(2)) else { return nil }
        return filterCalendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func dateKey(from date: Date) -> String {
        let components = filterCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static let filterCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
}

private extension PhotoFilterState {
    func withExtensions(_ value: Set<String>?) -> PhotoFilterState { var copy = self; copy.extensions = value; return copy }
    func withStorageSlot(_ value: UInt32?) -> PhotoFilterState { var copy = self; copy.storageSlot = value; return copy }
    func withDateRange(_ value: PhotoDateRange?) -> PhotoFilterState { var copy = self; copy.dateRange = value; return copy }
    func togglingProtected() -> PhotoFilterState { var copy = self; copy.protectedOnly.toggle(); return copy }
    func togglingBurst() -> PhotoFilterState { var copy = self; copy.burstOnly.toggle(); return copy }
    func togglingUntransferred() -> PhotoFilterState { var copy = self; copy.untransferredOnly.toggle(); return copy }
}
