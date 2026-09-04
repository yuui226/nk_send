package com.ztransfer.filter

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

private const val CANCELLATION_CHECK_INTERVAL = 4 * 1024
private const val NCP_MAX_MANUAL_STEP = 3f
private const val APPROXIMATE_MAX_HUE_SHIFT_DEGREES = 30f
private const val MAX_BAND_LIGHTNESS_SHIFT = 0.20f

const val NEUTRAL_PROTECTION_CHROMA_START = 4f / 255f
const val NEUTRAL_PROTECTION_CHROMA_END = 16f / 255f

/** Precomputed values for applying one selection to many ARGB pixels. */
class CompiledPhotoFilter internal constructor(
    internal val preset: PhotoFilterPreset,
    internal val strength: Float,
    internal val preserveAlpha: Boolean,
    internal val ncpHueShiftDegrees: Float = 0f,
    internal val ncpSaturationAdjustment: Float = 0f,
    internal val np3SaturationAdjustment: Float = 0f,
    internal val np3ColorBands: CompiledNp3ColorBands? = null,
    internal val np3TonalControls: CompiledNp3TonalControls? = null,
)

internal data class CompiledNp3ColorBands(
    val hue: IntArray,
    val chroma: IntArray,
    val brightness: IntArray,
)

internal data class CompiledNp3TonalControls(
    val blacksScale: Float,
    val shadowsScale: Float,
    val highlightsScale: Float,
    val whitesScale: Float,
    val contrastScale: Float,
)

fun compilePhotoFilter(
    selection: PhotoFilterSelection,
    preserveAlpha: Boolean,
): CompiledPhotoFilter {
    val preset = selection.preset
    val strength = selection.normalizedIntensityPercent / 100f
    return when (val parameters = preset.parameters) {
        is NcpPhotoFilterParameters -> CompiledPhotoFilter(
            preset = preset,
            strength = strength,
            preserveAlpha = preserveAlpha,
            ncpHueShiftDegrees = parameters.hueStep / NCP_MAX_MANUAL_STEP *
                APPROXIMATE_MAX_HUE_SHIFT_DEGREES,
            ncpSaturationAdjustment = parameters.saturationStep / NCP_MAX_MANUAL_STEP,
        )
        is Np3PhotoFilterParameters -> CompiledPhotoFilter(
            preset = preset,
            strength = strength,
            preserveAlpha = preserveAlpha,
            np3SaturationAdjustment = parameters.saturation / 100f,
            np3ColorBands = CompiledNp3ColorBands(
                hue = IntArray(parameters.colorBands.size) { parameters.colorBands[it].hue },
                chroma = IntArray(parameters.colorBands.size) { parameters.colorBands[it].chroma },
                brightness = IntArray(parameters.colorBands.size) {
                    parameters.colorBands[it].brightness
                },
            ),
            np3TonalControls = if (parameters.normalizedToneCurve == null) {
                CompiledNp3TonalControls(
                    blacksScale = parameters.blacks / 100f * 0.12f,
                    shadowsScale = parameters.shadows / 100f * 0.18f,
                    highlightsScale = parameters.highlights / 100f * 0.18f,
                    whitesScale = parameters.whites / 100f * 0.12f,
                    contrastScale = 2f.pow(parameters.contrast / 100f),
                )
            } else {
                null
            },
        )
    }
}

fun renderPhotoFilterArgbPixels(
    source: IntArray,
    selection: PhotoFilterSelection,
    preserveAlpha: Boolean,
): IntArray = source.copyOf().also { output ->
    renderPhotoFilterArgbRange(
        pixels = output,
        start = 0,
        end = output.size,
        compiled = compilePhotoFilter(selection, preserveAlpha),
    )
}

fun renderPhotoFilterArgbRange(
    pixels: IntArray,
    start: Int,
    end: Int,
    compiled: CompiledPhotoFilter,
    onCancellationCheck: () -> Unit = {},
) {
    require(start in 0..end && end <= pixels.size)
    var index = start
    var nextCancellationCheck = start
    while (index < end) {
        if (index == nextCancellationCheck) {
            onCancellationCheck()
            nextCancellationCheck += CANCELLATION_CHECK_INTERVAL
        }
        pixels[index] = filterPhotoPixel(pixels[index], compiled)
        index++
    }
}

fun buildPhotoFilterRgbLutRange(
    output: IntArray,
    start: Int,
    end: Int,
    compiled: CompiledPhotoFilter,
    onCancellationCheck: () -> Unit = {},
) {
    require(start in 0..end && end <= output.size)
    var rgb = start
    var nextCancellationCheck = start
    while (rgb < end) {
        if (rgb == nextCancellationCheck) {
            onCancellationCheck()
            nextCancellationCheck += CANCELLATION_CHECK_INTERVAL
        }
        output[rgb] = filterPhotoPixel(0xff000000.toInt() or rgb, compiled) and 0x00ffffff
        rgb++
    }
}

fun exactLookupOutputColor(
    originalColor: Int,
    mappedRgb: Int,
    preserveAlpha: Boolean,
): Int {
    val alpha = if (preserveAlpha) originalColor ushr 24 and 0xff else 0xff
    return if (alpha == 0) {
        originalColor
    } else {
        alpha shl 24 or (mappedRgb and 0x00ffffff)
    }
}

fun applyPhotoFilterExactRgbLutRange(
    pixels: IntArray,
    start: Int,
    end: Int,
    lookup: IntArray,
    preserveAlpha: Boolean,
    onCancellationCheck: () -> Unit = {},
) {
    require(start in 0..end && end <= pixels.size)
    var index = start
    var nextCancellationCheck = start
    while (index < end) {
        if (index == nextCancellationCheck) {
            onCancellationCheck()
            nextCancellationCheck += CANCELLATION_CHECK_INTERVAL
        }
        val color = pixels[index]
        pixels[index] = exactLookupOutputColor(
            originalColor = color,
            mappedRgb = lookup[color and 0x00ffffff],
            preserveAlpha = preserveAlpha,
        )
        index++
    }
}

private fun filterPhotoPixel(color: Int, compiled: CompiledPhotoFilter): Int {
    val alpha = if (compiled.preserveAlpha) color ushr 24 and 0xff else 0xff
    if (alpha == 0) return color
    val originalR = color ushr 16 and 0xff
    val originalG = color ushr 8 and 0xff
    val originalB = color and 0xff
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
        normalizePhotoFilterHue(
            when (maxValue) {
                red -> 60f * ((green - blue) / delta)
                green -> 60f * ((blue - red) / delta + 2f)
                else -> 60f * ((red - green) / delta + 4f)
            },
        )
    }
    val colorAdjustmentWeight = photoFilterNeutralProtectionWeight(delta)
    var hue = originalHue

    when (val parameters = compiled.preset.parameters) {
        is NcpPhotoFilterParameters -> {
            if (compiled.ncpHueShiftDegrees != 0f) {
                hue = normalizePhotoFilterHue(
                    originalHue + compiled.ncpHueShiftDegrees * colorAdjustmentWeight,
                )
            }
            if (compiled.ncpSaturationAdjustment != 0f) {
                saturation *= protectedSaturationScale(
                    compiled.ncpSaturationAdjustment,
                    colorAdjustmentWeight,
                )
            }
            lightness = mapPhotoFilterToneCurve(lightness, parameters.normalizedToneCurve)
        }
        is Np3PhotoFilterParameters -> {
            val leftIndex = when {
                originalHue < 30f -> 0
                originalHue < 60f -> 1
                originalHue < 120f -> 2
                originalHue < 180f -> 3
                originalHue < 240f -> 4
                originalHue < 280f -> 5
                originalHue < 320f -> 6
                else -> 7
            }
            val rightIndex = if (leftIndex == 7) 0 else leftIndex + 1
            val start = PHOTO_FILTER_COLOR_BAND_CENTERS[leftIndex]
            val end = if (rightIndex == 0) 360f else PHOTO_FILTER_COLOR_BAND_CENTERS[rightIndex]
            val progress = ((originalHue - start) / (end - start)).coerceIn(0f, 1f)
            val bands = checkNotNull(compiled.np3ColorBands)
            val inverseProgress = 1f - progress
            val hueShift = (bands.hue[leftIndex] * inverseProgress +
                bands.hue[rightIndex] * progress) / 100f * APPROXIMATE_MAX_HUE_SHIFT_DEGREES
            val chroma = bands.chroma[leftIndex] * inverseProgress +
                bands.chroma[rightIndex] * progress
            val brightness = bands.brightness[leftIndex] * inverseProgress +
                bands.brightness[rightIndex] * progress
            hue = normalizePhotoFilterHue(originalHue + hueShift * colorAdjustmentWeight)
            saturation *= 1f + chroma / 100f * colorAdjustmentWeight
            if (compiled.np3SaturationAdjustment != 0f) {
                saturation *= protectedSaturationScale(
                    compiled.np3SaturationAdjustment,
                    colorAdjustmentWeight,
                )
            }
            lightness += brightness / 100f * MAX_BAND_LIGHTNESS_SHIFT * colorAdjustmentWeight
            lightness = parameters.normalizedToneCurve?.let { curve ->
                mapPhotoFilterToneCurve(lightness, curve)
            } ?: applyNp3TonalControls(lightness, checkNotNull(compiled.np3TonalControls))
        }
    }

    val filtered = hslToRgbPacked(
        hue,
        saturation.coerceIn(0f, 1f),
        lightness.coerceIn(0f, 1f),
    )
    return alpha shl 24 or
        (mixChannel(originalR, filtered ushr 16 and 0xff, compiled.strength) shl 16) or
        (mixChannel(originalG, filtered ushr 8 and 0xff, compiled.strength) shl 8) or
        mixChannel(originalB, filtered and 0xff, compiled.strength)
}

private fun applyNp3TonalControls(value: Float, controls: CompiledNp3TonalControls): Float {
    var lightness = value.coerceIn(0f, 1f)
    val shadowWeight = if (controls.shadowsScale != 0f) {
        1f - smoothStep(0.18f, 0.72f, lightness)
    } else {
        0f
    }
    val highlightWeight = if (controls.highlightsScale != 0f) {
        smoothStep(0.28f, 0.82f, lightness)
    } else {
        0f
    }
    if (controls.blacksScale != 0f) {
        val inverse = 1f - lightness
        lightness += controls.blacksScale * inverse * inverse * inverse
    }
    if (controls.shadowsScale != 0f) lightness += controls.shadowsScale * shadowWeight
    if (controls.highlightsScale != 0f) lightness += controls.highlightsScale * highlightWeight
    if (controls.whitesScale != 0f) {
        lightness += controls.whitesScale * lightness * lightness * lightness
    }
    return ((lightness - 0.5f) * controls.contrastScale + 0.5f).coerceIn(0f, 1f)
}

private fun smoothStep(edge0: Float, edge1: Float, value: Float): Float {
    val x = ((value - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
    return x * x * (3f - 2f * x)
}

fun photoFilterNeutralProtectionWeight(rgbChroma: Float): Float = smoothStep(
    NEUTRAL_PROTECTION_CHROMA_START,
    NEUTRAL_PROTECTION_CHROMA_END,
    rgbChroma,
)

private fun protectedSaturationScale(adjustment: Float, colorAdjustmentWeight: Float): Float =
    1f + if (adjustment > 0f) adjustment * colorAdjustmentWeight else adjustment

private fun mixChannel(original: Int, filtered: Int, strength: Float): Int =
    (original + (filtered - original) * strength).roundToInt().coerceIn(0, 255)

private fun hslToRgbPacked(hue: Float, saturation: Float, lightness: Float): Int {
    val chroma = (1f - abs(2f * lightness - 1f)) * saturation
    val section = hue / 60f
    val sector = section.toInt()
    val x = photoFilterHslSecondaryComponent(section, sector, chroma)
    var r1 = 0f
    var g1 = 0f
    var b1 = 0f
    when (sector) {
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

fun normalizePhotoFilterHue(value: Float): Float = when {
    value < 0f -> value + 360f
    value >= 360f -> value - 360f
    else -> value
}

fun photoFilterHslSecondaryComponent(section: Float, sector: Int, chroma: Float): Float {
    val fraction = section - sector
    return chroma * if (sector and 1 == 0) fraction else 1f - fraction
}
