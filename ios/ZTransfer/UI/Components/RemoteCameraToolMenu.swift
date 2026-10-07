import SwiftUI
import UIKit

/// RemoteChoicePopup.kt: all coordinates are in the rotated monitor host.
struct RemoteCameraToolMenuPlacement {
    let width: CGFloat
    let availableHeight: CGFloat
    let opensAbove: Bool
    let frame: CGRect

    init(host: CGSize, anchor: CGRect?, landscape: Bool, width: CGFloat, contentHeight: CGFloat) {
        let above = max(0, min(host.height, max(0, anchor?.minY ?? 0)) - 14)
        let below = max(0, host.height - min(host.height, max(0, anchor?.maxY ?? 0)) - 14)
        opensAbove = landscape && anchor != nil && above > below
        availableHeight = max(1, opensAbove ? above : below)
        self.width = min(width, max(1, host.width - 16))
        let height = min(max(1, contentHeight), availableHeight)
        let x = min(max(8, anchor?.minX ?? 8), max(8, host.width - self.width - 8))
        let wantedY = opensAbove ? (anchor?.minY ?? host.height) - 6 - height : (anchor?.maxY ?? 8) + 6
        frame = CGRect(x: x, y: min(max(0, wantedY), max(0, host.height - height)), width: self.width, height: height)
    }
}

struct RemoteCameraToolMenu: View {
    @ObservedObject var panel: RemoteCameraToolController
    let anchor: CGRect?
    let hostSize: CGSize
    let landscape: Bool
    let canWrite: Bool
    @Environment(\.displayScale) private var scale
    @State private var rowsHeight: CGFloat?
    @State private var headerHeight: CGFloat = 0

    private var isWB: Bool { panel.tool == .whiteBalance }
    private var fontSize: CGFloat { isWB ? 13 : 14 }
    private var values: [UInt64] { panel.descriptor.map { panel.tool.orderedValues($0, model: panel.deviceModel) } ?? [] }
    private var trigger: GeniePopupTrigger {
        switch panel.tool {
        case .whiteBalance: .remoteWhiteBalance
        case .focusArea: .remoteFocusArea
        case .focusMode: .remoteFocusMode
        }
    }

    private func label(_ value: UInt64) -> String {
        if let p = panel.descriptor,
           panel.tool == .focusMode,
           p.property == .stillFocusMode,
           value == 3 {
            return AppLocalized.resource("remote_focus_manual_fixed")
        }
        if let p = panel.descriptor,
           panel.tool == .focusMode,
           let label = RemoteFocusMode.label(property: p.property, value: value) {
            return label
        }
        if let p = panel.descriptor,
           let key = panel.tool.labelResource(property: p.property.rawValue, value: value,
                                               model: panel.deviceModel, dataType: p.dataType) {
            return AppLocalized.resource(key)
        }
        return AppLocalized.formattedResource("remote_camera_option", ["%1$s": String(Int64(bitPattern: value))])
    }

    private func hasTap(_ value: UInt64) -> Bool {
        panel.descriptor.map { panel.tool.hasTapMarker($0, value: value, model: panel.deviceModel) } ?? false
    }

    private var preferredWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize)
        let maximum = values.map { value in
            ceil((label(value) as NSString).size(withAttributes: [.font: font]).width * scale) / scale
                + (hasTap(value) ? 22 : 0)
        }.max() ?? 60
        return isWB ? min(300, max(252, (maximum + 12) * 3 + 12)) : min(280, max(48, maximum + 24))
    }

    var body: some View {
        RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape,
            width: preferredWidth, contentHeight: rowsHeight.map { $0 + headerHeight + 8 },
            closing: panel.closeRequested, trigger: trigger,
            accessibilityID: "remote-camera-menu-backdrop", close: panel.requestClose, dismiss: panel.dismiss) {
                content(placement: $0)
            }
    }

    private func content(placement: RemoteCameraToolMenuPlacement) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if panel.descriptor == nil || panel.descriptor?.writable != true || panel.descriptor?.values.isEmpty == true {
                    Text(AppLocalized.resource("remote_camera_tool_unavailable"))
                        .foregroundStyle(ZTransferColors.secondaryText)
                        .font(.system(size: 12)).padding(12)
                }
                if let error = panel.errorResource {
                    Text(AppLocalized.resource(error)).foregroundStyle(ZTransferColors.accentOrange)
                        .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 8)
                        .accessibilityIdentifier("remote-camera-tool-error")
                }
            }
            .background { GeometryReader { proxy in
                Color.clear.preference(key: RemoteCameraToolHeaderHeight.self, value: proxy.size.height)
            } }
            ScrollView {
                VStack(spacing: isWB ? 2 : 0) {
                    if isWB {
                        ForEach(Array(stride(from: 0, to: values.count, by: 3)), id: \.self) { start in
                            HStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { column in
                                    if start + column < values.count { choice(values[start + column]).frame(maxWidth: .infinity) }
                                    else { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                                }
                            }
                        }
                    } else { ForEach(values, id: \.self) { choice($0) } }
                }
                .padding(.horizontal, isWB ? 4 : 0)
                .background { GeometryReader { proxy in
                    Color.clear.preference(key: RemoteCameraToolRowsHeight.self, value: proxy.size.height)
                } }
            }
            .frame(height: min(rowsHeight ?? placement.availableHeight, max(0, placement.availableHeight - headerHeight - 8)))
        }
        .padding(.vertical, 4)
        .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onPreferenceChange(RemoteCameraToolRowsHeight.self) {
            // A hosting-root replacement emits the preference's empty value;
            // it is not a measurement of the camera's real rows.
            if let height = $0, height > 0 || values.isEmpty { rowsHeight = height }
        }
        .onPreferenceChange(RemoteCameraToolHeaderHeight.self) { headerHeight = $0 }
    }

    private func choice(_ value: UInt64) -> some View {
        let selected = panel.busy ? panel.pendingValue == value : panel.descriptor?.current == value
        let name = label(value)
        let color = selected ? ZTransferColors.accentBlue : ZTransferColors.primaryText
        let secondary = selected ? ZTransferColors.accentBlue : ZTransferColors.secondaryText
        let qualifier = name.firstIndex { $0 == "(" || $0 == "（" }
        let text = qualifier.map {
            Text(String(name[..<$0])).foregroundColor(color) + Text(String(name[$0...])).foregroundColor(secondary)
        } ?? Text(name).foregroundColor(color)
        return Button { panel.select(value) } label: {
            HStack(spacing: 6) {
                text.font(.system(size: fontSize))
                    .lineSpacing(max(0, (isWB ? 18 : 20) - UIFont.systemFont(ofSize: fontSize).lineHeight))
                    .multilineTextAlignment(isWB ? .center : .leading)
                    .lineLimit(isWB ? 2 : nil)
                    .frame(maxWidth: .infinity, alignment: isWB ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if hasTap(value) {
                    RemoteEditorIcon(kind: .touch).fill(secondary).frame(width: 16, height: 16)
                        .accessibilityLabel(AppLocalized.resource("remote_af_tap_badge"))
                }
            }
            .padding(.horizontal, isWB ? 6 : 12).padding(.vertical, isWB ? 4 : 8)
            .frame(minHeight: isWB ? 40 : nil)
            .background(selected ? ZTransferColors.accentBlue.opacity(0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: isWB ? 8 : 0))
            .contentShape(Rectangle())
            .modifier(RemoteCameraToolPending(pending: panel.busy && panel.pendingValue == value && !panel.closeRequested))
        }
        .buttonStyle(.plain)
        .disabled(panel.closeRequested || panel.busy || !canWrite || panel.descriptor?.writable != true || panel.descriptor?.values.contains(value) != true)
        .accessibilityIdentifier("remote-camera-choice-\(value)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RemoteCameraToolRowsHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}
private struct RemoteCameraToolHeaderHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct RemoteCameraToolMenuHost: View {
    @ObservedObject var panel: RemoteCameraToolController
    let anchor: CGRect?
    let hostSize: CGSize
    let landscape: Bool
    let canWrite: Bool
    var body: some View {
        if !panel.loading {
            RemoteCameraToolMenu(panel: panel, anchor: anchor, hostSize: hostSize,
                                 landscape: landscape, canWrite: canWrite)
        }
    }
}
