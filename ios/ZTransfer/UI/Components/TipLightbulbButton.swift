import SwiftUI
import UIKit

/// Shared by GPS, STA/AP, both settings pages and the local effects workbench.
/// Each caller owns its Android-equivalent persisted viewed flag. Rendering
/// never marks a tip read; only the caller's tap action does so.
struct TipLightbulbButton: View {
    let attention: Bool
    let size: CGFloat
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var attentionOrigin = Date()

    var body: some View {
        TimelineView(.animation(paused: !attention || scenePhase != .active)) { context in
            let values = attention
                ? TipAttentionValues(elapsed: context.date.timeIntervalSince(attentionOrigin))
                : .read
            // Defer the popup state mutation until the touch-up transaction
            // has released the glass button. Otherwise the newly inserted
            // popup and the button's pressed-scale animation are composited
            // in the same frame, producing a visible size flash.
            Button(action: { Task { @MainActor in action() } }) {
                Image(systemName: "lightbulb.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.45, height: size * 0.45)
                    .frame(width: size, height: size)
                    .overlay(alignment: .topTrailing) {
                        if attention {
                            Circle()
                                .fill(Color(red: 1, green: 77.0 / 255, blue: 61.0 / 255))
                                .frame(width: 7, height: 7)
                                .scaleEffect(values.dotScale)
                                .opacity(values.dotOpacity)
                                .padding(.top, 5)
                                .padding(.trailing, 5)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(ZTransferGlassButtonStyle(tint: ZTransferColors.accentOrange, cornerRadius: 12))
            .scaleEffect(values.buttonScale)
            .accessibilityLabel(accessibilityLabel)
            // Parent popup animations must not animate the read-state reset
            // or interpolate the frame-by-frame attention clock a second time.
            .transaction { $0.animation = nil }
        }
        .onAppear { attentionOrigin = Date() }
        .onChange(of: attention) { unread in
            if unread { attentionOrigin = Date() }
        }
    }
}

/// Android AnchorPopup content stays clear of its bulb. Measure the natural
/// height, choose the side with room, and scroll only when the text cannot fit.
struct AdaptiveTipPanel<Content: View>: View {
    let anchor: CGRect
    var maxWidth: CGFloat = 300
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = min(maxWidth, max(1, proxy.size.width - 24))
            let below = max(0, proxy.size.height - anchor.maxY - 20)
            let above = max(0, anchor.minY - 20)
            let useBelow = contentHeight <= below || below >= above
            let height = min(contentHeight, useBelow ? below : above)
            let top = useBelow ? anchor.maxY + 8 : anchor.minY - 8 - height
            let left = min(max(12, anchor.midX - width / 2), max(12, proxy.size.width - width - 12))
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { measurement in
                        Color.clear.preference(key: TipContentHeightKey.self, value: measurement.size.height)
                    })
            }
            .frame(width: width, height: height)
            .offset(x: left, y: top)
            .onPreferenceChange(TipContentHeightKey.self) { contentHeight = $0 }
        }
    }
}

private struct TipContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Keep a real anchored popover on iOS 16 as well as newer compact devices.
    func bulbPopover<Content: View>(isPresented: Binding<Bool>, width: CGFloat = 300,
                                    @ViewBuilder content: () -> Content) -> some View {
        background(BulbPopoverPresenter(isPresented: isPresented, width: width, content: content()))
    }
}

private struct BulbPopoverPresenter<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let width: CGFloat
    let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ source: UIView, context: Context) {
        context.coordinator.isPresented = $isPresented
        guard isPresented else {
            context.coordinator.host?.dismiss(animated: true)
            context.coordinator.host = nil
            return
        }
        guard context.coordinator.host == nil, let window = source.window else { return }
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        let panelWidth = min(width, window.bounds.width - 32)
        let natural = UIHostingController(rootView: content.frame(width: panelWidth))
        let size = natural.sizeThatFits(in: CGSize(width: panelWidth, height: .greatestFiniteMagnitude))
        let rect = source.convert(source.bounds, to: window)
        let space = max(rect.minY - window.safeAreaInsets.top,
                        window.bounds.height - window.safeAreaInsets.bottom - rect.maxY) - 28
        let host = UIHostingController(rootView: ScrollView { content.frame(width: panelWidth) })
        host.preferredContentSize = CGSize(width: panelWidth, height: min(size.height, max(1, space)))
        host.modalPresentationStyle = .popover
        if let popover = host.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds.insetBy(dx: 0, dy: -8)
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = context.coordinator
        }
        context.coordinator.host = host
        presenter?.present(host, animated: true)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.host?.dismiss(animated: false)
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var isPresented: Binding<Bool>
        var host: UIViewController?
        init(isPresented: Binding<Bool>) { self.isPresented = isPresented }
        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            host = nil
            isPresented.wrappedValue = false
        }
    }
}
