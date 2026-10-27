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
    /** Four-megapixel stripes amortize bitmap access while remaining bounded for large photos. */
    private const val IN_PLACE_PIXELS_PER_STRIPE = 4 * 1024 * 1024

    /** A short image/region only needs its actual pixels, not an entire four-megapixel stripe. */
    internal fun scratchPixelCount(width: Int, height: Int): Int {
        require(width > 0 && height > 0)
        return width * min((IN_PLACE_PIXELS_PER_STRIPE / width).coerceAtLeast(1), height)
    }
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
    // 此池仅供预览使用；原图导出与其准备工作在调用方后台线程顺序计算。
    // 预览最多两个计算线程，保持交互响应，同时避免和下载、导出一起占满 CPU。
    private val filterParallelism =
        (Runtime.getRuntime().availableProcessors() - 1).coerceIn(1, 2)
    private val filterPool by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        ForkJoinPool(filterParallelism)
    }
    private val exactMemoLock = Any()
    @Volatile private var cachedExactMemo: ExactRgbMemoCache? = null
    @Volatile private var exactMemoDisabledAfterOom = false

    private data class ExactRgbMemoKey(
        val preset: PhotoFilterPreset,
        val intensityPercent: Int,
    )

    private data class ExactRgbMemoCache(
        val key: ExactRgbMemoKey,
        val colors: ExactRgbMemo,
    )

    internal class PreparedOriginalFilter internal constructor(
        internal val selection: PhotoFilterSelection,
        internal val exactRgbMemo: ExactRgbMemo?,
        internal val mode: PreparationMode,
        internal val cubeMapper: PhotoCubeMapper? = null,
        internal val cubeExecution: PhotoLutExecution = PhotoLutExecution.KOTLIN,
    )

    internal enum class PreparationMode { EXACT_CACHE, EXACT_ALLOCATED, DIRECT_FALLBACK }

    /** Constants derived from one selected preset; built once instead of once per pixel. */
    private data class CompiledFilter(
        val preset: PhotoFilterPreset,
        val strength: Float,
        val preserveAlpha: Boolean,
        val lutAdjustments: LutAdjustments = LutAdjustments(),
        val cubeMapper: PhotoCubeMapper? = null,
        val ncpHueShiftDegrees: Float = 0f,
        val ncpSaturationAdjustment: Float = 0f,
        val np3SaturationAdjustment: Float = 0f,
        val np3ColorBands: CompiledNp3ColorBands? = null,
        val np3TonalControls: CompiledNp3TonalControls? = null,
        val classicControls: CompiledClassicControls? = null,
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

    private data class CompiledClassicControls(
        val hueShift: Float,
        val saturationAdjustment: Float,
        val contrastScale: Float,
        val brightness: Float,
        val blackLift: Float,
        val monochromeAmount: Float,
        val redWeight: Float,
        val greenWeight: Float,
        val blueWeight: Float,
        val toningHue: Float,
        val toningSaturation: Float,
        val binaryAmount: Float,
        val toneCurve: FloatArray?,
    )

    private data class ClassicBaseLook(
        val contrast: Float = 1f,
        val saturation: Float = 1f,
        val brightness: Float = 0f,
        val hue: Float = 0f,
        val blackLift: Float = 0f,
        val toningHue: Float? = null,
        val binaryAmount: Float = 0f,
    )

    /**
     * NP3 names a Nikon base look but does not contain its RAW development tables. These modest
     * sRGB mappings deliberately remain separate from the existing Flexible Color conversions.
     * All per-recipe coefficients are compiled once; the pixel path allocates no objects.
     */
    private fun compileClassic(parameters: ClassicNp3PhotoFilterParameters): CompiledClassicControls {
        val look = when (parameters.base) {
            ClassicNp3Style.STANDARD, ClassicNp3Style.AUTO -> ClassicBaseLook()
            ClassicNp3Style.NEUTRAL -> ClassicBaseLook(0.95f, 0.94f)
            ClassicNp3Style.VIVID -> ClassicBaseLook(1.08f, 1.12f)
            ClassicNp3Style.PORTRAIT -> ClassicBaseLook(1f, 0.96f, 0.012f, 1f)
            ClassicNp3Style.LANDSCAPE -> ClassicBaseLook(1.05f, 1.10f, hue = -1.5f)
            ClassicNp3Style.FLAT -> ClassicBaseLook(0.86f, 0.92f, blackLift = 0.012f)
            ClassicNp3Style.MONOCHROME -> ClassicBaseLook()
            ClassicNp3Style.FLAT_MONOCHROME -> ClassicBaseLook(contrast = 0.85f)
            ClassicNp3Style.DEEP_TONE_MONOCHROME -> ClassicBaseLook(contrast = 1.18f)
            ClassicNp3Style.RICH_TONE_PORTRAIT -> ClassicBaseLook(1.04f, 1.04f, 0.005f)
            ClassicNp3Style.DREAM -> ClassicBaseLook(0.88f, 0.82f, 0.035f, blackLift = 0.025f)
            ClassicNp3Style.MORNING -> ClassicBaseLook(0.94f, 0.90f, 0.025f, 4f)
            ClassicNp3Style.POP -> ClassicBaseLook(1.12f, 1.20f)
            ClassicNp3Style.SUNDAY -> ClassicBaseLook(0.98f, 1.07f, 0.020f, 2f)
            ClassicNp3Style.SOMBER -> ClassicBaseLook(1.08f, 0.78f, -0.040f, -2f)
            ClassicNp3Style.DRAMATIC -> ClassicBaseLook(1.25f, 0.82f, -0.010f)
            ClassicNp3Style.SILENCE -> ClassicBaseLook(0.93f, 0.72f, hue = -3f, blackLift = 0.020f)
            ClassicNp3Style.BLEACHED -> ClassicBaseLook(0.83f, 0.60f, 0.035f, blackLift = 0.040f)
            ClassicNp3Style.MELANCHOLIC -> ClassicBaseLook(0.96f, 0.78f, -0.015f, -7f)
            ClassicNp3Style.PURE -> ClassicBaseLook(0.92f, 0.94f, 0.040f)
            ClassicNp3Style.DENIM -> ClassicBaseLook(1.04f, 0.80f, -0.010f, -10f, 0.015f)
            ClassicNp3Style.TOY -> ClassicBaseLook(1.18f, 1.18f, -0.020f, 3f)
            ClassicNp3Style.SEPIA -> ClassicBaseLook(contrast = 1.02f, toningHue = 35f)
            ClassicNp3Style.BLUE -> ClassicBaseLook(contrast = 1.04f, toningHue = 220f)
            ClassicNp3Style.RED -> ClassicBaseLook(contrast = 1.05f, toningHue = 0f)
            ClassicNp3Style.PINK -> ClassicBaseLook(contrast = 0.94f, brightness = 0.025f, toningHue = 330f)
            ClassicNp3Style.CHARCOAL -> ClassicBaseLook(contrast = 1.30f)
            ClassicNp3Style.GRAPHITE -> ClassicBaseLook(contrast = 1.15f, blackLift = 0.025f)
            ClassicNp3Style.BINARY -> ClassicBaseLook(binaryAmount = 0.85f)
            ClassicNp3Style.CARBON -> ClassicBaseLook(contrast = 1.40f, blackLift = -0.020f)
        }
        val baseStrength = if (parameters.base.creative) parameters.effectLevel / 100f else 1f
        val manualContrast = if (parameters.contrastQuarter == CLASSIC_PHOTO_FILTER_AUTO) 0f
            else parameters.contrastQuarter / 12f
        val manualSaturation = if (parameters.saturationQuarter == CLASSIC_PHOTO_FILTER_AUTO) 0f
            else parameters.saturationQuarter / 12f
        // Yellow / orange / red / green filters weight channels before monochrome conversion.
        // Each row sums to one, preserving neutral luminance and avoiding clipped white shifts.
        val weights = when (parameters.filterEffect) {
            1 -> floatArrayOf(0.30f, 0.65f, 0.05f)
            2 -> floatArrayOf(0.45f, 0.52f, 0.03f)
            3 -> floatArrayOf(0.70f, 0.28f, 0.02f)
            4 -> floatArrayOf(0.15f, 0.80f, 0.05f)
            else -> floatArrayOf(0.2126f, 0.7152f, 0.0722f)
        }
        val tone = when (parameters.toningEffect) {
            1 -> 35f // Sepia
            2 -> 205f // Cyanotype
            3 -> 0f
            4 -> 55f
            5 -> 120f
            6 -> 170f
            7 -> 230f
            8 -> 275f
            9 -> 325f
            else -> look.toningHue
        }
        return CompiledClassicControls(
            hueShift = look.hue * baseStrength +
                parameters.hueQuarter / 12f * APPROXIMATE_MAX_HUE_SHIFT_DEGREES,
            saturationAdjustment = (1f + (look.saturation - 1f) * baseStrength) *
                (1f + manualSaturation) - 1f,
            contrastScale = (1f + (look.contrast - 1f) * baseStrength) *
                if (parameters.toneCurve == null) 2f.pow(manualContrast) else 1f,
            brightness = look.brightness * baseStrength +
                if (parameters.toneCurve == null) parameters.brightnessQuarter / 6f * 0.12f else 0f,
            blackLift = look.blackLift * baseStrength,
            monochromeAmount = if (parameters.base.monochrome) baseStrength else 0f,
            redWeight = weights[0], greenWeight = weights[1], blueWeight = weights[2],
            toningHue = tone ?: 0f,
            // Creative fixed-color bases have no selectable toning enum; density still applies.
            toningSaturation = if (tone == null) 0f else parameters.toningDensityQuarter / 28f * 0.42f,
            binaryAmount = look.binaryAmount * baseStrength,
            toneCurve = parameters.normalizedToneCurve,
        )
    }

    private fun compileFilter(
        selection: PhotoFilterSelection,
        preserveAlpha: Boolean,
    ): CompiledFilter {
        val preset = selection.preset
        val strength = selection.normalizedIntensityPercent / 100f
        return when (val parameters = preset.parameters) {
            is ClassicNp3PhotoFilterParameters -> CompiledFilter(
                preset, strength, preserveAlpha, classicControls = compileClassic(parameters),
            )
            is CubePhotoFilterParameters -> CompiledFilter(
                preset, strength, preserveAlpha,
                lutAdjustments = selection.lutAdjustments.normalized(),
                cubeMapper = parameters.mapper,
            )
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
     * inside that stripe stays on the caller's background export worker. This is the original-resolution export path.
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
        // A cube already is a compact lookup; it does not need the exact-color memo.
        if (selection.preset.parameters is CubePhotoFilterParameters) {
            synchronized(exactMemoLock) { cachedExactMemo = null }
            // Pin only for this render: later regions must not reload an evicted/oversized LUT.
            val mapper = selection.preset.parameters.mapper
            val execution = mapper.prepareBulk()
            return PreparedOriginalFilter(selection, null, PreparationMode.DIRECT_FALLBACK,
                cubeMapper = mapper, cubeExecution = execution)
        }
        if (exactMemoDisabledAfterOom) {
            return PreparedOriginalFilter(
                selection,
                exactRgbMemo = null,
                mode = PreparationMode.DIRECT_FALLBACK,
            )
        }
        val key = ExactRgbMemoKey(
            preset = selection.preset,
            intensityPercent = selection.normalizedIntensityPercent,
        )
        cachedExactMemo?.takeIf { it.key == key }?.let {
            return PreparedOriginalFilter(selection, it.colors, PreparationMode.EXACT_CACHE)
        }
        var mode = PreparationMode.EXACT_CACHE
        val lookup = try {
            synchronized(exactMemoLock) {
                if (exactMemoDisabledAfterOom) {
                    mode = PreparationMode.DIRECT_FALLBACK
                    null
                } else {
                    cachedExactMemo?.takeIf { it.key == key }?.colors ?: run {
                        mode = PreparationMode.EXACT_ALLOCATED
                        // Drop the previous cache before allocating the replacement. Active
                        // renders keep their own reference; an idle old table can be reclaimed.
                        cachedExactMemo = null
                        val colors = ExactRgbMemo()
                        cachedExactMemo = ExactRgbMemoCache(key, colors)
                        colors
                    }
                }
            }
        } catch (_: OutOfMemoryError) {
            // Exact lookup is an optimization. Low-memory devices retain the established direct
            // renderer instead of failing the user's export.
            mode = PreparationMode.DIRECT_FALLBACK
            exactMemoDisabledAfterOom = true
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
        val requiredPixels = scratchPixelCount(width, height)
        val pixels = scratchPixels?.also {
            require(it.size >= requiredPixels) { "Filter scratch buffer is too small" }
        } ?: IntArray(requiredPixels)
        val compiled = prepared.cubeMapper?.let { mapper ->
            CompiledFilter(prepared.selection.preset,
                prepared.selection.normalizedIntensityPercent / 100f, preserveAlpha,
                lutAdjustments = prepared.selection.lutAdjustments.normalized(), cubeMapper = mapper)
        } ?: compileFilter(prepared.selection,
            preserveAlpha = if (prepared.exactRgbMemo == null) preserveAlpha else false)
        var top = 0
        while (top < height) {
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            val rows = min(rowsPerStripe, height - top)
            val count = width * rows
            source.getPixels(pixels, 0, width, 0, top, width, rows)
            prepared.exactRgbMemo?.let { lookup ->
                applyExactRgbMemoRange(
                    pixels = pixels,
                    start = 0,
                    end = count,
                    lookup = lookup,
                    compiled = compiled,
                    preserveAlpha = preserveAlpha,
                    isCancelled = isCancelled,
                )
            } ?: run {
                if (compiled.cubeMapper != null && prepared.cubeExecution != PhotoLutExecution.KOTLIN) {
                    compiled.cubeMapper.mapRange(pixels, 0, count, compiled.strength,
                        preserveAlpha, prepared.cubeExecution, isCancelled)
                    applyLutAdjustmentsRange(pixels, 0, count, compiled, isCancelled)
                } else {
                    // Keep the actual original loop for the baseline and native-unavailable fallback.
                    filterPixelRange(pixels, 0, count, compiled, isCancelled)
                }
            }
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            source.setPixels(pixels, 0, width, 0, top, width, rows)
            top += rows
        }
        return source
    }

    private fun applyExactRgbMemoRange(
        pixels: IntArray,
        start: Int,
        end: Int,
        lookup: ExactRgbMemo,
        compiled: CompiledFilter,
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
            val rgb = color and 0x00ffffff
            var mapped = lookup.get(rgb)
            if (mapped < 0) {
                mapped = filterPixel(0xff000000.toInt() or rgb, compiled) and 0x00ffffff
                lookup.put(rgb, mapped)
            }
            pixels[index] = exactLookupOutputColor(
                originalColor = color,
                mappedRgb = mapped,
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
        compiled.cubeMapper?.let {
            return LutColorPipeline.apply(
                it.map(color, compiled.strength, compiled.preserveAlpha),
                compiled.lutAdjustments,
                compiled.preserveAlpha,
            )
        }
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
            is ClassicNp3PhotoFilterParameters -> {
                val controls = checkNotNull(compiled.classicControls)
                hue = normalizeHue(originalHue + controls.hueShift * colorAdjustmentWeight)
                saturation *= protectedSaturationScale(controls.saturationAdjustment, colorAdjustmentWeight)
                if (controls.monochromeAmount > 0f) {
                    val monochrome = red * controls.redWeight + green * controls.greenWeight +
                        blue * controls.blueWeight
                    lightness += (monochrome - lightness) * controls.monochromeAmount
                    saturation += (controls.toningSaturation - saturation) * controls.monochromeAmount
                    if (controls.toningSaturation > 0f) {
                        var hueDistance = controls.toningHue - hue
                        if (hueDistance > 180f) hueDistance -= 360f
                        if (hueDistance < -180f) hueDistance += 360f
                        hue = normalizeHue(hue + hueDistance * controls.monochromeAmount)
                    }
                }
                lightness = ((lightness - 0.5f) * controls.contrastScale + 0.5f).coerceIn(0f, 1f)
                lightness += controls.brightness * 4f * lightness * (1f - lightness)
                lightness = (controls.blackLift + lightness * (1f - controls.blackLift)).coerceIn(0f, 1f)
                if (controls.binaryAmount > 0f) {
                    lightness += (smoothStep(0.42f, 0.58f, lightness) - lightness) * controls.binaryAmount
                }
                controls.toneCurve?.let { lightness = mapPhotoFilterToneCurve(lightness, it) }
            }
            is CubePhotoFilterParameters -> error("Cube handled before HSL conversion")
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

    private fun applyLutAdjustmentsRange(
        pixels: IntArray,
        start: Int,
        end: Int,
        compiled: CompiledFilter,
        isCancelled: () -> Boolean,
    ) {
        if (compiled.lutAdjustments.isNeutral) return
        var index = start
        var nextCancellationCheck = start
        while (index < end) {
            if (index == nextCancellationCheck) {
                if (isCancelled()) throw CancellationException("Photo filter render superseded")
                nextCancellationCheck += CANCELLATION_CHECK_INTERVAL
            }
            pixels[index] = LutColorPipeline.apply(
                pixels[index], compiled.lutAdjustments, compiled.preserveAlpha)
            index++
        }
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
     * 原始 HSL、颜色偏移和最短路径调色的输入均只会跨过一次 0° 或 360°。
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
