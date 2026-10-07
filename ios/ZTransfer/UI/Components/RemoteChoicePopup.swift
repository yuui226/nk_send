import SwiftUI

/// Shared RemoteChoicePopup shell; content owns its measurement and domain state.
/// Genie renderer fidelity remains tracked separately in T24.
struct RemoteChoicePopup<Content: View>: View {
    let anchor: CGRect?
    let hostSize: CGSize
    let landscape: Bool
    let width: CGFloat
    let contentHeight: CGFloat?
    let closing: Bool
    let trigger: GeniePopupTrigger
    let accessibilityID: String
    let close: () -> Void
    let dismiss: () -> Void
    @ViewBuilder var content: (RemoteCameraToolMenuPlacement) -> Content

    var body: some View {
        let placement = RemoteCameraToolMenuPlacement(host: hostSize, anchor: anchor,
            landscape: landscape, width: width, contentHeight: contentHeight ?? hostSize.height)
        let source = anchor ?? CGRect(x: placement.frame.minX, y: placement.frame.minY - 6, width: 29.2, height: 0)
        let gap = placement.opensAbove ? source.minY - placement.frame.maxY : placement.frame.minY - source.maxY
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(perform: close)
                .gesture(DragGesture(minimumDistance: 8).onChanged { _ in })
                .accessibilityIdentifier(accessibilityID)
            GeniePopupPanel(content: content(placement), trigger: trigger,
                targetProgress: contentHeight != nil && !closing ? 1 : 0,
                anchorX: (source.midX - placement.frame.minX) / placement.width,
                anchorWidth: 29.2 / placement.width, anchorGap: gap,
                opensAbove: placement.opensAbove, onSettled: { progress in
                    if progress == 0 && closing { dismiss() }
                })
                .frame(width: placement.width, height: placement.frame.height)
                .offset(x: placement.frame.minX, y: placement.frame.minY)
        }
        .frame(width: hostSize.width, height: hostSize.height, alignment: .topLeading)
        .accessibilityAction(.escape, close)
        .onAppear { if closing && contentHeight == nil { dismiss() } }
        .onChange(of: closing) { if $0 && contentHeight == nil { dismiss() } }
    }
}
