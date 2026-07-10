package com.nikon.transfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.nikon.transfer.ui.theme.AppTheme
import kotlin.math.sqrt

// 归一化几何参数（均为边长的倍数），改这里即可整体调形。竖直姿态绘制，整体旋转 45°。
private const val HANDLE_TOP = 0.08f       // 木杆顶端
private const val HANDLE_BOTTOM = 0.55f    // 木杆没入刷头处（与刷头上沿略有重叠）
private const val HANDLE_W = 0.10f         // 木杆粗细
private const val HEAD_TOP = 0.52f         // 刷头上沿
private const val HEAD_BOTTOM = 0.90f      // 刷头下沿
private const val HEAD_TOP_HALF = 0.09f    // 刷头上沿半宽（略宽于木杆）
private const val HEAD_BOTTOM_HALF = 0.28f // 刷头下沿半宽（外扩成扇形）
private const val CORNER_R = 0.06f         // 刷头下沿两角的圆角

/**
 * 自绘扫帚标志（"清空队列"FAB 与卡片"移出队列"按钮共用）：
 * 斜握 45° 的极简剪影——修长圆头木杆 + 圆角扇形刷头，只有两个元素，
 * 小到 16dp 依然清晰可辨。纯单色填充，不依赖背景，深浅主题仅由 [color] 区分。
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
        // 顺时针转 45°：木杆指向右上、刷头扫向左下，经典的"挥扫"姿态。
        rotate(degrees = 45f, pivot = center) {
            // 木杆（圆头长杆）
            drawLine(
                color = color,
                start = Offset(0.5f * s, HANDLE_TOP * s),
                end = Offset(0.5f * s, HANDLE_BOTTOM * s),
                strokeWidth = HANDLE_W * s,
                cap = StrokeCap.Round
            )
            // 刷头：上窄下宽的扇形，底部两角圆过渡。
            // 侧边单位方向 × 圆角半径 = 圆角起点沿斜边回退的偏移。
            val edgeDx = HEAD_BOTTOM_HALF - HEAD_TOP_HALF
            val edgeDy = HEAD_BOTTOM - HEAD_TOP
            val edgeLen = sqrt(edgeDx * edgeDx + edgeDy * edgeDy)
            val ox = edgeDx / edgeLen * CORNER_R
            val oy = edgeDy / edgeLen * CORNER_R
            val head = Path().apply {
                moveTo((0.5f - HEAD_TOP_HALF) * s, HEAD_TOP * s)
                lineTo((0.5f + HEAD_TOP_HALF) * s, HEAD_TOP * s)
                lineTo((0.5f + HEAD_BOTTOM_HALF - ox) * s, (HEAD_BOTTOM - oy) * s)
                quadraticBezierTo(
                    (0.5f + HEAD_BOTTOM_HALF) * s, HEAD_BOTTOM * s,
                    (0.5f + HEAD_BOTTOM_HALF - CORNER_R) * s, HEAD_BOTTOM * s
                )
                lineTo((0.5f - HEAD_BOTTOM_HALF + CORNER_R) * s, HEAD_BOTTOM * s)
                quadraticBezierTo(
                    (0.5f - HEAD_BOTTOM_HALF) * s, HEAD_BOTTOM * s,
                    (0.5f - HEAD_BOTTOM_HALF + ox) * s, (HEAD_BOTTOM - oy) * s
                )
                close()
            }
            drawPath(head, color)
        }
    }
}
