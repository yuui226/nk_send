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
import com.ztransfer.ui.theme.AppTheme
import kotlin.math.abs
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

// ── 所有工具按钮图标：统一线宽 = ToolMarkStrokeWidth(1.5dp)，风格克制简洁 ──

/** 直方图——5 根竖条，中间高两端低，经典”色阶分布”形状。 */
@Composable
internal fun HistogramMark(modifier: Modifier = Modifier) {
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
            drawLine(c, Offset(x, baseY), Offset(x, baseY - barH), sw, StrokeCap.Round)
        }
    }
}

/** 构图参考线——标准九宫格（”井”字），固定不随实际网格档位变形。 */
@Composable
internal fun GridMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val inset = 2.dp.toPx()
        for (f in floatArrayOf(0.30f, 0.70f)) {
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
internal fun FullscreenEnterMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val pad = 2.dp.toPx()
        val arm = 5.dp.toPx()
        val w = size.width
        val h = size.height
        // 每个角一个 L 形括号，开口朝外
        fun bracket(cornerX: Float, cornerY: Float, dx: Float, dy: Float) {
            drawLine(c, Offset(cornerX, cornerY), Offset(cornerX + dx * arm, cornerY), sw, StrokeCap.Round)
            drawLine(c, Offset(cornerX, cornerY), Offset(cornerX, cornerY + dy * arm), sw, StrokeCap.Round)
        }
        bracket(pad, pad, 1f, 1f)                    // 左上 ┌
        bracket(w - pad, pad, -1f, 1f)               // 右上 ┐
        bracket(pad, h - pad, 1f, -1f)               // 左下 └
        bracket(w - pad, h - pad, -1f, -1f)          // 右下 ┘
    }
}

/** 旋转——刻板意义上的「刷新」符号：顺时针圆弧 + 弧末端沿切线向前的实心箭头。 */
@Composable
internal fun RotateMark(modifier: Modifier = Modifier) {
    val c = LocalContentColor.current
    Canvas(modifier) {
        val sw = ToolMarkStrokeWidth.toPx()
        val cx = size.width / 2f; val cy = size.height / 2f
        val r = size.width / 2f - sw
        // 从 -60° 起顺时针扫 300°，缺口留在上方偏右（Material Refresh 同款布局）
        val sa = -60f; val sweep = 300f; val ea = sa + sweep
        val arc = Path().apply {
            val sr = Math.toRadians(sa.toDouble())
            moveTo(cx + r * cos(sr).toFloat(), cy + r * sin(sr).toFloat())
            arcTo(Rect(cx - r, cy - r, cx + r, cy + r), sa, sweep, false)
        }
        drawPath(arc, c, style = Stroke(sw, cap = StrokeCap.Round))
        // 箭头必须沿行进方向延伸：顺时针弧在末端角 θ 处的切线 T = (-sinθ, cosθ)，
        // 尖端 = 末端点 + T·len（越过弧末端继续向前），底边两角沿径向法线 N = (cosθ, sinθ)
        // 骑在弧末端上——这样整个图形才读作顺时针旋转，反了就成「倒带」。
        val rad = Math.toRadians(ea.toDouble())
        val px = cx + r * cos(rad).toFloat(); val py = cy + r * sin(rad).toFloat()
        val tx = -sin(rad).toFloat(); val ty = cos(rad).toFloat()
        val nx = cos(rad).toFloat(); val ny = sin(rad).toFloat()
        val len = r * 0.55f  // 尖端超出弧末端的长度
        val wid = r * 0.38f  // 底边半宽
        val head = Path().apply {
            moveTo(px + tx * len, py + ty * len)
            lineTo(px + nx * wid, py + ny * wid)
            lineTo(px - nx * wid, py - ny * wid)
            close()
        }
        drawPath(head, c)
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

/** ±1° 内算水平：够严格才有意义，又不至于因手抖级别的读数抖动反复变色。 */
private const val LevelToleranceDegrees = 1.0f

/**
 * 电子水平仪叠加层——相机式虚拟水平线。
 *
 * [rollDegrees] 是【相机机身】的滚转角（Nikon AngleLevel 0xD067），不是手机传感器：
 * 相机在三脚架上、手机在手里，只有相机自身的姿态对构图有意义。
 * 地平线按滚转角的反向旋转，因此它在画面里始终代表真水平；中央与两端的固定参考
 * 标记不随之旋转，两者的夹角就是偏差。水平时转绿，否则用琥珀色。
 *
 * [rollDegrees] 为 null（还没读到角度或机身不支持该属性）时什么都不画——
 * 宁可没有水平仪，也不画一条假的水平线。
 */
@Composable
internal fun ViewfinderLevelOverlay(
    rollDegrees: Float?,
    modifier: Modifier = Modifier
) {
    val roll = rollDegrees ?: return
    val colors = AppTheme.colors
    val horizonColor = (
        if (abs(roll) <= LevelToleranceDegrees) colors.statusConnected else colors.accentOrange
        ).copy(alpha = 0.82f)
    Canvas(modifier) {
        // 线宽与网格/直方图同一量级，半透明，不跟画面抢注意力。
        val horizonStroke = 1.2.dp.toPx()
        val refStroke = 1.5.dp.toPx()
        val innerGap = 16.dp.toPx()          // 中央留空，不压住主体
        val arm = (size.width * 0.27f).coerceAtMost(size.height * 0.42f)
        if (arm <= innerGap) return@Canvas
        val refColor = Color.White.copy(alpha = 0.45f)

        // 相机顺时针歪 3°，线就逆时针转 3°——画面里这条线才是真水平。
        rotate(degrees = -roll) {
            drawLine(
                horizonColor,
                Offset(center.x - arm, center.y),
                Offset(center.x - innerGap, center.y),
                horizonStroke,
                StrokeCap.Round
            )
            drawLine(
                horizonColor,
                Offset(center.x + innerGap, center.y),
                Offset(center.x + arm, center.y),
                horizonStroke,
                StrokeCap.Round
            )
        }

        // 固定中央参考短线（不旋转）
        val refHalf = 10.dp.toPx()
        drawLine(
            refColor,
            Offset(center.x - refHalf, center.y),
            Offset(center.x + refHalf, center.y),
            refStroke,
            StrokeCap.Round
        )
        // 固定两端刻度：水平时旋转的地平线正好压在这两个刻度上
        val tick = 4.dp.toPx()
        for (dx in floatArrayOf(-arm, arm)) {
            drawLine(
                refColor,
                Offset(center.x + dx, center.y - tick),
                Offset(center.x + dx, center.y + tick),
                refStroke,
                StrokeCap.Round
            )
        }
    }
}
