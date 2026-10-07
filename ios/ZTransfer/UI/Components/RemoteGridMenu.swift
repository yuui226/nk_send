import SwiftUI
import UIKit

struct RemoteGridMenu: View {
    @ObservedObject var tools: RemoteToolPreferences
    let anchor: CGRect?
    let hostSize: CGSize
    let landscape: Bool
    @Binding var closing: Bool
    let dismiss: () -> Void
    @Environment(\.displayScale) private var scale
    @State private var rowsHeight: CGFloat?

    private var preferredWidth: CGFloat {
        let maximum = RemoteGridMode.menuOrder.map {
            ceil((AppLocalized.resource($0.labelResource) as NSString)
                .size(withAttributes: [.font: UIFont.systemFont(ofSize: 14)]).width * scale) / scale
        }.max() ?? 0
        return min(280, max(48, maximum + 24))
    }

    var body: some View {
        RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape,
            width: preferredWidth, contentHeight: rowsHeight.map { $0 + 8 }, closing: closing,
            trigger: .remoteGrid, accessibilityID: "remote-grid-menu-backdrop",
            close: { closing = true }, dismiss: dismiss) { placement in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(RemoteGridMode.menuOrder, id: \.self) { option in
                            Button {
                                tools.grid = option
                                closing = true
                            } label: {
                                Text(AppLocalized.resource(option.labelResource))
                                    .font(.system(size: 14))
                                    .foregroundStyle(tools.grid == option ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                                    .lineSpacing(max(0, 20 - UIFont.systemFont(ofSize: 14).lineHeight))
                                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(tools.grid == option ? ZTransferColors.accentBlue.opacity(0.08) : .clear)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(closing)
                            .accessibilityIdentifier("remote-grid-choice-\(option.rawValue)")
                            .accessibilityAddTraits(tools.grid == option ? .isSelected : [])
                        }
                    }
                    .background { GeometryReader { proxy in
                        Color.clear.preference(key: RemoteGridRowsHeight.self, value: proxy.size.height)
                    } }
                }
                .frame(height: min(rowsHeight ?? placement.availableHeight, max(0, placement.availableHeight - 8)))
                .padding(.vertical, 4)
                .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onPreferenceChange(RemoteGridRowsHeight.self) { if let height = $0, height > 0 { rowsHeight = height } }
            }
    }
}

private struct RemoteGridRowsHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// GridMark: 2dp inset, 1.5dp stroke; OFF retains a thirds icon.
struct RemoteFramingGridMark: View {
    let grid: RemoteGridMode
    var body: some View {
        Canvas { context, size in
            let mode = grid == .off ? RemoteGridMode.thirds : grid
            let inner = CGSize(width: max(0, size.width - 4), height: max(0, size.height - 4))
            let lines = RemoteFramingGrid.lines(mode, width: Float(inner.width), height: Float(inner.height),
                                                aspect: Float(inner.width / max(1, inner.height)))
            var path = Path()
            for line in lines {
                path.move(to: CGPoint(x: line.start.x + 2, y: line.start.y + 2))
                path.addLine(to: CGPoint(x: line.end.x + 2, y: line.end.y + 2))
            }
            if mode.frameAspect != nil, let first = lines.first {
                // A closed rectangle preserves Android drawRect's joined corners.
                path = Path()
                path.addRect(CGRect(x: first.start.x + 2, y: first.start.y + 2,
                                    width: lines[1].start.x - first.start.x,
                                    height: lines[1].end.y - first.start.y))
            }
            context.stroke(path, with: .foreground,
                           style: StrokeStyle(lineWidth: 1.5, lineCap: mode.frameAspect == nil ? .round : .butt))
        }
    }
}
