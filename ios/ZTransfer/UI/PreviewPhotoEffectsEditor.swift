import SwiftUI

func showPreviewPhotoEffects(enabled: Bool, isReview: Bool, file: CameraFile?) -> Bool {
    guard enabled, !isReview, let file else { return false }
    return ["jpg", "jpeg"].contains((file.fileName as NSString).pathExtension.lowercased())
}

func photoEffectsEditorDraft(_ settings: PhotoEffectsSettings) -> PhotoEffectsSettings {
    var draft = settings
    draft.photoFrameBorderEnabled = settings.photoFrameEnabled && settings.photoFrameBorderEnabled
    draft.watermark.enabled = settings.photoFrameEnabled && settings.watermark.enabled
    draft.watermark.text = settings.watermark.displayText
    if draft.selectedFilter == nil, let first = PhotoFilterCatalog.presets.first {
        draft.selectedFilter = .init(preset: first, intensityPercent:
            settings.filterIntensities[PhotoEffectsSettings.filterKey(first.id)] ?? Np3FilterEngine.defaultIntensityPercent)
    }
    return draft
}

/// A fresh settings draft for this opening, backed by the global camera-effects store.
/// The current preview supplies pixels/EXIF; no latest-photo fetch is started here.
struct PreviewPhotoEffectsEditor: View {
    @ObservedObject var store: PhotoEffectsStore
    let directory: DirectoryAccessStore
    let source: UIImage?
    let exif: PhotoExif?
    let rotation: Int
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PhotoEffectsSettings
    @StateObject private var photoLUTEditor = PhotoLUTEditorState(role: .camera)
    @State private var chooser = PhotoFilterChooserState()
    @State private var hint: PhotoEffectsHint?
    init(store: PhotoEffectsStore, directory: DirectoryAccessStore, source: UIImage?, exif: PhotoExif?, rotation: Int) {
        self.store = store; self.directory = directory; self.source = source; self.exif = exif; self.rotation = rotation
        _draft = State(initialValue: photoEffectsEditorDraft(store.beginDraft()))
    }
    var body: some View {
        SettingsView(showPhotoEffectsEntry: true, effectsStore: store, directory: directory,
            effectsDraft: $draft, filterChooser: $chooser, effectsHint: $hint, dismissalRequested: false, photoLUTEditor: photoLUTEditor,
            effectsOnly: true, effectPreviewInitialRotationQuarterTurns: rotation,
            effectPreviewSource: source, effectPreviewExif: exif, onClose: { dismiss() })
            .overlay {
                if photoLUTEditor.showingChooser { PhotoLUTChooserOverlay(editor: photoLUTEditor, draft: $draft) }
                if chooser.isPresented { PhotoFilterChooserOverlay(draft: $draft, state: $chooser,
                        onFilterSelected: { photoLUTEditor.cancelPending() }) }
            }
            .photoEffectsHint($hint, duration: 1.8, multilineDuration: 3.6)
            .background(ZTransferColors.background)
            .interactiveDismissDisabled()
    }
}
