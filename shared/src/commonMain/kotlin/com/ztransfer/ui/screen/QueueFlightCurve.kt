@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.ui.geometry.Offset
import kotlin.math.abs

@kotlin.native.HiddenFromObjC
val QueueFlightEasing = CubicBezierEasing(0.5f, 0f, 0.8f, 0.35f)

/** 列表、单张预览与合集预览共用的入队弧线；只接收像素参数，不持有任何 Compose 状态。 */
@kotlin.native.HiddenFromObjC
fun queueFlightBezierPoint(
    progress: Float,
    start: Offset,
    end: Offset,
    liftBasePx: Float,
    maxLiftPx: Float,
    minApexYPx: Float,
    maxBowPx: Float,
    bowFadeDistancePx: Float,
): Offset {
    val t = progress.coerceIn(0f, 1f)
    val dx = abs(end.x - start.x)
    val lift = (0.35f * dx + liftBasePx).coerceAtMost(maxLiftPx)
    val controlY = maxOf(
        minOf(start.y, end.y) - lift,
        (4f * minApexYPx - start.y - end.y) / 2f,
    )
    val bow = maxBowPx * (1f - (dx / bowFadeDistancePx).coerceAtMost(1f))
    val controlX = (start.x + end.x) / 2f - bow
    val remaining = 1f - t
    return Offset(
        x = remaining * remaining * start.x +
            2f * remaining * t * controlX + t * t * end.x,
        y = remaining * remaining * start.y +
            2f * remaining * t * controlY + t * t * end.y,
    )
}
