package com.ztransfer.ui.screen

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.layout
import kotlin.math.roundToInt

/**
 * 手风琴收合：按 [progress]（1→0）缩减条目报告给布局的高度（内容顶部对齐、超出裁掉），
 * 绘制时同步淡出。高度变化是逐帧真实布局，下方内容随之连续上移——不经过条目位移
 * 动画器，不存在"移出屏幕的条目在边缘悬停"的框架问题。
 * 列表页分组收合与队列页卡片移除共用（包内共享）。
 */
fun Modifier.collapseHeight(progress: () -> Float): Modifier =
    clipToBounds().layout { measurable, constraints ->
        val placeable = measurable.measure(constraints)
        val p = progress().coerceIn(0f, 1f)
        layout(placeable.width, (placeable.height * p).roundToInt()) {
            placeable.placeRelativeWithLayer(0, 0) { alpha = p }
        }
    }
