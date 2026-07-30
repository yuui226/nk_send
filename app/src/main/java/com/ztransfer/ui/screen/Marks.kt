package com.ztransfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
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

/**
 * 筛选标志：直观的漏斗轮廓。
 * 与信号条、监看标志保持同一套单色圆头线条，收窄后的短尾明确表达
 * “内容经条件筛选后输出”，避免旧的三条横杠被误认为排序或列表密度。
 */
@Composable
fun FilterMark(
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
    contentDescription: String? = null
) {
    Canvas(modifier = modifier.markSemantics(contentDescription).aspectRatio(1f)) {
        val s = size.minDimension
        val funnel = Path().apply {
            // 宽口→斜肩→收窄通道→短尾：封闭轮廓在小尺寸下仍能一眼认成漏斗。
            moveTo(0.16f * s, 0.20f * s)
            lineTo(0.84f * s, 0.20f * s)
            lineTo(0.59f * s, 0.50f * s)
            lineTo(0.59f * s, 0.76f * s)
            lineTo(0.41f * s, 0.86f * s)
            lineTo(0.41f * s, 0.50f * s)
            close()
        }
        drawPath(
            path = funnel,
            color = color,
            style = Stroke(
                width = 0.075f * s,
                cap = StrokeCap.Round,
                join = StrokeJoin.Round
            )
        )
    }
}

/** 监看标志：一眼可识别的极简相机轮廓，镜头与快门灯只保留必要细节。 */
@Composable
fun RemoteMark(
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
    contentDescription: String? = null
) {
    Canvas(modifier = modifier.markSemantics(contentDescription).aspectRatio(1f)) {
        val s = size.minDimension
        val stroke = 0.075f * s
        // 相机机身：顶部把镜头座直接并入轮廓，避免在 24dp 下出现重叠杂线。
        val body = Path().apply {
            moveTo(0.20f * s, 0.30f * s)
            lineTo(0.30f * s, 0.30f * s)
            lineTo(0.36f * s, 0.20f * s)
            quadraticBezierTo(0.38f * s, 0.17f * s, 0.42f * s, 0.17f * s)
            lineTo(0.57f * s, 0.17f * s)
            quadraticBezierTo(0.61f * s, 0.17f * s, 0.63f * s, 0.20f * s)
            lineTo(0.70f * s, 0.30f * s)
            lineTo(0.80f * s, 0.30f * s)
            quadraticBezierTo(0.89f * s, 0.30f * s, 0.89f * s, 0.39f * s)
            lineTo(0.89f * s, 0.73f * s)
            quadraticBezierTo(0.89f * s, 0.82f * s, 0.80f * s, 0.82f * s)
            lineTo(0.20f * s, 0.82f * s)
            quadraticBezierTo(0.11f * s, 0.82f * s, 0.11f * s, 0.73f * s)
            lineTo(0.11f * s, 0.39f * s)
            quadraticBezierTo(0.11f * s, 0.30f * s, 0.20f * s, 0.30f * s)
            close()
        }
        drawPath(
            path = body,
            color = color,
            style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round)
        )
        // 大镜头圆环是最强识别特征；略偏左给右上的快门灯留出呼吸空间。
        drawCircle(
            color = color,
            radius = 0.16f * s,
            center = Offset(0.48f * s, 0.56f * s),
            style = Stroke(width = stroke)
        )
        drawCircle(
            color = color,
            radius = 0.035f * s,
            center = Offset(0.76f * s, 0.42f * s)
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
