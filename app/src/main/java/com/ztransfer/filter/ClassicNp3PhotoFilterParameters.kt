package com.ztransfer.filter

/** A camera Auto control inherits the already developed source; it is not a manual -32 step. */
internal const val CLASSIC_PHOTO_FILTER_AUTO = -128

/** IDs stored in NP3 tag 0300, not the camera's selectable Picture Control numbers. */
enum class ClassicNp3Style(val id: Int, val monochrome: Boolean = false, val creative: Boolean = false) {
    STANDARD(0x0001), NEUTRAL(0x03c2), VIVID(0x00c3), PORTRAIT(0x0486),
    LANDSCAPE(0x04c7), FLAT(0x028e), AUTO(0x02cf), MONOCHROME(0x064d, true),
    FLAT_MONOCHROME(0x0654, true), DEEP_TONE_MONOCHROME(0x0655, true),
    RICH_TONE_PORTRAIT(0x0493),
    DREAM(0x0801, creative = true), MORNING(0x0802, creative = true),
    POP(0x0803, creative = true), SUNDAY(0x0804, creative = true),
    SOMBER(0x0805, creative = true), DRAMATIC(0x0806, creative = true),
    SILENCE(0x0807, creative = true), BLEACHED(0x0808, creative = true),
    MELANCHOLIC(0x0809, creative = true), PURE(0x080a, creative = true),
    DENIM(0x080b, creative = true), TOY(0x080c, creative = true),
    SEPIA(0x080d, true, true), BLUE(0x080e, true, true), RED(0x080f, true, true),
    PINK(0x0810, true, true), CHARCOAL(0x0811, true, true),
    GRAPHITE(0x0812, true, true), BINARY(0x0813, true, true), CARBON(0x0814, true, true);

    companion object {
        fun fromNp3Id(id: Int): ClassicNp3Style? = entries.firstOrNull { it.id == id }
    }
}

/**
 * Traditional Picture Control controls applied to an already developed sRGB photo.
 * Nikon's built-in RAW development/look tables are not embedded in NP3. Base styles therefore
 * use explicit conservative approximations; numeric adjustments and recorded curves are kept.
 * Quarter-step values avoid discarding the fractional adjustments used by newer cameras.
 */
data class ClassicNp3PhotoFilterParameters(
    val base: ClassicNp3Style,
    val contrastQuarter: Int,
    val brightnessQuarter: Int,
    val saturationQuarter: Int,
    val hueQuarter: Int,
    val filterEffect: Int,
    val toningEffect: Int,
    val toningDensityQuarter: Int,
    val effectLevel: Int,
    val toneCurve: IntArray? = null,
) : PhotoFilterParameters {
    init {
        require(contrastQuarter == CLASSIC_PHOTO_FILTER_AUTO || contrastQuarter in -12..12)
        require(brightnessQuarter in -6..6)
        require(saturationQuarter == CLASSIC_PHOTO_FILTER_AUTO || saturationQuarter in -12..12)
        require(hueQuarter in -12..12)
        require(filterEffect in 0..4)
        require(toningEffect in 0..9)
        require(toningDensityQuarter in 0..28)
        require(effectLevel in 0..100)
        toneCurve?.let { curve ->
            require(curve.size == PHOTO_FILTER_TONE_CURVE_POINT_COUNT)
            require(curve.all { it in 0..PHOTO_FILTER_TONE_CURVE_MAX_VALUE })
        }
    }

    // The samples already contain the curve header's input/output levels and gamma.
    internal val normalizedToneCurve = toneCurve?.let { curve ->
        FloatArray(curve.size) { curve[it] / PHOTO_FILTER_TONE_CURVE_MAX_VALUE.toFloat() }
    }
}
