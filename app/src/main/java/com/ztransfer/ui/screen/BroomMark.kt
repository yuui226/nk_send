package com.ztransfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

// 归一化几何参数（均为边长的倍数），改这里即可整体调形。
// 竖直姿态绘制、整体旋转 45°：杆指向右上，毛束向左下甩出。
private const val HANDLE_TOP = 0.07f       // 木杆顶端
private const val HANDLE_BOTTOM = 0.44f    // 木杆没入箍带处
private const val HANDLE_W = 0.09f         // 木杆粗细
private const val BAND_Y = 0.505f          // 箍带（圆头粗横杠，略宽于杆）
private const val BAND_HALF = 0.105f
private const val BAND_W = 0.095f
private const val STRAND_TOP = 0.565f      // 毛束根部（略叠进箍带下方）
private const val STRAND_W = 0.05f         // 单根毛粗细
// 毛的控制点右移量：毛束先向右微鼓、再向左甩出——鞭梢式的弧线，整束同向弯曲。
private const val STRAND_CTRL_PULL = 0.045f
private const val STRAND_CTRL_SINK = 0.01f

// 五根毛：根部 x（窄间距，读作"一束"而非叉齿）/ 毛尖 (x, y)（沿弧线错落，斜切出扫过的动势）。
private val STRAND_START_X = floatArrayOf(0.425f, 0.4625f, 0.5f, 0.5375f, 0.575f)
private val STRAND_END = arrayOf(
    0.305f to 0.865f,
    0.365f to 0.895f,
    0.43f to 0.915f,
    0.50f to 0.925f,
    0.575f to 0.925f
)

// 扬尘两粒 (cx, cy, r)——【屏幕坐标】，落在旋转后毛尖甩出的左下方向。
// 只在足够大的尺寸绘制（见 SPECK_MIN_DP）：16dp 的卡片小按钮上会糊成噪点。
private val SPECKS = arrayOf(
    floatArrayOf(0.085f, 0.775f, 0.017f),
    floatArrayOf(0.175f, 0.925f, 0.012f)
)
private val SPECK_MIN_DP = 22.dp

/**
 * 自绘扫帚标志（"清空队列"FAB 与卡片"移出队列"按钮共用）：
 * 斜握 45° 的挥扫姿态——圆头木杆 + 箍带 + 五根鞭梢式曲线毛束（窄扇、整束同向
 * 弯曲、毛尖沿弧线错落），大尺寸下加两粒扬尘。圆头线条与信号条/筛选标同族。
 * 纯单色，深浅主题仅由 [color] 区分。
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
        rotate(degrees = 45f, pivot = center) {
            // 木杆（圆头长杆）
            drawLine(
                color = color,
                start = Offset(0.5f * s, HANDLE_TOP * s),
                end = Offset(0.5f * s, HANDLE_BOTTOM * s),
                strokeWidth = HANDLE_W * s,
                cap = StrokeCap.Round
            )
            // 箍带（圆头粗横杠）
            drawLine(
                color = color,
                start = Offset((0.5f - BAND_HALF) * s, BAND_Y * s),
                end = Offset((0.5f + BAND_HALF) * s, BAND_Y * s),
                strokeWidth = BAND_W * s,
                cap = StrokeCap.Round
            )
            // 毛束：五根二次贝塞尔曲线，先右鼓再左甩
            for (i in STRAND_START_X.indices) {
                val sx = STRAND_START_X[i]
                val (ex, ey) = STRAND_END[i]
                val strand = Path().apply {
                    moveTo(sx * s, STRAND_TOP * s)
                    quadraticBezierTo(
                        ((sx + ex) / 2 + STRAND_CTRL_PULL) * s,
                        ((STRAND_TOP + ey) / 2 + STRAND_CTRL_SINK) * s,
                        ex * s, ey * s
                    )
                }
                drawPath(strand, color, style = Stroke(width = STRAND_W * s, cap = StrokeCap.Round))
            }
        }
        // 扬尘（屏幕坐标，旋转之外；小尺寸不画）
        if (s >= SPECK_MIN_DP.toPx()) {
            for ((cx, cy, r) in SPECKS) {
                drawCircle(color, radius = r * s, center = Offset(cx * s, cy * s))
            }
        }
    }
}
