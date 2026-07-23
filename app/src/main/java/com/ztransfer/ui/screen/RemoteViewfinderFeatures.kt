package com.ztransfer.ui.screen

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

private val ToolMarkStrokeWidth = 1.5.dp

internal enum class ViewfinderGrid(val divisions: Int) {
    OFF(0), THIRDS(3), FOURTHS(4);

    fun next(): ViewfinderGrid = when (this) {
        OFF -> THIRDS
        THIRDS -> FOURTHS
        FOURTHS -> OFF
    }
}

/** ContentScale.Fit 在容器中的真实图像区域；网格、点击坐标与 AF 框共用。 */
internal fun fitCenterRect(
    containerWidth: Float,
    containerHeight: Float,
    imageAspectRatio: Float
): Rect {
    if (containerWidth <= 0f || containerHeight <= 0f ||
        !imageAspectRatio.isFinite() || imageAspectRatio <= 0f
    ) return Rect.Zero
    val containerAspect = containerWidth / containerHeight
    val width: Float
    val height: Float
    if (imageAspectRatio >= containerAspect) {
        width = containerWidth
        height = width / imageAspectRatio
    } else {
        height = containerHeight
        width = height * imageAspectRatio
    }
    val left = (containerWidth - width) / 2f
    val top = (containerHeight - height) / 2f
    return Rect(left, top, left + width, top + height)
}

/** 统一的相机式四角 AF 框，中央半按与点按对焦共用同一绘制实现。 */
internal fun DrawScope.drawFocusCornerReticle(
    center: Offset,
    halfSize: Float,
    cornerLength: Float,
    color: Color,
    strokeWidth: Float
) = drawFocusCornerReticle(
    center = center,
    halfWidth = halfSize,
    halfHeight = halfSize,
    cornerLength = cornerLength,
    color = color,
    strokeWidth = strokeWidth
)

/** 可保留相机真实 AF 区域宽高比的四角框。 */
internal fun DrawScope.drawFocusCornerReticle(
    center: Offset,
    halfWidth: Float,
    halfHeight: Float,
    cornerLength: Float,
    color: Color,
    strokeWidth: Float
) {
    val x0 = center.x - halfWidth
    val x1 = center.x + halfWidth
    val y0 = center.y - halfHeight
    val y1 = center.y + halfHeight
    drawLine(color, Offset(x0, y0 + cornerLength), Offset(x0, y0), strokeWidth, StrokeCap.Round)
    drawLine(color, Offset(x0, y0), Offset(x0 + cornerLength, y0), strokeWidth, StrokeCap.Round)
    drawLine(color, Offset(x1 - cornerLength, y0), Offset(x1, y0), strokeWidth, StrokeCap.Round)
    drawLine(color, Offset(x1, y0), Offset(x1, y0 + cornerLength), strokeWidth, StrokeCap.Round)
    drawLine(color, Offset(x0, y1 - cornerLength), Offset(x0, y1), strokeWidth, StrokeCap.Round)
    drawLine(color, Offset(x0, y1), Offset(x0 + cornerLength, y1), strokeWidth, StrokeCap.Round)
    drawLine(color, Offset(x1, y1 - cornerLength), Offset(x1, y1), strokeWidth, StrokeCap.Round)
    drawLine(color, Offset(x1 - cornerLength, y1), Offset(x1, y1), strokeWidth, StrokeCap.Round)
}

/** 抽样 RGB 直方图。每通道已归一化并用 log1p 压缩尖峰，绘制层不再做统计。 */
internal data class LuminanceHistogram(val bins: FloatArray)

/**
 * 从已经解码的 Live View Bitmap 抽样统计，不再解一遍 JPEG。目标约 24k 像素，
 * VGA/XGA 都有稳定上限；按行复用一个 IntArray，避免每帧分配整图像素数组。
 */
internal fun calculateLuminanceHistogram(bitmap: Bitmap): LuminanceHistogram {
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

@Composable
internal fun HistogramOverlay(histogram: LuminanceHistogram, modifier: Modifier = Modifier) {
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

@Composable
internal fun FramingGridOverlay(
    grid: ViewfinderGrid,
    imageAspectRatio: Float,
    modifier: Modifier = Modifier
) {
    if (grid == ViewfinderGrid.OFF) return
    Canvas(modifier) {
        val color = Color.White.copy(alpha = 0.42f)
        val stroke = 0.75.dp.toPx()
        val rect = fitCenterRect(size.width, size.height, imageAspectRatio)
        for (i in 1 until grid.divisions) {
            val fraction = i.toFloat() / grid.divisions
            drawLine(
                color,
                Offset(rect.left + rect.width * fraction, rect.top),
                Offset(rect.left + rect.width * fraction, rect.bottom),
                stroke
            )
            drawLine(
                color,
                Offset(rect.left, rect.top + rect.height * fraction),
                Offset(rect.right, rect.top + rect.height * fraction),
                stroke
            )
        }
    }
}

@Composable
internal fun HistogramMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val points = floatArrayOf(0.08f, 0.72f, 0.25f, 0.46f, 0.43f, 0.62f, 0.62f, 0.20f, 0.82f, 0.50f, 0.94f, 0.30f)
        for (i in 0 until points.size - 2 step 2) {
            drawLine(
                c,
                Offset(size.width * points[i], size.height * points[i + 1]),
                Offset(size.width * points[i + 2], size.height * points[i + 3]),
                sw,
                StrokeCap.Round
            )
        }
    }
}

@Composable
internal fun GridMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val inset = 2.dp.toPx()
        // 固定为清晰的“井”字按钮标识；它表示参考线功能，不跟随实际网格档位变形。
        // 两条线放在可绘区域的 30% / 70%，让中央留白比标准九宫格略宽。
        for (f in floatArrayOf(0.30f, 0.70f)) {
            val x = inset + (size.width - inset * 2f) * f
            val y = inset + (size.height - inset * 2f) * f
            drawLine(c, Offset(x, inset), Offset(x, size.height - inset), sw, StrokeCap.Round)
            drawLine(c, Offset(inset, y), Offset(size.width - inset, y), sw, StrokeCap.Round)
        }
    }
}

@Composable
internal fun HdMark(modifier: Modifier = Modifier) {
    val color = LocalContentColor.current
    Box(modifier, contentAlignment = Alignment.Center) {
        Text(
            text = "HD",
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            lineHeight = 11.sp
        )
    }
}

@Composable
internal fun FpsMark(modifier: Modifier = Modifier) {
    val color = LocalContentColor.current
    Box(modifier, contentAlignment = Alignment.Center) {
        Text(
            text = "FPS",
            color = color,
            fontSize = 9.5.sp,
            fontWeight = FontWeight.SemiBold,
            lineHeight = 10.sp
        )
    }
}

/** Four-corner full-screen glyph that morphs between expand and collapse. */
@Composable
internal fun FullscreenMark(collapseProgress: Float, modifier: Modifier = Modifier) {
    val color = LocalContentColor.current
    Canvas(modifier) {
        val stroke = ToolMarkStrokeWidth.toPx()
        val outer = 2.5.dp.toPx()
        val inner = 7.5.dp.toPx()
        val arm = inner - outer
        val progress = collapseProgress.coerceIn(0f, 1f)
        val radians = Math.PI.toFloat() * progress
        val cosAngle = cos(radians)
        val sinAngle = sin(radians)

        fun lerp(start: Float, end: Float): Float = start + (end - start) * progress
        fun rotate(vector: Offset): Offset = Offset(
            vector.x * cosAngle - vector.y * sinAngle,
            vector.x * sinAngle + vector.y * cosAngle
        )
        fun corner(start: Offset, end: Offset, firstArm: Offset, secondArm: Offset) {
            val vertex = Offset(lerp(start.x, end.x), lerp(start.y, end.y))
            drawLine(color, vertex, vertex + rotate(firstArm), stroke, StrokeCap.Round)
            drawLine(color, vertex, vertex + rotate(secondArm), stroke, StrokeCap.Round)
        }

        corner(Offset(outer, outer), Offset(inner, inner), Offset(arm, 0f), Offset(0f, arm))
        corner(
            Offset(size.width - outer, outer),
            Offset(size.width - inner, inner),
            Offset(-arm, 0f),
            Offset(0f, arm)
        )
        corner(
            Offset(outer, size.height - outer),
            Offset(inner, size.height - inner),
            Offset(arm, 0f),
            Offset(0f, -arm)
        )
        corner(
            Offset(size.width - outer, size.height - outer),
            Offset(size.width - inner, size.height - inner),
            Offset(-arm, 0f),
            Offset(0f, -arm)
        )
    }
}
