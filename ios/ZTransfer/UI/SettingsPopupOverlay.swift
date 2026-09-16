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
    @State private var contentHeight: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let overlayFrame = proxy.frame(in: .global)
            let localAnchor = anchor.offsetBy(dx: -overlayFrame.minX, dy: -overlayFrame.minY)
            let panelLeft: CGFloat = 12
            let panelWidth = max(0, proxy.size.width - panelLeft * 2)
            // The settings button normally supplies the exact anchor. During
            // the first layout pass the preference can still be zero (for
            // example when the connected list is handed off in the same
            // transaction as the tap). Keep the fallback below the complete
            // top-control row so the panel never covers the Z button.
            // The connected photo list's top controls occupy roughly the
            // first 100 points below the status bar on iPhone. The pre-
            // connection page has its compact controls at the very top, so
            // preserve its shorter fallback while keeping the connected list
            // clear of the Z row.
            let fallbackClearance: CGFloat = showPhotoEffectsEntry ? 106 : 50
            let fallbackPanelTop = max(proxy.safeAreaInsets.top + fallbackClearance,
                                       fallbackClearance)
            let panelTop = anchor == .zero
                ? fallbackPanelTop
                : max(localAnchor.maxY + 8, fallbackPanelTop)
            let availableHeight = max(1, proxy.size.height - panelTop - max(12, proxy.safeAreaInsets.bottom))
            // GeniePanelContainer is already positioned at panelTop by the
            // SwiftUI padding below. Convert both rectangles into that
            // container's local coordinate space; otherwise the mesh uses the
            // panel origin twice and opens from a point above the button.
            let sourceAnchor = (anchor == .zero
                ? CGRect(x: panelLeft, y: panelTop - 44, width: 36, height: 36)
                : localAnchor)
                .offsetBy(dx: -panelLeft, dy: -panelTop)
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
                        onContentHeightChange: { height in
                            contentHeight = height
                            guard !dismissalRequested else { return }
                            // Let SwiftUI commit the measured height before
                            // Genie captures the panel. Starting in the same
                            // update used to snapshot the provisional
                            // available-height layout, which caused the
                            // visible height flash on open.
                            DispatchQueue.main.async {
                                guard !dismissalRequested,
                                      contentHeight == height else { return }
                                animationProgress = 1
                            }
                        },
                        onClose: { close() }
                    ),
                    targetProgress: animationProgress,
                    anchor: sourceAnchor,
                    panelOrigin: .zero,
                    viewport: proxy.size,
                    onCollapsed: { isPresented = false }
                )
                .frame(width: panelWidth)
                // The panel grows to its content height, then clamps to the
                // space below the Z row. SettingsView's ScrollView takes the
                // remaining height on compact phones instead of covering the
                // fixed top controls.
                .frame(height: min(contentHeight ?? availableHeight, availableHeight), alignment: .top)
                .padding(.horizontal, panelLeft)
                .padding(.top, panelTop)
                if filterChooser.isPresented {
                    PhotoFilterChooserOverlay(draft: $effectsDraft, state: $filterChooser)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                effectsDraft = effectsStore.beginDraft()
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
        if contentHeight == nil {
            isPresented = false
            return
        }
        // The native mesh reports completion; the live panel is kept in the
        // hierarchy until it has reached the Z button, even if close interrupts
        // the opening animation.
        animationProgress = 0
    }
}
