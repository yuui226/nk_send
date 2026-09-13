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

    @State private var visible = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(visible ? 0.30 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                SettingsView(
                    showPhotoEffectsEntry: showPhotoEffectsEntry,
                    effectsStore: effectsStore,
                    directory: directory,
                    onClose: { close() }
                )
                .frame(width: max(0, proxy.size.width - 24),
                       height: max(0, proxy.size.height - 104))
                .padding(.horizontal, 12)
                .padding(.top, anchor == .zero ? 74 : anchor.maxY + 8)
                .scaleEffect(visible ? 1 : 0.94, anchor: .topLeading)
                .opacity(visible ? 1 : 0)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            }
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24), value: visible)
            .onAppear { visible = true }
        }
        .transition(.opacity)
        .zIndex(100)
    }

    private func close() {
        guard isPresented else { return }
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.20)) {
            visible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            isPresented = false
        }
    }
}
