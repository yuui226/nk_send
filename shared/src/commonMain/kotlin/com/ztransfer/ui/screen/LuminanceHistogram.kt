@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import kotlin.math.ceil
import kotlin.math.sqrt

/** 原Rec.709亮度抽样，256个bin按峰值线性归一化；不是RGB分通道或log压缩。 */
@kotlin.native.HiddenFromObjC
data class LuminanceHistogram(val bins: FloatArray)

@kotlin.native.HiddenFromObjC
fun calculateLuminanceHistogram(
    inputWidth: Int,
    inputHeight: Int,
    readRow: (y: Int, row: IntArray) -> Unit,
): LuminanceHistogram {
    val width = inputWidth.coerceAtLeast(1)
    val height = inputHeight.coerceAtLeast(1)
    val step = ceil(sqrt(width.toDouble() * height / 24_000.0)).toInt().coerceAtLeast(1)
    val counts = IntArray(256)
    val row = IntArray(width)
    var y = 0
    while (y < height) {
        readRow(y, row)
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
