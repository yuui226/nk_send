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
    }

    @State private var effectsDraft = PhotoEffectsSettings()
    @State private var filterChooser = PhotoFilterChooserState()
    @State private var effectsHint: PhotoEffectsHint?
    @State private var contentHeight: CGFloat?
    @State private var presentationID = 0

    var body: some View {
        GeometryReader { proxy in
            let localAnchor = proxy[anchor]
            let panelLeft: CGFloat = 12
            let panelWidth = max(1, proxy.size.width - panelLeft * 2)
            let panelTop = localAnchor.maxY + 8
            let availableHeight = max(1, proxy.size.height - panelTop - max(12, proxy.safeAreaInsets.bottom))
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
                        popupMotionPaused: !isPresented,
                        requestTransferDirectoryAttention: requestTransferDirectoryAttention,
                        effectPreviewSource: effectPreviewSource,
                        effectPreviewExif: effectPreviewExif,
                        onEffectPreviewRequested: onEffectPreviewRequested,
                        onContentHeightChange: { height in
                            contentHeight = height
                        },
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
                if filterChooser.isPresented {
                    PhotoFilterChooserOverlay(draft: $effectsDraft, state: $filterChooser)
                }
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
                    filterChooser = PhotoFilterChooserState()
                    effectsHint = nil
                }
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
        guard isPresented else { return }
        isPresented = false
    }
}
