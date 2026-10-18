import SwiftUI
import UIKit

/// LutChooserHeader / PresetCategoryBrowser: bounded dialog with a fixed header,
/// 36:64 independently scrolling columns and no system sheet toolbar.
struct PhotoEffectChooserDialog<Header: View, Content: View>: View {
    let categoryLabels: [String]
    let optionLabels: [String]
    let onDismiss: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let width = min(320, max(1, proxy.size.width - 48))
            let innerWidth = width - 20
            let listHeight = PhotoEffectChooserMetrics.listHeight(
                categoryLabels: categoryLabels, optionLabels: optionLabels,
                width: innerWidth, viewportHeight: proxy.size.height)
            ZStack {
                Color.black.opacity(0.32).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: onDismiss)
                VStack(spacing: 6) {
                    header.frame(height: 32)
                    if listHeight > 0 { content(innerWidth).frame(height: listHeight) }
                }
                .padding(10).frame(width: width)
                .background(ZTransferColors.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(
                    scheme == .dark ? .white.opacity(0.15) : .black.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .zIndex(200)
    }
}

enum PhotoEffectChooserMetrics {
    /// Resolve final height before presentation; no GeometryReader feedback
    /// that first stretches the dialog and then shrinks it after a frame.
    static func listHeight(categoryLabels: [String], optionLabels: [String], width: CGFloat,
                           viewportHeight: CGFloat,
                           measure: (String, CGFloat, UIFont) -> CGFloat = measureText) -> CGFloat {
        let available = max(0, min(max(viewportHeight - 120, 120), 440) - 58)
        let font = UIFont.systemFont(ofSize: 14, weight: .medium)
        func minimumHeight(_ count: Int, padding: CGFloat) -> CGFloat {
            CGFloat(count) * (ceil(font.lineHeight) + padding) + CGFloat(max(0, count - 1)) * 2
        }
        // Once even one-line rows fill the bounded dialog, no label needs
        // measuring. Otherwise at most a viewport's rows can affect the result.
        if minimumHeight(categoryLabels.count, padding: 20) >= available ||
            minimumHeight(optionLabels.count, padding: 16) >= available { return available }
        func columnHeight(_ labels: [String], width: CGFloat, category: Bool) -> CGFloat {
            var height = CGFloat(max(0, labels.count - 1)) * 2
            for label in labels {
                let textHeight = measure(label, max(1, width - (category ? 16 : 20)), font)
                height += ceil(min(font.lineHeight * 2, max(font.lineHeight, textHeight))) + (category ? 20 : 16)
                if height >= available { return available }
            }
            return height
        }
        let categoryHeight = columnHeight(categoryLabels, width: (width - 6) * 0.36, category: true)
        if categoryHeight >= available { return available }
        return max(categoryHeight, columnHeight(optionLabels, width: (width - 6) * 0.64, category: false))
    }
    static func measureText(_ label: String, width: CGFloat, font: UIFont) -> CGFloat {
        (label as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
    }
}

/// PresetCategoryBrowser keeps stable row identities and independently scrolls
/// each column. UITableView can position a distant selection without laying out
/// every preceding SwiftUI row, as LazyVStack.scrollTo did in the hosted test.
struct PhotoEffectChooserList<Item, ID: Hashable, Row: View>: UIViewRepresentable {
    let items: [Item]
    let id: KeyPath<Item, ID>
    var initialID: ID?
    var rowSpacing: CGFloat = 2
    /// Optional Android log-list follow policy: follow a changed final line
    /// only while the viewport is already within the final three rows.
    var followTailChange: AnyHashable?
    @ViewBuilder let row: (Item) -> Row

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PhotoEffectChooserTable {
        let table = PhotoEffectChooserTable(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            table.topEdgeEffect.isHidden = true
            table.bottomEdgeEffect.isHidden = true
        }
        table.sectionHeaderTopPadding = 0
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 35
        table.dataSource = context.coordinator
        table.register(UITableViewCell.self, forCellReuseIdentifier: "option")
        table.didLayout = { [weak coordinator = context.coordinator] table in
            coordinator?.positionInitially(in: table)
        }
        return table
    }
    func updateUIView(_ table: PhotoEffectChooserTable, context: Context) {
        context.coordinator.update(self, table: table, environment: context.environment)
    }
    static func dismantleUIView(_ table: PhotoEffectChooserTable, coordinator: Coordinator) {
        table.didLayout = nil
    }

    @MainActor final class Coordinator: NSObject, UITableViewDataSource {
        private var parent: PhotoEffectChooserList
        private var ids: [ID] = []
        private var indices: [ID: Int] = [:]
        private var initiallyPositioned = false
        private var environment = EnvironmentValues()
        init(_ parent: PhotoEffectChooserList) { self.parent = parent }

        func update(_ parent: PhotoEffectChooserList, table: UITableView, environment: EnvironmentValues) {
            let anchor = captureAnchor(in: table)
            let nextIDs = parent.items.map { $0[keyPath: parent.id] }
            let changed = nextIDs != ids
            let lastVisible = table.indexPathsForVisibleRows?.map(\.row).max() ?? -1
            let followTail = parent.followTailChange != nil && parent.followTailChange != self.parent.followTailChange
                && (lastVisible == -1 || lastVisible >= nextIDs.count - 3)
            self.parent = parent
            self.environment = environment
            UIView.performWithoutAnimation {
                if changed {
                    ids = nextIDs
                    indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                    table.reloadData()
                } else if table.window != nil {
                    for cell in table.visibleCells {
                        if let index = table.indexPath(for: cell)?.row { configure(cell, at: index) }
                    }
                    // A language/width change can alter two-line row heights.
                    table.beginUpdates(); table.endUpdates()
                }
                if table.window != nil { table.layoutIfNeeded() }
                if changed, table.window != nil, initiallyPositioned, let anchor {
                    let index = indices[anchor.id] ?? min(anchor.index, ids.count - 1)
                    if index >= 0 { position(index, offset: anchor.offset, in: table) }
                }
                if followTail, table.window != nil, initiallyPositioned, !ids.isEmpty {
                    position(ids.count - 1, offset: 0, in: table)
                }
            }
        }

        func positionInitially(in table: UITableView) {
            guard !initiallyPositioned, table.window != nil,
                  table.bounds.width > 0, table.bounds.height > 0, !ids.isEmpty else { return }
            initiallyPositioned = true
            let index = parent.initialID.flatMap { indices[$0] } ?? 0
            position(index, offset: 0, in: table)
        }
        private func position(_ index: Int, offset: CGFloat, in table: UITableView) {
            let path = IndexPath(row: index, section: 0)
            table.scrollToRow(at: path, at: .top, animated: false)
            table.layoutIfNeeded()
            // scrollToRow starts from estimated heights. Now that the target
            // cell is measured, align its actual rect before the first frame.
            let maximum = max(0, table.contentSize.height - table.bounds.height)
            let y = table.rectForRow(at: path).minY + offset
            table.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, y))), animated: false)
        }
        private func captureAnchor(in table: UITableView) -> (id: ID, index: Int, offset: CGFloat)? {
            guard initiallyPositioned,
                  let index = table.indexPathsForVisibleRows?.map(\.row).min(), ids.indices.contains(index) else { return nil }
            let y = table.rectForRow(at: IndexPath(row: index, section: 0)).minY
            return (ids[index], index, table.contentOffset.y - y)
        }
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { ids.count }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "option", for: indexPath)
            configure(cell, at: indexPath.row)
            return cell
        }
        private func configure(_ cell: UITableViewCell, at index: Int) {
            guard parent.items.indices.contains(index) else { return }
            cell.selectionStyle = .none
            cell.backgroundConfiguration = .clear()
            let content = parent.row(parent.items[index]).id(ids[index])
            let spacing: CGFloat = index + 1 < ids.count ? parent.rowSpacing : 0
            let environment = environment
            cell.contentConfiguration = UIHostingConfiguration {
                content.padding(.bottom, spacing)
                    .environment(\.colorScheme, environment.colorScheme)
                    .environment(\.locale, environment.locale)
                    .environment(\.layoutDirection, environment.layoutDirection)
                    .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                    .environment(\.isEnabled, environment.isEnabled)
            }.margins(.all, 0).minSize(width: 0, height: 0)
        }
    }
}

final class PhotoEffectChooserTable: UITableView {
    var didLayout: ((UITableView) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?(self)
    }
}

struct PhotoEffectChooserAction: View {
    let label: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(selected ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ZTransferColors.secondaryText.opacity(0.28), lineWidth: 0.75))
        }.buttonStyle(.plain)
    }
}

struct PhotoEffectChooserRow: View {
    let label: String
    var selected = false
    var favorite = false
    var category = false
    var accent = ZTransferColors.accentBlue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(favorite ? ZTransferColors.accentYellow :
                    (selected ? accent : (category ? ZTransferColors.secondaryText : ZTransferColors.primaryText)))
                .padding(.horizontal, category ? 8 : 10).padding(.vertical, category ? 10 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? accent.opacity(category ? 0.14 : 0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
