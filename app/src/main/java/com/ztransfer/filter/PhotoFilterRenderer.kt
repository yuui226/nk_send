package com.ztransfer.filter

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException

/** 在 sRGB 成片上近似 Flexible Color 的轻量渲染器。 */
object PhotoFilterRenderer {
    private const val ROW_CHUNK = 8
    private const val MAX_HUE_SHIFT_DEGREES = 30f
    private const val MAX_BAND_LIGHTNESS_SHIFT = 0.20f

    fun render(
        source: Bitmap,
        selection: PhotoFilterSelection,
        isCancelled: () -> Boolean = { false },
    ): Bitmap {
        val output = source.copy(Bitmap.Config.ARGB_8888, true)
            ?: error("Cannot allocate filtered bitmap")
        try {
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            val strength = selection.normalizedIntensityPercent / 100f
            if (strength <= 0f) return output

            val width = output.width
            val buffer = IntArray(width * min(ROW_CHUNK, output.height))
            var top = 0
            while (top < output.height) {
                if (isCancelled()) throw CancellationException("Photo filter render superseded")
                val rows = min(ROW_CHUNK, output.height - top)
                val count = width * rows
                output.getPixels(buffer, 0, width, 0, top, width, rows)
                for (index in 0 until count) {
                    buffer[index] = filterPixel(buffer[index], selection.preset, strength)
                }
                output.setPixels(buffer, 0, width, 0, top, width, rows)
                top += rows
            }
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            return output
        } catch (error: Throwable) {
            if (!output.isRecycled) output.recycle()
            throw error
        }
    }

    private fun filterPixel(color: Int, preset: PhotoFilterPreset, strength: Float): Int {
        val alpha = Color.alpha(color)
        if (alpha == 0) return color
        val originalR = Color.red(color)
        val originalG = Color.green(color)
        val originalB = Color.blue(color)
        val red = originalR / 255f
        val green = originalG / 255f
        val blue = originalB / 255f
        val maxValue = max(red, max(green, blue))
        val minValue = min(red, min(green, blue))
        val delta = maxValue - minValue
        var lightness = (maxValue + minValue) / 2f
        var saturation = if (delta == 0f) {
            0f
        } else {
            delta / (1f - abs(2f * lightness - 1f)).coerceAtLeast(0.0001f)
        }
        val originalHue = if (delta == 0f) {
            0f
        } else {
            normalizeHue(
                when (maxValue) {
                    red -> 60f * (((green - blue) / delta) % 6f)
                    green -> 60f * ((blue - red) / delta + 2f)
                    else -> 60f * ((red - green) / delta + 4f)
                },
            )
        }
        var leftIndex = 0
        var rightIndex = 1
        var progress = 0f
        for (index in PHOTO_FILTER_COLOR_BAND_CENTERS.indices) {
            val next = (index + 1) % PHOTO_FILTER_COLOR_BAND_CENTERS.size
            val start = PHOTO_FILTER_COLOR_BAND_CENTERS[index]
            val end = if (next == 0) 360f else PHOTO_FILTER_COLOR_BAND_CENTERS[next]
            val adjustedHue = if (next == 0 && originalHue < start) originalHue + 360f else originalHue
            if (adjustedHue in start..end) {
                leftIndex = index
                rightIndex = next
                progress = ((adjustedHue - start) / (end - start)).coerceIn(0f, 1f)
                break
            }
        }
        val left = preset.colorBands[leftIndex]
        val right = preset.colorBands[rightIndex]
        val inverseProgress = 1f - progress
        val hueShift = (left.hue * inverseProgress + right.hue * progress) /
            100f * MAX_HUE_SHIFT_DEGREES
        val chroma = left.chroma * inverseProgress + right.chroma * progress
        val bandBrightness = left.brightness * inverseProgress + right.brightness * progress
        val hue = normalizeHue(originalHue + hueShift)
        saturation *= 1f + chroma / 100f
        saturation *= 1f + preset.saturation / 100f
        lightness += bandBrightness / 100f * MAX_BAND_LIGHTNESS_SHIFT

        lightness = applyTonalControls(lightness, preset)
        val filtered = hslToRgbPacked(
            hue,
            saturation.coerceIn(0f, 1f),
            lightness.coerceIn(0f, 1f),
        )
        val filteredR = filtered ushr 16 and 0xff
        val filteredG = filtered ushr 8 and 0xff
        val filteredB = filtered and 0xff
        return Color.argb(
            alpha,
            mixChannel(originalR, filteredR, strength),
            mixChannel(originalG, filteredG, strength),
            mixChannel(originalB, filteredB, strength),
        )
    }

    private fun applyTonalControls(value: Float, preset: PhotoFilterPreset): Float {
        var lightness = value.coerceIn(0f, 1f)
        val shadowWeight = 1f - smoothStep(0.18f, 0.72f, lightness)
        val highlightWeight = smoothStep(0.28f, 0.82f, lightness)
        lightness += preset.blackLevel / 100f * 0.12f * (1f - lightness).pow(3)
        lightness += preset.shadows / 100f * 0.18f * shadowWeight
        lightness += preset.highlights / 100f * 0.18f * highlightWeight
        lightness += preset.whiteLevel / 100f * 0.12f * lightness.pow(3)
        val contrastScale = 2f.pow(preset.contrast / 100f)
        return ((lightness - 0.5f) * contrastScale + 0.5f).coerceIn(0f, 1f)
    }

    private fun smoothStep(edge0: Float, edge1: Float, value: Float): Float {
        val x = ((value - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
        return x * x * (3f - 2f * x)
    }

    private fun mixChannel(original: Int, filtered: Int, strength: Float): Int =
        (original + (filtered - original) * strength).roundToInt().coerceIn(0, 255)

    private fun hslToRgbPacked(hue: Float, saturation: Float, lightness: Float): Int {
        val chroma = (1f - abs(2f * lightness - 1f)) * saturation
        val section = normalizeHue(hue) / 60f
        val x = chroma * (1f - abs(section % 2f - 1f))
        var r1 = 0f
        var g1 = 0f
        var b1 = 0f
        when (section.toInt()) {
            0 -> { r1 = chroma; g1 = x }
            1 -> { r1 = x; g1 = chroma }
            2 -> { g1 = chroma; b1 = x }
            3 -> { g1 = x; b1 = chroma }
            4 -> { r1 = x; b1 = chroma }
            else -> { r1 = chroma; b1 = x }
        }
        val match = lightness - chroma / 2f
        val red = ((r1 + match) * 255f).roundToInt().coerceIn(0, 255)
        val green = ((g1 + match) * 255f).roundToInt().coerceIn(0, 255)
        val blue = ((b1 + match) * 255f).roundToInt().coerceIn(0, 255)
        return red shl 16 or (green shl 8) or blue
    }

    private fun normalizeHue(value: Float): Float = ((value % 360f) + 360f) % 360f
}
