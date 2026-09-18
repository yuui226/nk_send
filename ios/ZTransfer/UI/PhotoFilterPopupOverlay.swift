import SwiftUI

/// Android FileListScreen.FilterOverlay equivalent.  The filter editor is an
/// anchored, non-dimming popup; every chip commits immediately and the date
/// editor is a second page inside the same popup rather than a system sheet.
struct PhotoFilterPopupOverlay: View {
    @Binding var isPresented: Bool
    let anchor: CGRect
    let initial: PhotoFilterState
    let availableExtensions: [String]
    let availableStorageSlots: [UInt32]
    let suggestedDate: String?
    let onChange: (PhotoFilterState) -> Void

    @State private var working: PhotoFilterState
    @State private var editingDate = false
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var animationProgress: CGFloat = 0
    @State private var contentHeight: CGFloat?
    @State private var dismissalRequested = false
    @State private var frozenAnchor: CGRect = .zero

    init(isPresented: Binding<Bool>, anchor: CGRect,
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
            let overlayFrame = proxy.frame(in: .named(ZTransferPopupAnchorSpace.name))
            let stableAnchor = frozenAnchor == .zero ? anchor : frozenAnchor
            let localAnchor = stableAnchor.offsetBy(dx: -overlayFrame.minX, dy: -overlayFrame.minY)
            let width = min(340, max(1, proxy.size.width - 24))
            // Match Android FilterOverlay: the panel starts 8dp below the
            // measured filter button and clamps only horizontally. The old
            // bottom-based top clamp made a tall popup jump upward and lose
            // its relationship with the button.
            // The popup itself is centered in the viewport. The button anchor
            // only defines the transform origin; coupling it to panelLeft made
            // the entire filter form visibly lean toward the leading edge.
            let left = max(0, (proxy.size.width - width) / 2)
            let fallbackTop = max(proxy.safeAreaInsets.top + 106, 106)
            let top = stableAnchor == .zero
                ? fallbackTop
                : localAnchor.maxY + 8
            let availableHeight = max(1, proxy.size.height - top - max(12, proxy.safeAreaInsets.bottom))
            let panelHeight = min(contentHeight ?? availableHeight, availableHeight)
            let fallbackButton = CGRect(
                x: min(max(proxy.size.width * 0.35, 12), proxy.size.width - 52),
                y: top - 45,
                width: 40,
                height: 36
            )
            let sourceAnchor = GeniePopupMotion.attachmentAnchor(
                for: stableAnchor == .zero ? fallbackButton : localAnchor,
                cornerRadius: 22
            )
                .offsetBy(dx: -left, dy: -top)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                // Reuse the exact same anchored genie container as Settings:
                // identical mesh geometry, easing, duration, interruption and
                // collapse-completion semantics. The popup remains centered;
                // only the mesh mouth follows the filter button.
                GeniePopupPanel(
                    content: panelContent(width: width) { height in
                        guard height > 0,
                              abs((contentHeight ?? 0) - height) > 0.5 else { return }
                        contentHeight = height
                        guard !dismissalRequested else { return }
                        DispatchQueue.main.async {
                            guard !dismissalRequested,
                                  contentHeight == height else { return }
                            animationProgress = 1
                        }
                    },
                    targetProgress: animationProgress,
                    anchor: sourceAnchor,
                    panelOrigin: .zero,
                    viewport: proxy.size,
                    onCollapsed: { isPresented = false }
                )
                .frame(width: width, height: panelHeight, alignment: .top)
                .padding(.leading, left)
                .padding(.top, top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                if anchor != .zero { frozenAnchor = anchor }
                dismissalRequested = false
                animationProgress = 0
            }
            .onChange(of: anchor) { value in
                if frozenAnchor == .zero, value != .zero { frozenAnchor = value }
            }
        }
        .ignoresSafeArea()
        .zIndex(150)
    }

    @ViewBuilder
    private func panelContent(width: CGFloat, reportHeight: @escaping (CGFloat) -> Void) -> some View {
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
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { reportHeight(geometry.size.height) }
                    .onChange(of: geometry.size.height) { reportHeight($0) }
            }
        }
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
            let columns = min(5, max(1, availableExtensions.count + 1))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                FilterChip(label: AppLocalized.resource("filter_all"), selected: working.extensions == nil) {
                    commit(working.withExtensions(nil))
                }
                ForEach(availableExtensions, id: \.self) { ext in
                    FilterChip(label: ext.dropFirst().uppercased(), selected: working.extensions?.contains(ext) ?? true) {
                        var selected = working.extensions ?? Set(availableExtensions)
                        if selected.contains(ext) { selected.remove(ext) } else { selected.insert(ext) }
                        commit(working.withExtensions(selected.count == availableExtensions.count ? nil : selected.isEmpty ? nil : selected))
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
                    let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
                    commit(working.withDateRange(PhotoDateRange(start: f.string(from: a), end: f.string(from: b))))
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
        guard isPresented, !dismissalRequested else { return }
        dismissalRequested = true
        if contentHeight == nil {
            isPresented = false
            return
        }
        animationProgress = 0
    }

    private static func date(from value: String?) -> Date? {
        guard let value, value.count >= 8 else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: String(value.prefix(8)))
    }
}

private extension PhotoFilterState {
    func withExtensions(_ value: Set<String>?) -> PhotoFilterState { var copy = self; copy.extensions = value; return copy }
    func withStorageSlot(_ value: UInt32?) -> PhotoFilterState { var copy = self; copy.storageSlot = value; return copy }
    func withDateRange(_ value: PhotoDateRange?) -> PhotoFilterState { var copy = self; copy.dateRange = value; return copy }
    func togglingProtected() -> PhotoFilterState { var copy = self; copy.protectedOnly.toggle(); return copy }
    func togglingBurst() -> PhotoFilterState { var copy = self; copy.burstOnly.toggle(); return copy }
    func togglingUntransferred() -> PhotoFilterState { var copy = self; copy.untransferredOnly.toggle(); return copy }
}
