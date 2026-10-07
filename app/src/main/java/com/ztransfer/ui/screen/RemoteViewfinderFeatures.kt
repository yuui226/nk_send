package com.ztransfer.ui.screen

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

private val ToolMarkStrokeWidth = 1.5.dp

internal enum class ViewfinderGrid(val fractions: List<Float>, val labelRes: Int, val diagonals: Boolean = false, val frameAspect: Float? = null) {
    OFF(emptyList(), R.string.remote_grid_off),
    THIRDS(listOf(1f / 3f, 2f / 3f), R.string.remote_grid_thirds),
    FOURTHS(listOf(0.25f, 0.5f, 0.75f), R.string.remote_grid_fourths),
    CENTER(listOf(0.5f), R.string.remote_grid_center),
    GOLDEN(listOf(0.38196602f, 0.618034f), R.string.remote_grid_golden),
    THIRDS_DIAGONALS(listOf(1f / 3f, 2f / 3f), R.string.remote_grid_thirds_diagonals, true),
    FOURTHS_DIAGONALS(listOf(0.25f, 0.5f, 0.75f), R.string.remote_grid_fourths_diagonals, true),
    WIDE_235(emptyList(), R.string.remote_grid_235, frameAspect = 2.35f),
    WIDE_169(emptyList(), R.string.remote_grid_169, frameAspect = 16f/9f),
    FRAME_43(emptyList(), R.string.remote_grid_43, frameAspect = 4f/3f);

    fun next(): ViewfinderGrid = when (this) {
        OFF -> THIRDS
        THIRDS -> THIRDS_DIAGONALS
        THIRDS_DIAGONALS -> FOURTHS
        FOURTHS -> FOURTHS_DIAGONALS
        FOURTHS_DIAGONALS -> CENTER
        CENTER -> GOLDEN
        GOLDEN -> WIDE_235
        WIDE_235 -> WIDE_169
        WIDE_169 -> FRAME_43
        FRAME_43 -> OFF
    }
}

internal data class FramingGridLine(val start: Offset, val end: Offset)

/** Fractions are measured in the displayed image, after de-squeeze, excluding letterboxing. */
internal fun framingGridLines(
    grid: ViewfinderGrid,
    containerWidth: Float,
    containerHeight: Float,
    imageAspectRatio: Float
): List<FramingGridLine> {
    if (grid == ViewfinderGrid.OFF) return emptyList()
    val rect = fitCenterRect(containerWidth, containerHeight, imageAspectRatio)
    if (rect.width <= 0f || rect.height <= 0f) return emptyList()
    grid.frameAspect?.let { aspect ->
        val fitted=fitCenterRect(rect.width,rect.height,aspect)
        val frame=Rect(fitted.left+rect.left,fitted.top+rect.top,fitted.right+rect.left,fitted.bottom+rect.top)
        return listOf(
            FramingGridLine(frame.topLeft,Offset(frame.right,frame.top)),
            FramingGridLine(Offset(frame.right,frame.top),frame.bottomRight),
            FramingGridLine(frame.bottomRight,Offset(frame.left,frame.bottom)),
            FramingGridLine(Offset(frame.left,frame.bottom),frame.topLeft),
        )
    }
    val lines = grid.fractions.flatMap { fraction ->
        val x = rect.left + rect.width * fraction
        val y = rect.top + rect.height * fraction
        listOf(
            FramingGridLine(Offset(x, rect.top), Offset(x, rect.bottom)),
            FramingGridLine(Offset(rect.left, y), Offset(rect.right, y))
        )
    }
    return if (grid.diagonals) lines + listOf(
        FramingGridLine(rect.topLeft, rect.bottomRight),
        FramingGridLine(Offset(rect.right, rect.top), Offset(rect.left, rect.bottom)),
    ) else lines
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

/** 线性归一化的亮度统计，以及按需附带的 RGB 三通道统计；绘制层不再读取源图。 */
internal data class LuminanceHistogram(val bins: FloatArray, val rgb: List<FloatArray>? = null)

/**
 * 从已经解码的 Live View Bitmap 抽样统计，不再解一遍 JPEG。目标约 24k 像素，
 * VGA/XGA 都有稳定上限；按行复用一个 IntArray，避免每帧分配整图像素数组。
 */
internal fun calculateLuminanceHistogram(bitmap: Bitmap, includeRgb: Boolean = false, sampleLimit: Int = 24_000): LuminanceHistogram {
    val width = bitmap.width.coerceAtLeast(1)
    val height = bitmap.height.coerceAtLeast(1)
    val step = ceil(sqrt(width.toDouble() * height / sampleLimit.coerceAtLeast(1).toDouble())).toInt().coerceAtLeast(1)
    val counts = IntArray(256)
    // RGB_565 expands 5/6-bit channels into sparse 8-bit values. Group all channels
    // at the shared 5-bit precision instead of drawing empty bins as a comb.
    val rgbBinCount = if (bitmap.config == Bitmap.Config.RGB_565) 32 else 256
    val rgbBinWidth = 256 / rgbBinCount
    val channels = if (includeRgb) List(3) { IntArray(rgbBinCount) } else null
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
            channels?.let { it[0][red / rgbBinWidth]++; it[1][green / rgbBinWidth]++; it[2][blue / rgbBinWidth]++ }
            x += step
        }
        y += step
    }
    // 线性归一化保留“纵轴 = 像素数量”的直方图语义；0/255 两端尖峰不会被对数压平。
    val peak = counts.maxOrNull()?.coerceAtLeast(1) ?: 1
    // One shared RGB scale preserves relative channel counts; never normalize each separately.
    val rgbPeak = channels?.maxOf { it.maxOrNull() ?: 0 }?.coerceAtLeast(1) ?: 1
    return LuminanceHistogram(FloatArray(256) { i -> counts[i].toFloat() / peak },
        channels?.map { channel -> FloatArray(channel.size) { channel[it].toFloat() / rgbPeak } })
}

/** Decode only a small 8-bit RGB analysis image; display still uses RGB_565. */
internal fun previewHistogramFromJpeg(bytes: ByteArray): LuminanceHistogram? {
    return try {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while ((maxOf(bounds.outWidth, bounds.outHeight).toLong() + sample - 1) / sample > 512) sample *= 2
        val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            android.graphics.BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inPreferredColorSpace = android.graphics.ColorSpace.get(android.graphics.ColorSpace.Named.SRGB)
            }) ?: return null
        try {
            // Scan every pixel of this bounded image: tiny highlights should not fall between samples.
            calculateLuminanceHistogram(bitmap, includeRgb = true, sampleLimit = Int.MAX_VALUE)
        } finally {
            bitmap.recycle()
        }
    } catch (_: OutOfMemoryError) {
        null // An optional scope must not prevent the photograph from being displayed.
    } catch (_: Exception) {
        null
    }
}

/** 过曝斑马掩码：cols×rows 粗网格按行优先排列，true = 该格抽样亮度达到过曝阈值。 */
internal data class ZebraMask(val cols: Int, val rows: Int, val cells: BooleanArray)

/** 95 IRE 过曝阈值：255 满幅的 95%（≥242），与专业监视器的常用默认档一致。 */
private const val ZebraLumaThreshold = 242

/**
 * 从已解码的 Live View Bitmap 计算过曝斑马掩码。相机不会下发过曝信息，
 * 监看端只能自己对像素做逐帧分析——这里与直方图同一套纪律：粗网格最多约
 * 120×80 格（每格对应一小块像素，按该密度抽样格中心一个点即可），亮度用同一个
 * Rec.709 整数近似；按行复用一个 IntArray，每次调用只新分配一个掩码数组。
 */
internal fun calculateZebraMask(bitmap: Bitmap): ZebraMask {
    val width = bitmap.width.coerceAtLeast(1)
    val height = bitmap.height.coerceAtLeast(1)
    val cellW = (width + 119) / 120   // ceil(width/120)：横向最多 120 格
    val cellH = (height + 79) / 80    // ceil(height/80)：纵向最多 80 格
    val cols = (width + cellW - 1) / cellW
    val rows = (height + cellH - 1) / cellH
    val cells = BooleanArray(cols * rows)
    val sampled = Bitmap.createScaledBitmap(bitmap, cols, rows, false)
    val pixels = IntArray(cols * rows)
    try {
        sampled.getPixels(pixels, 0, cols, 0, 0, cols, rows)
    } finally {
        if (sampled !== bitmap) sampled.recycle()
    }
    var r = 0
    while (r < rows) {
        var c = 0
        while (c < cols) {
            val px = pixels[r * cols + c]
            val red = (px ushr 16) and 0xFF
            val green = (px ushr 8) and 0xFF
            val blue = px and 0xFF
            // 与直方图相同的 Rec.709 亮度整数近似（54 + 183 + 19 = 256）。
            cells[r * cols + c] =
                ((54 * red + 183 * green + 19 * blue) ushr 8) >= ZebraLumaThreshold
            c++
        }
        r++
    }
    return ZebraMask(cols, rows, cells)
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
    Box(modifier.drawWithCache {
        val lines = framingGridLines(grid, size.width, size.height, imageAspectRatio)
        val color = Color.White.copy(alpha = 0.42f)
        val stroke = 0.75.dp.toPx()
        onDrawBehind {
            lines.forEach { drawLine(color, it.start, it.end, stroke) }
        }
    })
}

// ── 所有工具按钮图标：统一线宽 = ToolMarkStrokeWidth(1.5dp)，风格克制简洁 ──

/** 直方图——5 根竖条，中间高两端低，经典”色阶分布”形状。 */
@Composable
internal fun HistogramMark(modifier: Modifier = Modifier, rgb: Boolean = false) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val barW = (size.width - 7.dp.toPx()) / 5f
        val gap = 1.5.dp.toPx()
        val baseY = size.height - 2.dp.toPx()
        val heights = floatArrayOf(0.38f, 0.62f, 0.85f, 0.55f, 0.28f)
        for (i in 0..4) {
            val x = 2.5.dp.toPx() + i * barW + i * gap
            val barH = baseY * heights[i]
            val color = if (rgb) ScopeRgbColors[minOf(i * 3 / 5, 2)] else c
            drawLine(color, Offset(x, baseY), Offset(x, baseY - barH), sw, StrokeCap.Round)
        }
    }
}

/** 按当前档位绘制参考线图标；关闭时保留九宫格入口，以按钮的非激活色区分。 */
@Composable
internal fun GridMark(grid: ViewfinderGrid, modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val inset = 2.dp.toPx()
        grid.frameAspect?.let { aspect ->
            val frame=fitCenterRect(size.width-inset*2,size.height-inset*2,aspect)
            drawRect(c,frame.topLeft+Offset(inset,inset),frame.size,style=Stroke(sw))
        }
        for (f in (if (grid == ViewfinderGrid.OFF) ViewfinderGrid.THIRDS else grid).fractions) {
            val x = inset + (size.width - inset * 2f) * f
            val y = inset + (size.height - inset * 2f) * f
            drawLine(c, Offset(x, inset), Offset(x, size.height - inset), sw, StrokeCap.Round)
            drawLine(c, Offset(inset, y), Offset(size.width - inset, y), sw, StrokeCap.Round)
        }
        if (grid.diagonals) {
            drawLine(c, Offset(inset, inset), Offset(size.width - inset, size.height - inset), sw, StrokeCap.Round)
            drawLine(c, Offset(size.width - inset, inset), Offset(inset, size.height - inset), sw, StrokeCap.Round)
        }
    }
}

/** 高清取景——HD 字母标识。 */
@Composable
internal fun HdMark(modifier: Modifier = Modifier) {
    val color = LocalContentColor.current
    Box(modifier, contentAlignment = Alignment.Center) {
        Text(
            text = "HD",
            color = color,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 13.sp,
            maxLines = 1,
            softWrap = false
        )
    }
}

/** 帧率显示——FPS 字母标识。 */
@Composable
internal fun FpsMark(modifier: Modifier = Modifier) {
    val color = LocalContentColor.current
    Box(modifier, contentAlignment = Alignment.Center) {
        Text(
            text = "FPS",
            color = color,
            fontSize = 10.5.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 11.sp,
            maxLines = 1,
            softWrap = false
        )
    }
}

/** 旋转：开放圆弧末端只保留外侧半边箭翼，小尺寸下比完整箭头更端正。 */
@Composable
internal fun RotateMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val s = size.minDimension
        val cx = size.width * 0.50f
        val cy = size.height * 0.49f
        val r = s * 0.29f
        val startAngle = -125f
        val sweepAngle = 225f

        // 略多于半圈，让右侧圆弧完整、左侧保持开放，避免看起来像“刷新”图标。
        drawArc(
            color = c,
            startAngle = startAngle,
            sweepAngle = sweepAngle,
            useCenter = false,
            topLeft = Offset(cx - r, cy - r),
            size = Size(r * 2f, r * 2f),
            style = Stroke(sw, cap = StrokeCap.Round)
        )

        // 箭头沿弧线末端的顺时针切线展开。只画外侧（下方）箭翼：内侧箭翼会与圆弧
        // 挤在一起，在 20dp 图标里产生视觉歪斜；单翼仍保留明确的旋转方向。
        val endAngle = startAngle + sweepAngle
        fun pointAt(angle: Float, distance: Float): Offset {
            val radians = Math.toRadians(angle.toDouble())
            return Offset(
                x = cx + cos(radians).toFloat() * distance,
                y = cy + sin(radians).toFloat() * distance
            )
        }
        val tip = pointAt(endAngle, r)
        val tangentAngle = endAngle + 90f
        val arrowLength = s * 0.16f
        val wingSpread = 32f
        val outerWingAngle = tangentAngle + 180f + wingSpread
        val wingRadians = Math.toRadians(outerWingAngle.toDouble())
        val wingEnd = Offset(
            x = tip.x + cos(wingRadians).toFloat() * arrowLength,
            y = tip.y + sin(wingRadians).toFloat() * arrowLength,
        )
        drawLine(c, tip, wingEnd, sw, StrokeCap.Round)
    }
}

/** 斑马纹——5 条等间距短斜线，纯粹条纹无需外框。 */
@Composable
internal fun ZebraMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val h = size.height
        // 缩短线段并保留充分留白，避免圆形按钮内显得比其他图标拥挤。
        for (i in 0..4) {
            val frac = (i + 1f) / 6f
            val cx = size.width * frac
            val d = h * 0.24f
            drawLine(c, Offset(cx - d, h / 2 - d), Offset(cx + d, h / 2 + d),
                sw, StrokeCap.Round)
        }
    }
}

/** 水平仪——实体水平尺轮廓：左右端仓，以及嵌入尺身上沿的 U 形水准槽。 */
@Composable
internal fun LevelMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = 1.65.dp.toPx()
        val left = size.width * 0.08f
        val right = size.width * 0.92f
        val top = size.height * 0.24f
        val bottom = size.height * 0.78f
        val corner = size.minDimension * 0.09f
        val leftDivider = size.width * 0.27f
        val rightDivider = size.width * 0.73f
        val vialLeft = size.width * 0.34f
        val vialRight = size.width * 0.66f
        val vialBottom = size.height * 0.49f

        // U 形槽是尺身上沿的一部分，最高点与外轮廓齐平，避免出现向上冒出的尖角。
        val body = Path().apply {
            moveTo(left + corner, top)
            lineTo(vialLeft, top)
            cubicTo(
                vialLeft,
                vialBottom,
                vialRight,
                vialBottom,
                vialRight,
                top
            )
            lineTo(right - corner, top)
            quadraticTo(right, top, right, top + corner)
            lineTo(right, bottom - corner)
            quadraticTo(right, bottom, right - corner, bottom)
            lineTo(left + corner, bottom)
            quadraticTo(left, bottom, left, bottom - corner)
            lineTo(left, top + corner)
            quadraticTo(left, top, left + corner, top)
            close()
        }
        drawPath(body, c, style = Stroke(sw, cap = StrokeCap.Round, join = StrokeJoin.Round))

        // 参考图中的左右独立端仓。
        drawLine(
            c,
            Offset(leftDivider, top),
            Offset(leftDivider, bottom),
            sw,
            StrokeCap.Round
        )
        drawLine(
            c,
            Offset(rightDivider, top),
            Offset(rightDivider, bottom),
            sw,
            StrokeCap.Round
        )

    }
}

/**
 * 斑马纹过曝警告叠加层——专业监视器语义：只在亮度 ≥95 IRE 的区域画 45° 斜纹，
 * 曝光正常的画面完全没有条纹；[mask] 为 null（未开启或首帧还没算出）时一笔不画。
 *
 * 绘制策略：把掩码里每行连续的过曝格合并成矩形拼成裁剪 Path，再对整个图像区域
 * 画一组全局 45° 斜线并裁剪到该 Path——避免逐格计算条纹端点（行程数远小于格数）。
 * 黑白两族斜线相错半个周期（糖果纹），确保在接近纯白的过曝区域上依然醒目。
 * 所有 Path 都在 drawWithCache 里构建：只在掩码实例或尺寸变化时重建
 * （掩码本身 250ms 才更新一次），不随帧率重跑。
 */
@Composable
internal fun ViewfinderZebraOverlay(
    mask: ZebraMask?,
    imageAspectRatio: Float,
    modifier: Modifier = Modifier
) {
    if (mask == null) return
    Box(
        modifier.drawWithCache {
            val rect = fitCenterRect(size.width, size.height, imageAspectRatio)
            val clip = Path()
            if (rect.width > 0f && rect.height > 0f) {
                val cellW = rect.width / mask.cols
                val cellH = rect.height / mask.rows
                var r = 0
                while (r < mask.rows) {
                    var c = 0
                    while (c < mask.cols) {
                        if (mask.cells[r * mask.cols + c]) {
                            val runStart = c
                            while (c < mask.cols && mask.cells[r * mask.cols + c]) c++
                            clip.addRect(
                                Rect(
                                    rect.left + runStart * cellW,
                                    rect.top + r * cellH,
                                    rect.left + c * cellW,
                                    rect.top + (r + 1) * cellH
                                )
                            )
                        } else {
                            c++
                        }
                    }
                    r++
                }
            }
            val whiteStripes = Path()
            val blackStripes = Path()
            if (!clip.isEmpty) {
                // 斜线族沿 45° 从左下奔右上，铺满整个图像区，交给 clip 裁出过曝块。
                val period = 5.dp.toPx()
                var x = rect.left - rect.height
                while (x < rect.right) {
                    whiteStripes.moveTo(x, rect.bottom)
                    whiteStripes.lineTo(x + rect.height, rect.top)
                    val half = x + period / 2f
                    blackStripes.moveTo(half, rect.bottom)
                    blackStripes.lineTo(half + rect.height, rect.top)
                    x += period
                }
            }
            val stroke = Stroke(1.4.dp.toPx())
            onDrawBehind {
                if (!clip.isEmpty) {
                    clipPath(clip) {
                        drawPath(blackStripes, Color.Black.copy(alpha = 0.50f), style = stroke)
                        drawPath(whiteStripes, Color.White.copy(alpha = 0.85f), style = stroke)
                    }
                }
            }
        }
    )
}

/** Separate enter/exit limits stop a nearly level camera from flickering between colors. */
internal fun horizonAligned(roll: Float, wasAligned: Boolean): Boolean {
    if (!roll.isFinite()) return false
    // Align to the nearest horizontal or vertical axis, including inverted orientations.
    val remainder = abs(roll % 90f)
    val deviation = minOf(remainder, 90f - remainder)
    return deviation <= if (wasAligned) 1.2f else 0.7f
}

/** Preserve physical orientation and unwrap across ±180° for the shortest animation path. */
internal fun horizonDisplayRoll(roll: Float, previous: Float = roll): Float =
    previous + ((roll - previous + 180f) % 360f + 360f) % 360f - 180f

/** Rotating diameter and parallel pitch chord; each axis indicates alignment independently. */
@Composable
internal fun ViewfinderLevelOverlay(
    rollDegrees: Float?,
    modifier: Modifier = Modifier,
    pitchDegrees: Float? = null,
) {
    val roll = rollDegrees?.takeIf { it.isFinite() } ?: return
    val pitch = pitchDegrees?.takeIf { it.isFinite() && kotlin.math.abs(it) <= 90f }
    var rollAligned by remember { mutableStateOf(horizonAligned(roll, false)) }
    var pitchAligned by remember { mutableStateOf(false) }
    LaunchedEffect(roll, pitch) {
        rollAligned = horizonAligned(roll, rollAligned)
        pitchAligned = pitch != null && kotlin.math.abs(pitch) <= if (pitchAligned) 1.2f else 0.7f
    }
    val aligned = rollAligned && (pitch == null || pitchAligned)
    val pitchOffset by animateFloatAsState((pitch ?: 0f).coerceIn(-30f, 30f) / 30f, tween(100), label = "horizonPitch")
    var rollTarget by remember { mutableFloatStateOf(roll) }
    LaunchedEffect(roll) { rollTarget = horizonDisplayRoll(roll, rollTarget) }
    val angle by animateFloatAsState(rollTarget, tween(100), label = "horizonRoll")
    val tint by animateColorAsState(
        if (rollAligned) Color(0xFF52F58B) else Color(0xFFFFC857),
        tween(160), label = "horizonColor",
    )
    val stroke by animateFloatAsState(if (rollAligned) 1.6f else 1.2f, tween(160), label = "horizonStroke")
    val pitchTint by animateColorAsState(
        if (pitchAligned) Color(0xFF52F58B) else Color.White.copy(alpha = 0.65f),
        tween(160), label = "horizonPitchColor",
    )
    val reference by animateColorAsState(
        if (aligned) Color(0xFF52F58B).copy(alpha = 0.38f) else Color.White.copy(alpha = 0.26f),
        tween(160), label = "horizonReference",
    )
    Canvas(modifier) {
        val radius = minOf(size.width * 0.19f, size.height * 0.28f)
        if (radius < 18.dp.toPx()) return@Canvas
        val outline = Color.Black.copy(alpha = 0.24f)
        drawCircle(Color.Black.copy(alpha = 0.12f), radius, style = Stroke(1.5.dp.toPx()))
        drawCircle(reference, radius, style = Stroke(0.75.dp.toPx()))
        // Only short fixed ticks: there is no competing fixed diameter.
        for (side in listOf(-1, 1)) {
            drawLine(reference, center + Offset(side * (radius - 4.dp.toPx()), 0f),
                center + Offset(side * radius, 0f), 1.dp.toPx(), StrokeCap.Round)
            drawLine(reference, center + Offset(0f, side * (radius - 4.dp.toPx())),
                center + Offset(0f, side * radius), 1.dp.toPx(), StrokeCap.Round)
        }
        // Match the camera display: the reported roll already has the required sign.
        rotate(angle) {
            // Leave room for rounded caps and the outline, keeping every stroke inside the ring.
            val innerRadius = (radius - 2.dp.toPx()).coerceAtLeast(0f)
            val start = center - Offset(innerRadius, 0f)
            val end = center + Offset(innerRadius, 0f)
            if (pitch != null) {
                // Both lines use the same rotation. Pitch translates perpendicular to the
                // diameter, and sqrt(r²-y²) keeps its endpoints on the inner circle.
                val y = pitchOffset * innerRadius * 0.75f
                val halfWidth = sqrt((innerRadius * innerRadius - y * y).coerceAtLeast(0f))
                val pitchCenter = center + Offset(0f, y)
                val pitchStart = pitchCenter - Offset(halfWidth, 0f)
                val pitchEnd = pitchCenter + Offset(halfWidth, 0f)
                drawLine(outline, pitchStart, pitchEnd, 2.dp.toPx(), StrokeCap.Round)
                drawLine(pitchTint, pitchStart, pitchEnd, 1.dp.toPx(), StrokeCap.Round)
            }
            // Draw roll last so a level-pitch chord cannot obscure a tilted roll warning.
            drawLine(outline, start, end, (stroke + 1f).dp.toPx(), StrokeCap.Round)
            drawLine(tint, start, end, stroke.dp.toPx(), StrokeCap.Round)
        }
        drawCircle(outline, 3.dp.toPx())
        // The centre marker reports pitch separately; single-axis cameras retain roll feedback.
        drawCircle(if (pitch != null) {
            if (pitchAligned) Color(0xFF52F58B) else Color(0xFFFFC857)
        } else tint, if (aligned) 2.2.dp.toPx() else 1.5.dp.toPx())
    }
}
