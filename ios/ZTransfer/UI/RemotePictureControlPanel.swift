import SwiftUI
import UniformTypeIdentifiers

/// Functional slot editor; detailed popup styling is deferred with the visual work.
struct RemotePictureControlPanel: View {
    @ObservedObject var model: PictureControlPanelModel
    @ObservedObject var folders: PictureControlFolderState
    @Environment(\.scenePhase) private var phase
    @State private var choosingFolder = false
    @State private var folderConfirmation = false
    @State private var clearConfirmation = false
    @State private var category: String = "built-in"
    @State private var shareURL: URL?
    @State private var sharing = false
    let dismiss: () -> Void
    private func text(_ key: String) -> String { AppLocalized.resource(key) }
    var body: some View {
        NavigationStack {
            Group {
                if model.loading && model.overview == nil { ProgressView(text("picture_control_loading")) }
                else if let slot = model.editingSlot, let target = model.overview?.slots.first(where: { $0.slot == slot }) {
                    editor(target)
                } else { slots }
            }
            .navigationTitle(model.editingSlot.map { "C\($0 - 200)" } ?? text("picture_control_slots_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.editingSlot == nil ? text("picture_control_cancel") : text("picture_control_back")) {
                        if model.editingSlot != nil { model.editingSlot = nil } else { dismiss() }
                    }.disabled(model.pending != nil)
                }
                if model.editingSlot != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(text("picture_control_folder")) {
                            if folders.folder == nil { folderConfirmation = true } else { choosingFolder = true }
                        }.disabled(!model.canBrowse)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.pending != nil)
        .sheet(isPresented: $sharing) {
            if let shareURL { PictureControlShareSheet(url: shareURL) }
        }
        .onAppear { model.open(); folders.onNotice = { model.notice(text($0)) } }
        .onChange(of: model.editingSlot) { slot in if slot != nil { category = "built-in"; folders.refresh() } }
        .onChange(of: phase) { if $0 == .active && model.editingSlot != nil { folders.refresh() } }
        .onChange(of: folders.failure) {
            if let reason = $0 {
                if reason == .missing || reason == .denied { category = "built-in" }
                model.notice(text(PictureControlFolderState.message(reason)))
            }
        }
        .onChange(of: folders.files) { files in
            let keys = Set(files.map { "folder:" + ($0.category ?? "") })
            if category != "built-in" && !keys.contains(category) { category = "built-in" }
        }
        .onChange(of: folders.scanning) { scanning in
            if !scanning && folders.failure == nil && folders.hasSnapshot && folders.files.isEmpty {
                model.notice(text("picture_control_folder_empty"))
            }
        }
        .onChange(of: model.presetsFailed) { if $0 { model.notice(text("picture_control_files_failed")) } }
        .alert(text("picture_control_choose_folder_hint"), isPresented: $folderConfirmation) {
            Button(text("picture_control_confirm")) { choosingFolder = true }
            Button(text("picture_control_cancel"), role: .cancel) {}
        }
        .alert(String(format: text("picture_control_clear_confirm"), (model.editingSlot ?? 200) - 200), isPresented: $clearConfirmation) {
            Button(text("picture_control_confirm"), role: .destructive) {
                if let slot = model.editingSlot { model.act(.clear(slot)) }
            }
            Button(text("picture_control_cancel"), role: .cancel) {}
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): folders.changeFolder(url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.notice(text("lut_folder_denied")) }
            }
        }
    }
    private var slots: some View {
        List {
            ForEach(model.overview?.slots ?? []) { slot in
                HStack {
                    Button {
                        if slot.availability == .empty { model.editingSlot = slot.slot }
                        else { model.act(.activate(slot.slot)) }
                    } label: {
                        HStack {
                            Text("C\(slot.number) · \(slotLabel(slot))")
                            Spacer()
                            if model.overview?.selected == slot.slot { Image(systemName: "checkmark") }
                            if model.pending?.slot == slot.slot { ProgressView() }
                        }
                    }
                    .disabled(!model.canBrowse || (slot.availability == .empty ? !model.canEdit(slot) :
                        slot.availability != .occupied || model.overview?.canActivate != true))
                    Button { model.editingSlot = slot.slot } label: { Image(systemName: "pencil") }
                        .accessibilityLabel(String(format: text("picture_control_edit_slot"), slot.number))
                        .disabled(!model.canEdit(slot))
                }.buttonStyle(.borderless)
            }
            #if DEBUG
            if !model.report.isEmpty {
                Button(text("picture_control_test_log")) {
                    do { shareURL = try PictureControlReportJournal.share(model.report); sharing = true }
                    catch { model.notice(text("picture_control_report_share_failed")) }
                }.disabled(!model.canBrowse)

            }
            #endif
        }
    }
    private func slotLabel(_ slot: PictureControlSlotInfo) -> String {
        switch slot.availability {
        case .occupied: slot.name ?? ""
        case .empty: text("picture_control_slot_empty")
        case .unreadable: text("picture_control_slot_unreadable")
        case .unsupported: text("picture_control_slot_unsupported")
        }
    }
    private func editor(_ slot: PictureControlSlotInfo) -> some View {
        let accessible = folders.failure != .missing && folders.failure != .denied
        let files = accessible ? folders.files : []
        let categories = PhotoLUTCategorySelection.categories(in: files)
        let labels = RemoteLUTCatalog.labels(files, uncategorized: text("lut_uncategorized"))
        return List {
            if slot.availability == .occupied {
                Button(text("picture_control_clear_slot"), role: .destructive) { clearConfirmation = true }
                    .disabled(!model.canEdit(slot))
            }
            Picker("", selection: $category) {
                Text(text("picture_control_built_in")).tag("built-in")
                ForEach(Array(categories.enumerated()), id: \.offset) { _, name in
                    Text(name ?? text("lut_uncategorized")).tag("folder:" + (name ?? ""))
                }
            }.disabled(!model.canBrowse)
            if category == "built-in" {
                ForEach(model.presets) { preset in
                    Button(preset.name) { model.act(.write(slot.slot, .builtIn(preset))) }.disabled(!model.canEdit(slot))
                }
            } else {
                ForEach(files.filter { "folder:" + ($0.category ?? "") == category }, id: \.identifier) { file in
                    Button(labels[file.identifier] ?? file.label) { model.act(.write(slot.slot, .document(file))) }
                        .disabled(!model.canEdit(slot) || folders.scanning)
                }
            }
            if model.pending != nil { ProgressView(text("picture_control_slot_busy")) }
        }
    }
}

private struct PictureControlShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
