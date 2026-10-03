package com.ztransfer.filter

/**
 * The canonical finishing pass for a LUT result. It deliberately stays in the existing sRGB
 * byte domain so preview, export and retry do not acquire different colour-space assumptions.
 */
internal object LutColorPipeline {
    private const val SHADOW_RANGE = 0.68f
    private const val HIGHLIGHT_START = 0.32f
    private const val MAX_TONE_SHIFT = 0.28f

    fun apply(color: Int, adjustments: LutAdjustments, preserveAlpha: Boolean): Int {
        if (adjustments.isNeutral) return color
        val alpha = if (preserveAlpha) color ushr 24 and 0xff else 0xff
        if (alpha == 0) return color
        var r = (color ushr 16 and 0xff) / 255f
        var g = (color ushr 8 and 0xff) / 255f
        var b = (color and 0xff) / 255f
        val luma = (r * 0.2126f + g * 0.7152f + b * 0.0722f).coerceIn(0f, 1f)
        val shadowWeight = smoothStep(0f, SHADOW_RANGE, 1f - luma)
        val highlightWeight = smoothStep(HIGHLIGHT_START, 1f, luma)
        val shadows = -adjustments.shadows / 100f * MAX_TONE_SHIFT * shadowWeight
        val highlights = adjustments.highlights / 100f * MAX_TONE_SHIFT * highlightWeight
        r = (r + shadows + highlights).coerceIn(0f, 1f)
        g = (g + shadows + highlights).coerceIn(0f, 1f)
        b = (b + shadows + highlights).coerceIn(0f, 1f)

        val contrast = 1f + adjustments.contrast / 100f * 0.75f
        r = ((r - 0.5f) * contrast + 0.5f).coerceIn(0f, 1f)
        g = ((g - 0.5f) * contrast + 0.5f).coerceIn(0f, 1f)
        b = ((b - 0.5f) * contrast + 0.5f).coerceIn(0f, 1f)

        val postLuma = (r * 0.2126f + g * 0.7152f + b * 0.0722f).coerceIn(0f, 1f)
        val saturation = 1f + adjustments.saturation / 100f
        r = (postLuma + (r - postLuma) * saturation).coerceIn(0f, 1f)
        g = (postLuma + (g - postLuma) * saturation).coerceIn(0f, 1f)
        b = (postLuma + (b - postLuma) * saturation).coerceIn(0f, 1f)
        return (alpha shl 24) or ((r * 255f + .5f).toInt() shl 16) or
            ((g * 255f + .5f).toInt() shl 8) or (b * 255f + .5f).toInt()
    }

    private fun smoothStep(edge0: Float, edge1: Float, value: Float): Float {
        if (edge0 == edge1) return if (value < edge0) 0f else 1f
        val t = ((value - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
        return t * t * (3f - 2f * t)
    }
}
