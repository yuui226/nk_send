import Foundation
import CoreGraphics

/// Continuously recomputed rotation fit used by Android's graphicsLayer.
/// Calculating it from the interpolated angle keeps portrait and landscape
/// photos inside the viewport for every frame instead of resizing only after
/// the quarter turn has finished.
func photoPreviewRotationFitScale(
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double
) -> CGFloat {
    guard let imageSize,
          imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
    let rawAspect = imageSize.width / imageSize.height
    let viewportAspect = viewportSize.width / viewportSize.height
    let baseWidth = rawAspect > viewportAspect
        ? viewportSize.width
        : viewportSize.height * rawAspect
    let baseHeight = rawAspect > viewportAspect
        ? viewportSize.width / rawAspect
        : viewportSize.height
    let radians = rotationDegrees * .pi / 180
    let absoluteCosine = abs(cos(radians))
    let absoluteSine = abs(sin(radians))
    let rotatedWidth = baseWidth * absoluteCosine + baseHeight * absoluteSine
    let rotatedHeight = baseWidth * absoluteSine + baseHeight * absoluteCosine
    guard rotatedWidth > 0, rotatedHeight > 0 else { return 1 }
    let fit = min(viewportSize.width / rotatedWidth, viewportSize.height / rotatedHeight)
    return fit
}

/// Axis-aligned size of the fitted image at the current quarter-turn target.
/// Android uses this size when constraining pan so no empty space can be pulled
/// into the viewport after zooming.
func photoPreviewDisplaySize(
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double
) -> CGSize {
    guard let imageSize,
          imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else { return viewportSize }
    let rawAspect = imageSize.width / imageSize.height
    let quarterTurns = Int((rotationDegrees / 90).rounded())
    let orientedAspect = abs(quarterTurns) % 2 == 1 ? 1 / rawAspect : rawAspect
    let viewportAspect = viewportSize.width / viewportSize.height
    if orientedAspect > viewportAspect {
        return CGSize(width: viewportSize.width, height: viewportSize.width / orientedAspect)
    }
    return CGSize(width: viewportSize.height * orientedAspect, height: viewportSize.height)
}

struct PhotoPreviewPlacement {
    let scale: CGFloat
    let size: CGSize
    let center: CGPoint
}

/// A mounted pager can report its bounds before its image receives the final
/// safe-area/tool inset proposal. Only admit the matching renderer placement.
func readyPhotoPreviewOpeningPlacement(_ placement: PhotoPreviewImagePlacement?,
                                      pageSize: CGSize, bottomPadding: CGFloat,
                                      rotation: Double, infoBottom: CGFloat) -> PhotoPreviewImagePlacement? {
    guard let placement, pageSize.width > 0, pageSize.height > bottomPadding,
          abs(placement.viewport.width - pageSize.width) < 0.5,
          abs(placement.viewport.height - (pageSize.height - bottomPadding)) < 0.5,
          abs((placement.infoBottom ?? 0) - infoBottom) < 0.5,
          abs(placement.rotation - rotation) < 0.001 else { return nil }
    return placement
}

/// One projection for the actual image renderer, opening anchor and current
/// zoomed closing position. No screen-centre approximation or second fit rule.
func photoPreviewImagePlacement(imageSize: CGSize?, viewportSize: CGSize, rotation: Double,
                                infoBottom: CGFloat?, scale: CGFloat = 1, offset: CGSize = .zero,
                                cropTop: CGFloat = 0, cropProgress: CGFloat = 0) -> PhotoPreviewImagePlacement? {
    guard let imageSize, imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else { return nil }
    let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
        rotationDegrees: rotation, infoBottom: infoBottom, cropTop: cropTop, cropProgress: cropProgress)
    let size = CGSize(width: placement.size.width * scale, height: placement.size.height * scale)
    return .init(image: CGRect(x: placement.center.x + offset.width - size.width / 2,
                              y: placement.center.y + offset.height - size.height / 2,
                              width: size.width, height: size.height),
                 viewport: viewportSize, rotation: rotation, infoBottom: infoBottom)
}

/// Final Android ZoomablePreviewViewport: width inset, information clearance,
/// portrait lift and rotation all contribute to the actual resting geometry.
func photoPreviewPlacement(imageSize: CGSize?, viewportSize: CGSize,
                           rotationDegrees: Double, infoBottom: CGFloat? = nil,
                           targetRotationDegrees: Double? = nil, cropTop: CGFloat = 0,
                           cropProgress: CGFloat = 0) -> PhotoPreviewPlacement {
    let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    guard let imageSize, imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else {
        return PhotoPreviewPlacement(scale: 1, size: viewportSize, center: center)
    }
    let aspect = imageSize.width / imageSize.height
    let baseWidth = min(viewportSize.width, viewportSize.height * aspect)
    let baseHeight = baseWidth / aspect
    let radians = rotationDegrees * .pi / 180
    let width = baseWidth * abs(cos(radians)) + baseHeight * abs(sin(radians))
    let height = baseWidth * abs(sin(radians)) + baseHeight * abs(cos(radians))
    let orientedAspect = abs(Int(((targetRotationDegrees ?? rotationDegrees) / 90).rounded())) % 2 == 1 ? 1 / aspect : aspect
    let inset: CGFloat = infoBottom == nil ? 0 : (orientedAspect < 1 ? 40 : 24)
    let fit = min(max(1, viewportSize.width - inset) / width, viewportSize.height / height)
    guard let infoBottom else {
        return PhotoPreviewPlacement(scale: fit, size: CGSize(width: width * fit, height: height * fit), center: center)
    }
    let layout = previewPhotoLayout(viewportHeight: viewportSize.height, imageHeight: height * fit,
                                    infoBottom: infoBottom, cropTop: cropTop + (orientedAspect > 1 ? 60 : 0),
                                    cropExtraBottom: 84, progress: cropProgress, cropTopAlignment: orientedAspect > 1 ? 0.5 : 1)
    let lift: CGFloat = orientedAspect < 1 ? min(12 * (1 - cropProgress), max(0, layout.centerY - height * fit * layout.scale / 2 - infoBottom)) : 0
    let scale = fit * layout.scale
    return PhotoPreviewPlacement(scale: scale, size: CGSize(width: width * scale, height: height * scale),
                                 center: CGPoint(x: center.x, y: layout.centerY - lift))
}

/// Android PreviewGestureGeometry.kt. Coordinates are relative to the resting
/// image center; applying the incremental factor preserves the touched pixel.
func previewPinchOffset(offset: CGSize, centroidFromCenter: CGPoint,
                        factor: CGFloat, pan: CGSize) -> CGSize {
    CGSize(width: offset.width * factor + centroidFromCenter.x * (1 - factor) + pan.width,
           height: offset.height * factor + centroidFromCenter.y * (1 - factor) + pan.height)
}

func clampPreviewPan(scale: CGFloat, offset: CGSize, image: CGSize,
                     viewport: CGSize, center: CGPoint) -> CGSize {
    guard scale > 1 else { return .zero }
    func axis(_ value: CGFloat, extent: CGFloat, container: CGFloat, origin: CGFloat) -> CGFloat {
        guard extent > container else { return 0 }
        let minimum = min(0, container - origin - extent / 2)
        let maximum = max(0, extent / 2 - origin)
        return min(max(value, minimum), maximum)
    }
    return CGSize(width: axis(offset.width, extent: image.width * scale,
                              container: viewport.width, origin: center.x),
                  height: axis(offset.height, extent: image.height * scale,
                               container: viewport.height, origin: center.y))
}

struct PreviewPhotoLayout: Equatable {
    let scale: CGFloat
    let centerY: CGFloat
}

func previewPhotoLayout(viewportHeight: CGFloat, imageHeight: CGFloat, infoBottom: CGFloat,
                        cropTop: CGFloat, cropExtraBottom: CGFloat, progress: CGFloat,
                        cropTopAlignment: CGFloat = 1) -> PreviewPhotoLayout {
    let height = max(viewportHeight, 1)
    let normalTop = min(max(infoBottom, 0), height - 1)
    let bottom = max(height - cropExtraBottom, 1)
    let top = min(max(cropTop, 0), bottom - 1)
    let normalScale = min(1, (height - normalTop) / max(imageHeight, 1))
    let cropScale = min(1, (bottom - top) / max(imageHeight, 1))
    let p = min(max(progress, 0), 1)
    let normalCenter = (normalTop + height) / 2
    let halfHeight = imageHeight * cropScale / 2
    let upperCenter = top + halfHeight
    let cropCenter = min(max(normalCenter + (upperCenter - normalCenter) *
                             min(max(cropTopAlignment, 0), 1), upperCenter),
                         max(upperCenter, bottom - halfHeight))
    return PreviewPhotoLayout(scale: normalScale + (cropScale - normalScale) * p,
                              centerY: normalCenter + (cropCenter - normalCenter) * p)
}

func photoPreviewClampedOffset(
    _ proposed: CGSize,
    scale: CGFloat,
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double,
    infoBottom: CGFloat? = nil
) -> CGSize {
    let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                          rotationDegrees: rotationDegrees, infoBottom: infoBottom)
    return clampPreviewPan(scale: scale, offset: proposed, image: placement.size,
                           viewport: viewportSize, center: placement.center)
}

func photoPreviewDoubleTapOffset(
    location: CGPoint,
    scale: CGFloat,
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double,
    infoBottom: CGFloat? = nil
) -> CGSize {
    let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                          rotationDegrees: rotationDegrees, infoBottom: infoBottom)
    return photoPreviewClampedOffset(
        CGSize(
            width: (location.x - placement.center.x) * (1 - scale),
            height: (location.y - placement.center.y) * (1 - scale)
        ),
        scale: scale,
        imageSize: imageSize,
        viewportSize: viewportSize,
        rotationDegrees: rotationDegrees, infoBottom: infoBottom
    )
}

func photoPreviewMaximumZoom(
    imageSize: CGSize?,
    viewportSize: CGSize,
    rotationDegrees: Double,
    infoBottom: CGFloat? = nil
) -> CGFloat {
    guard let imageSize,
          imageSize.width > 0, imageSize.height > 0,
          viewportSize.width > 0, viewportSize.height > 0 else { return 4 }
    let rawAspect = imageSize.width / imageSize.height
    let viewportAspect = viewportSize.width / viewportSize.height
    let baseWidth = rawAspect > viewportAspect
        ? viewportSize.width
        : viewportSize.height * rawAspect
    let baseHeight = rawAspect > viewportAspect
        ? viewportSize.width / rawAspect
        : viewportSize.height
    let fit = max(0.01, photoPreviewPlacement(imageSize: imageSize, viewportSize: viewportSize,
                                             rotationDegrees: rotationDegrees,
                                             infoBottom: infoBottom).scale)
    let oneToOne = max(imageSize.width / baseWidth, imageSize.height / baseHeight) / fit
    return max(4, oneToOne)
}

