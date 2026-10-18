import SwiftUI

/// Android SettingsOverlay/AnchorPopup equivalent. It lives in the presenting
/// view's hierarchy so the page remains visible beneath the panel.
struct SettingsPopupOverlay: View {
    @Binding var isPresented: Bool
    let showPhotoEffectsEntry: Bool
    let effectsStore: PhotoEffectsStore
    let directory: DirectoryAccessStore
    let anchor: Anchor<CGRect>
    let requestTransferDirectoryAttention: Bool
    let effectPreviewSource: UIImage?
    let effectPreviewExif: PhotoExif?
    let onEffectPreviewRequested: () -> Void
    let onPhotoLoadingRangeChanged: (PhotoLoadingRange) -> Void

    let onDismissed: () -> Void
    let effectsOnly: Bool
    let effectPreviewInitialRotationQuarterTurns: Int

    init(isPresented: Binding<Bool>, showPhotoEffectsEntry: Bool, effectsStore: PhotoEffectsStore,
         directory: DirectoryAccessStore, anchor: Anchor<CGRect>,
         requestTransferDirectoryAttention: Bool = false, effectPreviewSource: UIImage? = nil,
         effectPreviewExif: PhotoExif? = nil, onEffectPreviewRequested: @escaping () -> Void = {},
         onPhotoLoadingRangeChanged: @escaping (PhotoLoadingRange) -> Void = { _ in },
         effectsOnly: Bool = false, effectPreviewInitialRotationQuarterTurns: Int = 0,
         onDismissed: @escaping () -> Void = {}) {
        _isPresented = isPresented
        self.showPhotoEffectsEntry = showPhotoEffectsEntry
        self.effectsStore = effectsStore
        self.directory = directory
        self.anchor = anchor
        self.requestTransferDirectoryAttention = requestTransferDirectoryAttention
        self.effectPreviewSource = effectPreviewSource
        self.effectPreviewExif = effectPreviewExif
        self.onEffectPreviewRequested = onEffectPreviewRequested
        self.onPhotoLoadingRangeChanged = onPhotoLoadingRangeChanged
        self.onDismissed = onDismissed
        self.effectsOnly = effectsOnly
        self.effectPreviewInitialRotationQuarterTurns = effectPreviewInitialRotationQuarterTurns
    }

    @State private var effectsDraft = PhotoEffectsSettings()
    @StateObject private var photoLUTLifetime = PhotoLUTEditorLifetime(role: .camera)
    private var photoLUTEditor: PhotoLUTEditorState { photoLUTLifetime.editor }
    @State private var filterChooser = PhotoFilterChooserState()
    @State private var effectsHint: PhotoEffectsHint?
    @State private var contentHeight: CGFloat?
    @State private var presentationID = 0
    @State private var showingPremium = false
    @State private var backdropProgress = SettingsBackdropProgress()
    @State private var panelVisible = false
    // The overlay observes launch membership. Its owner only retains lifetime,
    // so starting/finishing a firework does not rebuild the settings/editor tree.
    @State private var fireworks = PremiumFireworks()

    var body: some View {
        GeometryReader { proxy in
            let measuringPresentation = presentationID
            let localAnchor = proxy[anchor]
            let panelLeft: CGFloat = 12
            let panelWidth = max(1, proxy.size.width - panelLeft * 2)
            let panelTop = effectsOnly ? proxy.safeAreaInsets.top + 8 : localAnchor.maxY + 8
            // The geometry already excludes the bottom safe area (including
            // the keyboard). Add a gap only when no system inset provides one;
            // subtracting that inset again would collapse the editor twice.
            let bottomGap: CGFloat = effectsOnly ? proxy.safeAreaInsets.bottom + 8 : (proxy.safeAreaInsets.bottom > 0 ? 0 : 12)
            let availableHeight = max(1, proxy.size.height - panelTop - bottomGap)
            let sourceAnchor = GeniePopupMotion.attachmentAnchor(
                for: localAnchor, cornerRadius: 22
            ).offsetBy(dx: -panelLeft, dy: -panelTop)
            ZStack(alignment: .topLeading) {
                // AnchorPopup dims the page with the same rendered progress
                // as the complete panel and consumes drags outside it.
                SettingsBackdrop(progress: backdropProgress, onDismiss: close)

                GeniePopupPanel(
                    content: SettingsView(
                        showPhotoEffectsEntry: showPhotoEffectsEntry,
                        effectsStore: effectsStore,
                        directory: directory,
                        effectsDraft: $effectsDraft,
                        filterChooser: $filterChooser,
                        effectsHint: $effectsHint,
                        dismissalRequested: !isPresented,
                        photoLUTEditor: photoLUTEditor,
                        popupMotionPaused: !isPresented || showingPremium,
                        effectsOnly: effectsOnly,
                        effectPreviewInitialRotationQuarterTurns: effectPreviewInitialRotationQuarterTurns,
                        requestTransferDirectoryAttention: requestTransferDirectoryAttention,
                        effectPreviewSource: effectPreviewSource,
                        effectPreviewExif: effectPreviewExif,
                        onEffectPreviewRequested: onEffectPreviewRequested,
                        onPhotoLoadingRangeChanged: onPhotoLoadingRangeChanged,
                        onContentHeightChange: { height in
                            // A retired page can deliver a late preference when
                            // reopening. Only the current presentation may size it.
                            guard measuringPresentation == presentationID else { return }
                            if contentHeight != height { contentHeight = height }
                        },
                        onShowPremium: { showingPremium = true },
                        onPlayFireworks: { fireworks.launch() },
                        onClose: { close() }
                    )
                    .id(presentationID),
                    trigger: .settings,
                    // Lay out the complete scroll column while hidden. Its
                    // measured height must exist before the first visible frame.
                    targetProgress: isPresented && contentHeight != nil ? 1 : 0,
                    anchorX: sourceAnchor.midX / max(1, panelWidth),
                    anchorWidth: sourceAnchor.width / max(1, panelWidth),
                    anchorGap: max(0, -sourceAnchor.maxY),
                    fillsProposedSize: true,
                    gentleMotion: effectsOnly,
                    gentleAnchorY: min(1, max(0, (localAnchor.midY - panelTop) / availableHeight)),
                    onSettled: { if $0 == 0 && !isPresented { onDismissed() } },
                    onProgress: {
                        backdropProgress.value = $0
                        if panelVisible != ($0 > 0) { panelVisible = $0 > 0 }
                    }
                )
                .frame(width: panelWidth)
                // Natural whole-page height, capped by the available viewport.
                // The provisional full height is never used by the animation.
                .frame(height: effectsOnly ? availableHeight : min(contentHeight ?? availableHeight, availableHeight), alignment: .top)
                .padding(.horizontal, panelLeft)
                .padding(.top, panelTop)
                .allowsHitTesting(!showingPremium)
                PhotoLUTChooserPresentation(editor: photoLUTEditor, draft: $effectsDraft)
                if filterChooser.isPresented {
                    PhotoFilterChooserOverlay(draft: $effectsDraft, state: $filterChooser,
                        onFilterSelected: { photoLUTEditor.cancelPending() })
                }
                if showingPremium {
                    PremiumPurchaseView(onClose: { showingPremium = false },
                                        onCelebrate: { fireworks.launch() })
                }
                PremiumFireworksOverlay(state: fireworks)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(isPresented || panelVisible)
            .onAppear { if isPresented { beginPresentation() } }
            .onChange(of: isPresented) { presented in
                if presented {
                    beginPresentation()
                } else {
                    showingPremium = false
                    photoLUTEditor.close()
                    filterChooser = PhotoFilterChooserState()
                    effectsHint = nil
                }
            }
        }
        // Android WatermarkTextField brings the focused editor into view.
        // Keep the popup anchored below the toolbar, but let its scroll view
        // shrink above the keyboard so the text stays visible while editing.
        .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
        .zIndex(100)
        .photoEffectsHint($effectsHint, duration: 1.8, multilineDuration: 3.6)
        .onChange(of: effectsDraft) { value in
            effectsStore.persistEditorPreferences(from: value)
        }
    }

    private func beginPresentation() {
        photoLUTEditor.resetForPresentation()
        let stored = effectsStore.beginDraft()
        effectsDraft = effectsOnly ? photoEffectsEditorDraft(stored) : stored
        filterChooser = PhotoFilterChooserState()
        effectsHint = nil
        contentHeight = nil
        presentationID &+= 1
    }

    private func close() {
        guard isPresented else { return }
        isPresented = false
    }
}

/// Only the backdrop subscribes to display frames; the settings hierarchy is
/// not rebuilt each tick while its recorded layer is expanding/collapsing.
@MainActor
private final class SettingsBackdropProgress: ObservableObject {
    @Published var value: CGFloat = 0
}

private struct SettingsBackdrop: View {
    @ObservedObject var progress: SettingsBackdropProgress
    @Environment(\.colorScheme) private var scheme
    let onDismiss: () -> Void
    var body: some View {
        Color.black.opacity((scheme == .dark ? 0.40 : 0.32) * progress.value)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            .gesture(DragGesture(minimumDistance: 1).onChanged { _ in })
    }
}
