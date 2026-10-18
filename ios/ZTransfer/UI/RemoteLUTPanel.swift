import SwiftUI

/// Android LutCategoryList keeps browsing state local to the open menu and
/// preserves that category on a rescan unless it disappears or selection changes.
struct RemoteLUTPanel: View {
    @ObservedObject var monitor: RemoteLUTMonitorState
    let onChooseFolder: () -> Void
    @State private var categorySelection: PhotoLUTCategorySelection

    init(monitor: RemoteLUTMonitorState, onChooseFolder: @escaping () -> Void) {
        self.monitor = monitor
        self.onChooseFolder = onChooseFolder
        var selection = PhotoLUTCategorySelection()
        selection.reconcile(catalog: monitor.catalog, selected: monitor.active?.file.identifier)
        _categorySelection = State(initialValue: selection)
    }

    var body: some View {
        let status = RemoteLUTPanelStatus(hasFolder: monitor.folder != nil,
            failure: monitor.folderFailure, scanning: monitor.scanning, empty: monitor.files.isEmpty)
        let catalog = monitor.catalog
        let categories = catalog.categories
        let visible = catalog.filesByCategory[categorySelection.category] ?? []
        return NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        ZTransferHaptics.shared.tick()
                        monitor.chooseOff()
                    } label: {
                        HStack {
                            Text(AppLocalized.resource("lut_turn_off"))
                            if monitor.active == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Spacer()
                    Button(AppLocalized.resource(status.folderAction)) {
                        ZTransferHaptics.shared.tick()
                        monitor.prepareFolderPicker()
                        onChooseFolder()
                    }
                }
                if let guidance = status.guidance { Text(AppLocalized.resource(guidance)).font(.footnote) }
                if status.showMonitorOnly { Text(AppLocalized.resource("lut_monitor_only")).font(.footnote) }
                if let notice = monitor.noticeResource, notice != status.guidance {
                    Text(AppLocalized.resource(notice)).font(.footnote)
                }
                if status.accessible && !monitor.files.isEmpty {
                    if categories.count > 1 {
                        Picker("", selection: $categorySelection.category) {
                            ForEach(categories, id: \.self) { category in
                                Text(category ?? AppLocalized.resource("lut_uncategorized")).tag(category)
                            }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    ScrollViewReader { proxy in
                        List(visible, id: \.identifier) { file in
                            Button {
                                ZTransferHaptics.shared.tick()
                                monitor.select(file)
                            } label: {
                                HStack {
                                    Text(file.label).lineLimit(2)
                                    Spacer()
                                    if monitor.loadingIdentifier == file.identifier { ProgressView() }
                                    if monitor.active?.file.identifier == file.identifier { Image(systemName: "checkmark") }
                                }
                            }.id(file.identifier)
                        }
                        .onAppear {
                            if let target = visible.first(where: { $0.identifier == monitor.active?.file.identifier }) ?? visible.first {
                                proxy.scrollTo(target.identifier, anchor: .top)
                            }
                        }
                    }.id(categorySelection.category)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("LUT")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: ObjectIdentifier(catalog)) { _ in
                categorySelection.reconcile(catalog: catalog, selected: monitor.active?.file.identifier)
            }
            .onChange(of: monitor.active?.file.identifier) { selected in
                categorySelection.reconcile(catalog: catalog, selected: selected)
            }
        }
    }

}
