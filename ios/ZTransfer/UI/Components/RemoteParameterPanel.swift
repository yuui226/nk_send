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
    @State private var rowsHeight: CGFloat?
    @State private var positioned = false
    @State private var initialIndex: Int

    init(field: RemoteExposureField, descriptor: RemotePropertyDescriptor, anchor: CGRect?, hostSize: CGSize,
         landscape: Bool, onSelect: @escaping (UInt64) -> Void, onDismiss: @escaping () -> Void) {
        self.field = field; self.descriptor = descriptor; self.anchor = anchor
        self.hostSize = hostSize; self.landscape = landscape; self.onSelect = onSelect; self.onDismiss = onDismiss
        _initialIndex = State(initialValue: max(0, (descriptor.values.firstIndex(of: descriptor.current) ?? -1) - 3))
    }

    private var preferredWidth: CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        let width = descriptor.values.map {
            ceil((RemoteExposureParameters.monitorFormat(descriptor.property, raw: $0) as NSString)
                .size(withAttributes: [.font: font]).width * scale) / scale
        }.max() ?? 0
        return min(220, max(64, width + 28))
    }
    var body: some View {
        RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape,
            width: preferredWidth, contentHeight: rowsHeight.map { $0 + 8 }, closing: closing,
            trigger: field.popupTrigger, accessibilityID: "remote-parameter-menu-backdrop",
            close: { closing = true }, dismiss: onDismiss, besideAnchor: landscape, usesFullAnchor: true) { placement in
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(descriptor.values.enumerated()), id: \.element) { index, value in
                                choice(value).id(index)
                            }
                        }
                        .background { GeometryReader { proxy in
                            Color.clear.preference(key: RemoteParameterRowsHeight.self, value: proxy.size.height)
                        } }
                    }
                    .frame(height: min(rowsHeight ?? placement.availableHeight, max(0, placement.availableHeight - 8)))
                    .onChange(of: rowsHeight) { height in
                        guard height != nil, !positioned else { return }
                        positioned = true
                        reader.scrollTo(initialIndex, anchor: .top)
                    }
                }
                .padding(.vertical, 4)
                .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onPreferenceChange(RemoteParameterRowsHeight.self) { if let height = $0, height > 0 { rowsHeight = height } }
            }
    }
    private func choice(_ value: UInt64) -> some View {
        let selected = value == descriptor.current
        return Button {
            onSelect(value)
            closing = true
        } label: {
            Text(RemoteExposureParameters.monitorFormat(descriptor.property, raw: value))
                .font(.system(size: 15, weight: selected ? .semibold : .regular, design: .monospaced))
                .lineLimit(1).frame(maxWidth: .infinity)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                // Use an explicit rectangle: newer iOS plain buttons supply
                // a rounded background shape to the ShapeStyle overload.
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
