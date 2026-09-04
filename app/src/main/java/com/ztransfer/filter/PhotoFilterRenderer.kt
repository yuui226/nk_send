package com.ztransfer.filter

import android.graphics.Bitmap
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
    /** Four-megapixel stripes amortize worker dispatch while remaining bounded for large photos. */
    private const val IN_PLACE_PIXELS_PER_STRIPE = 4 * 1024 * 1024
    private const val CANCELLATION_CHECK_INTERVAL = 4 * 1024
    private const val EXACT_RGB_LUT_SIZE = 1 shl 24
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
    // 滤镜是成片生成的主要瓶颈；共享池最多使用六个线程，并始终给界面保留一个处理器。
    // 多张图并发时仍共用这一个池，不会按图片倍增线程数。
    private val filterParallelism =
        (Runtime.getRuntime().availableProcessors() - 1).coerceIn(1, 6)
    private val filterPool by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        ForkJoinPool(filterParallelism)
    }
    private val exactLutLock = Any()
    @Volatile private var cachedExactLut: ExactRgbLut? = null
    @Volatile private var exactLutDisabledAfterOom = false

    private data class ExactRgbLutKey(
        val preset: PhotoFilterPreset,
        val intensityPercent: Int,
    )

    private data class ExactRgbLut(
        val key: ExactRgbLutKey,
        val colors: IntArray,
    )

    internal class PreparedOriginalFilter internal constructor(
        internal val selection: PhotoFilterSelection,
        internal val exactRgbLut: IntArray?,
        internal val mode: PreparationMode,
    )

    internal enum class PreparationMode { EXACT_CACHE, EXACT_BUILT, DIRECT_FALLBACK }

    /** Constants derived from one selected preset; built once instead of once per pixel. */
    private data class CompiledFilter(
        val preset: PhotoFilterPreset,
        val strength: Float,
        val preserveAlpha: Boolean,
        val ncpHueShiftDegrees: Float = 0f,
        val ncpSaturationAdjustment: Float = 0f,
        val np3SaturationAdjustment: Float = 0f,
        val np3ColorBands: CompiledNp3ColorBands? = null,
        val np3TonalControls: CompiledNp3TonalControls? = null,
    )

    private data class CompiledNp3ColorBands(
        val hue: IntArray,
        val chroma: IntArray,
        val brightness: IntArray,
    )

    private data class CompiledNp3TonalControls(
        val blacksScale: Float,
        val shadowsScale: Float,
        val highlightsScale: Float,
        val whitesScale: Float,
        val contrastScale: Float,
    )

    private fun compileFilter(
        selection: PhotoFilterSelection,
        preserveAlpha: Boolean,
    ): CompiledFilter {
        val preset = selection.preset
        val strength = selection.normalizedIntensityPercent / 100f
        return when (val parameters = preset.parameters) {
            is NcpPhotoFilterParameters -> CompiledFilter(
                preset = preset,
                strength = strength,
                preserveAlpha = preserveAlpha,
                ncpHueShiftDegrees = parameters.hueStep / NCP_MAX_MANUAL_STEP *
                    APPROXIMATE_MAX_HUE_SHIFT_DEGREES,
                ncpSaturationAdjustment = parameters.saturationStep / NCP_MAX_MANUAL_STEP,
            )
            is Np3PhotoFilterParameters -> CompiledFilter(
                preset = preset,
                strength = strength,
                preserveAlpha = preserveAlpha,
                np3SaturationAdjustment = parameters.saturation / 100f,
                np3ColorBands = CompiledNp3ColorBands(
                    hue = IntArray(parameters.colorBands.size) { parameters.colorBands[it].hue },
                    chroma = IntArray(parameters.colorBands.size) {
                        parameters.colorBands[it].chroma
                    },
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
        val compiled = compileFilter(selection, preserveAlpha = source.hasAlpha())
        if (filterParallelism > 1 && pixels.size >= PARALLEL_PIXEL_THRESHOLD) {
            filterPool.invoke(
                FilterPixelsAction(
                    pixels = pixels,
                    start = 0,
                    end = pixels.size,
                    compiled = compiled,
                    isCancelled = isCancelled,
                )
            )
        } else {
            filterPixelRange(
                pixels = pixels,
                start = 0,
                end = pixels.size,
                compiled = compiled,
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
    ): Bitmap = renderInPlace(
        source = source,
        prepared = prepareOriginalFilter(selection, isCancelled),
        isCancelled = isCancelled,
        scratchPixels = scratchPixels,
    )

    internal fun prepareOriginalFilter(
        selection: PhotoFilterSelection,
        isCancelled: () -> Boolean = { false },
    ): PreparedOriginalFilter {
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
        if (exactLutDisabledAfterOom) {
            return PreparedOriginalFilter(
                selection,
                exactRgbLut = null,
                mode = PreparationMode.DIRECT_FALLBACK,
            )
        }
        val key = ExactRgbLutKey(
            preset = selection.preset,
            intensityPercent = selection.normalizedIntensityPercent,
        )
        cachedExactLut?.takeIf { it.key == key }?.let {
            return PreparedOriginalFilter(selection, it.colors, PreparationMode.EXACT_CACHE)
        }
        var mode = PreparationMode.EXACT_CACHE
        val lookup = try {
            synchronized(exactLutLock) {
                if (exactLutDisabledAfterOom) {
                    mode = PreparationMode.DIRECT_FALLBACK
                    null
                } else {
                    cachedExactLut?.takeIf { it.key == key }?.colors ?: run {
                        mode = PreparationMode.EXACT_BUILT
                        // Drop the previous cache before allocating the replacement. Active
                        // renders keep their own reference; an idle old table can be reclaimed.
                        cachedExactLut = null
                        val compiled = compileFilter(selection, preserveAlpha = false)
                        val colors = buildExactRgbLut(compiled, isCancelled)
                        cachedExactLut = ExactRgbLut(key, colors)
                        colors
                    }
                }
            }
        } catch (_: OutOfMemoryError) {
            // Exact lookup is an optimization. Low-memory devices retain the established direct
            // renderer instead of failing the user's export.
            mode = PreparationMode.DIRECT_FALLBACK
            exactLutDisabledAfterOom = true
            null
        }
        return PreparedOriginalFilter(selection, lookup, mode)
    }

    internal fun renderInPlace(
        source: Bitmap,
        prepared: PreparedOriginalFilter,
        isCancelled: () -> Boolean = { false },
        scratchPixels: IntArray? = null,
    ): Bitmap {
        require(source.isMutable) { "Original-quality filter source must be mutable" }
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
        val width = source.width
        val height = source.height
        val preserveAlpha = source.hasAlpha()
        val rowsPerStripe = (IN_PLACE_PIXELS_PER_STRIPE / width).coerceAtLeast(1)
        val requiredPixels = width * min(rowsPerStripe, height)
        val pixels = scratchPixels?.also {
            require(it.size >= requiredPixels) { "Filter scratch buffer is too small" }
        } ?: IntArray(requiredPixels)
        val compiled = if (prepared.exactRgbLut == null) {
            compileFilter(prepared.selection, preserveAlpha = preserveAlpha)
        } else {
            null
        }
        var top = 0
        while (top < height) {
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            val rows = min(rowsPerStripe, height - top)
            val count = width * rows
            source.getPixels(pixels, 0, width, 0, top, width, rows)
            prepared.exactRgbLut?.let { lookup ->
                applyExactRgbLut(
                    pixels = pixels,
                    count = count,
                    lookup = lookup,
                    preserveAlpha = preserveAlpha,
                    isCancelled = isCancelled,
                )
            } ?: filterPixels(
                pixels = pixels,
                count = count,
                compiled = checkNotNull(compiled),
                isCancelled = isCancelled,
            )
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            source.setPixels(pixels, 0, width, 0, top, width, rows)
            top += rows
        }
        return source
    }

    private fun buildExactRgbLut(
        compiled: CompiledFilter,
        isCancelled: () -> Boolean,
    ): IntArray {
        val colors = IntArray(EXACT_RGB_LUT_SIZE)
        if (filterParallelism > 1) {
            filterPool.invoke(
                BuildExactRgbLutAction(
                    output = colors,
                    start = 0,
                    end = colors.size,
                    compiled = compiled,
                    isCancelled = isCancelled,
                ),
            )
        } else {
            buildExactRgbLutRange(colors, 0, colors.size, compiled, isCancelled)
        }
        return colors
    }

    private class BuildExactRgbLutAction(
        private val output: IntArray,
        private val start: Int,
        private val end: Int,
        private val compiled: CompiledFilter,
        private val isCancelled: () -> Boolean,
    ) : RecursiveAction() {
        override fun compute() {
            if (end - start <= PIXELS_PER_TASK) {
                buildExactRgbLutRange(output, start, end, compiled, isCancelled)
                return
            }
            val middle = start + (end - start) / 2
            invokeAll(
                BuildExactRgbLutAction(output, start, middle, compiled, isCancelled),
                BuildExactRgbLutAction(output, middle, end, compiled, isCancelled),
            )
        }
    }

    private fun buildExactRgbLutRange(
        output: IntArray,
        start: Int,
        end: Int,
        compiled: CompiledFilter,
        isCancelled: () -> Boolean,
    ) {
        var rgb = start
        var nextCancellationCheck = start
        while (rgb < end) {
            if (rgb == nextCancellationCheck) {
                if (isCancelled()) throw CancellationException("Photo filter render superseded")
                nextCancellationCheck += CANCELLATION_CHECK_INTERVAL
            }
            output[rgb] = filterPixel(0xff000000.toInt() or rgb, compiled) and 0x00ffffff
            rgb++
        }
    }

    private fun applyExactRgbLut(
        pixels: IntArray,
        count: Int,
        lookup: IntArray,
        preserveAlpha: Boolean,
        isCancelled: () -> Boolean,
    ) {
        if (filterParallelism > 1 && count >= PARALLEL_PIXEL_THRESHOLD) {
            filterPool.invoke(
                ApplyExactRgbLutAction(
                    pixels,
                    0,
                    count,
                    lookup,
                    preserveAlpha,
                    isCancelled,
                ),
            )
        } else {
            applyExactRgbLutRange(
                pixels,
                0,
                count,
                lookup,
                preserveAlpha,
                isCancelled,
            )
        }
    }

    private class ApplyExactRgbLutAction(
        private val pixels: IntArray,
        private val start: Int,
        private val end: Int,
        private val lookup: IntArray,
        private val preserveAlpha: Boolean,
        private val isCancelled: () -> Boolean,
    ) : RecursiveAction() {
        override fun compute() {
            if (end - start <= PIXELS_PER_TASK) {
                applyExactRgbLutRange(
                    pixels,
                    start,
                    end,
                    lookup,
                    preserveAlpha,
                    isCancelled,
                )
                return
            }
            val middle = start + (end - start) / 2
            invokeAll(
                ApplyExactRgbLutAction(
                    pixels, start, middle, lookup, preserveAlpha, isCancelled,
                ),
                ApplyExactRgbLutAction(
                    pixels, middle, end, lookup, preserveAlpha, isCancelled,
                ),
            )
        }
    }

    private fun applyExactRgbLutRange(
        pixels: IntArray,
        start: Int,
        end: Int,
        lookup: IntArray,
        preserveAlpha: Boolean,
        isCancelled: () -> Boolean,
    ) {
        var index = start
        var nextCancellationCheck = start
        while (index < end) {
            if (index == nextCancellationCheck) {
                if (isCancelled()) throw CancellationException("Photo filter render superseded")
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

    @Suppress("NOTHING_TO_INLINE")
    internal inline fun exactLookupOutputColor(
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

    private fun filterPixels(
        pixels: IntArray,
        count: Int,
        compiled: CompiledFilter,
        isCancelled: () -> Boolean,
    ) {
        if (filterParallelism > 1 && count >= PARALLEL_PIXEL_THRESHOLD) {
            filterPool.invoke(
                FilterPixelsAction(
                    pixels = pixels,
                    start = 0,
                    end = count,
                    compiled = compiled,
                    isCancelled = isCancelled,
                ),
            )
        } else {
            filterPixelRange(
                pixels = pixels,
                start = 0,
                end = count,
                compiled = compiled,
                isCancelled = isCancelled,
            )
        }
    }

    /** Bitmap-independent pixel path used to freeze renderer output before moving it to shared. */
    internal fun renderArgbPixels(
        source: IntArray,
        selection: PhotoFilterSelection,
        preserveAlpha: Boolean,
    ): IntArray = source.copyOf().also { output ->
        filterPixelRange(
            pixels = output,
            start = 0,
            end = output.size,
            compiled = compileFilter(selection, preserveAlpha),
            isCancelled = { false },
        )
    }

    private class FilterPixelsAction(
        private val pixels: IntArray,
        private val start: Int,
        private val end: Int,
        private val compiled: CompiledFilter,
        private val isCancelled: () -> Boolean,
    ) : RecursiveAction() {
        override fun compute() {
            if (end - start <= PIXELS_PER_TASK) {
                filterPixelRange(pixels, start, end, compiled, isCancelled)
                return
            }
            val middle = start + (end - start) / 2
            invokeAll(
                FilterPixelsAction(pixels, start, middle, compiled, isCancelled),
                FilterPixelsAction(pixels, middle, end, compiled, isCancelled),
            )
        }
    }

    private fun filterPixelRange(
        pixels: IntArray,
        start: Int,
        end: Int,
        compiled: CompiledFilter,
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
            pixels[index] = filterPixel(pixels[index], compiled)
            index++
        }
    }

    private fun filterPixel(color: Int, compiled: CompiledFilter): Int {
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
                normalizeHue(
                when (maxValue) {
                    // (green-blue)/delta is guaranteed in [-1, 1], so % 6 is a no-op.
                    red -> 60f * ((green - blue) / delta)
                    green -> 60f * ((blue - red) / delta + 2f)
                    else -> 60f * ((red - green) / delta + 4f)
                },
            )
        }
        val colorAdjustmentWeight = neutralProtectionWeight(delta)
        var hue = originalHue

        when (val parameters = compiled.preset.parameters) {
            is NcpPhotoFilterParameters -> {
                if (compiled.ncpHueShiftDegrees != 0f) {
                    hue = normalizeHue(
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
                val bands = checkNotNull(compiled.np3ColorBands)
                val inverseProgress = 1f - progress
                val hueShift = (bands.hue[leftIndex] * inverseProgress +
                    bands.hue[rightIndex] * progress) /
                    100f * APPROXIMATE_MAX_HUE_SHIFT_DEGREES
                val chroma = bands.chroma[leftIndex] * inverseProgress +
                    bands.chroma[rightIndex] * progress
                val brightness = bands.brightness[leftIndex] * inverseProgress +
                    bands.brightness[rightIndex] * progress
                hue = normalizeHue(originalHue + hueShift * colorAdjustmentWeight)
                saturation *= 1f + chroma / 100f * colorAdjustmentWeight
                if (compiled.np3SaturationAdjustment != 0f) {
                    saturation *= protectedSaturationScale(
                        compiled.np3SaturationAdjustment,
                        colorAdjustmentWeight,
                    )
                }
                lightness += brightness / 100f * MAX_BAND_LIGHTNESS_SHIFT *
                    colorAdjustmentWeight
                lightness = parameters.normalizedToneCurve?.let { curve ->
                    mapPhotoFilterToneCurve(lightness, curve)
                } ?: applyNp3TonalControls(
                    lightness,
                    checkNotNull(compiled.np3TonalControls),
                )
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

    private fun applyNp3TonalControls(
        value: Float,
        controls: CompiledNp3TonalControls,
    ): Float {
        var lightness = value.coerceIn(0f, 1f)
        // Both weights intentionally use the same pre-adjustment lightness as the original formula.
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
        if (controls.shadowsScale != 0f) {
            lightness += controls.shadowsScale * shadowWeight
        }
        if (controls.highlightsScale != 0f) {
            lightness += controls.highlightsScale * highlightWeight
        }
        if (controls.whitesScale != 0f) {
            lightness += controls.whitesScale * lightness * lightness * lightness
        }
        return ((lightness - 0.5f) * controls.contrastScale + 0.5f).coerceIn(0f, 1f)
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
        // hue 已在 [0, 360)。利用扇区奇偶计算第二分量，避免逐像素浮点取模。
        val section = hue / 60f
        val sector = section.toInt()
        val x = hslSecondaryComponent(section, sector, chroma)
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

    /**
     * 本渲染器传入值严格位于 [-60, 390)：原始 HSL 最低 -60°，滤镜最多偏移 30°。
     * 单次加减即可归一化，避免每个像素执行两次昂贵的浮点取模。
     */
    internal fun normalizeHue(value: Float): Float = when {
        value < 0f -> value + 360f
        value >= 360f -> value - 360f
        else -> value
    }

    internal fun hslSecondaryComponent(section: Float, sector: Int, chroma: Float): Float {
        val fraction = section - sector
        return chroma * if (sector and 1 == 0) fraction else 1f - fraction
    }
}
