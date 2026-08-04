package com.ztransfer.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import com.ztransfer.ui.theme.AppTheme
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

private val SETTINGS_WHEEL_ROW_HEIGHT = 18.dp

internal fun wheelPositionAfterDrag(
    startIndex: Int,
    accumulatedDy: Float,
    rowHeightPx: Float,
    lastIndex: Int,
): Float {
    if (lastIndex <= 0 || rowHeightPx <= 0f) return 0f
    return (startIndex - accumulatedDy / rowHeightPx).coerceIn(0f, lastIndex.toFloat())
}

internal fun wheelReleaseIndex(position: Float, lastIndex: Int): Int =
    position.roundToInt().coerceIn(0, lastIndex.coerceAtLeast(0))

/**
 * 设置页专用的紧凑拨轮。
 *
 * 拖动期间只更新本地预览位置，不会调用 [onValueCommitted]；正常松手时才吸附到最近一档并
 * 提交一次。手势被取消（例如父级滚动接管）时恢复已保存值，也不会误写偏好。轻点相当于一次
 * 完整的按下/松开，向下一档循环，方便无障碍服务和不习惯拖动的用户使用。
 */
@Composable
internal fun <T> ReleaseCommitWheel(
    options: List<T>,
    selected: T,
    optionLabel: (T) -> String,
    onValueCommitted: (T) -> Unit,
    modifier: Modifier = Modifier,
    label: String? = null,
    onDetent: () -> Unit = {},
    enabled: Boolean = true,
) {
    require(options.isNotEmpty()) { "ReleaseCommitWheel requires at least one option" }

    val colors = AppTheme.colors
    val density = LocalDensity.current
    val rowPx = with(density) { SETTINGS_WHEEL_ROW_HEIGHT.toPx() }
    val selectedIndex = options.indexOf(selected).coerceAtLeast(0)
    val latestSelectedIndex by rememberUpdatedState(selectedIndex)
    val latestOptions by rememberUpdatedState(options)
    val latestCommit by rememberUpdatedState(onValueCommitted)
    val latestDetent by rememberUpdatedState(onDetent)

    var dragging by remember { mutableStateOf(false) }
    var position by remember { mutableFloatStateOf(selectedIndex.toFloat()) }
    var dragStartIndex by remember { mutableIntStateOf(selectedIndex) }
    var lastPreviewDetent by remember { mutableIntStateOf(selectedIndex) }

    LaunchedEffect(selectedIndex, dragging, options.size) {
        if (!dragging) position = selectedIndex.toFloat()
    }

    val shape = RoundedCornerShape(13.dp)
    val labelAlpha by animateFloatAsState(
        targetValue = if (dragging) 0f else 1f,
        animationSpec = tween(if (dragging) 90 else 180),
        label = "settingsWheelLabel",
    )
    val darkTheme = colors.background.luminance() < 0.5f
    val badgeText = if (darkTheme) Color(0xFFC6E2E8) else Color(0xFF496872)
    val badgeBackground = if (darkTheme) {
        Color(0xFF8BB9C7).copy(alpha = 0.14f)
    } else {
        Color(0xFFE3F0F3).copy(alpha = 0.92f)
    }
    val badgeBorder = if (darkTheme) {
        Color(0xFFB2D5DE).copy(alpha = 0.24f)
    } else {
        Color(0xFF88AAB5).copy(alpha = 0.34f)
    }
    val enabledModifier = if (enabled) {
        modifier
    } else {
        modifier.graphicsLayer { alpha = 0.48f }
    }
    Box(
        modifier = enabledModifier
            .height(54.dp)
            .clip(shape)
            .background(colors.glassSurface)
            .background(
                Brush.verticalGradient(
                    listOf(colors.glassHighlightTop, colors.glassHighlightBottom)
                )
            )
            .border(
                width = if (dragging) 1.5.dp else 1.dp,
                brush = if (dragging) {
                    Brush.verticalGradient(listOf(colors.accentBlue, colors.accentBlue))
                } else {
                    Brush.verticalGradient(
                        listOf(colors.glassBorderTop, colors.glassBorderBottom)
                    )
                },
                shape = shape
            )
            .semantics {
                contentDescription = buildString {
                    if (!label.isNullOrBlank()) append("$label, ")
                    append(optionLabel(options[selectedIndex]))
                }
            }
            .pointerInput(options.size, rowPx, enabled) {
                if (!enabled) return@pointerInput
                var accumulatedDy = 0f
                try {
                    detectVerticalDragGestures(
                        onDragStart = {
                            dragging = true
                            dragStartIndex = latestSelectedIndex
                            lastPreviewDetent = dragStartIndex
                            accumulatedDy = 0f
                            position = dragStartIndex.toFloat()
                        },
                        onDragEnd = {
                            val currentOptions = latestOptions
                            val target = wheelReleaseIndex(position, currentOptions.lastIndex)
                            position = target.toFloat()
                            dragging = false
                            if (target != latestSelectedIndex) {
                                latestCommit(currentOptions[target])
                            }
                        },
                        onDragCancel = {
                            position = latestSelectedIndex.toFloat()
                            dragging = false
                        },
                    ) { change, dy ->
                        change.consume()
                        accumulatedDy += dy
                        position = wheelPositionAfterDrag(
                            startIndex = dragStartIndex,
                            accumulatedDy = accumulatedDy,
                            rowHeightPx = rowPx,
                            lastIndex = latestOptions.lastIndex,
                        )
                        val detent = wheelReleaseIndex(position, latestOptions.lastIndex)
                        if (detent != lastPreviewDetent) {
                            latestDetent()
                            lastPreviewDetent = detent
                        }
                    }
                } finally {
                    if (dragging) {
                        position = latestSelectedIndex.toFloat()
                        dragging = false
                    }
                }
            }
            .clickable(enabled = enabled) {
                val currentOptions = latestOptions
                val next = (latestSelectedIndex + 1) % currentOptions.size
                if (next != latestSelectedIndex) {
                    latestDetent()
                    latestCommit(currentOptions[next])
                }
            }
    ) {
        if (label != null) {
            ControlTileCornerBadge(
                text = label,
                textColor = badgeText,
                backgroundColor = badgeBackground,
                borderColor = badgeBorder,
                borderWidth = 0.5.dp,
                shape = RoundedCornerShape(bottomEnd = 5.dp),
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .height(15.dp)
                    .graphicsLayer { alpha = labelAlpha },
            )
        }

        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            val firstVisible = floor(position).toInt() - 1
            val lastVisible = ceil(position).toInt() + 1
            val idleCenter = wheelReleaseIndex(position, options.lastIndex)
            for (index in firstVisible..lastVisible) {
                if (index !in options.indices) continue
                // 与监看参数拨轮一致：静止时只显示中心真值，只有实际拖动后才显示邻档。
                if (!dragging && index != idleCenter) continue
                val distance = abs(index - position)
                Text(
                    text = optionLabel(options[index]),
                    style = MaterialTheme.typography.labelMedium,
                    fontSize = 14.sp,
                    lineHeight = 16.sp,
                    fontWeight = if (distance < 0.5f) FontWeight.SemiBold else FontWeight.Normal,
                    color = colors.onBackground.copy(
                        alpha = if (distance < 0.5f) 1f else 0.38f
                    ),
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .offset {
                            IntOffset(
                                x = 0,
                                y = (rowPx * (index - position)).roundToInt(),
                            )
                        },
                )
            }
        }
    }
}
