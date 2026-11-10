import Foundation
import CoreGraphics

/// Full Crop geometry and the portion actually visible in the scrolling grid.
struct PhotoPreviewAnchorBounds: Equatable {
    let image: CGRect
    let visible: CGRect
    init(image: CGRect, visible: CGRect? = nil) {
        self.image = image; self.visible = visible ?? image
    }
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        .init(image: image.offsetBy(dx: dx, dy: dy), visible: visible.offsetBy(dx: dx, dy: dy))
    }
    static func clipped(image: CGRect, to viewport: CGRect) -> Self? {
        guard !image.isEmpty, !image.isNull, !image.isInfinite,
              !viewport.isEmpty, !viewport.isNull, !viewport.isInfinite else { return nil }
        let visible = image.intersection(viewport)
        guard !visible.isEmpty, !visible.isNull else { return nil }
        return .init(image: image, visible: visible)
    }
}

struct PhotoPreviewImagePlacement: Equatable {
    let image: CGRect
    let viewport: CGSize
    let rotation: Double
    let infoBottom: CGFloat?
}

struct PhotoPreviewAnchorFrame: Equatable {
    let scale: CGFloat
    let translation: CGPoint
    let clip: CGRect
    let rotation: Double
    let clipRotation: Double
    var transform: CGAffineTransform {
        let radians = rotation * .pi / 180
        return .init(a: scale * cos(radians), b: scale * sin(radians),
                     c: -scale * sin(radians), d: scale * cos(radians),
                     tx: translation.x, ty: translation.y)
    }
    func clipTransform(about center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: clipRotation * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
    }
}

/// PreviewAnchorGeometry.kt: one uniform transform of the actual fitted image,
/// with a gradually released Crop rectangle. Coordinates belong to the pager.
/// Invalid/missing layout is handled by the caller's existing page transition.
func photoPreviewAnchorFrame(anchor: PhotoPreviewAnchorBounds, image: CGRect,
                             progress: CGFloat, imageRotation: Double = 0) -> PhotoPreviewAnchorFrame? {
    guard [anchor.image, anchor.visible, image].allSatisfy({ rect in
        !rect.isEmpty && !rect.isNull && !rect.isInfinite &&
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }), progress.isFinite, imageRotation.isFinite else { return nil }
    let p = min(1, max(0, progress))
    let direction = ((imageRotation + 180).truncatingRemainder(dividingBy: 360) + 360)
        .truncatingRemainder(dividingBy: 360) - 180
    let swapped = abs(Int(floor(direction / 90 + 0.5))) % 2 == 1
    let rawWidth = swapped ? image.height : image.width
    let rawHeight = swapped ? image.width : image.height
    let startScale = max(anchor.image.width / rawWidth, anchor.image.height / rawHeight)
    let scale = startScale + (1 - startScale) * p
    let center = CGPoint(x: anchor.image.midX + (image.midX - anchor.image.midX) * p,
                         y: anchor.image.midY + (image.midY - anchor.image.midY) * p)
    let halfWidth = (anchor.visible.width + (rawWidth - anchor.visible.width) * p) / (2 * scale)
    let halfHeight = (anchor.visible.height + (rawHeight - anchor.visible.height) * p) / (2 * scale)
    let clipCenter = CGPoint(x: image.midX + (anchor.visible.midX - anchor.image.midX) * (1 - p) / scale,
                             y: image.midY + (anchor.visible.midY - anchor.image.midY) * (1 - p) / scale)
    let rotation = -direction * (1 - p)
    let radians = rotation * .pi / 180
    let rotatedCenter = CGPoint(x: image.midX * cos(radians) - image.midY * sin(radians),
                                y: image.midX * sin(radians) + image.midY * cos(radians))
    return .init(scale: scale,
        translation: .init(x: center.x - rotatedCenter.x * scale, y: center.y - rotatedCenter.y * scale),
        clip: .init(x: clipCenter.x - halfWidth, y: clipCenter.y - halfHeight,
                    width: 2 * halfWidth, height: 2 * halfHeight), rotation: rotation, clipRotation: direction)
}
