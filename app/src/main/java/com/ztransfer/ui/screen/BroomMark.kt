package com.ztransfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.ztransfer.ui.theme.AppTheme

// 归一化几何参数（均为边长的倍数），改这里即可整体调形。竖直姿态绘制，整体旋转 45°。
private const val HANDLE_TOP = 0.10f       // 木杆顶端
private const val HANDLE_BOTTOM = 0.46f    // 木杆没入箍带处
private const val HANDLE_W = 0.10f         // 木杆粗细
private const val BAND_TOP = 0.48f         // 箍带上沿
private const val BAND_BOTTOM = 0.585f     // 箍带下沿
private const val BAND_HALF = 0.14f        // 箍带半宽（宽于木杆与刷头颈部，做出"收束"轮廓）
private const val BAND_R = 0.04f           // 箍带圆角

// 刷头多边形（x 偏移相对中线，y 为边长倍数），顺时针：窄颈下探、向两侧外扩，
// 底边斜切（毛尖连线右高左低，旋转后读作"扫过"的动势），并切出两道毛缝——
// 分簇的刷毛是"扫帚"区别于铲子/簸箕的关键特征（实心刷头会读成铲头）。
private val HEAD_POINTS = arrayOf(
    -0.10f to 0.60f, 0.10f to 0.60f,                     // 颈部上沿（藏在箍带下）
    0.26f to 0.845f,                                      // 右下角（毛尖最高点）
    0.12f to 0.8585f, 0.115f to 0.72f,                    // 毛缝 2 右壁
    0.065f to 0.72f, 0.06f to 0.8642f,                    // 毛缝 2 左壁
    -0.06f to 0.8758f, -0.065f to 0.72f,                  // 毛缝 1 右壁
    -0.115f to 0.72f, -0.12f to 0.8815f,                  // 毛缝 1 左壁
    -0.26f to 0.895f                                      // 左下角（毛尖最低点）
)

/**
 * 自绘扫帚标志（"清空队列"FAB 与卡片"移出队列"按钮共用）：
 * 斜握 45° 的极简剪影——圆头木杆 + 收束箍带 + 外扩刷头。刷头底边斜切、
 * 切开两道毛缝，保住大块剪影（16dp 依然清晰）同时明确"这是刷毛不是铲刃"。
 * 纯单色填充，不依赖背景，深浅主题仅由 [color] 区分。
 */
@Composable
fun BroomMark(
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
    contentDescription: String? = null
) {
    Canvas(
        modifier = modifier
            .let { m ->
                if (contentDescription != null) {
                    m.semantics { this.contentDescription = contentDescription }
                } else m
            }
            .aspectRatio(1f)
    ) {
        val s = size.minDimension
        // 顺时针转 45°：木杆指向右上、刷毛扫向左下，经典的"挥扫"姿态。
        rotate(degrees = 45f, pivot = center) {
            // 木杆（圆头长杆）
            drawLine(
                color = color,
                start = Offset(0.5f * s, HANDLE_TOP * s),
                end = Offset(0.5f * s, HANDLE_BOTTOM * s),
                strokeWidth = HANDLE_W * s,
                cap = StrokeCap.Round
            )
            // 箍带（杆与刷头之间的收束横带）
            drawRoundRect(
                color = color,
                topLeft = Offset((0.5f - BAND_HALF) * s, BAND_TOP * s),
                size = Size(BAND_HALF * 2 * s, (BAND_BOTTOM - BAND_TOP) * s),
                cornerRadius = CornerRadius(BAND_R * s)
            )
            // 刷头（带毛缝与斜切底边的外扩多边形）
            val head = Path().apply {
                HEAD_POINTS.forEachIndexed { i, (dx, y) ->
                    if (i == 0) moveTo((0.5f + dx) * s, y * s)
                    else lineTo((0.5f + dx) * s, y * s)
                }
                close()
            }
            drawPath(head, color)
        }
    }
}
