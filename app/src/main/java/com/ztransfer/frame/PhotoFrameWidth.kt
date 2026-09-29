package com.ztransfer.frame

import kotlin.math.roundToInt

/** Expand decoration only: the source rectangle is never resampled in original-quality output. */
internal fun PhotoFrameLayout.withFrameWidth(preset: PhotoFramePreset, percent: Int): PhotoFrameLayout {
    val extra = (normalizePhotoFrameWidthPercent(percent) - 100) / 100f
    if (extra == 0f || preset == PhotoFramePreset.IMMERSIVE) return this
    val right = canvasWidth - photoRight
    val bottom = canvasHeight - photoBottom
    val photoWidth = photoRight - photoLeft
    var leftExtra = photoLeft * extra
    var rightExtra = right * extra
    var topExtra = photoTop * extra
    var bottomExtra = bottom * extra
    when (preset) {
        PhotoFramePreset.PLAQUE -> {
            leftExtra = 0f; rightExtra = 0f; topExtra = 0f
        }
        PhotoFramePreset.GALLERY_MAT -> {
            // A square canvas must remain square even around a panoramic source.
            val padding = minOf(photoLeft, right, photoTop, bottom) * extra
            leftExtra = padding; rightExtra = padding; topExtra = padding; bottomExtra = padding
        }
        PhotoFramePreset.PARAMETER_POSTER -> {
            // Grow the outer breathing room, not the much wider portrait information column.
            val padding = minOf(photoLeft, right, photoTop, bottom) * extra
            leftExtra = padding; rightExtra = padding; topExtra = padding; bottomExtra = padding
        }
        PhotoFramePreset.FILM_GALLERY -> {
            // Sprocket strips keep their original thickness.
            val bar = photoWidth * FILM_GALLERY_BAR_TO_PHOTO_WIDTH
            topExtra = (photoTop - bar).coerceAtLeast(0f) * extra
            bottomExtra = (bottom - bar).coerceAtLeast(0f) * extra
        }
        else -> Unit
    }
    val dx = leftExtra.roundToInt().toFloat()
    val dy = topExtra.roundToInt().toFloat()
    return copy(
        canvasWidth = Math.addExact(canvasWidth, (leftExtra + rightExtra).roundToInt()),
        canvasHeight = Math.addExact(canvasHeight, (topExtra + bottomExtra).roundToInt()),
        photoLeft = photoLeft + dx,
        photoRight = photoRight + dx,
        photoTop = photoTop + dy,
        photoBottom = photoBottom + dy,
        metadataTop = metadataTop + dy,
        addedBottomMargin = (topExtra + bottomExtra).roundToInt() - dy,
    )
}

/** Bound preview allocation after expansion; export never takes this path. */
internal fun PhotoFrameLayout.fitPreview(longEdge: Int?): PhotoFrameLayout {
    if (longEdge == null || maxOf(canvasWidth, canvasHeight) <= longEdge) return this
    val scale = longEdge.toFloat() / maxOf(canvasWidth, canvasHeight)
    return copy(
        canvasWidth = (canvasWidth * scale).roundToInt().coerceAtLeast(1),
        canvasHeight = (canvasHeight * scale).roundToInt().coerceAtLeast(1),
        photoLeft = photoLeft * scale, photoTop = photoTop * scale,
        photoRight = photoRight * scale, photoBottom = photoBottom * scale,
        metadataTop = metadataTop * scale,
        designWidth = designWidth * scale, designHeight = designHeight * scale,
        designMetadataTop = designMetadataTop * scale,
        addedBottomMargin = addedBottomMargin * scale,
    )
}

/** Both full-bitmap and region-based exports must select exactly the same template geometry. */
internal fun calculateOriginalQualityFrameLayout(
    width: Int,
    height: Int,
    preset: PhotoFramePreset,
): PhotoFrameLayout = when {
    preset == PhotoFramePreset.PLAQUE -> calculateOriginalQualityPlaqueLayout(width, height)
    preset == PhotoFramePreset.IMMERSIVE -> calculateImmersiveFrameLayout(width, height, maxOf(width, height))
    preset.isBrandFrame() -> calculateOriginalQualityBrandFrameLayout(width, height, preset)
    preset.isEditorialFrame() -> calculateOriginalQualityEditorialFrameLayout(width, height, preset)
    else -> calculateOriginalQualityPhotoFrameLayout(width, height)
}
