package com.ztransfer.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
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
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
 * 提交一次。手势被取消（例如父级滚动接管）时恢复已保存值，也不会误写偏好。轻点默认向下一档
 * 循环；单项操作型波轮可通过 [onActivated] 执行自己的点击动作。
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
    onActivated: (() -> Unit)? = null,
    enabled: Boolean = true,
    wheelHeight: Dp = 50.dp,
    optionRowHeight: Dp = SETTINGS_WHEEL_ROW_HEIGHT,
    optionMaxLines: Int = 1,
    showDragHint: Boolean = true,
    accentColor: Color? = null,
    emphasized: Boolean = false,
    favoriteOption: (T) -> Boolean = { false },
    favoriteIconColor: Color? = null,
) {
    require(options.isNotEmpty()) { "ReleaseCommitWheel requires at least one option" }

    val colors = AppTheme.colors
    val resolvedAccent = accentColor ?: colors.accentBlue
    val density = LocalDensity.current
    val rowPx = with(density) { optionRowHeight.toPx() }
    val selectedIndex = options.indexOf(selected).coerceAtLeast(0)
    val latestSelectedIndex by rememberUpdatedState(selectedIndex)
    val latestOptions by rememberUpdatedState(options)
    val latestCommit by rememberUpdatedState(onValueCommitted)
    val latestDetent by rememberUpdatedState(onDetent)
    val latestActivated by rememberUpdatedState(onActivated)
    val latestFavoriteOption by rememberUpdatedState(favoriteOption)

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
    val emphasisProgress by animateFloatAsState(
        targetValue = if (emphasized) 1f else 0f,
        animationSpec = tween(220),
        label = "settingsWheelEmphasis",
    )
    val darkTheme = colors.background.luminance() < 0.5f
    val badgeText = if (darkTheme) resolvedAccent.copy(alpha = 0.94f) else resolvedAccent
    val badgeBackground = resolvedAccent.copy(alpha = if (darkTheme) 0.13f else 0.10f)
    val badgeBorder = resolvedAccent.copy(alpha = if (darkTheme) 0.25f else 0.30f)
    val enabledModifier = if (enabled) {
        modifier
    } else {
        modifier.graphicsLayer { alpha = 0.48f }
    }
    Box(
        modifier = enabledModifier
            .height(wheelHeight)
            .clip(shape)
            .background(colors.glassSurface)
            .background(
                Brush.verticalGradient(
                    listOf(colors.glassHighlightTop, colors.glassHighlightBottom)
                )
            )
            .background(
                resolvedAccent.copy(
                    alpha = (if (darkTheme) 0.045f else 0.035f) +
                        (if (darkTheme) 0.105f else 0.075f) * emphasisProgress,
                )
            )
            .border(
                width = when {
                    dragging -> 1.5.dp
                    emphasisProgress > 0f -> (1f + 0.35f * emphasisProgress).dp
                    else -> 1.dp
                },
                brush = if (dragging || emphasisProgress > 0f) {
                    Brush.verticalGradient(
                        listOf(
                            resolvedAccent.copy(alpha = 0.92f),
                            resolvedAccent.copy(alpha = 0.38f + 0.30f * emphasisProgress),
                        )
                    )
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
                    if (latestFavoriteOption(options[selectedIndex])) append("★ ")
                    append(optionLabel(options[selectedIndex]))
                }
            }
            .pointerInput(options.size, rowPx, enabled) {
                if (!enabled || options.size <= 1) return@pointerInput
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
                latestActivated?.let { activate ->
                    activate()
                    return@clickable
                }
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
                val itemAlpha = if (distance < 0.5f) 1f else 0.38f
                val itemOffsetY = (rowPx * (index - position)).roundToInt()
                val itemModifier = Modifier
                    .fillMaxWidth()
                    // The lambda offset overload places every full-width text row in a separate
                    // graphics layer. On screenshot capture that layer boundary can become a faint
                    // wheel-wide band. A layout-only offset keeps identical motion without a layer.
                    .layout { measurable, constraints ->
                        val placeable = measurable.measure(constraints)
                        layout(placeable.width, placeable.height) {
                            placeable.placeRelative(0, itemOffsetY)
                        }
                    }
                val textStyle = MaterialTheme.typography.labelMedium
                val textWeight = if (distance < 0.5f) {
                    FontWeight.SemiBold
                } else {
                    FontWeight.Normal
                }
                if (favoriteOption(options[index])) {
                    Row(
                        modifier = itemModifier,
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Star,
                            contentDescription = null,
                            tint = (favoriteIconColor ?: resolvedAccent).copy(alpha = itemAlpha),
                            modifier = Modifier.size(13.dp),
                        )
                        Spacer(Modifier.width(3.dp))
                        Text(
                            text = optionLabel(options[index]),
                            style = textStyle,
                            fontSize = 14.sp,
                            lineHeight = if (optionMaxLines > 1) 15.sp else 16.sp,
                            fontWeight = textWeight,
                            color = colors.onBackground.copy(alpha = itemAlpha),
                            maxLines = optionMaxLines,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                } else {
                    Text(
                        text = optionLabel(options[index]),
                        style = textStyle,
                        fontSize = 14.sp,
                        lineHeight = if (optionMaxLines > 1) 15.sp else 16.sp,
                        fontWeight = textWeight,
                        color = if (emphasized && distance < 0.5f) {
                            resolvedAccent.copy(alpha = itemAlpha)
                        } else {
                            colors.onBackground.copy(alpha = itemAlpha)
                        },
                        textAlign = TextAlign.Center,
                        maxLines = optionMaxLines,
                        overflow = TextOverflow.Ellipsis,
                        modifier = itemModifier,
                    )
                }
            }
        }

        if (showDragHint) {
            // 纯视觉拖动提示：不安装任何手势或点击处理，事件仍完整交给外层波轮。
            Text(
                text = "↕",
                color = colors.onBackground.copy(alpha = 0.30f),
                fontSize = 10.sp,
                lineHeight = 10.sp,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 8.dp, bottom = 5.dp)
                    .graphicsLayer { alpha = labelAlpha }
                    .clearAndSetSemantics { },
            )
        }
    }
}
