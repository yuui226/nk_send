package com.ztransfer.filter

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import java.util.concurrent.ForkJoinPool
import java.util.concurrent.RecursiveAction

/** Applies the supported NCP/NP3 controls to an already developed sRGB image. */
object PhotoFilterRenderer {
    private const val PARALLEL_PIXEL_THRESHOLD = 512 * 512
    private const val PIXELS_PER_TASK = 64 * 1024
    /** Export stripes stay small even for 45MP originals while still feeding all filter workers. */
    private const val IN_PLACE_PIXELS_PER_STRIPE = 1024 * 1024
    private const val CANCELLATION_CHECK_INTERVAL = 4 * 1024
    private const val NCP_MAX_MANUAL_STEP = 3f
    // Nikon does not publish its post-RAW sRGB transform. Manual hue controls are mapped linearly,
    // while the source tone curves and Flexible Color mixer values remain exact.
    private const val APPROXIMATE_MAX_HUE_SHIFT_DEGREES = 30f
    private const val MAX_BAND_LIGHTNESS_SHIFT = 0.20f
    /**
     * Hue is not reliable close to the neutral axis: tiny sensor/JPEG channel differences can
     * assign neighboring gray pixels to unrelated color bands. Fade chromatic adjustments in
     * over a deliberately small sRGB-chroma range so neutral noise is not turned into blotches,
     * while established colors retain the preset's original result.
     */
    internal const val NEUTRAL_PROTECTION_CHROMA_START = 4f / 255f
    internal const val NEUTRAL_PROTECTION_CHROMA_END = 16f / 255f
    // 最多使用四个工作线程，并始终为界面/系统保留至少一个处理器。
    private val filterParallelism =
        (Runtime.getRuntime().availableProcessors() - 1).coerceIn(1, 4)
    private val filterPool by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        ForkJoinPool(filterParallelism)
    }

    fun render(
        source: Bitmap,
        selection: PhotoFilterSelection,
        isCancelled: () -> Boolean = { false },
    ): Bitmap {
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
        val width = source.width
        val height = source.height
        val pixels = IntArray(width * height)
        source.getPixels(pixels, 0, width, 0, 0, width, height)
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
        val strength = selection.normalizedIntensityPercent / 100f
        if (filterParallelism > 1 && pixels.size >= PARALLEL_PIXEL_THRESHOLD) {
            filterPool.invoke(
                FilterPixelsAction(
                    pixels = pixels,
                    start = 0,
                    end = pixels.size,
                    preset = selection.preset,
                    strength = strength,
                    isCancelled = isCancelled,
                )
            )
        } else {
            filterPixelRange(
                pixels = pixels,
                start = 0,
                end = pixels.size,
                preset = selection.preset,
                strength = strength,
                isCancelled = isCancelled,
            )
        }
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            density = source.density
            setHasAlpha(source.hasAlpha())
        }
        try {
            output.setPixels(pixels, 0, width, 0, 0, width, height)
            return output
        } catch (error: Throwable) {
            output.recycle()
            throw error
        }
    }

    /**
     * Applies a filter to a mutable export bitmap without allocating another full-resolution
     * bitmap and full-image [IntArray]. Only one bounded stripe is resident at a time; pixel work
     * inside that stripe still uses the filter pool. This is the original-resolution export path.
     */
    fun renderInPlace(
        source: Bitmap,
        selection: PhotoFilterSelection,
        isCancelled: () -> Boolean = { false },
        scratchPixels: IntArray? = null,
    ): Bitmap {
        require(source.isMutable) { "Original-quality filter source must be mutable" }
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
        val width = source.width
        val height = source.height
        val rowsPerStripe = (IN_PLACE_PIXELS_PER_STRIPE / width).coerceAtLeast(1)
        val requiredPixels = width * min(rowsPerStripe, height)
        val pixels = scratchPixels?.also {
            require(it.size >= requiredPixels) { "Filter scratch buffer is too small" }
        } ?: IntArray(requiredPixels)
        val strength = selection.normalizedIntensityPercent / 100f
        var top = 0
        while (top < height) {
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            val rows = min(rowsPerStripe, height - top)
            val count = width * rows
            source.getPixels(pixels, 0, width, 0, top, width, rows)
            filterPixels(
                pixels = pixels,
                count = count,
                preset = selection.preset,
                strength = strength,
                isCancelled = isCancelled,
            )
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            source.setPixels(pixels, 0, width, 0, top, width, rows)
            top += rows
        }
        return source
    }

    private fun filterPixels(
        pixels: IntArray,
        count: Int,
        preset: PhotoFilterPreset,
        strength: Float,
        isCancelled: () -> Boolean,
    ) {
        if (filterParallelism > 1 && count >= PARALLEL_PIXEL_THRESHOLD) {
            filterPool.invoke(
                FilterPixelsAction(
                    pixels = pixels,
                    start = 0,
                    end = count,
                    preset = preset,
                    strength = strength,
                    isCancelled = isCancelled,
                ),
            )
        } else {
            filterPixelRange(
                pixels = pixels,
                start = 0,
                end = count,
                preset = preset,
                strength = strength,
                isCancelled = isCancelled,
            )
        }
    }

    private class FilterPixelsAction(
        private val pixels: IntArray,
        private val start: Int,
        private val end: Int,
        private val preset: PhotoFilterPreset,
        private val strength: Float,
        private val isCancelled: () -> Boolean,
    ) : RecursiveAction() {
        override fun compute() {
            if (end - start <= PIXELS_PER_TASK) {
                filterPixelRange(pixels, start, end, preset, strength, isCancelled)
                return
            }
            val middle = start + (end - start) / 2
            invokeAll(
                FilterPixelsAction(pixels, start, middle, preset, strength, isCancelled),
                FilterPixelsAction(pixels, middle, end, preset, strength, isCancelled),
            )
        }
    }

    private fun filterPixelRange(
        pixels: IntArray,
        start: Int,
        end: Int,
        preset: PhotoFilterPreset,
        strength: Float,
        isCancelled: () -> Boolean,
    ) {
        var index = start
        var nextCancellationCheck = start
        while (index < end) {
            if (index == nextCancellationCheck) {
                if (isCancelled()) {
                    throw CancellationException("Photo filter render superseded")
                }
                nextCancellationCheck += CANCELLATION_CHECK_INTERVAL
            }
            pixels[index] = filterPixel(pixels[index], preset, strength)
            index++
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
        val colorAdjustmentWeight = neutralProtectionWeight(delta)
        var hue = originalHue

        when (val parameters = preset.parameters) {
            is NcpPhotoFilterParameters -> {
                hue = normalizeHue(
                    originalHue + parameters.hueStep / NCP_MAX_MANUAL_STEP *
                        APPROXIMATE_MAX_HUE_SHIFT_DEGREES * colorAdjustmentWeight,
                )
                saturation *= protectedSaturationScale(
                    parameters.saturationStep / NCP_MAX_MANUAL_STEP,
                    colorAdjustmentWeight,
                )
                lightness = mapPhotoFilterToneCurve(lightness, parameters.normalizedToneCurve)
            }

            is Np3PhotoFilterParameters -> {
                // 色带中心固定且已排序；直接定位区间，避免每个 FHD 像素都遍历八段并做取模。
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
                val left = parameters.colorBands[leftIndex]
                val right = parameters.colorBands[rightIndex]
                val inverseProgress = 1f - progress
                val hueShift = (left.hue * inverseProgress + right.hue * progress) /
                    100f * APPROXIMATE_MAX_HUE_SHIFT_DEGREES
                val chroma = left.chroma * inverseProgress + right.chroma * progress
                val brightness = left.brightness * inverseProgress + right.brightness * progress
                hue = normalizeHue(originalHue + hueShift * colorAdjustmentWeight)
                saturation *= 1f + chroma / 100f * colorAdjustmentWeight
                saturation *= protectedSaturationScale(
                    parameters.saturation / 100f,
                    colorAdjustmentWeight,
                )
                lightness += brightness / 100f * MAX_BAND_LIGHTNESS_SHIFT *
                    colorAdjustmentWeight
                lightness = parameters.normalizedToneCurve?.let { curve ->
                    mapPhotoFilterToneCurve(lightness, curve)
                } ?: applyNp3TonalControls(lightness, parameters)
            }
        }

        val filtered = hslToRgbPacked(
            hue,
            saturation.coerceIn(0f, 1f),
            lightness.coerceIn(0f, 1f),
        )
        return Color.argb(
            alpha,
            mixChannel(originalR, filtered ushr 16 and 0xff, strength),
            mixChannel(originalG, filtered ushr 8 and 0xff, strength),
            mixChannel(originalB, filtered and 0xff, strength),
        )
    }

    private fun applyNp3TonalControls(
        value: Float,
        parameters: Np3PhotoFilterParameters,
    ): Float {
        var lightness = value.coerceIn(0f, 1f)
        val shadowWeight = 1f - smoothStep(0.18f, 0.72f, lightness)
        val highlightWeight = smoothStep(0.28f, 0.82f, lightness)
        lightness += parameters.blacks / 100f * 0.12f * (1f - lightness).pow(3)
        lightness += parameters.shadows / 100f * 0.18f * shadowWeight
        lightness += parameters.highlights / 100f * 0.18f * highlightWeight
        lightness += parameters.whites / 100f * 0.12f * lightness.pow(3)
        val contrastScale = 2f.pow(parameters.contrast / 100f)
        return ((lightness - 0.5f) * contrastScale + 0.5f).coerceIn(0f, 1f)
    }

    private fun smoothStep(edge0: Float, edge1: Float, value: Float): Float {
        val x = ((value - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
        return x * x * (3f - 2f * x)
    }

    internal fun neutralProtectionWeight(rgbChroma: Float): Float = smoothStep(
        NEUTRAL_PROTECTION_CHROMA_START,
        NEUTRAL_PROTECTION_CHROMA_END,
        rgbChroma,
    )

    /** Positive saturation can reveal neutral chroma noise; desaturation cannot amplify it. */
    private fun protectedSaturationScale(adjustment: Float, colorAdjustmentWeight: Float): Float =
        1f + if (adjustment > 0f) adjustment * colorAdjustmentWeight else adjustment

    private fun mixChannel(original: Int, filtered: Int, strength: Float): Int =
        (original + (filtered - original) * strength).roundToInt().coerceIn(0, 255)

    private fun hslToRgbPacked(hue: Float, saturation: Float, lightness: Float): Int {
        val chroma = (1f - abs(2f * lightness - 1f)) * saturation
        // 调用方已经把色相归一化到 [0, 360)，这里避免每个像素再次执行两次浮点取模。
        val section = hue / 60f
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
