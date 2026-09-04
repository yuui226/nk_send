package com.ztransfer.frame

import kotlin.math.min
import kotlin.math.roundToInt

private const val PLAQUE_BAND_TO_WIDTH = 0.12f
private const val BRAND_FRAME_SIDE_TO_PHOTO_WIDTH = 0.032f
private const val BRAND_INSET_BOTTOM_TO_PHOTO_WIDTH = 0.032f
private const val BRAND_GALLERY_BOTTOM_TO_PHOTO_WIDTH = 0.16f
private const val CLASSIC_SIGNATURE_SIDE_TO_PHOTO_WIDTH = 0.03f
private const val CLASSIC_SIGNATURE_TOP_TO_PHOTO_WIDTH = 0.095f
private const val CLASSIC_SIGNATURE_BOTTOM_TO_PHOTO_WIDTH = 0.15f
private const val FILM_GALLERY_SIDE_TO_PHOTO_WIDTH = 0.085f
private const val FILM_GALLERY_TOP_TO_PHOTO_WIDTH = 0.16f
const val FILM_GALLERY_BAR_TO_PHOTO_WIDTH = 0.09f
private const val FILM_GALLERY_BOTTOM_TO_PHOTO_WIDTH = 0.34f
private const val FILM_EDGE_SIDE_TO_PHOTO_WIDTH = 0.07f
private const val FILM_EDGE_TOP_TO_PHOTO_WIDTH = 0.035f
private const val FILM_EDGE_BOTTOM_TO_PHOTO_WIDTH = 0.085f
private const val COLOR_ARCHIVE_SIDE_TO_PHOTO_WIDTH = 0.04f
private const val COLOR_ARCHIVE_TOP_TO_PHOTO_WIDTH = 0.04f
private const val COLOR_ARCHIVE_BOTTOM_TO_PHOTO_WIDTH = 0.17f

data class PhotoFrameLayout(
    val canvasWidth: Int,
    val canvasHeight: Int,
    val photoLeft: Float,
    val photoTop: Float,
    val photoRight: Float,
    val photoBottom: Float,
    val metadataTop: Float,
)

data class FrameTextVisualBounds(
    /** Top coordinate relative to the text baseline, normally negative. */
    val top: Float,
    /** Bottom coordinate relative to the text baseline, normally zero or positive. */
    val bottom: Float,
)

data class PhotoWatermarkTextBounds(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
)

data class PhotoWatermarkPlacement(
    val originX: Float,
    val baseline: Float,
)

data class BrandFrameBounds(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top

    fun intersects(other: BrandFrameBounds): Boolean =
        left < other.right && other.left < right && top < other.bottom && other.top < bottom
}

fun calculatePhotoFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    val sourceAspect = sourceWidth.toFloat() / sourceHeight
    val (canvasWidth, canvasHeight) = when {
        sourceAspect > 1.9f -> longEdge to longEdge * 9 / 16
        sourceAspect > 1.1f -> longEdge to longEdge * 3 / 4
        sourceAspect >= 0.9f -> longEdge to longEdge
        sourceAspect >= 0.72f -> longEdge * 3 / 4 to longEdge
        sourceAspect >= 0.56f -> longEdge * 2 / 3 to longEdge
        else -> longEdge * 9 / 16 to longEdge
    }
    val portrait = canvasHeight > canvasWidth
    val square = canvasHeight == canvasWidth
    val side = canvasWidth * 0.052f
    val top = canvasHeight * when {
        portrait -> 0.030f
        square -> 0.040f
        else -> 0.050f
    }
    val metadataTop = canvasHeight * when {
        portrait -> 0.900f
        square -> 0.870f
        else -> 0.830f
    }
    val availableWidth = canvasWidth - side * 2f
    val availableHeight = metadataTop - top - canvasHeight * 0.012f
    val scale = min(availableWidth / sourceWidth, availableHeight / sourceHeight)
    val photoWidth = sourceWidth * scale
    val photoHeight = sourceHeight * scale
    val left = (canvasWidth - photoWidth) / 2f
    val photoAreaCenterY = top + availableHeight / 2f
    val photoTop = photoAreaCenterY - photoHeight / 2f
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = left,
        photoTop = photoTop,
        photoRight = left + photoWidth,
        photoBottom = photoTop + photoHeight,
        metadataTop = metadataTop,
    )
}

fun calculateOriginalQualityPhotoFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)

    fun fits(longEdge: Int): Boolean {
        val layout = calculatePhotoFrameLayout(sourceWidth, sourceHeight, longEdge)
        return layout.photoRight - layout.photoLeft >= sourceWidth.toFloat() &&
            layout.photoBottom - layout.photoTop >= sourceHeight.toFloat()
    }

    var low = maxOf(sourceWidth, sourceHeight)
    var high = low
    while (!fits(high)) {
        check(high <= Int.MAX_VALUE / 2) { "Original photo is too large to frame" }
        high *= 2
    }
    while (low < high) {
        val middle = low + (high - low) / 2
        if (fits(middle)) high = middle else low = middle + 1
    }

    val base = calculatePhotoFrameLayout(sourceWidth, sourceHeight, low)
    val left = ((base.canvasWidth - sourceWidth) / 2f)
        .roundToInt()
        .coerceIn(0, base.canvasWidth - sourceWidth)
        .toFloat()
    val desiredTop = ((base.photoTop + base.photoBottom) / 2f - sourceHeight / 2f).roundToInt()
    val maxTop = minOf(
        base.canvasHeight - sourceHeight,
        (base.metadataTop - sourceHeight).toInt(),
    ).coerceAtLeast(0)
    val top = desiredTop.coerceIn(0, maxTop).toFloat()
    return base.copy(
        photoLeft = left,
        photoTop = top,
        photoRight = left + sourceWidth,
        photoBottom = top + sourceHeight,
    )
}

fun calculateOriginalQualityPlaqueLayout(
    sourceWidth: Int,
    sourceHeight: Int,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    val bandHeight = (sourceWidth * PLAQUE_BAND_TO_WIDTH).roundToInt().coerceAtLeast(1)
    check(sourceHeight <= Int.MAX_VALUE - bandHeight) { "Original photo is too large to frame" }
    return PhotoFrameLayout(
        canvasWidth = sourceWidth,
        canvasHeight = sourceHeight + bandHeight,
        photoLeft = 0f,
        photoTop = 0f,
        photoRight = sourceWidth.toFloat(),
        photoBottom = sourceHeight.toFloat(),
        metadataTop = sourceHeight.toFloat(),
    )
}

fun calculatePlaqueFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(longEdge > 0)
    val compositeHeight = sourceHeight + sourceWidth * PLAQUE_BAND_TO_WIDTH
    val scale = min(longEdge.toFloat() / sourceWidth, longEdge.toFloat() / compositeHeight)
    val canvasWidth = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
    val preferredBandHeight = (canvasWidth * PLAQUE_BAND_TO_WIDTH).roundToInt().coerceAtLeast(1)
    val photoHeight = (sourceHeight * scale).roundToInt()
        .coerceIn(1, maxOf(1, longEdge - preferredBandHeight))
    val canvasHeight = photoHeight + preferredBandHeight
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = 0f,
        photoTop = 0f,
        photoRight = canvasWidth.toFloat(),
        photoBottom = photoHeight.toFloat(),
        metadataTop = photoHeight.toFloat(),
    )
}

fun calculateImmersiveFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(longEdge > 0)
    val scale = min(1f, longEdge.toFloat() / maxOf(sourceWidth, sourceHeight))
    val canvasWidth = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
    val canvasHeight = (sourceHeight * scale).roundToInt().coerceAtLeast(1)
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = 0f,
        photoTop = 0f,
        photoRight = canvasWidth.toFloat(),
        photoBottom = canvasHeight.toFloat(),
        metadataTop = canvasHeight.toFloat(),
    )
}

fun calculateBrandFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(longEdge > 0)
    require(preset.isBrandFrame())
    val bottomRatio = when (preset) {
        PhotoFramePreset.BRAND_INSET -> BRAND_INSET_BOTTOM_TO_PHOTO_WIDTH
        PhotoFramePreset.BRAND_GALLERY -> BRAND_GALLERY_BOTTOM_TO_PHOTO_WIDTH
        else -> error("Not a brand frame")
    }
    val compositeWidth = sourceWidth * (1f + BRAND_FRAME_SIDE_TO_PHOTO_WIDTH * 2f)
    val compositeHeight = sourceHeight + sourceWidth *
        (BRAND_FRAME_SIDE_TO_PHOTO_WIDTH + bottomRatio)
    val scale = min(longEdge / compositeWidth, longEdge / compositeHeight)
    val photoWidth = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
    val photoHeight = (sourceHeight * scale).roundToInt().coerceAtLeast(1)
    val side = (photoWidth * BRAND_FRAME_SIDE_TO_PHOTO_WIDTH).roundToInt().coerceAtLeast(1)
    val top = side
    val bottom = (photoWidth * bottomRatio).roundToInt().coerceAtLeast(1)
    val canvasWidth = photoWidth + side * 2
    val canvasHeight = photoHeight + top + bottom
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = side.toFloat(),
        photoTop = top.toFloat(),
        photoRight = (side + photoWidth).toFloat(),
        photoBottom = (top + photoHeight).toFloat(),
        metadataTop = (top + photoHeight).toFloat(),
    )
}

fun calculateOriginalQualityBrandFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(preset.isBrandFrame())
    val bottomRatio = when (preset) {
        PhotoFramePreset.BRAND_INSET -> BRAND_INSET_BOTTOM_TO_PHOTO_WIDTH
        PhotoFramePreset.BRAND_GALLERY -> BRAND_GALLERY_BOTTOM_TO_PHOTO_WIDTH
        else -> error("Not a brand frame")
    }
    val side = (sourceWidth * BRAND_FRAME_SIDE_TO_PHOTO_WIDTH).roundToInt().coerceAtLeast(1)
    val bottom = (sourceWidth * bottomRatio).roundToInt().coerceAtLeast(1)
    check(sourceWidth <= Int.MAX_VALUE - side * 2) { "Original photo is too large to frame" }
    check(sourceHeight <= Int.MAX_VALUE - side - bottom) { "Original photo is too large to frame" }
    return PhotoFrameLayout(
        canvasWidth = sourceWidth + side * 2,
        canvasHeight = sourceHeight + side + bottom,
        photoLeft = side.toFloat(),
        photoTop = side.toFloat(),
        photoRight = (side + sourceWidth).toFloat(),
        photoBottom = (side + sourceHeight).toFloat(),
        metadataTop = (side + sourceHeight).toFloat(),
    )
}

fun calculateEditorialFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(longEdge > 0)
    val original = calculateOriginalQualityEditorialFrameLayout(sourceWidth, sourceHeight, preset)
    val scale = longEdge.toFloat() / maxOf(original.canvasWidth, original.canvasHeight)
    fun scaled(value: Float): Float = value * scale
    return PhotoFrameLayout(
        canvasWidth = (original.canvasWidth * scale).roundToInt().coerceAtLeast(1),
        canvasHeight = (original.canvasHeight * scale).roundToInt().coerceAtLeast(1),
        photoLeft = scaled(original.photoLeft),
        photoTop = scaled(original.photoTop),
        photoRight = scaled(original.photoRight),
        photoBottom = scaled(original.photoBottom),
        metadataTop = scaled(original.metadataTop),
    )
}

fun calculateOriginalQualityEditorialFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(preset.isEditorialFrame())
    fun px(ratio: Float): Int = (sourceWidth * ratio).roundToInt().coerceAtLeast(1)
    return when (preset) {
        PhotoFramePreset.CLASSIC_SIGNATURE -> borderedEditorialLayout(
            sourceWidth, sourceHeight,
            px(CLASSIC_SIGNATURE_SIDE_TO_PHOTO_WIDTH),
            px(CLASSIC_SIGNATURE_TOP_TO_PHOTO_WIDTH),
            px(CLASSIC_SIGNATURE_BOTTOM_TO_PHOTO_WIDTH),
        )
        PhotoFramePreset.GALLERY_MAT -> {
            val aspect = sourceWidth.toFloat() / sourceHeight
            val (widthFraction, heightFraction) = when {
                aspect > 1.08f -> 0.80f to 0.56f
                aspect < 0.92f -> 0.56f to 0.80f
                else -> 0.68f to 0.68f
            }
            val side = maxOf(sourceWidth / widthFraction, sourceHeight / heightFraction)
                .roundToInt()
                .coerceAtLeast(maxOf(sourceWidth, sourceHeight))
            val left = (side - sourceWidth) / 2f
            val top = (side - sourceHeight) * 0.45f
            PhotoFrameLayout(
                canvasWidth = side,
                canvasHeight = side,
                photoLeft = left,
                photoTop = top,
                photoRight = left + sourceWidth,
                photoBottom = top + sourceHeight,
                metadataTop = top + sourceHeight,
            )
        }
        PhotoFramePreset.COLOR_ARCHIVE -> borderedEditorialLayout(
            sourceWidth, sourceHeight,
            px(COLOR_ARCHIVE_SIDE_TO_PHOTO_WIDTH),
            px(COLOR_ARCHIVE_TOP_TO_PHOTO_WIDTH),
            px(COLOR_ARCHIVE_BOTTOM_TO_PHOTO_WIDTH),
        )
        PhotoFramePreset.FILM_GALLERY -> {
            val side = px(FILM_GALLERY_SIDE_TO_PHOTO_WIDTH)
            val top = px(FILM_GALLERY_TOP_TO_PHOTO_WIDTH)
            val bar = px(FILM_GALLERY_BAR_TO_PHOTO_WIDTH)
            val bottom = px(FILM_GALLERY_BOTTOM_TO_PHOTO_WIDTH)
            val photoTop = top + bar
            PhotoFrameLayout(
                canvasWidth = sourceWidth + side * 2,
                canvasHeight = sourceHeight + top + bar * 2 + bottom,
                photoLeft = side.toFloat(),
                photoTop = photoTop.toFloat(),
                photoRight = (side + sourceWidth).toFloat(),
                photoBottom = (photoTop + sourceHeight).toFloat(),
                metadataTop = (photoTop + sourceHeight + bar).toFloat(),
            )
        }
        PhotoFramePreset.FILM_EDGE -> borderedEditorialLayout(
            sourceWidth, sourceHeight,
            px(FILM_EDGE_SIDE_TO_PHOTO_WIDTH),
            px(FILM_EDGE_TOP_TO_PHOTO_WIDTH),
            px(FILM_EDGE_BOTTOM_TO_PHOTO_WIDTH),
        )
        else -> error("Not an editorial frame")
    }
}

private fun borderedEditorialLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    side: Int,
    top: Int,
    bottom: Int,
): PhotoFrameLayout = PhotoFrameLayout(
    canvasWidth = sourceWidth + side * 2,
    canvasHeight = sourceHeight + top + bottom,
    photoLeft = side.toFloat(),
    photoTop = top.toFloat(),
    photoRight = (side + sourceWidth).toFloat(),
    photoBottom = (top + sourceHeight).toFloat(),
    metadataTop = (top + sourceHeight).toFloat(),
)

fun PhotoFramePreset.isBrandFrame(): Boolean =
    this == PhotoFramePreset.BRAND_INSET || this == PhotoFramePreset.BRAND_GALLERY

fun PhotoFramePreset.isEditorialFrame(): Boolean = when (this) {
    PhotoFramePreset.CLASSIC_SIGNATURE,
    PhotoFramePreset.GALLERY_MAT,
    PhotoFramePreset.COLOR_ARCHIVE,
    PhotoFramePreset.FILM_GALLERY,
    PhotoFramePreset.FILM_EDGE -> true
    else -> false
}

fun placeBrandMetadataBlock(
    photo: BrandFrameBounds,
    preferredBottom: Float,
    blockHeight: Float,
    blockWidth: Float,
    occupied: BrandFrameBounds?,
    gap: Float,
): BrandFrameBounds {
    require(photo.width > 0f && photo.height > 0f)
    require(blockHeight in 0f..photo.height)
    require(blockWidth > 0f)
    require(gap >= 0f)

    val width = blockWidth.coerceAtMost(photo.width)
    val left = photo.left + (photo.width - width) / 2f
    fun blockEndingAt(bottom: Float): BrandFrameBounds {
        val clampedBottom = bottom.coerceIn(photo.top + blockHeight, photo.bottom)
        return BrandFrameBounds(left, clampedBottom - blockHeight, left + width, clampedBottom)
    }

    val preferred = blockEndingAt(preferredBottom)
    if (occupied == null || !preferred.intersects(occupied)) return preferred

    val above = blockEndingAt(occupied.top - gap)
    if (above.top >= photo.top && !above.intersects(occupied)) return above

    val belowTop = occupied.bottom + gap
    if (belowTop + blockHeight <= photo.bottom) {
        val below = BrandFrameBounds(left, belowTop, left + width, belowTop + blockHeight)
        if (!below.intersects(occupied)) return below
    }

    val roomAbove = (occupied.top - gap - photo.top).coerceAtLeast(0f)
    val roomBelow = (photo.bottom - occupied.bottom - gap).coerceAtLeast(0f)
    return if (roomAbove >= roomBelow) {
        blockEndingAt((occupied.top - gap).coerceAtLeast(photo.top + blockHeight))
    } else {
        val top = (occupied.bottom + gap).coerceAtMost(photo.bottom - blockHeight)
        BrandFrameBounds(left, top, left + width, top + blockHeight)
    }
}

fun photoFrameCornerRadius(layout: PhotoFrameLayout): Float =
    (layout.canvasHeight - layout.metadataTop) * 0.26f

fun PhotoFrameWatermarkPosition.isPhotoPlacement(): Boolean = when (this) {
    PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
    PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
    PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT,
    PhotoFrameWatermarkPosition.PHOTO_CENTER,
    PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT,
    PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
    PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT -> true
    PhotoFrameWatermarkPosition.AUTO,
    PhotoFrameWatermarkPosition.LEFT,
    PhotoFrameWatermarkPosition.CENTER,
    PhotoFrameWatermarkPosition.RIGHT -> false
}

fun calculatePhotoWatermarkPlacement(
    photoLeft: Float,
    photoTop: Float,
    photoRight: Float,
    photoBottom: Float,
    textBounds: PhotoWatermarkTextBounds,
    position: PhotoFrameWatermarkPosition,
): PhotoWatermarkPlacement {
    require(photoRight > photoLeft)
    require(photoBottom > photoTop)
    require(textBounds.right >= textBounds.left)
    require(textBounds.bottom >= textBounds.top)
    require(position.isPhotoPlacement())

    val safeInset = min(photoRight - photoLeft, photoBottom - photoTop) * 0.04f
    val minOriginX = photoLeft + safeInset - textBounds.left
    val maxOriginX = photoRight - safeInset - textBounds.right
    val minBaseline = photoTop + safeInset - textBounds.top
    val maxBaseline = photoBottom - safeInset - textBounds.bottom
    val centeredOriginX = (photoLeft + photoRight - textBounds.left - textBounds.right) / 2f
    val centeredBaseline = (photoTop + photoBottom - textBounds.top - textBounds.bottom) / 2f

    val requestedX = when (position) {
        PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT -> minOriginX
        PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER -> centeredOriginX
        PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT -> maxOriginX
        else -> error("A metadata placement cannot be positioned inside the photo")
    }
    val requestedBaseline = when (position) {
        PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
        PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT -> minBaseline
        PhotoFrameWatermarkPosition.PHOTO_CENTER -> centeredBaseline
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT -> maxBaseline
        else -> error("A metadata placement cannot be positioned inside the photo")
    }
    return PhotoWatermarkPlacement(
        originX = if (minOriginX <= maxOriginX) requestedX.coerceIn(minOriginX, maxOriginX)
        else centeredOriginX,
        baseline = if (minBaseline <= maxBaseline) requestedBaseline.coerceIn(minBaseline, maxBaseline)
        else centeredBaseline,
    )
}

fun watermarkAlpha(opacityPercent: Int): Int =
    (normalizePhotoFrameWatermarkOpacityPercent(opacityPercent) * 255f / 100f).roundToInt()

fun frameTextScaleToFit(areaHeight: Float, rows: List<FrameTextVisualBounds>): Float {
    require(areaHeight >= 0f)
    rows.forEach { require(it.bottom >= it.top) }
    val textHeight = rows.sumOf { (it.bottom - it.top).toDouble() }.toFloat()
    if (textHeight <= 0f || textHeight <= areaHeight) return 1f
    return (areaHeight / textHeight * 0.98f).coerceIn(0f, 1f)
}

fun frameMetadataVerticalPadding(areaHeight: Float): Float {
    require(areaHeight >= 0f)
    return areaHeight * 0.06f
}

fun centeredFrameTextBaselines(
    areaTop: Float,
    areaBottom: Float,
    rows: List<FrameTextVisualBounds>,
    preferredGap: Float,
): List<Float> {
    require(areaBottom >= areaTop)
    require(preferredGap >= 0f)
    if (rows.isEmpty()) return emptyList()
    rows.forEach { require(it.bottom >= it.top) }

    val areaHeight = areaBottom - areaTop
    val textHeight = rows.sumOf { (it.bottom - it.top).toDouble() }.toFloat()
    val gapCount = rows.size - 1
    val gap = if (gapCount > 0) {
        min(preferredGap, ((areaHeight - textHeight) / gapCount).coerceAtLeast(0f))
    } else {
        0f
    }
    val groupHeight = textHeight + gap * gapCount
    var cursor = areaTop + (areaHeight - groupHeight).coerceAtLeast(0f) / 2f
    return rows.map { row ->
        val baseline = cursor - row.top
        cursor += row.bottom - row.top + gap
        baseline
    }
}
