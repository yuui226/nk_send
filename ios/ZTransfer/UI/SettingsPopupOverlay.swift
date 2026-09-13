import SwiftUI

/// Android SettingsOverlay/AnchorPopup equivalent. It lives in the presenting
/// view's hierarchy so the page remains visible beneath a dim scrim; a system
/// sheet would slide from the bottom and changes the interaction model.
struct SettingsPopupOverlay: View {
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
                    // GeometryReader is hosted inside the safe-area content
                    // region. Expand and offset the scrim explicitly so the
                    // status bar and home-indicator regions are dimmed too.
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom,
                    )
                    .offset(y: -proxy.safeAreaInsets.top)
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
            isPresented = false
        }
    }
}
