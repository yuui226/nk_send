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

    init(isPresented: Binding<Bool>, showPhotoEffectsEntry: Bool, effectsStore: PhotoEffectsStore,
         directory: DirectoryAccessStore, anchor: Anchor<CGRect>,
         requestTransferDirectoryAttention: Bool = false, effectPreviewSource: UIImage? = nil,
         effectPreviewExif: PhotoExif? = nil, onEffectPreviewRequested: @escaping () -> Void = {}) {
        _isPresented = isPresented
        self.showPhotoEffectsEntry = showPhotoEffectsEntry
        self.effectsStore = effectsStore
        self.directory = directory
        self.anchor = anchor
        self.requestTransferDirectoryAttention = requestTransferDirectoryAttention
        self.effectPreviewSource = effectPreviewSource
        self.effectPreviewExif = effectPreviewExif
        self.onEffectPreviewRequested = onEffectPreviewRequested
        self.onPhotoLoadingRangeChanged = { _ in }
    }

    init(isPresented: Binding<Bool>, showPhotoEffectsEntry: Bool, effectsStore: PhotoEffectsStore,
         directory: DirectoryAccessStore, anchor: Anchor<CGRect>,
         requestTransferDirectoryAttention: Bool = false, effectPreviewSource: UIImage? = nil,
         effectPreviewExif: PhotoExif? = nil, onEffectPreviewRequested: @escaping () -> Void = {},
         onPhotoLoadingRangeChanged: @escaping (PhotoLoadingRange) -> Void) {
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
    }

    @State private var effectsDraft = PhotoEffectsSettings()
    @State private var filterChooser = PhotoFilterChooserState()
    @State private var effectsHint: PhotoEffectsHint?
    @State private var contentHeight: CGFloat?
    @State private var presentationID = 0
    @State private var showingPremium = false
    @StateObject private var fireworks = PremiumFireworks()

    var body: some View {
        GeometryReader { proxy in
            let localAnchor = proxy[anchor]
            let panelLeft: CGFloat = 12
            let panelWidth = max(1, proxy.size.width - panelLeft * 2)
            let panelTop = localAnchor.maxY + 8
            // The geometry already excludes the bottom safe area (including
            // the keyboard). Add a gap only when no system inset provides one;
            // subtracting that inset again would collapse the editor twice.
            let bottomGap: CGFloat = proxy.safeAreaInsets.bottom > 0 ? 0 : 12
            let availableHeight = max(1, proxy.size.height - panelTop - bottomGap)
            let sourceAnchor = GeniePopupMotion.attachmentAnchor(
                for: localAnchor, cornerRadius: 22
            ).offsetBy(dx: -panelLeft, dy: -panelTop)
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
                        dismissalRequested: !isPresented,
                        popupMotionPaused: !isPresented || showingPremium,
                        requestTransferDirectoryAttention: requestTransferDirectoryAttention,
                        effectPreviewSource: effectPreviewSource,
                        effectPreviewExif: effectPreviewExif,
                        onEffectPreviewRequested: onEffectPreviewRequested,
                        onPhotoLoadingRangeChanged: onPhotoLoadingRangeChanged,
                        onContentHeightChange: { height in
                            contentHeight = height
                        },
                        onShowPremium: { showingPremium = true },
                        onPlayFireworks: { fireworks.launch() },
                        onClose: { close() }
                    )
                    .id(presentationID),
                    trigger: .settings,
                    targetProgress: isPresented ? 1 : 0,
                    anchorX: sourceAnchor.midX / max(1, panelWidth),
                    anchorWidth: sourceAnchor.width / max(1, panelWidth),
                    anchorGap: max(0, -sourceAnchor.maxY)
                )
                .frame(width: panelWidth)
                // The panel grows to its content height, then clamps to the
                // space below the Z row. SettingsView's ScrollView takes the
                // remaining height on compact phones instead of covering the
                // fixed top controls.
                .frame(height: min(contentHeight ?? availableHeight, availableHeight), alignment: .top)
                .padding(.horizontal, panelLeft)
                .padding(.top, panelTop)
                .allowsHitTesting(!showingPremium)
                if filterChooser.isPresented {
                    PhotoFilterChooserOverlay(draft: $effectsDraft, state: $filterChooser)
                }
                if showingPremium {
                    PremiumPurchaseView(onClose: { showingPremium = false },
                                        onCelebrate: { fireworks.launch() })
                }
                PremiumFireworksOverlay(state: fireworks)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(isPresented)
            .onChange(of: isPresented) { presented in
                if presented {
                    effectsDraft = effectsStore.beginDraft()
                    filterChooser = PhotoFilterChooserState()
                    effectsHint = nil
                    presentationID &+= 1
                } else {
                    showingPremium = false
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
        .photoEffectsHint($effectsHint, duration: 1.8)
        .onChange(of: effectsDraft) { value in
            effectsStore.persistEditorPreferences(from: value)
        }
    }

    private func close() {
        guard isPresented else { return }
        isPresented = false
    }
}
