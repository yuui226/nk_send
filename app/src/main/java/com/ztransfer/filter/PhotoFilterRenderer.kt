package com.ztransfer.filter

import android.graphics.Bitmap
import kotlin.math.min
import kotlinx.coroutines.CancellationException
import java.util.concurrent.ForkJoinPool
import java.util.concurrent.RecursiveAction

/** Applies the supported NCP/NP3 controls to an already developed sRGB image. */
object PhotoFilterRenderer {
    private const val PARALLEL_PIXEL_THRESHOLD = 512 * 512
    private const val PIXELS_PER_TASK = 64 * 1024
    /** Four-megapixel stripes amortize worker dispatch while remaining bounded for large photos. */
    private const val IN_PLACE_PIXELS_PER_STRIPE = 4 * 1024 * 1024
    private const val EXACT_RGB_LUT_SIZE = 1 shl 24
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
        val compiled = compilePhotoFilter(selection, preserveAlpha = source.hasAlpha())
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
                        val compiled = compilePhotoFilter(selection, preserveAlpha = false)
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
            compilePhotoFilter(prepared.selection, preserveAlpha = preserveAlpha)
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
        compiled: CompiledPhotoFilter,
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
        private val compiled: CompiledPhotoFilter,
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
        compiled: CompiledPhotoFilter,
        isCancelled: () -> Boolean,
    ) = buildPhotoFilterRgbLutRange(output, start, end, compiled) {
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
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
    ) = applyPhotoFilterExactRgbLutRange(
        pixels,
        start,
        end,
        lookup,
        preserveAlpha,
    ) {
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
    }

    private fun filterPixels(
        pixels: IntArray,
        count: Int,
        compiled: CompiledPhotoFilter,
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

    private class FilterPixelsAction(
        private val pixels: IntArray,
        private val start: Int,
        private val end: Int,
        private val compiled: CompiledPhotoFilter,
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
        compiled: CompiledPhotoFilter,
        isCancelled: () -> Boolean,
    ) = renderPhotoFilterArgbRange(pixels, start, end, compiled) {
        if (isCancelled()) throw CancellationException("Photo filter render superseded")
    }

}
