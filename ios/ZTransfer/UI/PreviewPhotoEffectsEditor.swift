import SwiftUI

/// Android PhotoPreview.PreviewEffectsDialog sits above the album's queue
/// controls. Carry the editor to that same root layer without duplicating its
/// draft or dismissing the preview underneath it. Retain it through close.
struct PreviewPhotoEffectsPresentationKey: PreferenceKey {
    static var defaultValue: PreviewPhotoEffectsEditor? { nil }
    static func reduce(value: inout PreviewPhotoEffectsEditor?, nextValue: () -> PreviewPhotoEffectsEditor?) {
        value = nextValue() ?? value
    }
}

extension View {
    func previewPhotoEffectsPresentation() -> some View {
        modifier(PreviewPhotoEffectsPresentation())
    }
}

private struct PreviewPhotoEffectsBlockingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct PreviewPhotoEffectsPresentation: ViewModifier {
    @State private var blocksBackground = false
    func body(content: Content) -> some View {
        content
            // Match Dialog's modal input/accessibility boundary, including the
            // 8pt margin and rounded corners where the page remains visible.
            .allowsHitTesting(!blocksBackground)
            .accessibilityHidden(blocksBackground)
            .overlayPreferenceValue(PreviewPhotoEffectsPresentationKey.self) { editor in
                ZStack { editor }
                    .preference(key: PreviewPhotoEffectsBlockingKey.self, value: editor != nil)
            }
            .onPreferenceChange(PreviewPhotoEffectsBlockingKey.self) { blocksBackground = $0 }
    }
}

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
    var sourceName: String = ""
    let source: UIImage?
    let exif: PhotoExif?
    let rotation: Int
    let anchor: Anchor<CGRect>
    let onDismissed: () -> Void

    var body: some View {
        SettingsPopupOverlay(isPresented: $isPresented, showPhotoEffectsEntry: true,
            effectsStore: store, directory: directory, anchor: anchor,
            effectPreviewSource: source, effectPreviewExif: exif, effectPreviewSourceName: sourceName,
            effectsOnly: true, effectPreviewInitialRotationQuarterTurns: rotation, onDismissed: onDismissed)
    }
}
