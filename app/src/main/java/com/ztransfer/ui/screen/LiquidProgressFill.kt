package com.ztransfer.ui.screen

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.sin

private const val LIQUID_PROGRESS_TWO_PI = 6.2831855f
private const val DEFAULT_CYCLE_MILLIS = 2_200
private const val DEFAULT_SEGMENTS = 8
private val DEFAULT_AMPLITUDE = 2.dp

private fun smoothStep(start: Float, end: Float, value: Float): Float {
    val t = ((value - start) / (end - start)).coerceIn(0f, 1f)
    return t * t * (3f - 2f * t)
}

/** 波浪只在进度中段完整出现，起点和终点自然压回竖直边缘。 */
internal fun liquidProgressWaveEnvelope(progress: Float): Float {
    val p = normalizedTransferProgress(progress)
    val enter = smoothStep(0.05f, 0.14f, p)
    val exit = 1f - smoothStep(0.90f, 0.98f, p)
    return enter * exit
}

/** 每个任务获得稳定相位；不创建 Random，也不会在重组时改变波形。 */
internal fun liquidProgressWaveSeed(seedKey: Long?): Float {
    var hash = (seedKey ?: 0L).hashCode()
    hash = (hash xor (hash ushr 16)) * 0x45D9F3B
    hash = hash xor (hash ushr 16)
    return (hash and 0xFFFF) / 65535f
}

/** 三个周期谐波叠加成连续、不规则但首尾无跳变的单位波形。 */
internal fun liquidProgressWaveUnitOffset(
    normalizedY: Float,
    phaseTurns: Float,
    seedTurns: Float,
    spatialScale: Float = 1f,
): Float {
    val y = normalizedY.coerceIn(0f, 1f) * spatialScale.coerceAtLeast(0f)
    val time = phaseTurns * LIQUID_PROGRESS_TWO_PI
    val seed = seedTurns * LIQUID_PROGRESS_TWO_PI
    return 0.64f * sin(time + y * LIQUID_PROGRESS_TWO_PI * 1.15f + seed) +
        0.24f * sin(-2f * time + y * LIQUID_PROGRESS_TWO_PI * 2.40f + seed * 0.73f) +
        0.12f * sin(3f * time + y * LIQUID_PROGRESS_TWO_PI * 3.35f + seed * 1.31f)
}

/**
 * 轻量液态进度填充。调用方负责用自身形状裁切本层；进度、相位都只在绘制阶段读取，
 * 不会逐帧重组内容或布局。波幅不可见时不创建无限动画。
 */
@Composable
internal fun LiquidProgressFill(
    progress: () -> Float,
    waveEligible: Boolean,
    seedKey: Long?,
    color: Color,
    modifier: Modifier = Modifier,
    amplitude: Dp = DEFAULT_AMPLITUDE,
    cycleMillis: Int = DEFAULT_CYCLE_MILLIS,
    segments: Int = DEFAULT_SEGMENTS,
    spatialScale: Float = 1f,
    label: String = "liquidProgress",
) {
    val fillPath = remember { Path() }
    val seedTurns = remember(seedKey) { liquidProgressWaveSeed(seedKey) }
    val latestProgress by rememberUpdatedState(progress)
    val waveVisible by remember(waveEligible) {
        derivedStateOf {
            waveEligible && liquidProgressWaveEnvelope(latestProgress()) > 0.001f
        }
    }
    val waveMotion = if (waveVisible) {
        rememberInfiniteTransition(label = label).animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(
                    durationMillis = cycleMillis.coerceAtLeast(1),
                    easing = LinearEasing,
                ),
                repeatMode = RepeatMode.Restart,
            ),
            label = "${label}Phase",
        )
    } else {
        null
    }
    val segmentCount = segments.coerceAtLeast(2)

    Canvas(modifier = modifier) {
        // 协议层异常值也必须在进入 Canvas 前归零，避免 NaN/Infinity 污染 Path。
        val p = normalizedTransferProgress(progress())
        if (p <= 0f) return@Canvas

        val fillWidth = size.width * p
        val envelope = liquidProgressWaveEnvelope(p)
        if (waveMotion == null || envelope <= 0.001f) {
            drawRect(color = color, size = Size(fillWidth, size.height))
            return@Canvas
        }

        val phaseTurns = waveMotion.value
        val phaseRadians = phaseTurns * LIQUID_PROGRESS_TWO_PI
        val breathing = 0.90f +
            0.10f * sin(2f * phaseRadians + seedTurns * LIQUID_PROGRESS_TWO_PI)
        val waveAmplitude = amplitude.toPx().coerceAtLeast(0f) * envelope * breathing
        val segmentHeight = size.height / segmentCount

        fillPath.reset()
        val topX = (
            fillWidth + waveAmplitude * liquidProgressWaveUnitOffset(
                normalizedY = 0f,
                phaseTurns = phaseTurns,
                seedTurns = seedTurns,
                spatialScale = spatialScale,
            )
            ).coerceIn(0f, size.width)
        fillPath.moveTo(0f, 0f)
        fillPath.lineTo(topX, 0f)

        var currentX = topX
        var currentY = 0f
        for (index in 1..segmentCount) {
            val nextY = segmentHeight * index
            val nextX = (
                fillWidth + waveAmplitude * liquidProgressWaveUnitOffset(
                    normalizedY = index.toFloat() / segmentCount,
                    phaseTurns = phaseTurns,
                    seedTurns = seedTurns,
                    spatialScale = spatialScale,
                )
                ).coerceIn(0f, size.width)
            fillPath.quadraticTo(
                currentX,
                currentY,
                (currentX + nextX) / 2f,
                (currentY + nextY) / 2f,
            )
            currentX = nextX
            currentY = nextY
        }
        fillPath.quadraticTo(currentX, currentY, currentX, currentY)
        fillPath.lineTo(0f, size.height)
        fillPath.close()
        drawPath(path = fillPath, color = color)
    }
}
