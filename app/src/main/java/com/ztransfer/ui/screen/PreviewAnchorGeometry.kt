package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.lerp
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.roundToInt

internal data class PreviewAnchorBounds(val image: Rect, val visible: Rect)

/** A uniform transform about the layer's origin, with clipping in its untransformed coordinates. */
internal data class PreviewAnchorFrame(val scale: Float, val translation: Offset, val clip: Rect,
    val rotation: Float, val clipRotation: Float)

/**
 * Grid thumbnails use Crop; the viewer uses Fit and may sit above/below the screen centre.
 * Map the actual image, not the whole screen, onto the source tile. Interpolating the visible
 * bounds releases the square crop continuously without stretching the image or moving its centre.
 * Both rectangles must be in the pager's local coordinates.
 */
internal fun previewAnchorFrame(anchor: Rect, image: Rect, progress: Float,
    imageRotation: Float = 0f, visibleAnchor: Rect = anchor): PreviewAnchorFrame {
    val p = progress.coerceIn(0f, 1f)
    // The thumbnail is unrotated. Cancel the saved viewer direction at the source, then
    // smoothly restore it, together with its crop, along the shortest quarter-turn path.
    val direction = ((imageRotation + 180f) % 360f + 360f) % 360f - 180f
    val swapped = kotlin.math.abs((direction / 90f).roundToInt()) % 2 == 1
    val rawWidth = if (swapped) image.height else image.width
    val rawHeight = if (swapped) image.width else image.height
    val startScale = maxOf(anchor.width / rawWidth, anchor.height / rawHeight)
    val scale = startScale + (1f - startScale) * p
    val center = lerp(anchor.center, image.center, p)
    val halfWidth = (visibleAnchor.width + (rawWidth - visibleAnchor.width) * p) / (2f * scale)
    val halfHeight = (visibleAnchor.height + (rawHeight - visibleAnchor.height) * p) / (2f * scale)
    val clipCenter = image.center + (visibleAnchor.center - anchor.center) * ((1f - p) / scale)
    val rotation = -direction * (1f - p)
    val radians = Math.toRadians(rotation.toDouble())
    val c = cos(radians).toFloat()
    val s = sin(radians).toFloat()
    val rotatedCenter = Offset(image.center.x*c - image.center.y*s, image.center.x*s + image.center.y*c)
    return PreviewAnchorFrame(
        scale = scale,
        translation = center - rotatedCenter * scale,
        clip = Rect(clipCenter.x - halfWidth, clipCenter.y - halfHeight,
            clipCenter.x + halfWidth, clipCenter.y + halfHeight),
        rotation = rotation,
        clipRotation = direction,
    )
}
