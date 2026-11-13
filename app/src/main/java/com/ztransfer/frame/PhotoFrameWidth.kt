package com.ztransfer.frame

import kotlin.math.roundToInt

private const val UNIFORM_FRAME_REFERENCE_WIDTH = 1000
private const val UNIFORM_FRAME_REFERENCE_HEIGHT = 667

/**
 * Frames that need a uniform-border variant and have no permanent decorative bands.
 * BRAND_INSET is already uniform: retain its existing geometry, rounding and output identity.
 */
internal val PhotoFramePreset.supportsUniformPhotoFrameBorder: Boolean
    get() = when (this) {
        PhotoFramePreset.MIST,
        PhotoFramePreset.CINEMA,
        PhotoFramePreset.MINIMAL,
        PhotoFramePreset.FROSTED,
        PhotoFramePreset.BRAND_GALLERY,
        PhotoFramePreset.CLASSIC_SIGNATURE -> true
        else -> false
    }

/** Use the switches, not missing EXIF: preview placeholders and export must select one layout. */
internal fun usesUniformPhotoFrameBorder(
    preset: PhotoFramePreset,
    metadataSettings: PhotoFrameMetadataSettings,
    watermark: PhotoFrameWatermark,
): Boolean {
    if (!preset.supportsUniformPhotoFrameBorder || watermark.occupiesFrameBand(preset)) return false
    val settings = normalizePhotoFrameMetadataSettings(metadataSettings)
    // Brand Gallery keeps its other information inside the photo; it needs a band only for
    // the brand/model. Those inner fields still need metadata and must remain visible.
    val hasBandInformation = if (preset == PhotoFramePreset.BRAND_GALLERY) {
        settings.showBrand || settings.showModel
    } else {
        settings.requiresCameraMetadata
    }
    return !hasBandInformation
}

/**
 * Keep the original photo at 1:1 and use the template's 3:2 reference side margin on all four
 * sides. This branch needs no fixed-ratio information band: choosing the old canvas ratio from
 * the source aspect would let preview downsampling cross a ratio threshold and change margins.
 * A single integer margin avoids asymmetric rounding; styling units stay independent of the dial.
 */
internal fun calculateUniformPhotoFrameLayout(
    width: Int,
    height: Int,
    preset: PhotoFramePreset,
    percent: Int,
): PhotoFrameLayout {
    require(width > 0 && height > 0)
    require(preset.supportsUniformPhotoFrameBorder)
    val reference = calculateOriginalQualityFrameLayout(
        UNIFORM_FRAME_REFERENCE_WIDTH, UNIFORM_FRAME_REFERENCE_HEIGHT, preset,
    )
    val scale = width.toFloat() / UNIFORM_FRAME_REFERENCE_WIDTH
    val marginPixels = kotlin.math.ceil(
        reference.photoLeft.toDouble() * normalizePhotoFrameWidthPercent(percent) * width /
            (100.0 * UNIFORM_FRAME_REFERENCE_WIDTH),
    )
    require(marginPixels.isFinite() && marginPixels in 0.0..Int.MAX_VALUE.toDouble()) {
        "Frame content is too large"
    }
    val margin = marginPixels.toInt()
    val doubledMargin = Math.multiplyExact(margin, 2)
    return PhotoFrameLayout(
        canvasWidth = Math.addExact(width, doubledMargin),
        canvasHeight = Math.addExact(height, doubledMargin),
        photoLeft = margin.toFloat(),
        photoTop = margin.toFloat(),
        photoRight = margin + width.toFloat(),
        photoBottom = margin + height.toFloat(),
        metadataTop = margin + height.toFloat(),
        designWidth = reference.designWidth * scale,
        // Adapt to the photo height continuously, retaining the template's decoration sizes.
        designHeight = height + (reference.designHeight - UNIFORM_FRAME_REFERENCE_HEIGHT) * scale,
        designMetadataTop = height + (reference.designMetadataTop - UNIFORM_FRAME_REFERENCE_HEIGHT) * scale,
        textLayout = MeasuredFrameTextPlan(emptyList()),
        textLayoutScale = scale,
        photoTextLayout = if (preset.isBrandFrame()) MeasuredFrameTextPlan(emptyList()) else null,
    )
}

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
