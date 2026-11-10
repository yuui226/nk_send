import SwiftUI
import UIKit

/// The expanded effects inspector has its own whole-page presentation. Keep
/// that owner's existing transition separate from the album image/crop mapping.
@preconcurrency
struct PhotoPreviewAnchorTransform: AnimatableModifier {
    var progress: CGFloat
    let anchor: CGRect?
    let enabled: Bool
    let closing: Bool

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let viewport = UIScreen.main.bounds
        let validAnchor = anchor.flatMap { rect in
            rect.width > 0 && rect.height > 0 && viewport.width > 0 && viewport.height > 0 ? rect : nil
        }
        let shouldAnchor = enabled && validAnchor != nil
        let startScale = validAnchor.map { min(max($0.width / viewport.width, 0.05), 1) } ?? 1
        let scale = shouldAnchor ? startScale + (1 - startScale) * progress : 1
        let origin = validAnchor.map {
            UnitPoint(
                x: min(max(($0.midX - viewport.minX) / viewport.width, 0), 1),
                y: min(max(($0.midY - viewport.minY) / viewport.height, 0), 1)
            )
        } ?? .center
        content
            .scaleEffect(scale, anchor: origin)
            .opacity(shouldAnchor ? (closing ? min(progress * 1.6, 1) : 1) : progress)
    }
}

struct PhotoPreviewOpeningSource {
    let anchor: PhotoPreviewAnchorBounds?
    let file: CameraFile?
    let thumbnail: UIImage?
    var hasImage: Bool {
        guard let thumbnail, thumbnail.size.width.isFinite, thumbnail.size.height.isFinite,
              thumbnail.size.width > 0, thumbnail.size.height > 0 else { return false }
        return file.map { ![".mov", ".mp4"].contains($0.fileExtension.lowercased()) } == true
    }
}

struct PhotoPreviewPresentationOpacity: ViewModifier {
    @ObservedObject var clock: PhotoPreviewPresentationClock
    var factor: CGFloat = 1
    func body(content: Content) -> some View { content.opacity(clock.progress * factor) }
}

/// A stable modifier stack survives the end of the transition. The pager is
/// never replaced merely because the image has reached its resting rectangle.
struct PhotoPreviewAnchorPresentation: ViewModifier {
    @ObservedObject var clock: PhotoPreviewPresentationClock
    let anchor: PhotoPreviewAnchorBounds?
    let placement: PhotoPreviewImagePlacement?
    let viewport: CGRect
    let enabled: Bool
    let closing: Bool
    let openingReady: Bool

    func body(content: Content) -> some View {
        let p = clock.progress
        let local = anchor?.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        let anchored = enabled && local?.image.isEmpty == false && viewport.width > 0 && viewport.height > 0
        let frame = anchored ? local.flatMap { anchor in
            placement.flatMap { photoPreviewAnchorFrame(anchor: anchor, image: $0.image,
                                                        progress: p, imageRotation: $0.rotation) }
        } : nil
        let transform = layerTransform(frame: frame, anchor: anchored ? local?.image : nil, progress: p)
        content
            .clipShape(PhotoPreviewAnchorClip(frame: p < 1 ? frame : nil,
                imageCenter: placement.map { CGPoint(x: $0.image.midX, y: $0.image.midY) } ?? .zero,
                progress: p))
            .projectionEffect(ProjectionTransform(transform))
            .opacity(anchored ? (closing ? min(p * 1.6, 1) : openingReady ? 1 : 0) : p)
    }

    private func layerTransform(frame: PhotoPreviewAnchorFrame?, anchor: CGRect?, progress: CGFloat) -> CGAffineTransform {
        if let frame { return frame.transform }
        guard let rect = anchor else { return .identity }
        // Collections/videos keep Android's existing whole-page fallback.
        let start = min(1, max(0.05, rect.width / viewport.width))
        let scale = start + (1 - start) * progress
        let x = min(viewport.width, max(0, rect.midX))
        let y = min(viewport.height, max(0, rect.midY))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x * (1 - scale), ty: y * (1 - scale))
    }
}

struct PhotoPreviewAnchorClip: Shape {
    let frame: PhotoPreviewAnchorFrame?
    let imageCenter: CGPoint
    let progress: CGFloat
    func path(in rect: CGRect) -> Path {
        guard let frame else { return Path(rect) }
        let radius = 8 * (1 - min(1, max(0, progress))) / frame.scale
        return Path(roundedRect: frame.clip, cornerRadius: radius)
            .applying(frame.clipTransform(about: imageCenter))
    }
}
