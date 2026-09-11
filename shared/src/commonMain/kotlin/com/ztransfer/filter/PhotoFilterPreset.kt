package com.ztransfer.filter

data class PhotoFilterPreset(
    val id: String,
    val name: String,
    val parameters: PhotoFilterParameters,
) {
    init {
        require(id.isNotBlank())
        require(name.isNotBlank())
    }
}

sealed interface PhotoFilterParameters

/** Controls transferable from a legacy NCP preset to an already developed sRGB image. */
data class NcpPhotoFilterParameters(
    val saturationStep: Int,
    val hueStep: Int,
    val toneCurve: IntArray,
) : PhotoFilterParameters {
    init {
        require(saturationStep in -3..3)
        require(hueStep in -3..3)
        validateToneCurve(toneCurve)
    }

    /** Normalized lookup values consumed by each platform renderer. */
    val normalizedToneCurve = normalizeToneCurve(toneCurve)
}

/** Supported Flexible Color controls converted from an NP3 preset. */
data class Np3PhotoFilterParameters(
    val contrast: Int,
    val highlights: Int,
    val shadows: Int,
    val whites: Int,
    val blacks: Int,
    val saturation: Int,
    val colorBands: List<PhotoFilterColorBand>,
    val toneCurve: IntArray? = null,
) : PhotoFilterParameters {
    init {
        listOf(contrast, highlights, shadows, whites, blacks, saturation).forEach {
            require(it in -100..100)
        }
        require(colorBands.size == PHOTO_FILTER_COLOR_BAND_CENTERS.size)
        colorBands.forEachIndexed { index, band ->
            require(band.centerDegrees == PHOTO_FILTER_COLOR_BAND_CENTERS[index])
            require(band.hue in -100..100)
            require(band.chroma in -100..100)
            require(band.brightness in -100..100)
        }
        toneCurve?.let(::validateToneCurve)
    }

    /** Normalized lookup values consumed by each platform renderer, when a curve is present. */
    val normalizedToneCurve = toneCurve?.let(::normalizeToneCurve)
}

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

const val DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT = 80

/** Valid intensity detents are 2, 4, ... 100; disabling the filter is represented separately. */
fun normalizePhotoFilterIntensity(value: Int): Int {
    val clamped = value.coerceIn(2, 100)
    return ((clamped + 1) / 2 * 2).coerceAtMost(100)
}

fun mapPhotoFilterToneCurve(value: Float, curve: FloatArray): Float {
    val position = value.coerceIn(0f, 1f) * (PHOTO_FILTER_TONE_CURVE_POINT_COUNT - 1)
    val left = position.toInt().coerceIn(0, PHOTO_FILTER_TONE_CURVE_POINT_COUNT - 1)
    val right = minOf(left + 1, PHOTO_FILTER_TONE_CURVE_POINT_COUNT - 1)
    val progress = position - left
    return (curve[left] + (curve[right] - curve[left]) * progress).coerceIn(0f, 1f)
}

private fun validateToneCurve(curve: IntArray) {
    require(curve.size == PHOTO_FILTER_TONE_CURVE_POINT_COUNT)
    require(curve.all { it in 0..PHOTO_FILTER_TONE_CURVE_MAX_VALUE })
}

private fun normalizeToneCurve(curve: IntArray) =
    FloatArray(PHOTO_FILTER_TONE_CURVE_POINT_COUNT) { index ->
        curve[index] / PHOTO_FILTER_TONE_CURVE_MAX_VALUE.toFloat()
    }

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

const val PHOTO_FILTER_TONE_CURVE_POINT_COUNT = 257
const val PHOTO_FILTER_TONE_CURVE_MAX_VALUE = 0x7fff
