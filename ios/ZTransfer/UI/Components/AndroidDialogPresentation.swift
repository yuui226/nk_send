import SwiftUI
import UIKit

/// Compose Dialog inherits Theme.Material's window animation: enter from +20dp
/// over 220ms with standard (0.2,0,0,1), exit to -10dp over 150ms with
/// standard_accelerate (0.3,0,1,1), both with matching alpha. See dialog ledger.
/// Only the surface/backdrop observe frames; expensive dialog content stays put.
@MainActor
final class AndroidDialogClock: ObservableObject {
    @MainActor final class Frame: ObservableObject {
        @Published private(set) var alpha: Double = 0
        @Published private(set) var offset: CGFloat = 20
        func update(alpha: Double, offset: CGFloat) {
            if self.alpha != alpha { self.alpha = alpha }
            if self.offset != offset { self.offset = offset }
        }
    }
    @Published private(set) var retained = false
    let frame = Frame()
    private(set) var presented = false
    private var start: CFTimeInterval = 0
    private var fromAlpha: Double = 0
    private var fromOffset: CGFloat = 20
    private var link: CADisplayLink?
    var running: Bool { link != nil }

    func setPresented(_ value: Bool, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard value != presented else { return }
        if running { advance(time) }
        if value && !retained { frame.update(alpha: 0, offset: 20) }
        presented = value
        if value { retained = true }
        fromAlpha = frame.alpha; fromOffset = frame.offset; start = time
        if link == nil {
            let link = ZTransferDisplayLink.make(owner: self) { owner, link in owner.advance(link.timestamp) }
            self.link = link
            link.add(to: .main, forMode: .common)
        }
    }
    func advance(_ time: CFTimeInterval) {
        let elapsed = max(0, time - start)
        let duration = presented ? 0.22 : 0.15
        let progress = Double(ZTransferAndroidMotion.cubicBezier(Float(min(1, elapsed / duration)),
            x1: presented ? 0.2 : 0.3, x2: presented ? 0 : 1))
        frame.update(alpha: fromAlpha + ((presented ? 1 : 0) - fromAlpha) * progress,
                     offset: fromOffset + ((presented ? 0 : -10) - fromOffset) * progress)
        if elapsed >= duration {
            stop()
            if !presented { retained = false }
        }
    }
    private func stop() { link?.invalidate(); link = nil }
    func reset() {
        stop()
        presented = false
        retained = false
        frame.update(alpha: 0, offset: 20)
    }
}

private struct AndroidDialogFrameKey: EnvironmentKey {
    static let defaultValue: AndroidDialogClock.Frame? = nil
}
extension EnvironmentValues {
    var androidDialogFrame: AndroidDialogClock.Frame? {
        get { self[AndroidDialogFrameKey.self] }
        set { self[AndroidDialogFrameKey.self] = newValue }
    }
}

struct AndroidDialogPresentation<Content: View>: View {
    let isPresented: Bool
    @ViewBuilder let content: () -> Content
    @StateObject private var clock = AndroidDialogClock()
    var body: some View {
        ZStack {
            if clock.retained {
                // Preserve a modal input barrier during exit, including STA's
                // intentionally transparent backdrop. No tap-through to pages.
                Color.clear.ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { _ in })
                content().environment(\.androidDialogFrame, clock.frame)
                    .allowsHitTesting(isPresented)
                    .accessibilityHidden(!isPresented)
                    .transition(.identity)
            }
        }
        .background { if clock.retained { PopupDragBoundary() } }
        .allowsHitTesting(clock.retained)
        .onAppear { clock.setPresented(isPresented) }
        .onChange(of: isPresented) { clock.setPresented($0) }
        .onDisappear { clock.reset() }
    }
}

struct DialogBackdrop: View {
    var opacity: Double = 0.32
    let onDismiss: () -> Void
    @Environment(\.androidDialogFrame) private var frame
    var body: some View {
        Group {
            if let frame { AnimatedDialogBackdrop(frame: frame, opacity: opacity, onDismiss: onDismiss) }
            else { surface(alpha: 1) }
        }
    }
    fileprivate func surface(alpha: Double) -> some View {
        Color.black.opacity(opacity * alpha).ignoresSafeArea().contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .gesture(DragGesture(minimumDistance: 1).onChanged { _ in })
    }
}
private struct AnimatedDialogBackdrop: View {
    @ObservedObject var frame: AndroidDialogClock.Frame
    let opacity: Double
    let onDismiss: () -> Void
    var body: some View { DialogBackdrop(opacity: opacity, onDismiss: onDismiss).surface(alpha: frame.alpha) }
}
private struct DialogSurfaceMotion: ViewModifier {
    @Environment(\.androidDialogFrame) private var frame
    func body(content: Content) -> some View {
        if let frame { content.modifier(AnimatedDialogSurface(frame: frame)) }
        else { content }
    }
}
private struct AnimatedDialogSurface: ViewModifier {
    @ObservedObject var frame: AndroidDialogClock.Frame
    func body(content: Content) -> some View {
        content.compositingGroup().offset(y: frame.offset).opacity(frame.alpha)
    }
}
extension View {
    func androidDialogSurface() -> some View { modifier(DialogSurfaceMotion()) }
}
