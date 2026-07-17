package com.ztransfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.ztransfer.ui.theme.AppTheme

/**
 * 自绘小标志集合：与信号按钮的信号条同族——统一的"圆头杆件"绘制语言
 *（圆头线段、克制的几何、纯单色），比 Material 通用图标更贴合本 App 的气质。
 */

private fun Modifier.markSemantics(contentDescription: String?): Modifier =
    if (contentDescription != null) {
        semantics { this.contentDescription = contentDescription }
    } else this

/** 筛选标志：三条递减的圆头横杠（漏斗的极简形）。 */
@Composable
fun FilterMark(
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
    contentDescription: String? = null
) {
    Canvas(modifier = modifier.markSemantics(contentDescription).aspectRatio(1f)) {
        val s = size.minDimension
        val stroke = 0.13f * s
        fun bar(y: Float, halfWidth: Float) = drawLine(
            color = color,
            start = Offset((0.5f - halfWidth) * s, y * s),
            end = Offset((0.5f + halfWidth) * s, y * s),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        bar(0.24f, 0.40f)
        bar(0.50f, 0.25f)
        bar(0.76f, 0.10f)
    }
}

/**
 * 监看标志：取景框四角 + 中心镜头圆环（监看/遥控拍摄的极简形）。
 * 四角 = 取景/监看；中心用【圆环而非实心点】表示镜头——既把语义拉回"相机"，
 * 又避开与预览页 AF 对焦框（实心角框）撞形。
 */
@Composable
fun RemoteMark(
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
    contentDescription: String? = null
) {
    Canvas(modifier = modifier.markSemantics(contentDescription).aspectRatio(1f)) {
        val s = size.minDimension
        val stroke = 0.13f * s
        val edge = 0.16f      // 角点到边缘的距离
        val arm = 0.18f       // 角臂长度
        fun corner(x: Float, y: Float, dx: Float, dy: Float) {
            drawLine(
                color = color,
                start = Offset(x * s, y * s),
                end = Offset((x + arm * dx) * s, y * s),
                strokeWidth = stroke,
                cap = StrokeCap.Round
            )
            drawLine(
                color = color,
                start = Offset(x * s, y * s),
                end = Offset(x * s, (y + arm * dy) * s),
                strokeWidth = stroke,
                cap = StrokeCap.Round
            )
        }
        corner(edge, edge, 1f, 1f)             // 左上
        corner(1f - edge, edge, -1f, 1f)       // 右上
        corner(edge, 1f - edge, 1f, -1f)       // 左下
        corner(1f - edge, 1f - edge, -1f, -1f) // 右下
        // 中心镜头圆环：描边比杆件略细，半径留出与四角的呼吸间距。
        drawCircle(
            color = color,
            radius = 0.12f * s,
            center = Offset(0.5f * s, 0.5f * s),
            style = Stroke(width = 0.10f * s)
        )
    }
}

/** 回到顶部标志：顶杠 + 上指箭头。 */
@Composable
fun BackToTopMark(
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
    contentDescription: String? = null
) {
    Canvas(modifier = modifier.markSemantics(contentDescription).aspectRatio(1f)) {
        val s = size.minDimension
        val stroke = 0.13f * s
        // 顶杠（目的地）
        drawLine(
            color = color,
            start = Offset(0.24f * s, 0.16f * s),
            end = Offset(0.76f * s, 0.16f * s),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        // 箭头竖杆
        drawLine(
            color = color,
            start = Offset(0.5f * s, 0.38f * s),
            end = Offset(0.5f * s, 0.86f * s),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        // 箭头两翼
        drawLine(
            color = color,
            start = Offset(0.5f * s, 0.38f * s),
            end = Offset(0.29f * s, 0.59f * s),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            color = color,
            start = Offset(0.5f * s, 0.38f * s),
            end = Offset(0.71f * s, 0.59f * s),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
    }
}
