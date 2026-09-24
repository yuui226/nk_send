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
import androidx.compose.ui.graphics.drawscope.DrawScope
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

internal enum class ViewfinderGrid(val fractions: List<Float>, val labelRes: Int) {
    OFF(emptyList(), R.string.remote_grid_off),
    THIRDS(listOf(1f / 3f, 2f / 3f), R.string.remote_grid_thirds),
    FOURTHS(listOf(0.25f, 0.5f, 0.75f), R.string.remote_grid_fourths),
    CENTER(listOf(0.5f), R.string.remote_grid_center),
    GOLDEN(listOf(0.38196602f, 0.618034f), R.string.remote_grid_golden);

    fun next(): ViewfinderGrid = when (this) {
        OFF -> THIRDS
        THIRDS -> FOURTHS
        FOURTHS -> CENTER
        CENTER -> GOLDEN
        GOLDEN -> OFF
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
    return grid.fractions.flatMap { fraction ->
        val x = rect.left + rect.width * fraction
        val y = rect.top + rect.height * fraction
        listOf(
            FramingGridLine(Offset(x, rect.top), Offset(x, rect.bottom)),
            FramingGridLine(Offset(rect.left, y), Offset(rect.right, y))
        )
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

/** 线性归一化的亮度统计，以及按需附带的 RGB 三通道统计；绘制层不再读取源图。 */
internal data class LuminanceHistogram(val bins: FloatArray, val rgb: List<FloatArray>? = null)

/**
 * 从已经解码的 Live View Bitmap 抽样统计，不再解一遍 JPEG。目标约 24k 像素，
 * VGA/XGA 都有稳定上限；按行复用一个 IntArray，避免每帧分配整图像素数组。
 */
internal fun calculateLuminanceHistogram(bitmap: Bitmap, includeRgb: Boolean = false): LuminanceHistogram {
    val width = bitmap.width.coerceAtLeast(1)
    val height = bitmap.height.coerceAtLeast(1)
    val step = ceil(sqrt(width.toDouble() * height / 24_000.0)).toInt().coerceAtLeast(1)
    val counts = IntArray(256)
    val channels = if (includeRgb) List(3) { IntArray(256) } else null
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
            channels?.let { it[0][red]++; it[1][green]++; it[2][blue]++ }
            x += step
        }
        y += step
    }
    // 线性归一化保留“纵轴 = 像素数量”的直方图语义；0/255 两端尖峰不会被对数压平。
    val peak = counts.maxOrNull()?.coerceAtLeast(1) ?: 1
    // One shared RGB scale preserves relative channel counts; never normalize each separately.
    val rgbPeak = channels?.maxOf { it.maxOrNull() ?: 0 }?.coerceAtLeast(1) ?: 1
    return LuminanceHistogram(FloatArray(256) { i -> counts[i].toFloat() / peak },
        channels?.map { channel -> FloatArray(256) { channel[it].toFloat() / rgbPeak } })
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
    val row = IntArray(width)
    var r = 0
    while (r < rows) {
        val y = (r * cellH + cellH / 2).coerceAtMost(height - 1)
        bitmap.getPixels(row, 0, width, 0, y, width, 1)
        var c = 0
        while (c < cols) {
            val x = (c * cellW + cellW / 2).coerceAtMost(width - 1)
            val px = row[x]
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
        for (f in (if (grid == ViewfinderGrid.OFF) ViewfinderGrid.THIRDS else grid).fractions) {
            val x = inset + (size.width - inset * 2f) * f
            val y = inset + (size.height - inset * 2f) * f
            drawLine(c, Offset(x, inset), Offset(x, size.height - inset), sw, StrokeCap.Round)
            drawLine(c, Offset(inset, y), Offset(size.width - inset, y), sw, StrokeCap.Round)
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

/** 全屏——四角括号（通用「放大到全屏」符号）。 */
@Composable
internal fun FullscreenMark(modifier: Modifier = Modifier, exiting: Boolean = false) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val pad = 2.dp.toPx()
        val arm = 5.dp.toPx()
        val w = size.width
        val h = size.height
        // 每个角一个 L 形括号，开口朝外
        fun bracket(cornerX: Float, cornerY: Float, dx: Float, dy: Float) {
            val corner = Offset(cornerX, cornerY) + if (exiting) Offset(dx * arm, dy * arm) else Offset.Zero
            val direction = if (exiting) -1f else 1f
            drawLine(c, corner, corner + Offset(dx * arm * direction, 0f), sw, StrokeCap.Round)
            drawLine(c, corner, corner + Offset(0f, dy * arm * direction), sw, StrokeCap.Round)
        }
        bracket(pad, pad, 1f, 1f)                    // 左上 ┌
        bracket(w - pad, pad, -1f, 1f)               // 右上 ┐
        bracket(pad, h - pad, 1f, -1f)               // 左下 └
        bracket(w - pad, h - pad, -1f, -1f)          // 右下 ┘
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
internal fun horizonAligned(roll: Float, wasAligned: Boolean): Boolean =
    roll.isFinite() && abs(roll) <= if (wasAligned) 1.2f else 0.7f

/** Z30-style circular reference. Only camera roll is available; no simulated pitch indicator. */
@Composable
internal fun ViewfinderLevelOverlay(
    rollDegrees: Float?,
    modifier: Modifier = Modifier,
) {
    val roll = rollDegrees?.takeIf { it.isFinite() } ?: return
    var aligned by remember { mutableStateOf(horizonAligned(roll, false)) }
    LaunchedEffect(roll) { aligned = horizonAligned(roll, aligned) }
    val angle by animateFloatAsState(roll, tween(100), label = "horizonRoll")
    val tint by animateColorAsState(
        if (aligned) Color(0xFF52F58B) else Color(0xFFFFC857),
        tween(160), label = "horizonColor",
    )
    val stroke by animateFloatAsState(if (aligned) 3f else 1.8f, tween(160), label = "horizonStroke")
    Canvas(modifier) {
        val radius = minOf(size.width * 0.19f, size.height * 0.28f)
        if (radius < 18.dp.toPx()) return@Canvas
        val outline = Color.Black.copy(alpha = 0.65f)
        val reference = if (aligned) tint.copy(alpha = 0.95f) else Color.White.copy(alpha = 0.65f)
        drawCircle(outline, radius, style = Stroke(4.dp.toPx()))
        drawCircle(reference, radius, style = Stroke(if (aligned) 2.5.dp.toPx() else 1.5.dp.toPx()))
        // Fixed horizontal and vertical references remain anchored to the viewfinder.
        drawLine(outline, center - Offset(radius, 0f), center + Offset(radius, 0f), 4.dp.toPx())
        drawLine(reference, center - Offset(radius, 0f), center + Offset(radius, 0f), 1.dp.toPx())
        drawLine(reference.copy(alpha = 0.45f), center - Offset(0f, radius), center + Offset(0f, radius), 1.dp.toPx())
        rotate(-angle) {
            val start = center - Offset(radius, 0f)
            val end = center + Offset(radius, 0f)
            drawLine(outline, start, end, (stroke + 2f).dp.toPx(), StrokeCap.Round)
            drawLine(tint, start, end, stroke.dp.toPx(), StrokeCap.Round)
            for (side in listOf(-1, 1)) {
                val x = center.x + side * radius
                drawLine(tint, Offset(x, center.y - 5.dp.toPx()), Offset(x, center.y + 5.dp.toPx()), stroke.dp.toPx(), StrokeCap.Round)
            }
        }
        drawCircle(outline, 4.dp.toPx())
        drawCircle(tint, if (aligned) 3.dp.toPx() else 1.8.dp.toPx())
    }
}
