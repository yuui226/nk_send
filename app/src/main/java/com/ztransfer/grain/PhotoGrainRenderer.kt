package com.ztransfer.grain

import android.graphics.Bitmap
import kotlinx.coroutines.CancellationException
import kotlin.math.min

/** Grain modifies photo pixels before frames/watermarks, never the decorated output canvas. */
object PhotoGrainRenderer {
    const val DEFAULT_SEED: Int = 0x5a544752
    private const val STRIPE_PIXELS = 512 * 1024

    internal fun scratchPixelCount(width: Int, height: Int): Int {
        require(width > 0 && height > 0)
        return width * min((STRIPE_PIXELS / width).coerceAtLeast(1), height)
    }

    /** OFF returns source unchanged. Enabled renders own a new mutable bitmap. */
    fun render(
        source: Bitmap,
        settings: PhotoGrainSettings,
        seed: Int = DEFAULT_SEED,
        isCancelled: () -> Boolean = { false },
    ): Bitmap {
        if (!settings.isEnabled) return source
        checkCancellation(isCancelled)
        NativePhotoGrain.requireAvailable()
        val output = source.copy(Bitmap.Config.ARGB_8888, true)
            ?: error("Cannot allocate grain preview")
        try {
            output.density = source.density
            output.setHasAlpha(source.hasAlpha())
            return renderInPlace(output, settings, seed, isCancelled = isCancelled)
        } catch (error: Throwable) {
            output.recycle()
            throw error
        }
    }

    /**
     * Full dimensions/origin describe the raw source photograph, not the current stripe.
     * EXIF 1..8 maps that space into the same upright coordinate system used by previews.
     * Already oriented images use orientation=1. A fixed photograph/seed is independent of
     * stripe sizes, scheduling and export retries. OFF does not allocate or access native code.
     */
    fun renderInPlace(
        source: Bitmap,
        settings: PhotoGrainSettings,
        seed: Int = DEFAULT_SEED,
        fullWidth: Int = source.width,
        fullHeight: Int = source.height,
        originX: Int = 0,
        originY: Int = 0,
        orientation: Int = 1,
        isCancelled: () -> Boolean = { false },
        scratchPixels: IntArray? = null,
    ): Bitmap {
        if (!settings.isEnabled) return source
        require(source.isMutable && source.config == Bitmap.Config.ARGB_8888) {
            "Grain requires a mutable ARGB_8888 bitmap"
        }
        require(fullWidth > 0 && fullHeight > 0 && originX >= 0 && originY >= 0)
        require(source.width <= fullWidth - originX && source.height <= fullHeight - originY)
        require(orientation in 1..8)
        checkCancellation(isCancelled)
        NativePhotoGrain.requireAvailable()
        val width = source.width
        val height = source.height
        val pixels = scratchPixels?.takeIf { it.size >= width }
            ?: IntArray(scratchPixelCount(width, height))
        // Even a reused larger buffer does not make cancellation wait on a full photograph.
        val rowsPerStripe = min(pixels.size / width, (STRIPE_PIXELS / width).coerceAtLeast(1))
        val intensity = settings.normalized().intensityPercent
        var top = 0
        while (top < height) {
            checkCancellation(isCancelled)
            val rows = min(rowsPerStripe, height - top)
            val count = width * rows
            source.getPixels(pixels, 0, width, 0, top, width, rows)
            var offset = 0
            while (offset < count) {
                checkCancellation(isCancelled)
                val batch = min(NativePhotoGrain.BATCH_PIXELS, count - offset)
                NativePhotoGrain.applyBatch(
                    pixels, offset, batch, width, offset,
                    fullWidth, fullHeight, originX, originY + top, orientation,
                    intensity, seed, settings.style.nativeId,
                )
                offset += batch
            }
            checkCancellation(isCancelled)
            source.setPixels(pixels, 0, width, 0, top, width, rows)
            top += rows
        }
        return source
    }

    private fun checkCancellation(isCancelled: () -> Boolean) {
        if (isCancelled()) throw CancellationException("Photo grain render superseded")
    }
}
