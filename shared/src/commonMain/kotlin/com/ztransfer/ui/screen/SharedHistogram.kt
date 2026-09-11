@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.material3.LocalContentColor
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

private val HistogramMarkStrokeWidth = 1.5.dp

/** Reads the same sampled rows from an already decoded image, without another JPEG decode. */
@kotlin.native.HiddenFromObjC
fun calculateImageLuminanceHistogram(bitmap: ImageBitmap): LuminanceHistogram =
    calculateLuminanceHistogram(bitmap.width, bitmap.height) { y, row ->
        bitmap.readPixels(row, startX = 0, startY = y, width = row.size, height = 1,
            bufferOffset = 0, stride = row.size)
    }

@kotlin.native.HiddenFromObjC
@Composable
fun HistogramOverlay(histogram: LuminanceHistogram, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(width = 118.dp, height = 62.dp)
            .background(Color.Black.copy(alpha = 0.48f), RoundedCornerShape(8.dp))
    ) {
        Canvas(Modifier.matchParentSize()) {
            val left = 7.dp.toPx()
            val top = 6.dp.toPx()
            val width = size.width - left * 2
            val height = size.height - top * 2
            val bottom = top + height
            val path = Path().apply {
                moveTo(left, bottom)
                histogram.bins.forEachIndexed { i, value ->
                    lineTo(
                        left + width * i / 255f,
                        top + height * (1f - value.coerceIn(0f, 1f))
                    )
                }
                lineTo(left + width, bottom)
                close()
            }
            drawPath(path, Color.White.copy(alpha = 0.28f))
            drawPath(
                path,
                Color.White.copy(alpha = 0.90f),
                style = Stroke(1.05.dp.toPx(), cap = StrokeCap.Round)
            )
            drawLine(
                Color.White.copy(alpha = 0.22f),
                Offset(left, bottom),
                Offset(left + width, bottom),
                0.75.dp.toPx()
            )
        }
    }
}

/** 直方图——5 根竖条，中间高两端低，经典”色阶分布”形状。 */
@kotlin.native.HiddenFromObjC
@Composable
fun HistogramMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = HistogramMarkStrokeWidth.toPx()
        val barW = (size.width - 7.dp.toPx()) / 5f
        val gap = 1.5.dp.toPx()
        val baseY = size.height - 2.dp.toPx()
        val heights = floatArrayOf(0.38f, 0.62f, 0.85f, 0.55f, 0.28f)
        for (i in 0..4) {
            val x = 2.5.dp.toPx() + i * barW + i * gap
            val barH = baseY * heights[i]
            drawLine(c, Offset(x, baseY), Offset(x, baseY - barH), sw, StrokeCap.Round)
        }
    }
}
