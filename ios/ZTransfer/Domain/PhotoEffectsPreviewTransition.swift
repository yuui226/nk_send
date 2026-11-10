import Foundation

/// Android SettingsScreen.planPhotoEffectsPreviewTransition (eec5d6db).
/// A rendered result is not the presented frame until its canvas is accepted.
enum PhotoEffectsPreviewChange { case keep, initial, update, crossfade, replaceCanvas }

struct PhotoEffectsPreviewTransition<Frame> {
    let frame: Frame?
    let change: PhotoEffectsPreviewChange
}

func planPhotoEffectsPreviewTransition<Frame, Canvas: Equatable>(
    current: Frame?, next: Frame?, requestedCanvas: Canvas,
    canvasOf: (Frame) -> Canvas, sameImage: (Frame, Frame) -> Bool
) -> PhotoEffectsPreviewTransition<Frame> {
    guard let next, canvasOf(next) == requestedCanvas else { return .init(frame: current, change: .keep) }
    guard let current else { return .init(frame: next, change: .initial) }
    let change: PhotoEffectsPreviewChange = sameImage(current, next) ? .update
        : canvasOf(current) != canvasOf(next) ? .replaceCanvas : .crossfade
    return .init(frame: next, change: change)
}

func photoEffectsPreviewCanvasVisible<Canvas: Equatable>(
    displayedCanvas: Canvas, requestedCanvas: Canvas, failed: Bool
) -> Bool {
    failed || displayedCanvas == requestedCanvas
}
