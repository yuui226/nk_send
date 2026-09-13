import SwiftUI
import UIKit

/// Android SettingsOverlay/AnchorPopup equivalent. It lives in the presenting
/// view's hierarchy so the page remains visible beneath a dim scrim; a system
/// sheet would slide from the bottom and changes the interaction model.
struct SettingsPopupOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    let showPhotoEffectsEntry: Bool
    let effectsStore: PhotoEffectsStore
    let directory: DirectoryAccessStore
    let anchor: CGRect

    @State private var animationProgress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.30 * animationProgress)
                    // The overlay itself is installed above the page and
                    // ignores the safe area. Let the scrim fill that root
                    // directly instead of manually adding inset heights;
                    // manual expansion is clipped before reaching the status
                    // bar on iOS 26.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                SettingsView(
                    showPhotoEffectsEntry: showPhotoEffectsEntry,
                    effectsStore: effectsStore,
                    directory: directory,
                    onClose: { close() }
                )
                .frame(width: max(0, proxy.size.width - 24))
                // AnchorPopup measures its content intrinsically and only
                // clamps when the available window is smaller. Keep the same
                // behavior here: the main page stays compact, while the
                // longer effects page can still scroll on a small phone.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: max(0, min(proxy.size.height - 150, proxy.size.height * 0.82)), alignment: .top)
                .padding(.horizontal, 12)
                .padding(.top, anchor == .zero ? 74 : anchor.maxY + 8)
                .scaleEffect(0.92 + 0.08 * animationProgress, anchor: .topLeading)
                .opacity(animationProgress)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28), value: animationProgress)
            .onAppear {
                updateWindowScrimBackground()
                animationProgress = 0
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)) {
                    animationProgress = 1
                }
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .zIndex(100)
    }

    private func close() {
        guard isPresented else { return }
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.22)) {
            animationProgress = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            clearWindowScrimBackground()
            isPresented = false
        }
    }

    /// UIKit keeps the status-bar surface outside the SwiftUI safe-area tree.
    /// Match the composited scrim color there as well; otherwise a light theme
    /// leaves a bright strip above the popup while the app content is dimmed.
    private func updateWindowScrimBackground() {
        let base: CGFloat = colorScheme == .dark ? 0.07 : 0.95
        let composited = base * 0.70
        let color = UIColor(white: composited, alpha: 1)
        window()?.backgroundColor = color
        // SwiftUI's hosting controller owns the status-bar backdrop on recent
        // iOS releases, so update its root view too. This is outside the
        // safe-area tree and is the only surface behind the status bar.
        window()?.rootViewController?.view.backgroundColor = color
        SystemBarScrim.shared.show(color: color, on: window())
    }

    private func clearWindowScrimBackground() {
        window()?.backgroundColor = nil
        window()?.rootViewController?.view.backgroundColor = nil
        SystemBarScrim.shared.hide()
    }

    private func window() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }
}

/// SwiftUI cannot draw over the system status/home-indicator surfaces. Keep a
/// tiny non-key overlay window for those two inset strips while Settings is
/// open, matching the same composited scrim color without affecting content.
@MainActor private final class SystemBarScrim {
    static let shared = SystemBarScrim()
    private var overlay: UIWindow?

    func show(color: UIColor, on source: UIWindow?) {
        guard let scene = source?.windowScene else { return }
        let window = overlay ?? UIWindow(windowScene: scene)
        overlay = window
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let controller = window.rootViewController ?? UIViewController()
        window.rootViewController = controller
        let root = controller.view!
        root.backgroundColor = .clear
        root.subviews.forEach { $0.removeFromSuperview() }
        // safeAreaInsets.top includes the extra inset below the status-bar
        // glyphs (the dynamic-island cutout area), which statusBarFrame.height
        // omits and would leave a narrow bright seam.
        let topHeight = max(window.safeAreaInsets.top, scene.statusBarManager?.statusBarFrame.height ?? 0)
        let top = UIView(frame: CGRect(x: 0, y: 0, width: window.bounds.width, height: topHeight))
        top.backgroundColor = color
        let bottomHeight = window.safeAreaInsets.bottom
        let bottom = UIView(frame: CGRect(x: 0, y: window.bounds.height - bottomHeight, width: window.bounds.width, height: bottomHeight))
        bottom.backgroundColor = color
        root.addSubview(top)
        root.addSubview(bottom)
        window.isHidden = false
    }

    func hide() {
        overlay?.isHidden = true
        overlay = nil
    }
}
