package com.ztransfer.filter

internal val PHOTO_FILTER_COLOR_BAND_CENTERS = floatArrayOf(
    0f,
    30f,
    60f,
    120f,
    180f,
    240f,
    280f,
    320f,
)

/** A filter definition fully understood by the app renderer, independent of any import format. */
data class PhotoFilterPreset(
    val id: String,
    val name: String,
    val contrast: Int,
    val highlights: Int,
    val shadows: Int,
    val whiteLevel: Int,
    val blackLevel: Int,
    val saturation: Int,
    val colorBands: List<PhotoFilterColorBand>,
)

data class PhotoFilterColorBand(
    val centerDegrees: Float,
    val hue: Int,
    val chroma: Int,
    val brightness: Int,
)

data class PhotoFilterSelection(
    val preset: PhotoFilterPreset,
    val intensityPercent: Int,
) {
    val normalizedIntensityPercent: Int
        get() = normalizePhotoFilterIntensity(intensityPercent)
}

fun normalizePhotoFilterIntensity(value: Int): Int = value.coerceIn(0, 100)

/** Circular interpolation weights shared by the renderer and JVM tests. */
internal fun adjacentColorBandWeights(
    hueDegrees: Float,
    centers: List<Float>,
): Triple<Int, Int, Float> {
    require(centers.size >= 2)
    val hue = ((hueDegrees % 360f) + 360f) % 360f
    for (index in centers.indices) {
        val next = (index + 1) % centers.size
        val start = centers[index]
        val end = if (next == 0) centers[0] + 360f else centers[next]
        val adjustedHue = if (next == 0 && hue < start) hue + 360f else hue
        if (adjustedHue in start..end) {
            val progress = ((adjustedHue - start) / (end - start)).coerceIn(0f, 1f)
            return Triple(index, next, progress)
        }
    }
    return Triple(0, 1, 0f)
}
