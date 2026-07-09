package com.nikon.transfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import com.nikon.transfer.ui.theme.AppTheme

// 归一化几何参数（均为高度的倍数），改这里即可整体调形。
private const val BAR = 0.13f      // 横杠厚度
private const val DIAG = 0.15f     // 斜杠的水平厚度
private const val ZW = 0.62f       // 单个 Z 的宽度（剪切前）
private const val SHEAR = 0.30f    // 斜体剪切量（顶部右移，≈17°）
private const val DX = 0.44f       // 右 Z 相对左 Z 的偏移
private const val GAP = 0.06f      // 两 Z 交叠处的分隔缝
private const val ASPECT = ZW + SHEAR + DX   // 整个标志的宽高比

/**
 * 尼康 Z 系列风格的双 Z 标志（自绘矢量，无图片资源）：两个斜体 Z 错位叠放，
 * 右 Z 在上层，交叠处留一道分隔缝。缝隙用 BlendMode.Clear 在离屏层上冲出，
 * 因此适用于任何背景（包括毛玻璃半透明底）。调用方只需约束高度，宽度按比例自适应。
 */
@Composable
fun ZMark(
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground
) {
    Canvas(
        modifier = modifier
            .aspectRatio(ASPECT)
            // Clear 混合需要离屏合成，否则会把窗口背景也冲掉（黑洞）。
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
    ) {
        val h = size.height
        val t = BAR * h
        val s = DIAG * h
        val w = ZW * h
        val shear = SHEAR * h

        // 单个 Z 的轮廓：先按直立 Z 取点，再逐点做斜体剪切 x' = x + shear·(1 - y/h)，
        // 平行边剪切后保持平行，斜杠的水平厚度不变。顺时针 10 点。
        fun zPath(offsetX: Float) = Path().apply {
            fun pt(x: Float, y: Float) = Offset(offsetX + x + shear * (1f - y / h), y)
            val p = listOf(
                pt(0f, 0f), pt(w, 0f), pt(w, t),   // 顶杠：上缘与右端
                pt(s, h - t),                      // 沿斜杠右下缘降至底杠上缘
                pt(w, h - t), pt(w, h), pt(0f, h), // 底杠
                pt(0f, h - t),                     // 底杠左端上行
                pt(w - s, t), pt(0f, t)            // 沿斜杠左上缘升回顶杠下缘
            )
            moveTo(p[0].x, p[0].y)
            for (i in 1 until p.size) lineTo(p[i].x, p[i].y)
            close()
        }

        val leftZ = zPath(0f)
        val rightZ = zPath(DX * h)

        drawPath(leftZ, color)
        // 右 Z 在上层：先把"右 Z 外扩一圈缝宽"的区域从已绘内容中冲掉，再实填右 Z，
        // 左 Z 上便留出干净的分隔缝——正是尼康 Z 标的层叠效果。
        val gapStroke = Stroke(width = GAP * h * 2, join = StrokeJoin.Round)
        drawPath(rightZ, Color.Black, style = gapStroke, blendMode = BlendMode.Clear)
        drawPath(rightZ, Color.Black, blendMode = BlendMode.Clear)
        drawPath(rightZ, color)
    }
}
