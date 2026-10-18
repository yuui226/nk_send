import SwiftUI
import UniformTypeIdentifiers

/// Android RemotePictureControlPanel / PictureControlPresetChooser. Camera
/// mutations stay in the existing model; this host owns only popup navigation.
struct RemotePictureControlPanel: View {
    @ObservedObject var model: PictureControlPanelModel
    @ObservedObject var folders: PictureControlFolderState
    var anchor: CGRect? = nil
    var hostSize = CGSize(width: 320, height: 600)
    var landscape = false
    var canWrite = true
    let dismiss: () -> Void
    let chooseFolder: (Int) -> Void
    var pickerActive = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.displayScale) private var scale
    @StateObject private var motion = RemotePictureControlMotion()
    @State private var confirmation: RemotePictureControlPage.Confirmation?
    @State private var category = "built-in"
    @State private var shareURL: URL?
    @State private var sharing = false
    private func text(_ key: String) -> String { AppLocalized.resource(key) }
    private var page: RemotePictureControlPage { .init(slot: model.editingSlot, confirmation: confirmation) }
    private var idle: Bool { motion.settled && !model.closeRequested && model.canBrowse && !pickerActive }
    private var categories: [RemotePresetCategory] {
        let accessible = folders.failure != .missing && folders.failure != .denied
        let catalog = folders.catalog
        let labels = catalog.labels(uncategorized: text("lut_uncategorized"))
        return [.init(id: "built-in", label: text("picture_control_built_in"),
                      choices: model.presets.map { .init(choice: .builtIn($0), label: $0.name) })] +
            (accessible ? catalog.categories.map { name in
                RemotePresetCategory(id: name.map { "folder:" + $0 } ?? "root", label: name ?? text("lut_uncategorized"),
                    choices: (catalog.filesByCategory[name] ?? []).map { .init(choice: .document($0), label: labels[$0.identifier] ?? $0.label) })
            } : [])
    }
    private var guidance: String? {
        guard phase == .active, model.editingSlot != nil, confirmation == nil, !model.closeRequested,
              !folders.scanning else { return nil }
        if let failure = folders.failure { return PictureControlFolderState.message(failure) }
        if folders.hasSnapshot && folders.folder != nil && folders.files.isEmpty { return "picture_control_folder_empty" }
        if model.presetsFailed { return "picture_control_files_failed" }
        return nil
    }
    var body: some View {
        Group {
            if model.overview != nil {
                let layout = RemotePictureControlLayout(overview: model.overview!, categories: categories,
                    category: category, hostSize: hostSize, anchor: anchor, landscape: landscape, scale: scale)
                let targetSize = layout.size(for: page)
                RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape,
                    width: motion.ready ? motion.size.width : targetSize.width,
                    contentHeight: motion.ready ? motion.size.height : nil, closing: model.closeRequested,
                    trigger: .remotePictureControl, accessibilityID: "remote-preset-backdrop",
                    close: model.requestClose, dismiss: dismiss, usesFullAnchor: true, back: back) { _ in
                        ZStack(alignment: .topLeading) {
                            ForEach(motion.exits) { outgoing in
                                content(outgoing.page, size: outgoing.size, layout: layout, active: false)
                                    .opacity(outgoing.opacity).allowsHitTesting(false).accessibilityHidden(true)
                            }
                            content(motion.page, size: motion.targetSize, layout: layout, active: motion.page == page)
                                .opacity(motion.incomingOpacity)
                        }
                        .frame(width: motion.size.width, height: motion.size.height, alignment: .topLeading)
                        .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("remote-preset-popup")
                    }
                    .onAppear { motion.configure(page: page, size: targetSize, scale: scale) }
                    .onChange(of: page) { motion.configure(page: $0, size: layout.size(for: $0), scale: scale) }
                    .onChange(of: targetSize) { motion.configure(page: page, size: $0, scale: scale) }
            } else {
                #if DEBUG
                if model.initialLoadFinished && model.loadFailed { failedOverview }
                #endif
            }
        }
        .sheet(isPresented: $sharing) { if let shareURL { PictureControlShareSheet(url: shareURL) } }
        .onAppear {
            model.open()
            folders.onNotice = { [weak model] in model?.notice(AppLocalized.resource($0)) }
        }
        .onDisappear { motion.stop() }
        .onChange(of: model.editingSlot) { slot in
            confirmation = nil
            if slot != nil { category = "built-in"; folders.refresh() }
        }
        .onChange(of: phase) {
            model.interactionAllowed = $0 == .active && !pickerActive
            if $0 == .active && model.editingSlot != nil && confirmation == nil { folders.refresh() }
        }
        .onChange(of: pickerActive) { model.interactionAllowed = !$0 && phase == .active }
        .onChange(of: categories.map(\.id)) { keys in
            if !keys.contains(category) { category = keys.first ?? "built-in" }
        }
        .task(id: guidance) { if let guidance { model.notice(text(guidance)) } }

    }
    private func back() {
        guard !model.closeRequested, model.pending == nil else { return }
        if confirmation != nil { confirmation = nil }
        else if model.editingSlot != nil { model.editingSlot = nil }
        else { model.requestClose() }
    }
    private func perform(_ action: PictureControlPanelModel.Action) {
        guard idle, canWrite else { return }
        model.act(action)
        if model.pending != nil { confirmation = nil }
    }
    @ViewBuilder private func content(_ displayed: RemotePictureControlPage, size: CGSize,
                                      layout: RemotePictureControlLayout, active: Bool) -> some View {
        let enabled = active && idle
        let slot = model.overview?.slots.first { $0.slot == displayed.slot }
        VStack(spacing: 0) {
            if let number = displayed.slot {
                header(number, slot: slot, confirmation: displayed.confirmation, enabled: enabled)
                    .frame(height: 34)
                if let confirmation = displayed.confirmation {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Text(confirmation == .folder ? text("picture_control_choose_folder_hint") :
                                 String(format: text("picture_control_clear_confirm"), number - 200))
                                .font(.system(size: 14)).foregroundStyle(ZTransferColors.secondaryText)
                                .lineSpacing(RemotePictureControlLayout.bodyLineSpacing)
                                .padding(.vertical, RemotePictureControlLayout.bodyLineSpacing / 2)
                                .multilineTextAlignment(confirmation == .folder ? .leading : .center)
                                .frame(maxWidth: .infinity, alignment: confirmation == .folder ? .leading : .center)
                                .fixedSize(horizontal: false, vertical: true).padding(12)
                            if confirmation == .clear {
                                outlinedButton(text("picture_control_confirm"), destructive: true, compact: false,
                                    enabled: enabled && canWrite && slot.map(model.canEdit) == true && slot?.availability == .occupied) {
                                        perform(.clear(number))
                                    }
                            } else {
                                RemotePresetChoiceRow(text: text("picture_control_confirm"), enabled: enabled) {
                                    model.feedback(); self.confirmation = nil; chooseFolder(number)
                                }
                            }
                            RemotePresetChoiceRow(text: text("picture_control_cancel"), enabled: enabled,
                                centered: confirmation == .clear) { model.feedback(); self.confirmation = nil }
                        }
                    }.presetScrollEdges()
                } else {
                    RemotePresetCategoryBrowser(categories: layout.categories, category: $category,
                        enabled: enabled, row: { item in
                            RemotePresetChoiceRow(text: item.label, pending: pendingKey == item.id,
                                enabled: enabled && canWrite && slot.map(model.canEdit) == true &&
                                    (item.isBuiltIn || !folders.scanning)) { perform(.write(number, item.choice)) }
                        })
                        .onAppear { if active && phase == .active { folders.refresh() } }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(model.overview?.slots ?? []) { item in slotRow(item, enabled: enabled) }
                        #if DEBUG
                        HStack {
                            Spacer(minLength: 0)
                            reportButton(enabled: enabled)
                        }.padding(.horizontal, 8)
                        #endif
                    }
                }.presetScrollEdges()
            }
        }
        .padding(.horizontal, displayed.slot == nil ? 0 : 8)
        .padding(.top, displayed.slot == nil ? 0 : 4)
        .padding(.bottom, displayed.slot == nil ? 0 : 8)
        .frame(width: max(1, size.width), height: max(1, size.height), alignment: .topLeading)
        .allowsHitTesting(enabled)
        .accessibilityIdentifier(displayed.slot.map { "remote-preset-editor-\($0)" } ?? "remote-preset-slots")
    }
    private var pendingKey: String? {
        if case .write(_, let choice) = model.pending { return choice.id }
        return nil
    }
    private func slotRow(_ item: PictureControlSlotInfo, enabled: Bool) -> some View {
        let editable = enabled && canWrite && model.canEdit(item)
        let activatable = item.availability == .empty ? editable :
            enabled && canWrite && !model.loadFailed && model.overview?.canActivate == true && item.availability == .occupied
        let selected = model.overview?.selected == item.slot
        return HStack(spacing: 0) {
            RemotePresetChoiceRow(text: RemotePictureControlLayout.slotLabel(item), selected: selected,
                pending: model.pending?.slot == item.slot, enabled: activatable, verticalPadding: 4,
                selectionBackground: false) {
                    if item.availability == .empty { model.feedback(); model.editingSlot = item.slot }
                    else { perform(.activate(item.slot)) }
                }
            Button { model.feedback(); model.editingSlot = item.slot } label: {
                RemoteEditorIcon(kind: .edit)
                    .fill(selected && editable ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                    .frame(width: 18, height: 18).opacity(editable ? 1 : 0.35)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!editable).padding(.trailing, 3)
                .accessibilityLabel(String(format: text("picture_control_edit_slot"), item.number))
                .accessibilityIdentifier("remote-preset-edit-\(item.slot)")
        }
        .background { Rectangle().fill(selected ? ZTransferColors.accentBlue.opacity(0.08) : .clear) }
    }
    private func header(_ number: Int, slot: PictureControlSlotInfo?,
                        confirmation: RemotePictureControlPage.Confirmation?, enabled: Bool) -> some View {
        HStack(spacing: 0) {
            Button { model.feedback(); back() } label: {
                RemoteEditorIcon(kind: .arrowBack).fill(ZTransferColors.secondaryText).frame(width: 18, height: 18)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(text("picture_control_back"))
                .accessibilityIdentifier("remote-preset-back")
            Text("C\(number - 200)").font(.system(size: 16, weight: .medium)).foregroundStyle(ZTransferColors.primaryText)
                .lineLimit(1).padding(.horizontal, 6)
            if confirmation == nil && slot?.availability == .occupied {
                outlinedButton(text("picture_control_clear_slot"), destructive: true,
                    enabled: enabled && canWrite && slot.map(model.canEdit) == true) { model.feedback(); self.confirmation = .clear }
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
            if confirmation == nil {
                outlinedButton(text("picture_control_folder"), enabled: enabled && !folders.isRestoring) {
                    model.feedback()
                    if folders.folder == nil { self.confirmation = .folder } else { chooseFolder(number) }
                }.frame(maxWidth: 112)
            }
        }.padding(.bottom, 2)
    }
    private func outlinedButton(_ label: String, destructive: Bool = false, compact: Bool = true,
                                enabled: Bool, action: @escaping () -> Void) -> some View {
        let color = destructive ? ZTransferColors.statusError : ZTransferColors.secondaryText
        return Button(action: action) {
            Text(label).font(.system(size: compact ? 12 : 14, weight: .medium)).lineLimit(1)
                .foregroundStyle(color.opacity(destructive && !enabled ? 0.35 : 1))
                .frame(minHeight: compact ? 16 : 20).padding(.horizontal, compact ? 8 : 12)
                .padding(.vertical, compact ? 3 : 8)
                .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 28 : 32)
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(enabled ? 0.28 : 0.12), lineWidth: 0.75))
        }.buttonStyle(.plain).disabled(!enabled)
    }
    #if DEBUG
    private var failedOverview: some View {
        let message = text(model.loadFailureResource == "picture_control_movie_bank_unsupported" ?
            model.loadFailureResource : "picture_control_slot_unreadable")
        let font = UIFont.systemFont(ofSize: 14, weight: .medium)
        let buttonWidth = (text("picture_control_test_log") as NSString).size(withAttributes: [.font: font]).width + 16
        let measured = (message as NSString).boundingRect(with: CGSize(width: max(1, 220 - 24 - buttonWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        let height = max(36, ceil(measured.height / font.lineHeight) * 20)
        return RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape, width: 220,
            contentHeight: height, closing: model.closeRequested, trigger: .remotePictureControl,
            accessibilityID: "remote-preset-backdrop", close: model.requestClose, dismiss: dismiss, usesFullAnchor: true) { _ in
            HStack(spacing: 0) {
                Text(message).lineSpacing(max(0, 20 - font.lineHeight))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(ZTransferColors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                reportButton(enabled: !model.closeRequested)
            }.padding(.horizontal, 12).frame(height: height)
                .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("remote-preset-read-failure")
        }
    }
    #endif
    private func reportButton(enabled: Bool) -> some View {
        Button { shareReport() } label: {
            Text(text("picture_control_test_log")).font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled && !model.report.isEmpty ? ZTransferColors.accentBlue : ZTransferColors.secondaryText.opacity(0.35))
                .lineLimit(1).frame(height: 20).padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ZTransferColors.secondaryText.opacity(enabled && !model.report.isEmpty ? 0.28 : 0.12), lineWidth: 0.75))
        }.buttonStyle(.plain).disabled(!enabled || model.report.isEmpty)
            .accessibilityIdentifier("remote-preset-test-log")
    }
    private func shareReport() {
        guard model.canBrowse, !model.opening, !pickerActive, !model.report.isEmpty else { return }
        model.feedback()
        let report = model.report
        Task {
            do { shareURL = try await Task.detached { try PictureControlReportJournal.share(report) }.value; sharing = true }
            catch { model.notice(text("picture_control_report_share_failed")) }
        }
    }
}

struct RemotePresetCategory: Identifiable {
    let id: String
    let label: String
    let choices: [RemotePresetItem]
}
struct RemotePresetItem: Identifiable {
    let choice: PictureControlPresetChoice
    let label: String
    var id: String { choice.id }
    var isBuiltIn: Bool { if case .builtIn = choice { true } else { false } }
}

/// LutCategoryList.kt: independent scroll columns .36/.64, 6pt gap, category
/// selection persists through scans; only the option list resets on category change.
struct RemotePresetCategoryBrowser<Row: View>: View {
    let categories: [RemotePresetCategory]
    @Binding var category: String
    let enabled: Bool
    @ViewBuilder let row: (RemotePresetItem) -> Row
    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 6)
            HStack(alignment: .top, spacing: 6) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(categories) { item in
                            Button { category = item.id } label: {
                                Text(item.label).font(.system(size: 14, weight: .medium))
                                    .lineSpacing(RemotePictureControlLayout.labelLineSpacing).lineLimit(2)
                                    .padding(.vertical, RemotePictureControlLayout.labelLineSpacing / 2)
                                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 8).padding(.vertical, 10)
                                    .foregroundStyle(category == item.id ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                                    .background(category == item.id ? ZTransferColors.accentBlue.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!enabled)
                                .accessibilityIdentifier("remote-preset-category-\(item.id)")
                        }
                    }
                }.presetScrollEdges().frame(width: available * 0.36)
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(categories.first { $0.id == category }?.choices ?? []) { row($0) }
                    }
                }.presetScrollEdges().id(category).frame(width: available * 0.64)
            }
        }
    }
}

struct RemotePresetChoiceRow: View {
    let text: String
    var selected = false
    var pending = false
    var enabled = true
    var verticalPadding: CGFloat = 8
    var selectionBackground = true
    var centered = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected || pending ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                .lineSpacing(RemotePictureControlLayout.labelLineSpacing).lineLimit(2)
                                    .padding(.vertical, RemotePictureControlLayout.labelLineSpacing / 2)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, verticalPadding)
                .background(selected && selectionBackground ? ZTransferColors.accentBlue.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .modifier(RemoteCameraToolPending(pending: pending))
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Measure the same bounded text/rows before opening; there is no temporary
/// full-height sheet or late scroll-content height handoff.
struct RemotePictureControlLayout {
    let overview: PictureControlOverview
    let categories: [RemotePresetCategory]
    let category: String
    let hostSize: CGSize
    let anchor: CGRect?
    let landscape: Bool
    let scale: CGFloat
    static var labelLineSpacing: CGFloat { max(0, 20 - UIFont.systemFont(ofSize: 14, weight: .medium).lineHeight) }
    static var bodyLineSpacing: CGFloat { max(0, 20 - UIFont.systemFont(ofSize: 14).lineHeight) }
    static func slotLabel(_ item: PictureControlSlotInfo) -> String {
        let label: String = switch item.availability {
        case .occupied: item.name ?? ""
        case .empty: AppLocalized.resource("picture_control_slot_empty")
        case .unreadable: AppLocalized.resource("picture_control_slot_unreadable")
        case .unsupported: AppLocalized.resource("picture_control_slot_unsupported")
        }
        return "C\(item.number) · \(label)"
    }
    private func width(_ value: String) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .medium)]).width * scale) / scale
    }
    private func height(_ value: String, width: CGFloat, limit: Int? = 2, medium: Bool = true) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 14, weight: medium ? .medium : .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = max(0, 20 - font.lineHeight)
        let bounds = (value as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
        let lines = max(1, Int(ceil((bounds.height + paragraph.lineSpacing) / 20)))
        // First line uses font metrics; subsequent baselines are exactly 20pt.
        return CGFloat(min(lines, limit ?? lines)) * 20
    }
    func size(for page: RemotePictureControlPage) -> CGSize {
        let preferred = page.slot == nil ? min(320, (overview.slots.map { width(Self.slotLabel($0)) }.max() ?? 60) + 59) : 260
        let placement = RemoteCameraToolMenuPlacement(host: hostSize, anchor: anchor, landscape: landscape,
            width: preferred, contentHeight: hostSize.height)
        let w = placement.width
        let h: CGFloat
        if page.slot == nil {
            h = overview.slots.reduce(0) { $0 + max(32, height(Self.slotLabel($1), width: w - 59) + 8) } + Self.logHeight
        } else if let confirmation = page.confirmation {
            let message = confirmation == .folder ? AppLocalized.resource("picture_control_choose_folder_hint") :
                String(format: AppLocalized.resource("picture_control_clear_confirm"), (page.slot ?? 200) - 200)
            h = 46 + height(message, width: w - 40, limit: nil, medium: false) + 24 + 72
        } else {
            let inner = max(1, w - 22)
            let left = categories.reduce(CGFloat(0)) { $0 + height($1.label, width: inner * 0.36 - 16) + 20 + 2 }
            let right = (categories.first { $0.id == category }?.choices ?? []).reduce(CGFloat(0)) {
                $0 + height($1.label, width: inner * 0.64 - 24) + 16 + 2
            }
            h = 46 + max(0, max(left, right) - 2)
        }
        return CGSize(width: w, height: min(placement.availableHeight, ceil(h * scale) / scale))
    }
    private static var logHeight: CGFloat {
        #if DEBUG
        36
        #else
        0
        #endif
    }
}

struct RemotePictureControlToolMark: View {
    @ObservedObject var panel: PictureControlPanelModel
    var body: some View {
        if panel.opening { RemoteCameraToolLoading() }
        else { RemoteToolMark(tool: .pictureControl) }
    }
}
private struct PictureControlShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension View {
    @ViewBuilder func presetScrollEdges() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden() }
        else { self }
    }
}
