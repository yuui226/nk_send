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
    let ratingProgress: PhotoRatingScan
    let onChange: (PhotoFilterState) -> Void

    @State private var working: PhotoFilterState
    @State private var editingDate = false
    @State private var showRatingTip = false
    @State private var ratingTipFrame: CGRect = .zero
    @State private var ratingTipSize: CGSize = .zero
    @State private var ratingPulse: CGFloat = 1
    @AppStorage("haptics_enabled") private var hapticsEnabled = true

    init(isPresented: Binding<Bool>, anchor: Anchor<CGRect>,
         initial: PhotoFilterState,
         availableExtensions: [String], availableStorageSlots: [UInt32],
         suggestedDate: String?, ratingProgress: PhotoRatingScan = PhotoRatingScan(),
         onChange: @escaping (PhotoFilterState) -> Void) {
        _isPresented = isPresented
        self.anchor = anchor
        self.initial = initial
        self.availableExtensions = availableExtensions.map { $0.lowercased() }
        self.availableStorageSlots = availableStorageSlots
        self.suggestedDate = suggestedDate
        self.ratingProgress = ratingProgress
        self.onChange = onChange
        _working = State(initialValue: initial)
    }

    var body: some View {
        GeometryReader { proxy in
            let localAnchor = proxy[anchor]
            // Android's final rating row fixes the panel at 14 + 81 + 8 +
            // 154 + 14 dp. Keep that width stable while controls crossfade.
            let width = min(271, max(1, proxy.size.width - 24))
            // Android FilterOverlay centers the fixed-width panel. The trigger
            // only supplies the genie origin and the vertical attachment.
            let left = max(12, (proxy.size.width - width) / 2)
            let top = localAnchor.maxY + 8
            let maxPanelHeight = max(100, proxy.size.height - top - 20)
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
                    content: panelContent(width: width, maxHeight: maxPanelHeight),
                    trigger: .filter,
                    targetProgress: isPresented ? 1 : 0,
                    anchorX: unitAnchorX,
                    anchorWidth: sourceAnchor.width / width,
                    anchorGap: top - localAnchor.maxY
                )
                .frame(width: width, alignment: .top)
                .padding(.leading, left)
                    .padding(.top, top)

                if showRatingTip, ratingTipFrame != .zero {
                    ratingHelpBubble(in: proxy, anchor: ratingTipFrame)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: "filter-root")
            .onPreferenceChange(RatingTipSizePreferenceKey.self) { ratingTipSize = $0 }
            .allowsHitTesting(isPresented)
        }
        .ignoresSafeArea()
        .zIndex(150)
        .onAppear {
            if isPresented { resetDraft() }
        }
        .onChange(of: isPresented) { presented in
            if presented { resetDraft(); showRatingTip = false }
        }
        .onChange(of: initial) { value in
            // Android's remember(current) follows an external clear while the
            // popup is still mounted; keep the draft from resurrecting it.
            working = value
        }
        .task(id: ratingProgress.loading) {
            guard ratingProgress.loading else {
                ratingPulse = 1
                return
            }
            ratingPulse = 0.72
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: true)) {
                ratingPulse = 1
            }
        }
    }

    @ViewBuilder
    private func panelContent(width: CGFloat, maxHeight: CGFloat) -> some View {
        Group {
            if editingDate {
                dateEditor
                    .transition(.opacity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    filterForm.transition(.opacity)
                }
                .frame(maxHeight: maxHeight)
            }
        }
        .frame(width: max(1, width - 28))
        .padding(14)
        // Shadow the panel surface once. Applying a shadow to the entire
        // content makes the synchronous Genie capture blur every child.
        .background {
            ZTransferGlassSurface(cornerRadius: 16, kind: .panel)
                .compositingGroup()
                .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
        }
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: editingDate)
    }

    private var filterForm: some View {
            VStack(alignment: .leading, spacing: 0) {
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
                    if availableStorageSlots.count == 1 {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            divider
            ratingFilterRow
            divider
            HStack(spacing: 8) {
                FilterChip(label: working.dateRange.map(formatRange) ?? AppLocalized.resource("filter_date"), selected: working.dateRange != nil) {
                    editingDate = true
                }
                if working.dateRange != nil {
                    FilterClearButton { commit(working.withDateRange(nil)) }
                }
            }
        }
    }

    private var dateEditor: some View {
        PhotoFilterDateEditor(current: working.dateRange, suggestedDate: suggestedDate,
                              onBack: { editingDate = false }) { range in
            commit(working.withDateRange(range))
            editingDate = false
        }
    }

    /// Android's fixed-width rating row. The loader switch is independent from
    /// the concrete star filter: enabling it alone keeps the photo grid intact
    /// while it fills the connection-scoped snapshot.
    private var ratingFilterRow: some View {
        let statusLabel: String = {
            if !working.ratingEnabled { return AppLocalized.resource("filter_rating_off") }
            if ratingProgress.waitingForRange {
                return "0/\(ratingProgress.total)"
            }
            if ratingProgress.loading {
                return "\(min(ratingProgress.completed, ratingProgress.total))/\(ratingProgress.total)"
            }
            return AppLocalized.resource("filter_rating_on")
        }()
        let accent: Color = {
            if !working.ratingEnabled { return ZTransferColors.accentBlue }
            if ratingProgress.waitingForRange { return ZTransferColors.accentYellow }
            if ratingProgress.loading { return ZTransferColors.accentBlue }
            return ZTransferColors.statusConnected
        }()

        return HStack(spacing: 8) {
            FilterChip(
                label: statusLabel,
                selected: working.ratingEnabled,
                accentColor: accent,
                minHeight: 34,
                cornerLabel: AppLocalized.resource("filter_rating_enabled"),
                onLongPress: working.ratingEnabled ? {
                    UIPasteboard.general.string = PhotoRatingDiagnostics.snapshot()
                } : nil
            ) {
                commit(working.withRating(
                    enabled: !working.ratingEnabled,
                    rating: working.ratingEnabled ? nil : working.rating
                ))
                ZTransferHaptics.shared.tick()
            }
            .frame(width: 81)
            .opacity(working.ratingEnabled && ratingProgress.loading ? ratingPulse : 1)
            .accessibilityLabel(AppLocalized.resource("filter_rating_enabled"))

            ZStack(alignment: .leading) {
                if !working.ratingEnabled {
                    HStack(spacing: 8) {
                        DetentWheel(
                            label: AppLocalized.resource("filter_rating_range_label"),
                            options: [1, 3, 5, 0],
                            selected: [1, 3, 5, 0].contains(working.ratingDays) ? working.ratingDays : 3,
                            optionLabel: { days in
                                days == 0
                                    ? AppLocalized.resource("filter_rating_range_all")
                                    : AppLocalized.formattedResource("filter_rating_range_days", ["%1$d": String(days)])
                            },
                            onCommit: { days in commit(working.withRatingDays(days)) },
                            rowHeight: 18,
                            wheelHeight: 34,
                            cornerRadius: 10,
                            optionFontSize: 12,
                            optionFontWeight: .medium,
                            showDragHint: false,
                            onDetent: { ZTransferHaptics.shared.tick() }
                        )
                        .frame(width: 81, height: 34)
                        TipLightbulbButton(
                            attention: false,
                            size: 34,
                            accessibilityLabel: AppLocalized.resource("filter_rating_help_title"),
                            embeddedInPanel: true,
                            action: { showRatingTip = true }
                        )
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: RatingTipFramePreferenceKey.self,
                                    value: geometry.frame(in: .named("filter-root"))
                                )
                            }
                        )
                    }
                    .transition(.opacity)
                } else {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { star in
                        PhotoEffectFavoriteButton(
                            favorite: star <= (working.rating ?? 0),
                            enabled: true,
                            compact: true,
                            compactSize: 30,
                            description: AppLocalized.formattedResource("filter_rating_stars", ["%1$d": String(star)])
                        ) {
                            commit(working.withRating(
                                enabled: true,
                                rating: working.rating == star ? nil : star
                            ))
                        }
                    }
                }
                    .frame(width: 154, height: 34, alignment: .leading)
                    .transition(.opacity)
                }
            }
            .frame(width: 154, height: 34, alignment: .leading)
            .animation(.linear(duration: 0.18), value: working.ratingEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(RatingTipFramePreferenceKey.self) { ratingTipFrame = $0 }
    }

    @ViewBuilder
    private func ratingHelpBubble(in proxy: GeometryProxy, anchor: CGRect) -> some View {
        let width = min(260, max(220, proxy.size.width - 36))
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized.resource("filter_rating_help_title"))
                .zTransferTypography(.titleMedium, weight: .semibold)
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(AppLocalized.resource("filter_rating_help_description"))
                    .zTransferText(size: ZTransferMetrics.caption)
                    .foregroundStyle(ZTransferColors.primaryText)
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: RatingTipSizePreferenceKey.self, value: geometry.size)
            }
        )
        .background {
            ZTransferGlassSurface(cornerRadius: 16, kind: .panel)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        }
        .position(
            x: proxy.size.width - 18 - width / 2,
            y: anchor.maxY + 8 + (ratingTipSize.height > 0 ? ratingTipSize.height / 2 : 48)
        )
        .transition(.opacity)
        .zIndex(2)
        .onTapGesture { showRatingTip = false }
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: showRatingTip ? 0.34 : 0.26), value: showRatingTip)
    }

    private func section(_ title: String) -> some View {
        Text(title).zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
            .foregroundStyle(ZTransferColors.secondaryText)
            .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle().fill(ZTransferColors.secondaryText.opacity(0.16)).frame(height: 1).padding(.vertical, 13)
    }

    private var allExtensions: [String] {
        Set(availableExtensions + (working.extensions ?? [])).sorted()
    }

    private var fileTypeColumnCount: Int {
        min(5, max(1, allExtensions.count + 1))
    }

    private var fileTypeRows: [[String?]] {
        let choices: [String?] = [nil] + allExtensions.map(Optional.some)
        return stride(from: 0, to: choices.count, by: fileTypeColumnCount).map {
            Array(choices[$0..<min($0 + fileTypeColumnCount, choices.count)])
        }
    }

    @ViewBuilder
    private func fileTypeChip(_ extensionValue: String?) -> some View {
        if let ext = extensionValue {
            FilterChip(
                label: ext.hasPrefix(".") ? String(ext.dropFirst()).uppercased() : ext.uppercased(),
                selected: working.extensions?.contains(ext) ?? true
            ) {
                var selected = working.extensions ?? Set(allExtensions)
                if selected.contains(ext) { selected.remove(ext) } else { selected.insert(ext) }
                commit(working.withExtensions(
                    selected.count == allExtensions.count || selected.isEmpty ? nil : selected
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
    }
}

private struct FilterClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ZTransferColors.secondaryText)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 9, panel: true))
    }
}

/// Android DateRangeEditor owns these two values only while its page exists.
/// Opening the filter popup itself must not parse or initialize date drafts.
@MainActor
private struct PhotoFilterDateEditor: View {
    let onBack: () -> Void
    let onApply: (PhotoDateRange?) -> Void
    @State private var startDate: Date
    @State private var endDate: Date

    init(current: PhotoDateRange?, suggestedDate: String?,
         onBack: @escaping () -> Void, onApply: @escaping (PhotoDateRange?) -> Void) {
        self.onBack = onBack
        self.onApply = onApply
        let initialDate = Self.date(from: current?.end)
            ?? Self.date(from: suggestedDate)
            ?? Calendar.current.startOfDay(for: Date())
        _startDate = State(initialValue: Self.date(from: current?.start) ?? initialDate)
        _endDate = State(initialValue: initialDate)
    }

    var body: some View {
        let calendar = Calendar.current
        let startYear = calendar.component(.year, from: startDate)
        let endYear = calendar.component(.year, from: endDate)
        let years = Array(min(1990, startYear, endYear)...max(1990, calendar.component(.year, from: Date()) + 1, startYear, endYear))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { onBack() } label: {
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
                    onApply(nil)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 11, panel: true))
                .frame(maxWidth: .infinity, minHeight: 40)
                Button(AppLocalized.resource("done")) {
                    let cal = Calendar.current
                    let a = cal.startOfDay(for: min(startDate, endDate))
                    let b = cal.startOfDay(for: max(startDate, endDate))
                    onApply(PhotoDateRange(
                        start: Self.dateKey(from: a), end: Self.dateKey(from: b)
                    ))
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
        .onChange(of: startDate) { value in
            if value > endDate { endDate = value }
        }
        .onChange(of: endDate) { value in
            if value < startDate { startDate = value }
        }
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
    func withRating(enabled: Bool, rating: Int?) -> PhotoFilterState { var copy = self; copy.ratingEnabled = enabled; copy.rating = rating; return copy }
    func withRatingDays(_ value: Int) -> PhotoFilterState { var copy = self; copy.ratingDays = value; return copy }
    func togglingProtected() -> PhotoFilterState { var copy = self; copy.protectedOnly.toggle(); return copy }
    func togglingBurst() -> PhotoFilterState { var copy = self; copy.burstOnly.toggle(); return copy }
    func togglingUntransferred() -> PhotoFilterState { var copy = self; copy.untransferredOnly.toggle(); return copy }
}

private struct RatingTipFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct RatingTipSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
