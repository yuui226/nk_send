package com.ztransfer.frame

import kotlin.math.roundToInt

/** Bound preview allocation after expansion; export never takes this path. */
internal fun PhotoFrameLayout.fitPreview(longEdge: Int?, allowUpscale: Boolean = false): PhotoFrameLayout {
    if (longEdge == null || (!allowUpscale && maxOf(canvasWidth, canvasHeight) <= longEdge)) return this
    val scale = longEdge.toFloat() / maxOf(canvasWidth, canvasHeight)
    return copy(
        canvasWidth = (canvasWidth * scale).roundToInt().coerceAtLeast(1),
        canvasHeight = (canvasHeight * scale).roundToInt().coerceAtLeast(1),
        photoLeft = photoLeft * scale, photoTop = photoTop * scale,
        photoRight = photoRight * scale, photoBottom = photoBottom * scale,
        metadataTop = metadataTop * scale,
        designWidth = designWidth * scale, designHeight = designHeight * scale,
        designMetadataTop = designMetadataTop * scale,
        posterLayoutScale = posterLayoutScale * scale,
        textLayoutScale = textLayoutScale * scale,
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
