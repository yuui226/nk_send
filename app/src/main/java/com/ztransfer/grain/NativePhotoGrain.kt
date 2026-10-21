package com.ztransfer.grain

import androidx.annotation.Keep

/** Bounded synchronous JNI calls; no native handles, worker threads or pinned Java arrays. */
@Keep
internal object NativePhotoGrain {
    const val BATCH_PIXELS = 16 * 1024
    private val loadFailure: Throwable? by lazy {
        try {
            System.loadLibrary("ztransfer_crop")
            null
        } catch (error: UnsatisfiedLinkError) {
            error
        } catch (error: SecurityException) {
            error
        }
    }

    fun requireAvailable() {
        loadFailure?.let { throw IllegalStateException("Photo grain renderer unavailable", it) }
    }

    external fun applyBatch(
        pixels: IntArray, start: Int, count: Int, tileWidth: Int, pixelOffset: Int,
        fullWidth: Int, fullHeight: Int, originX: Int, originY: Int, orientation: Int,
        intensityPercent: Int, seed: Int, style: Int,
    )
}
