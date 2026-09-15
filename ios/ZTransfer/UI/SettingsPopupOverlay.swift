import SwiftUI

/// Android SettingsOverlay/AnchorPopup equivalent. It lives in the presenting
/// view's hierarchy so the page remains visible beneath the panel.
struct SettingsPopupOverlay: View {
    @Binding var isPresented: Bool
    let showPhotoEffectsEntry: Bool
    let effectsStore: PhotoEffectsStore
    let directory: DirectoryAccessStore
    let anchor: CGRect
    let effectPreviewSource: UIImage?
    let effectPreviewExif: PhotoExif?
    let onEffectPreviewRequested: () -> Void

    init(isPresented: Binding<Bool>, showPhotoEffectsEntry: Bool, effectsStore: PhotoEffectsStore,
         directory: DirectoryAccessStore, anchor: CGRect, effectPreviewSource: UIImage? = nil,
         effectPreviewExif: PhotoExif? = nil, onEffectPreviewRequested: @escaping () -> Void = {}) {
        _isPresented = isPresented
        self.showPhotoEffectsEntry = showPhotoEffectsEntry
        self.effectsStore = effectsStore
        self.directory = directory
        self.anchor = anchor
        self.effectPreviewSource = effectPreviewSource
        self.effectPreviewExif = effectPreviewExif
        self.onEffectPreviewRequested = onEffectPreviewRequested
    }

    @State private var animationProgress: CGFloat = 0
    @State private var dismissalRequested = false
    @State private var effectsDraft = PhotoEffectsSettings()
    @State private var filterChooser = PhotoFilterChooserState()
    @State private var effectsHint: PhotoEffectsHint?

    var body: some View {
        GeometryReader { proxy in
            let overlayFrame = proxy.frame(in: .global)
            let localAnchor = anchor.offsetBy(dx: -overlayFrame.minX, dy: -overlayFrame.minY)
            let panelLeft: CGFloat = 12
            let panelWidth = max(0, proxy.size.width - panelLeft * 2)
            let panelTop = anchor == .zero ? 74 : localAnchor.maxY + 8
            ZStack(alignment: .topLeading) {
                // A transparent hit area still closes the popup on outside
                // taps without altering the photo list or system bars.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                GeniePopupPanel(
                    content: SettingsView(
                        showPhotoEffectsEntry: showPhotoEffectsEntry,
                        effectsStore: effectsStore,
                        directory: directory,
                        effectsDraft: $effectsDraft,
                        filterChooser: $filterChooser,
                        effectsHint: $effectsHint,
                        dismissalRequested: dismissalRequested,
                        effectPreviewSource: effectPreviewSource,
                        effectPreviewExif: effectPreviewExif,
                        onEffectPreviewRequested: onEffectPreviewRequested,
                        onClose: { close() }
                    ),
                    targetProgress: animationProgress,
                    anchor: localAnchor,
                    panelOrigin: CGPoint(x: panelLeft, y: panelTop),
                    viewport: proxy.size,
                    onCollapsed: { isPresented = false }
                )
                .frame(width: panelWidth)
                // AnchorPopup measures its content intrinsically and only
                // clamps when the available window is smaller. Keep the same
                // behavior here: the main page stays compact, while the
                // longer effects page can still scroll on a small phone.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: max(0, min(proxy.size.height - 150, proxy.size.height * 0.82)), alignment: .top)
                .padding(.horizontal, panelLeft)
                .padding(.top, panelTop)
                if filterChooser.isPresented {
                    PhotoFilterChooserOverlay(draft: $effectsDraft, state: $filterChooser)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                effectsDraft = effectsStore.beginDraft()
                animationProgress = 1
            }
        }
        .ignoresSafeArea()
        .zIndex(100)
        .photoEffectsHint($effectsHint, duration: 1.8)
        .onChange(of: effectsDraft) { value in
            let persisted = effectsStore.settings.persistingEditorPreferences(from: value)
            if persisted != effectsStore.settings { effectsStore.update(persisted) }
        }
    }

    private func close() {
        guard isPresented && !dismissalRequested else { return }
        dismissalRequested = true
        // The native mesh reports completion; the live panel is kept in the
        // hierarchy until it has reached the Z button, even if close interrupts
        // the opening animation.
        animationProgress = 0
    }
}
