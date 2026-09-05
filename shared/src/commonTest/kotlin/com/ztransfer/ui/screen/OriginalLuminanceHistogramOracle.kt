package com.ztransfer.ui.screen

import kotlin.math.ceil
import kotlin.math.sqrt

// Test-only oracle from Android 55876fa. Production must use the shared implementation.
internal fun originalHistogramOracle(width: Int, height: Int, pixel: (Int, Int) -> Int): FloatArray =
    originalHistogram(HistogramOracleBitmap(width, height, pixel)).bins

private class HistogramOracleBitmap(val width: Int, val height: Int, val pixel: (Int, Int) -> Int) {
    fun getPixels(target: IntArray, offset: Int, stride: Int, x: Int, y: Int, width: Int, height: Int) {
        for (r in 0 until height) for (c in 0 until width) {
            target[offset + r * stride + c] = pixel(x + c, y + r)
        }
    }
}

private fun originalHistogram(bitmap: HistogramOracleBitmap): LuminanceHistogram {
    val width = bitmap.width.coerceAtLeast(1)
    val height = bitmap.height.coerceAtLeast(1)
    val step = ceil(sqrt(width.toDouble() * height / 24_000.0)).toInt().coerceAtLeast(1)
    val counts = IntArray(256)
    val row = IntArray(width)
    var y = 0
    while (y < height) {
        bitmap.getPixels(row, 0, width, 0, y, width, 1)
        var x = 0
        while (x < width) {
            val px = row[x]
            val red = (px ushr 16) and 0xFF
            val green = (px ushr 8) and 0xFF
            val blue = px and 0xFF
            // Rec.709 亮度权重的整数近似（54 + 183 + 19 = 256）。
            counts[(54 * red + 183 * green + 19 * blue) ushr 8]++
            x += step
        }
        y += step
    }
    // 线性归一化保留“纵轴 = 像素数量”的直方图语义；0/255 两端尖峰不会被对数压平。
    val peak = counts.maxOrNull()?.coerceAtLeast(1) ?: 1
    return LuminanceHistogram(FloatArray(256) { i -> counts[i].toFloat() / peak })
}
