import SwiftUI
import UIKit

/// RemoteLutPanel.kt / LutCategoryList.kt: anchored chooser, fixed global
/// actions and independent 36:64 columns. Monitor and photo LUT state stay separate.
struct RemoteLUTPanel: View {
    @ObservedObject var monitor: RemoteLUTMonitorState
    let anchor: CGRect?
    let hostSize: CGSize
    let landscape: Bool
    let closing: Bool
    let pickerActive: Bool
    let close: () -> Void
    let dismiss: () -> Void
    let onChooseFolder: () -> Void
    @State private var categorySelection = PhotoLUTCategorySelection()

    private func categoryLabel(_ category: String?) -> String {
        category ?? AppLocalized.resource("lut_uncategorized")
    }

    var body: some View {
        let status = RemoteLUTPanelStatus(hasFolder: monitor.folder != nil,
            failure: monitor.folderFailure, scanning: monitor.scanning, empty: monitor.files.isEmpty)
        let catalog = monitor.catalog
        // Reconcile before measuring the first frame; preserve user browsing on rescan.
        var selection = categorySelection
        let _ = selection.reconcile(catalog: catalog, selected: monitor.active?.file.identifier)
        let category = selection.category
        let visible = catalog.filesByCategory[category] ?? []
        let showList = status.accessible && !monitor.files.isEmpty
        let layout = RemoteLUTPanelLayout(hostSize: hostSize, anchor: anchor, landscape: landscape,
            hasFiles: !monitor.files.isEmpty, guidance: status.guidance.map { AppLocalized.resource($0) },
            monitorOnly: status.showMonitorOnly ? AppLocalized.resource("lut_monitor_only") : nil,
            categories: showList ? catalog.categories.map(categoryLabel) : [],
            options: showList ? visible : [])
        let enabled = !closing && !pickerActive
        RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape,
            width: layout.width, contentHeight: layout.height, closing: closing,
            trigger: .remoteLUT, accessibilityID: "remote-lut-backdrop", close: close, dismiss: dismiss) { _ in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    PhotoEffectChooserAction(label: AppLocalized.resource("lut_turn_off"), selected: monitor.active == nil) {
                        ZTransferHaptics.shared.play(.selection); monitor.chooseOff()
                    }.accessibilityIdentifier("remote-lut-off")
                    PhotoEffectChooserAction(label: AppLocalized.resource("lut_folder")) {
                        ZTransferHaptics.shared.play(.navigation)
                        monitor.prepareFolderPicker(); onChooseFolder()
                    }.accessibilityIdentifier("remote-lut-folder")
                }.disabled(!enabled).padding(.bottom, 6)
                if let guidance = status.guidance {
                    Text(AppLocalized.resource(guidance)).zTransferTypography(.bodySmall, weight: .regular)
                        .foregroundStyle(ZTransferColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true).padding(12)
                }
                if status.showMonitorOnly {
                    Text(AppLocalized.resource("lut_monitor_only")).zTransferTypography(.bodySmall, weight: .regular)
                        .foregroundStyle(ZTransferColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
                }
                if showList {
                    HStack(alignment: .top, spacing: 6) {
                        PhotoEffectChooserList(items: catalog.categories, id: \.self, initialID: .some(category)) { value in
                            RemotePresetChoiceRow(text: categoryLabel(value), selected: category == value,
                                enabled: enabled, verticalPadding: 10, category: true) {
                                categorySelection = selection
                                categorySelection.category = value
                            }.accessibilityIdentifier("remote-lut-category-\(value.map { "folder:\($0)" } ?? "root")")
                        }.frame(width: layout.columnWidth * 0.36)
                        PhotoEffectChooserList(items: visible, id: \.identifier,
                            initialID: visible.first { $0.identifier == monitor.active?.file.identifier }?.identifier ?? visible.first?.identifier) { file in
                            RemotePresetChoiceRow(text: file.label, selected: monitor.active?.file.identifier == file.identifier,
                                pending: monitor.loadingIdentifier == file.identifier, enabled: enabled) {
                                ZTransferHaptics.shared.play(.selection); monitor.select(file)
                            }.accessibilityIdentifier("remote-lut-option-\(file.identifier)")
                        }.id(category).frame(width: layout.columnWidth * 0.64)
                    }.frame(height: layout.listHeight)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10) // panel 6 + popup shell 4
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(enabled)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote-lut-popup")
        }
        .onAppear { categorySelection = selection }
        .onChange(of: ObjectIdentifier(catalog)) { _ in
            categorySelection.reconcile(catalog: catalog, selected: monitor.active?.file.identifier)
        }
        .onChange(of: monitor.active?.file.identifier) {
            categorySelection.reconcile(catalog: catalog, selected: $0)
        }
    }
}

/// Bounded measurement before opening: no full-height first frame, and no
/// traversal of a large catalog once the visible column is already filled.
struct RemoteLUTPanelLayout {
    let width: CGFloat
    let height: CGFloat
    let listHeight: CGFloat
    var columnWidth: CGFloat { max(0, width - 26) }

    init(hostSize: CGSize, anchor: CGRect?, landscape: Bool, hasFiles: Bool,
         guidance: String?, monitorOnly: String?, categories: [String], options: [RemoteLUTFile]) {
        let placement = RemoteCameraToolMenuPlacement(host: hostSize, anchor: anchor, landscape: landscape,
            width: hasFiles ? 320 : 260, contentHeight: hostSize.height)
        let resolvedWidth = placement.width
        width = resolvedWidth
        func textHeight(_ text: String, width: CGFloat, size: CGFloat, line: CGFloat, limit: Int?) -> CGFloat {
            let font = UIFont.systemFont(ofSize: size, weight: size == 14 ? .medium : .regular)
            let measured = PhotoEffectChooserMetrics.measureText(text, width: max(1, width), font: font)
            let lines = max(1, Int(ceil(measured / font.lineHeight)))
            return CGFloat(min(lines, limit ?? lines)) * line
        }
        let fixed = 58 + (guidance.map { textHeight($0, width: resolvedWidth - 44, size: 12, line: 16, limit: nil) + 24 } ?? 0)
            + (monitorOnly.map { textHeight($0, width: resolvedWidth - 44, size: 12, line: 16, limit: nil) } ?? 0)
        let available = max(0, placement.availableHeight - fixed)
        func column(count: Int, label: (Int) -> String, width: CGFloat, padding: CGFloat) -> CGFloat {
            if CGFloat(count) * (20 + padding + 2) - 2 >= available { return available }
            var value: CGFloat = 0
            for index in 0..<count {
                if value > 0 { value += 2 }
                value += textHeight(label(index), width: width, size: 14, line: 20, limit: 2) + padding
                if value >= available { return available }
            }
            return value
        }
        listHeight = max(column(count: categories.count, label: { categories[$0] }, width: (width - 26) * 0.36 - 16, padding: 20),
                         column(count: options.count, label: { options[$0].label }, width: (width - 26) * 0.64 - 24, padding: 16))
        height = min(placement.availableHeight, fixed + listHeight)
    }
}
