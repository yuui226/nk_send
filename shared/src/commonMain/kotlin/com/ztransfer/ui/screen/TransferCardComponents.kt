package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask

/** Already-localized display values. No camera service, Android resources or number formatter here. */
data class TransferTaskCardText(
    val speedText: String?,
    val transferDuration: String?,
    val generationDuration: String?,
    val effectText: String?,
    val fileSizeText: String,
    val failureText: String,
)

private enum class TransferCardPillTone { SIZE, SPEED, EFFECT, TRANSFER_DURATION, GENERATION_DURATION }

private enum class TransferCardVisualState { WAITING, TRANSFERRING, GENERATING, COMPLETED, FAILED, CANCELLED }

private fun transferCardVisualState(task: TransferTask): TransferCardVisualState = when {
    task.isGeneratingFrame -> TransferCardVisualState.GENERATING
    task.status == TransferStatus.WAITING -> TransferCardVisualState.WAITING
    task.status == TransferStatus.TRANSFERING -> TransferCardVisualState.TRANSFERRING
    task.status == TransferStatus.COMPLETED -> TransferCardVisualState.COMPLETED
    task.status == TransferStatus.FAILED -> TransferCardVisualState.FAILED
    else -> TransferCardVisualState.CANCELLED
}

@Composable
fun SharedTransferRetryButton(
    visible: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
) {
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn() + scaleIn(
            initialScale = 0.75f,
            transformOrigin = TransformOrigin(1f, 0f),
        ),
        exit = fadeOut() + scaleOut(
            targetScale = 0.75f,
            transformOrigin = TransformOrigin(1f, 0f),
        ),
        modifier = modifier,
    ) {
        GlassButton(
            onClick = onClick,
            enabled = enabled,
            shape = CircleShape,
            contentPadding = PaddingValues(6.dp),
        ) {
            Icon(
                Icons.Default.Refresh,
                contentDescription = contentDescription,
                tint = AppTheme.colors.accentBlue,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

fun transferCardStateColor(task: TransferTask, colors: AppColors): Color = when (
    transferCardVisualState(task)
) {
    TransferCardVisualState.WAITING -> colors.accentYellow
    TransferCardVisualState.TRANSFERRING -> colors.accentBlue
    TransferCardVisualState.GENERATING -> colors.accentPurple
    TransferCardVisualState.COMPLETED -> colors.statusConnected
    TransferCardVisualState.FAILED -> colors.statusError
    TransferCardVisualState.CANCELLED -> colors.onSurfaceVariant
}

@Composable
fun TaskStatusBadge(
    task: TransferTask,
    taskId: Long,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val visualState = transferCardVisualState(task)
    val badgeColor = transferCardStateColor(task, colors)
    val iconPop = remember(taskId) { Animatable(1f) }
    var previousState by remember(taskId) { mutableStateOf(visualState) }
    LaunchedEffect(visualState) {
        val was = previousState
        previousState = visualState
        if (was != visualState) {
            iconPop.snapTo(0.62f)
            iconPop.animateTo(1f, Motion.bouncy())
        }
    }
    Surface(
        modifier = modifier.graphicsLayer {
            scaleX = iconPop.value
            scaleY = iconPop.value
        },
        shape = CircleShape,
        color = badgeColor,
        border = BorderStroke(2.dp, colors.surface),
    ) {
        Box(
            modifier = Modifier.size(22.dp),
            contentAlignment = Alignment.Center,
        ) {
            Crossfade(
                targetState = visualState,
                animationSpec = tween(180),
                label = "taskStatusBadge",
            ) { state ->
                Icon(
                    imageVector = when (state) {
                        TransferCardVisualState.WAITING -> Icons.Default.Schedule
                        TransferCardVisualState.TRANSFERRING -> Icons.Default.Downloading
                        TransferCardVisualState.GENERATING -> Icons.Default.AutoAwesome
                        TransferCardVisualState.COMPLETED -> Icons.Default.Check
                        TransferCardVisualState.FAILED -> Icons.Default.PriorityHigh
                        TransferCardVisualState.CANCELLED -> Icons.Default.Close
                    },
                    contentDescription = null,
                    tint = colors.onAccent,
                    modifier = Modifier.size(13.dp),
                )
            }
        }
    }
}
@Composable
fun SharedTransferTaskCardContent(
    task: TransferTask,
    text: TransferTaskCardText,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val isFailed = task.status == TransferStatus.FAILED
    val speedText = text.speedText
    val transferDuration = text.transferDuration
    val generationDuration = text.generationDuration
    val effectText = text.effectText
    val animateTransferPills = task.status == TransferStatus.TRANSFERING
    val animateGenerationPills = task.isGeneratingFrame

    Column(modifier = modifier) {
        Text(
            text = task.file.fileName,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium,
            color = if (task.status == TransferStatus.CANCELLED) {
                colors.onSurfaceVariant
            } else {
                colors.onBackground
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = if (isFailed) Modifier.padding(end = 42.dp) else Modifier,
        )

        Spacer(modifier = Modifier.height(6.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            TransferInfoPill(
                text = text.fileSizeText,
                tone = TransferCardPillTone.SIZE,
                respond = animateTransferPills && speedText != null,
            )
            TransferPillVisibility(
                visible = speedText != null,
                delayMillis = 60,
            ) {
                speedText?.let {
                    TransferInfoPill(
                        text = it,
                        tone = TransferCardPillTone.SPEED,
                        respond = transferDuration != null,
                    )
                }
            }
            TransferPillVisibility(
                visible = transferDuration != null,
                delayMillis = 150,
            ) {
                transferDuration?.let {
                    TransferInfoPill(text = it, tone = TransferCardPillTone.TRANSFER_DURATION)
                }
            }
        }

        if (isFailed) {
            Spacer(modifier = Modifier.height(7.dp))
            Text(
                text = text.failureText,
                style = MaterialTheme.typography.labelMedium,
                color = colors.statusError,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        } else if (effectText != null) {
            Spacer(modifier = Modifier.height(7.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                TransferInfoPill(
                    text = effectText,
                    tone = TransferCardPillTone.EFFECT,
                    respond = animateGenerationPills && generationDuration != null,
                    modifier = Modifier.weight(1f, fill = false),
                )
                TransferPillVisibility(
                    visible = generationDuration != null,
                    delayMillis = 80,
                ) {
                    generationDuration?.let {
                        TransferInfoPill(text = it, tone = TransferCardPillTone.GENERATION_DURATION)
                    }
                }
            }
        }
    }
}

@Composable
private fun TransferPillVisibility(
    visible: Boolean,
    delayMillis: Int,
    content: @Composable () -> Unit,
) {
    // 初次组合时直接采用真实状态；只有当前卡片留在组合内发生 false → true，才播放
    // “从左侧胶囊分裂”动画。LazyColumn 滚出再滚回不会重播，速度数值更新也不会触发。
    val visibilityState = remember {
        MutableTransitionState(visible).apply { targetState = visible }
    }
    LaunchedEffect(visible) {
        visibilityState.targetState = visible
    }
    AnimatedVisibility(
        visibleState = visibilityState,
        enter = transferCardPillEnter(delayMillis),
        exit = fadeOut(tween(100)) + shrinkHorizontally(shrinkTowards = Alignment.Start),
    ) { content() }
}

private fun transferCardPillEnter(delayMillis: Int) =
    fadeIn(tween(200, delayMillis = delayMillis)) +
        expandHorizontally(
            expandFrom = Alignment.Start,
            animationSpec = Motion.bouncy(),
        ) +
        slideInHorizontally(
            initialOffsetX = { -minOf(it, 8) },
            animationSpec = spring(
                dampingRatio = 0.62f,
                stiffness = 360f,
            ),
        ) +
        scaleIn(
            initialScale = 0.78f,
            transformOrigin = TransformOrigin(0f, 0.5f),
            animationSpec = tween(200, delayMillis = delayMillis),
        )

@Composable
private fun TransferInfoPill(
    text: String,
    tone: TransferCardPillTone,
    modifier: Modifier = Modifier,
    respond: Boolean = false,
) {
    val colors = AppTheme.colors
    val accent = when (tone) {
        TransferCardPillTone.SIZE -> colors.onSurfaceVariant
        TransferCardPillTone.SPEED -> colors.statusConnected
        TransferCardPillTone.EFFECT -> colors.accentPurple
        TransferCardPillTone.TRANSFER_DURATION -> colors.accentBlue
        TransferCardPillTone.GENERATION_DURATION -> colors.accentYellow
    }
    val sourceScale = remember { Animatable(1f) }
    var previouslyResponding by remember { mutableStateOf(respond) }
    LaunchedEffect(respond) {
        val shouldRespond = respond && !previouslyResponding
        previouslyResponding = respond
        if (shouldRespond) {
            sourceScale.snapTo(1f)
            sourceScale.animateTo(0.94f, tween(105, easing = FastOutSlowInEasing))
            sourceScale.animateTo(1f, Motion.bouncy())
        }
    }
    Box(
        modifier = modifier
            // 左侧为分裂锚点；仅改变 X 缩放，左边界始终固定，回弹发生在右缘。
            .graphicsLayer {
                transformOrigin = TransformOrigin(0f, 0.5f)
                scaleX = sourceScale.value
            }
            .clip(RoundedCornerShape(999.dp))
            .background(accent.copy(alpha = 0.10f))
            .border(1.dp, accent.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = accent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * 右下角悬浮的"图标 FAB + 二次确认"控件（清空/重试全部共用）：毛玻璃圆形按钮，
 * 点击后在其左上方弹出确认卡片（缩放动画以 FAB 所在的右下角为原点，向左上放大），
 * 确认后才真正执行。外边距由调用方的叠放容器统一提供（可能同时叠两颗）。
 */
@Composable
fun SharedQueueConfirmFab(
    expanded: Boolean,
    icon: @Composable () -> Unit,
    title: String,
    confirmText: String,
    confirmColor: Color,
    onToggle: () -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    cancelText: String,
    subtitle: String? = null,
    enabled: Boolean = true,
    modifier: Modifier = Modifier
) {
    Column(horizontalAlignment = Alignment.End, modifier = modifier) {
        AnimatedVisibility(
            visible = expanded,
            // 以右下角为原点缩放弹出，视觉上从 FAB 位置向左上方展开。
            enter = scaleIn(transformOrigin = TransformOrigin(1f, 1f)) + fadeIn(),
            exit = scaleOut(transformOrigin = TransformOrigin(1f, 1f)) + fadeOut()
        ) {
            ConfirmCard(
                title = title,
                subtitle = subtitle,
                confirmText = confirmText,
                confirmColor = confirmColor,
                onConfirm = onConfirm,
                onDismiss = onDismiss,
                cancelText = cancelText,
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        GlassButton(
            onClick = onToggle,
            enabled = enabled,
            shape = CircleShape,
            contentPadding = PaddingValues(16.dp),
            modifier = Modifier.align(Alignment.End)
        ) {
            icon()
        }
    }
}

@Composable
private fun ConfirmCard(
    title: String,
    confirmText: String,
    confirmColor: Color,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    cancelText: String,
    subtitle: String? = null
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        // 与设置面板/提示条同一"重毛玻璃"面板语言，深浅主题下观感统一。
        color = AppTheme.colors.glassSurfaceHeavy,
        shadowElevation = 8.dp,
        border = BorderStroke(1.dp, confirmColor.copy(alpha = 0.4f)),
        // 消费卡片区域的点击，避免穿透到背后的全屏遮罩而被误关闭。
        modifier = Modifier
            .widthIn(max = 260.dp)
            .pointerInput(Unit) { detectTapGestures { } }
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = AppTheme.colors.onBackground
            )
            if (subtitle != null) {
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = AppTheme.colors.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.height(12.dp))
            Row(
                modifier = Modifier.align(Alignment.End),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = onDismiss) {
                    Text(cancelText, color = AppTheme.colors.onSurfaceVariant)
                }
                Button(
                    onClick = onConfirm,
                    colors = ButtonDefaults.buttonColors(containerColor = confirmColor),
                    shape = RoundedCornerShape(10.dp)
                ) {
                    Text(confirmText)
                }
            }
        }
    }
}

/** Presentation only; request/cache/retry ownership remains with the platform caller. */
@Composable
fun QueueThumbnailContent(thumbnail: ImageBitmap?, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(52.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(AppTheme.colors.thumbPlaceholder),
        contentAlignment = Alignment.Center
    ) {
        val image = thumbnail
        if (image != null) {
            Image(
                bitmap = image,
                contentDescription = null,
                // 黑边已在解码时精确裁除（与列表页同源，见 CameraViewModel.cropLetterbox）。
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            Icon(
                Icons.Default.Image,
                contentDescription = null,
                tint = AppTheme.colors.onSurfaceVariant,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}
