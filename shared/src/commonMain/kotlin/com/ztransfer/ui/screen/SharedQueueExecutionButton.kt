package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion

/** 与状态胶囊同材质的顶部队列操作按钮，不跟随可选按钮皮肤。 */
@Composable
fun SharedQueueExecutionButton(
    startDescription: String,
    pauseDescription: String,
    pauseScheduledDescription: String,
    control: QueueExecutionControl,
    pauseRequested: Boolean,
    startEnabled: Boolean,
    onStart: () -> Unit,
    onPause: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val accent by animateColorAsState(
        targetValue = if (control == QueueExecutionControl.START) {
            colors.accentBlue
        } else {
            colors.accentYellow
        },
        animationSpec = tween(180),
        label = "queueExecutionAccent",
    )
    val activeProgress by animateFloatAsState(
        targetValue = if (
            control == QueueExecutionControl.PAUSE && pauseRequested
        ) 1f else 0f,
        animationSpec = tween(180),
        label = "queueExecutionActive",
    )
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val pressScale by animateFloatAsState(
        targetValue = if (pressed &&
            (control == QueueExecutionControl.PAUSE || startEnabled)
        ) {
            0.92f
        } else {
            1f
        },
        animationSpec = if (pressed) tween(80) else Motion.bouncy(),
        label = "queueExecutionPress",
    )
    val enabled = control == QueueExecutionControl.PAUSE || startEnabled
    val visualAlpha = if (enabled) 1f else 0.45f
    // 与通用毛玻璃按钮一致，不让半透明 Surface、投影和缩放共用矩形 RenderNode。
    // 部分 GPU 会把那层缓存边界显成浅色方框；固定外层尺寸、只改变圆形内容尺寸，
    // 禁用态透明度直接落到绘制颜色上，深色/浅色及按压态都不会生成矩形边框。
    Box(
        modifier = modifier.size(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size((32f * pressScale).dp)
                .clip(CircleShape)
                .background(
                    colors.glassSurface.copy(
                        alpha = colors.glassSurface.alpha * visualAlpha,
                    )
                )
                .background(
                    Brush.verticalGradient(
                        listOf(
                            colors.glassHighlightTop.copy(
                                alpha = colors.glassHighlightTop.alpha * visualAlpha,
                            ),
                            colors.glassHighlightBottom.copy(
                                alpha = colors.glassHighlightBottom.alpha * visualAlpha,
                            ),
                        )
                    )
                )
                .background(
                    accent.copy(alpha = 0.16f * activeProgress * visualAlpha)
                )
                .clickable(
                    enabled = enabled,
                    role = Role.Button,
                    interactionSource = interactionSource,
                    indication = null,
                    onClick = if (control == QueueExecutionControl.START) onStart else onPause,
                ),
            contentAlignment = Alignment.Center,
        ) {
            AnimatedContent(
                targetState = control,
                transitionSpec = {
                    (fadeIn(tween(150, delayMillis = 35)) +
                        scaleIn(initialScale = 0.72f, animationSpec = tween(175, delayMillis = 25)))
                        .togetherWith(
                            fadeOut(tween(100)) +
                                scaleOut(targetScale = 0.72f, animationSpec = tween(120))
                        )
                },
                contentAlignment = Alignment.Center,
                label = "queueExecutionIcon",
            ) { current ->
                Icon(
                    imageVector = if (current == QueueExecutionControl.START) {
                        Icons.Rounded.PlayArrow
                    } else {
                        Icons.Default.Pause
                    },
                    contentDescription = when {
                        current == QueueExecutionControl.START -> startDescription
                        pauseRequested -> pauseScheduledDescription
                        else -> pauseDescription
                    },
                    tint = accent.copy(alpha = accent.alpha * visualAlpha),
                    modifier = Modifier.size(
                        if (current == QueueExecutionControl.START) 21.dp else 18.dp
                    ),
                )
            }
        }
    }
}
