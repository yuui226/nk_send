package com.ztransfer.filter

import androidx.annotation.Keep
import java.nio.ByteBuffer

/** Synchronous bulk work on the caller's thread. No native handles, threads or pinned Java arrays. */
@Keep
internal object NativePhotoLut {
    const val BATCH_PIXELS = 16 * 1024
    const val AXIS_BYTES = 6 * 256 * 4 * 2
    val available: Boolean by lazy {
        try { System.loadLibrary("ztransfer_crop"); true }
        catch (_: UnsatisfiedLinkError) { false }
        catch (_: SecurityException) { false }
    }

    external fun mapBatch(table: ByteBuffer, pixels: IntArray, start: Int, count: Int,
        strength: Float, preserveAlpha: Boolean)
}
