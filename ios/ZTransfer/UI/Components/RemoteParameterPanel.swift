import SwiftUI
import UIKit

/// Android RemoteParameterPanel.kt: no header, rcFormat labels, initial
/// selection minus three rows, immediate write and animated close. Width is
/// measured using the semibold monospaced font even for unselected rows.
struct RemoteParameterPanel: View {
    let field: RemoteExposureField
    let descriptor: RemotePropertyDescriptor
    let anchor: CGRect?
    let hostSize: CGSize
    let landscape: Bool
    let onSelect: (UInt64) -> Void
    let onDismiss: () -> Void
    @Environment(\.displayScale) private var scale
    @State private var closing = false
    @State private var rowHeight: CGFloat?
    @State private var catalogCache = RemoteParameterMenuCache()
    @State private var initialIndex: Int

    init(field: RemoteExposureField, descriptor: RemotePropertyDescriptor, anchor: CGRect?, hostSize: CGSize,
         landscape: Bool, onSelect: @escaping (UInt64) -> Void, onDismiss: @escaping () -> Void) {
        self.field = field; self.descriptor = descriptor; self.anchor = anchor
        self.hostSize = hostSize; self.landscape = landscape; self.onSelect = onSelect; self.onDismiss = onDismiss
        _initialIndex = State(initialValue: max(0, (descriptor.values.firstIndex(of: descriptor.current) ?? -1) - 3))
    }

    var body: some View {
        let catalog = catalogCache.resolve(descriptor: descriptor, scale: scale)
        let height = rowHeight.map { $0 * CGFloat(descriptor.values.count) }
        RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape,
            width: catalog.width, contentHeight: height.map { $0 + 8 }, closing: closing,
            trigger: field.popupTrigger, accessibilityID: "remote-parameter-menu-backdrop",
            close: { closing = true }, dismiss: onDismiss, besideAnchor: landscape, usesFullAnchor: true) { placement in
                PhotoEffectChooserList(items: descriptor.values, id: \.self,
                    initialID: descriptor.values.indices.contains(initialIndex) ? descriptor.values[initialIndex] : nil,
                    rowSpacing: 0) { value in
                        choice(value, label: catalog.labels[value] ?? "")
                    }
                    .frame(height: min(height ?? placement.availableHeight, max(0, placement.availableHeight - 8)))
                    // All entries use the same single-line font and padding.
                    // Measure one real SwiftUI row (including pixel rounding),
                    // not an eager VStack of the entire camera value domain.
                    .background(alignment: .top) {
                        choice(descriptor.current, label: " ")
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden().allowsHitTesting(false).accessibilityHidden(true)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: RemoteParameterRowsHeight.self, value: proxy.size.height)
                            } }
                    }
                    .padding(.vertical, 4)
                    .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onPreferenceChange(RemoteParameterRowsHeight.self) {
                        if let next = $0, next > 0, next != rowHeight { rowHeight = next }
                    }
            }
    }
    private func choice(_ value: UInt64, label: String) -> some View {
        RemoteParameterChoice(value: value, label: label, selected: value == descriptor.current,
            closing: closing) { onSelect(value); closing = true }
    }
}

struct RemoteParameterChoice: View {
    let value: UInt64
    let label: String
    let selected: Bool
    let closing: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: selected ? .semibold : .regular, design: .monospaced))
                .lineLimit(1).frame(maxWidth: .infinity)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                // Preserve the rectangular full-width highlight on newer iOS.
                .background { Rectangle().fill(selected ? ZTransferColors.accentBlue.opacity(0.08) : .clear) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(closing)
        .accessibilityIdentifier("remote-parameter-choice-\(value)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RemoteParameterRowsHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// Android remember(prop, values) / remember(labels, density, style). Current
/// selection and closing animations do not reformat or remeasure the domain.
@MainActor
final class RemoteParameterMenuCache {
    final class Catalog {
        let property: RemoteProperty
        let values: [UInt64]
        let labels: [UInt64: String]
        let scale: CGFloat
        let width: CGFloat
        init(property: RemoteProperty, values: [UInt64], labels: [UInt64: String], scale: CGFloat, width: CGFloat) {
            self.property = property; self.values = values; self.labels = labels
            self.scale = scale; self.width = width
        }
    }
    private var catalog: Catalog?
    func resolve(descriptor: RemotePropertyDescriptor, scale: CGFloat,
                 format: (RemoteProperty, UInt64) -> String = RemoteExposureParameters.monitorFormat,
                 measure: @MainActor (String, CGFloat) -> CGFloat = measureLabel) -> Catalog {
        let previous = catalog
        let sameLabels = previous?.property == descriptor.property && previous?.values == descriptor.values
        if sameLabels, let previous, previous.scale == scale { return previous }
        let labels: [UInt64: String]
        if sameLabels, let previous { labels = previous.labels }
        else { labels = Dictionary(descriptor.values.map { ($0, format(descriptor.property, $0)) },
                                   uniquingKeysWith: { first, _ in first }) }
        let width = labels.values.reduce(CGFloat.zero) { max($0, measure($1, scale)) }
        let next = Catalog(property: descriptor.property, values: descriptor.values,
            labels: labels, scale: scale, width: min(220, max(64, width + 28)))
        catalog = next
        return next
    }
    private static func measureLabel(_ text: String, scale: CGFloat) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width * scale) / scale
    }
}
