package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size

/** Keep the pixel under the gesture centroid stationary while applying incremental zoom. */
internal fun previewPinchOffset(offset: Offset, centroidFromCenter: Offset, factor: Float, pan: Offset): Offset =
    offset * factor + centroidFromCenter * (1f - factor) + pan

/** Pan limits use the actual rendered image and its (possibly top-aligned) resting center. */
internal fun clampPreviewPan(scale: Float, offset: Offset, image: Size, viewport: Size, center: Offset): Offset {
    if (scale <= 1f) return Offset.Zero
    fun axis(value: Float, extent: Float, container: Float, origin: Float): Float {
        if (extent <= container) return 0f
        // Keep the resting position reachable even when the image is deliberately off-center.
        val minimum = minOf(0f, container - origin - extent / 2f)
        val maximum = maxOf(0f, extent / 2f - origin)
        return value.coerceIn(minimum, maximum)
    }
    return Offset(axis(offset.x, image.width * scale, viewport.width, center.x),
        axis(offset.y, image.height * scale, viewport.height, center.y))
}

internal data class PreviewPhotoLayout(val scale: Float, val centerY: Float)

/** Normal preview is centered; crop uses the upper edge and reserves its additional controls. */
internal fun previewPhotoLayout(viewportHeight: Float, imageHeight: Float, infoBottom: Float,
    cropTop: Float, cropExtraBottom: Float, progress: Float, cropTopAlignment: Float = 1f): PreviewPhotoLayout {
    val height = viewportHeight.coerceAtLeast(1f)
    val normalTop = infoBottom.coerceIn(0f, height - 1f)
    val cropBottom = (height - cropExtraBottom).coerceAtLeast(1f)
    val top = cropTop.coerceIn(0f, cropBottom - 1f)
    val normalScale = minOf(1f, (height - normalTop) / imageHeight.coerceAtLeast(1f))
    val cropScale = minOf(1f, (cropBottom - top) / imageHeight.coerceAtLeast(1f))
    val p = progress.coerceIn(0f, 1f)
    val normalCenter = (normalTop + height) / 2f
    val halfCropHeight = imageHeight * cropScale / 2f
    val upperCenter = top + halfCropHeight
    val cropCenter = (normalCenter + (upperCenter-normalCenter)*cropTopAlignment.coerceIn(0f, 1f))
        .coerceIn(upperCenter, maxOf(upperCenter, cropBottom-halfCropHeight))
    return PreviewPhotoLayout(normalScale + (cropScale-normalScale)*p,
        normalCenter + (cropCenter-normalCenter)*p)
}
