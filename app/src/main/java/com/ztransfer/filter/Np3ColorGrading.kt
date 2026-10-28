package com.ztransfer.filter

import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/** Source NP3 values, owned by the immutable recipe used by both preview and export. */
data class Np3ColorGradingRegion(
    val hue: Int = 0,
    val chroma: Int = 0,
    val brightness: Int = 0,
) {
    init {
        require(hue in 0..360)
        require(chroma in -100..100 && brightness in -100..100)
    }

    val isNeutral: Boolean get() = chroma == 0 && brightness == 0
}

data class Np3ColorGrading(
    val highlights: Np3ColorGradingRegion = Np3ColorGradingRegion(),
    val midtones: Np3ColorGradingRegion = Np3ColorGradingRegion(),
    val shadows: Np3ColorGradingRegion = Np3ColorGradingRegion(),
    val blending: Int = 50,
    val balance: Int = 0,
) {
    init {
        require(blending in 0..100 && balance in -100..100)
    }

    val isNeutral: Boolean get() = highlights.isNeutral && midtones.isNeutral && shadows.isNeutral
}

/**
 * Developed-sRGB approximation, not Nikon's unpublished RAW color science. Three smooth,
 * normalized luminance masks blend zero-luminance tint vectors; balance shifts the masks
 * toward highlights or shadows. Brightness and gamut fitting keep the result in gamut without
 * clipping individual channels. Pure black/white stay neutral; a preceding curve can lift them.
 *
 * Compile the masks once into four small tables. The common preview/export pixel loop does
 * no allocation or trigonometry, and neutral/legacy recipes never enter this path.
 */
internal class CompiledNp3ColorGrading private constructor(grading: Np3ColorGrading) {
    private val red = FloatArray(TABLE_SIZE + 1)
    private val green = FloatArray(TABLE_SIZE + 1)
    private val blue = FloatArray(TABLE_SIZE + 1)
    private val brightness = FloatArray(TABLE_SIZE + 1)

    init {
        val shadowTint = tint(grading.shadows)
        val midTint = tint(grading.midtones)
        val highlightTint = tint(grading.highlights)
        val radius = 0.5f + grading.blending / 200f
        val balance = grading.balance / 400f
        for (index in 0..TABLE_SIZE) {
            val luminance = index / TABLE_SIZE.toFloat()
            val tone = (luminance + balance).coerceIn(0f, 1f)
            val sw = mask(tone, radius)
            val mw = mask(abs(tone - 0.5f), radius)
            val hw = mask(1f - tone, radius)
            val total = sw + mw + hw // Always positive: adjacent masks overlap, even at blend=0.
            val s = sw / total
            val m = mw / total
            val h = hw / total
            val lift = (grading.shadows.brightness * s + grading.midtones.brightness * m +
                grading.highlights.brightness * h) / 100f * MAX_BRIGHTNESS_SHIFT
            val target = (luminance + lift * 4f * luminance * (1f - luminance)).coerceIn(0f, 1f)
            brightness[index] = when {
                target > luminance -> (target - luminance) / (1f - luminance)
                target < luminance -> (target - luminance) / luminance
                else -> 0f
            }
            val envelope = 4f * target * (1f - target)
            red[index] = (shadowTint[0] * s + midTint[0] * m + highlightTint[0] * h) * envelope
            green[index] = (shadowTint[1] * s + midTint[1] * m + highlightTint[1] * h) * envelope
            blue[index] = (shadowTint[2] * s + midTint[2] * m + highlightTint[2] * h) * envelope
        }
    }

    /** Input/output are packed RGB; the caller retains and blends the original alpha. */
    fun apply(rgb: Int): Int {
        var r = (rgb ushr 16 and 255) / 255f
        var g = (rgb ushr 8 and 255) / 255f
        var b = (rgb and 255) / 255f
        val position = ((r * RED_LUMA + g * GREEN_LUMA + b * BLUE_LUMA) * TABLE_SIZE)
            .coerceIn(0f, TABLE_SIZE.toFloat())
        val left = position.toInt()
        val right = min(left + 1, TABLE_SIZE)
        val fraction = position - left
        val lift = sample(brightness, left, right, fraction)
        if (lift >= 0f) {
            r += (1f - r) * lift
            g += (1f - g) * lift
            b += (1f - b) * lift
        } else {
            r *= 1f + lift
            g *= 1f + lift
            b *= 1f + lift
        }
        val dr = sample(red, left, right, fraction)
        val dg = sample(green, left, right, fraction)
        val db = sample(blue, left, right, fraction)
        // Limit the whole tint vector together, retaining its direction and zero luminance.
        val amount = min(1f, min(gamutLimit(r, dr), min(gamutLimit(g, dg), gamutLimit(b, db))))
        return (channel(r + dr * amount) shl 16) or (channel(g + dg * amount) shl 8) or
            channel(b + db * amount)
    }

    companion object {
        private const val TABLE_SIZE = 1024
        private const val MAX_CHROMA_SHIFT = 0.4f
        private const val MAX_BRIGHTNESS_SHIFT = 0.25f
        private const val RED_LUMA = 0.2126f
        private const val GREEN_LUMA = 0.7152f
        private const val BLUE_LUMA = 0.0722f

        fun compile(grading: Np3ColorGrading): CompiledNp3ColorGrading? =
            if (grading.isNeutral) null else CompiledNp3ColorGrading(grading)

        private fun mask(distance: Float, radius: Float): Float {
            val t = (distance / radius).coerceIn(0f, 1f)
            return 1f - t * t * (3f - 2f * t)
        }

        private fun tint(region: Np3ColorGradingRegion): FloatArray {
            val hue = (region.hue % 360) / 60f
            val secondary = 1f - abs(hue % 2f - 1f)
            val rgb = when (hue.toInt()) {
                0 -> floatArrayOf(1f, secondary, 0f)
                1 -> floatArrayOf(secondary, 1f, 0f)
                2 -> floatArrayOf(0f, 1f, secondary)
                3 -> floatArrayOf(0f, secondary, 1f)
                4 -> floatArrayOf(secondary, 0f, 1f)
                else -> floatArrayOf(1f, 0f, secondary)
            }
            val luminance = rgb[0] * RED_LUMA + rgb[1] * GREEN_LUMA + rgb[2] * BLUE_LUMA
            val amount = region.chroma / 100f * MAX_CHROMA_SHIFT
            for (index in rgb.indices) rgb[index] = (rgb[index] - luminance) * amount
            return rgb
        }

        private fun sample(values: FloatArray, left: Int, right: Int, t: Float): Float =
            values[left] + (values[right] - values[left]) * t

        private fun gamutLimit(value: Float, offset: Float): Float = when {
            offset > 0f -> (1f - value) / offset
            offset < 0f -> -value / offset
            else -> 1f
        }

        private fun channel(value: Float): Int = (value * 255f).roundToInt().coerceIn(0, 255)
    }
}
