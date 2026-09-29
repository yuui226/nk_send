package com.ztransfer.filter

import com.ztransfer.lut.CubeLut
import kotlin.math.roundToInt
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CancellationException

/** Queued recipes reload immutable private snapshots through a bounded shared resource cache. */
internal class CubePhotoFilterParameters private constructor(
    private val acquire: () -> PhotoCubeResourceCache.Loaded,
) : PhotoFilterParameters {
    val table: CubeLut get() = acquire().table
    val mapper: PhotoCubeMapper get() = acquire().mapper

    constructor(table: CubeLut) : this(PhotoCubeResourceCache.Loaded(table))
    private constructor(loaded: PhotoCubeResourceCache.Loaded) : this({ loaded })

    companion object {
        private val resources = PhotoCubeResourceCache()
        fun fromSnapshot(key: String, cache: PhotoCubeResourceCache = resources, read: () -> CubeLut) =
            CubePhotoFilterParameters { cache.acquire(key, read) }
        fun seedSnapshot(key: String, table: CubeLut) = resources.seed(key, table)
    }
}

/** Full float table, trilinear interpolation, one final 8-bit quantization; no HSL conversion. */
internal class PhotoCubeMapper(private val table: CubeLut) {
    private class Axis(table: CubeLut, channel: Int, stride: Int) {
        val low = IntArray(256)
        val high = IntArray(256)
        val fraction = FloatArray(256)
        init {
            val range = table.domainMax[channel] - table.domainMin[channel]
            for (value in 0..255) {
                val coordinate = ((value / 255f - table.domainMin[channel]) / range)
                    .coerceIn(0f, 1f) * (table.size - 1)
                val cell = coordinate.toInt()
                low[value] = cell * stride
                high[value] = minOf(cell + 1, table.size - 1) * stride
                fraction[value] = coordinate - cell
            }
        }
    }
    private val red = Axis(table, 0, 3)
    private val green = Axis(table, 1, table.size * 3)
    private val blue = Axis(table, 2, table.size * table.size * 3)

    // Only active renderers allocate the direct copy. The shared resource cache reserves its
    // size in advance, so enabling this path cannot silently double that cache's budget.
    internal val gridSize: Int get() = table.size
    internal val budgetBytes: Int get() = table.rgb.size * 8 + 3 * 256 * 12 + NativePhotoLut.AXIS_BYTES
    private val nativeTable: ByteBuffer? by lazy {
        if (!NativePhotoLut.available) null else try {
            ByteBuffer.allocateDirect(NativePhotoLut.AXIS_BYTES + table.rgb.size * 4)
                .order(ByteOrder.nativeOrder()).apply {
                    for (axis in listOf(red, green, blue)) {
                        axis.low.forEach { putInt(it) }
                        axis.high.forEach { putInt(it) }
                    }
                    for (axis in listOf(red, green, blue)) {
                        axis.fraction.forEach { putFloat(it) }
                        axis.fraction.forEach { putFloat(1f - it) }
                    }
                    asFloatBuffer().put(table.rgb)
                    rewind()
                }.asReadOnlyBuffer()
        } catch (_: OutOfMemoryError) { null } // Original exact Kotlin path remains usable.
    }

    internal fun prepareBulk(requested: PhotoLutExecution = PhotoLutExecution.NATIVE_16K): PhotoLutExecution =
        if (requested != PhotoLutExecution.KOTLIN && nativeTable != null) requested else PhotoLutExecution.KOTLIN

    /** Bounded synchronous batches keep cancellation responsive without adding compute workers. */
    internal fun mapRange(pixels: IntArray, start: Int, end: Int, strength: Float,
        preserveAlpha: Boolean, execution: PhotoLutExecution = PhotoLutExecution.NATIVE_16K,
        isCancelled: () -> Boolean) {
        require(start >= 0 && end >= start && end <= pixels.size)
        val native = if (execution == PhotoLutExecution.KOTLIN) null else nativeTable
        var offset = start
        while (offset < end) {
            if (isCancelled()) throw CancellationException("Photo filter render superseded")
            val count = minOf(if (native != null) execution.batchPixels else 4096, end - offset)
            if (native != null) NativePhotoLut.mapBatch(native, pixels, offset, count, strength, preserveAlpha)
            else for (i in offset until offset + count) pixels[i] = map(pixels[i], strength, preserveAlpha)
            offset += count
        }
    }

    fun map(color: Int, strength: Float, preserveAlpha: Boolean): Int {
        val alpha = if (preserveAlpha) color ushr 24 else 255
        if (alpha == 0) return color
        val r = color ushr 16 and 255
        val g = color ushr 8 and 255
        val b = color and 255
        val x0 = red.low[r]; val x1 = red.high[r]
        val y0 = green.low[g]; val y1 = green.high[g]
        val z0 = blue.low[b]; val z1 = blue.high[b]
        // The eight lattice addresses are shared by all three output channels.
        val p000 = z0+y0+x0; val p100 = z0+y0+x1
        val p010 = z0+y1+x0; val p110 = z0+y1+x1
        val p001 = z1+y0+x0; val p101 = z1+y0+x1
        val p011 = z1+y1+x0; val p111 = z1+y1+x1
        val tx = red.fraction[r]; val ty = green.fraction[g]; val tz = blue.fraction[b]
        val data = table.rgb
        fun channel(c: Int, original: Int): Int {
            val a = data[p000+c] * (1f-tx) + data[p100+c] * tx
            val b0 = data[p010+c] * (1f-tx) + data[p110+c] * tx
            val c0 = data[p001+c] * (1f-tx) + data[p101+c] * tx
            val d = data[p011+c] * (1f-tx) + data[p111+c] * tx
            val result = ((a * (1f-ty) + b0 * ty) * (1f-tz) + (c0 * (1f-ty) + d * ty) * tz)
                .coerceIn(0f, 1f) * 255f
            return (original + (result-original) * strength).roundToInt().coerceIn(0, 255)
        }
        return (alpha shl 24) or (channel(0,r) shl 16) or (channel(1,g) shl 8) or channel(2,b)
    }
}
