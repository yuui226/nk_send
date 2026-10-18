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

/// The same panel, state ownership, pickers and persistence as list settings.
/// Effects-only back closes this overlay and leaves the current preview intact.
struct PreviewPhotoEffectsEditor: View {
    @Binding var isPresented: Bool
    let store: PhotoEffectsStore
    let directory: DirectoryAccessStore
    let source: UIImage?
    let exif: PhotoExif?
    let rotation: Int
    let anchor: Anchor<CGRect>
    let onDismissed: () -> Void

    var body: some View {
        SettingsPopupOverlay(isPresented: $isPresented, showPhotoEffectsEntry: true,
            effectsStore: store, directory: directory, anchor: anchor,
            effectPreviewSource: source, effectPreviewExif: exif,
            effectsOnly: true, effectPreviewInitialRotationQuarterTurns: rotation, onDismissed: onDismissed)
    }
}
