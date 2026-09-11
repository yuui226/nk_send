package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.zIndex
import com.ztransfer.ui.theme.*
import com.ztransfer.connection.WirelessMode
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlin.math.cos
import kotlin.math.sin

private const val CONNECTION_ATTENTION_MS = 2_400
private const val CONNECTION_ATTENTION_FRAME_MS = 8L

data class ConnectionCardFeedback(
    val title: String,
    val body: String?,
    val accent: Color,
    val busy: Boolean = false,
    val multiline: Boolean = false,
)


@Composable
fun WifiModeTabs(
    selectedMode: WirelessMode,
    enabled: Boolean,
    onSelectAp: () -> Unit,
    onSelectSta: () -> Unit,
) {
    val colors = AppTheme.colors
    val containerShape = remember { RoundedCornerShape(10.dp) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(30.dp)
            .clip(containerShape)
            .background(colors.onBackground.copy(alpha = 0.055f))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        listOf(
            WirelessMode.STA to onSelectSta,
            WirelessMode.AP to onSelectAp,
        ).forEach { (mode, onClick) ->
            val selected = selectedMode == mode
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(8.dp))
                    .background(
                        if (selected) colors.accentBlue.copy(alpha = 0.16f)
                        else Color.Transparent,
                    )
                    .clickable(enabled = enabled && !selected, onClick = onClick),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = mode.name,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    color = if (selected) colors.accentBlue else colors.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * 每轮只有一个峰值：缓入吸气、柔和呼气、短暂停顿；另一张卡错开半拍。
 * 五次平滑插值让起止速度都归零，避免线性缩放的机械感和峰值处的顿挫。
 */
private fun connectionAttention(phase: Float): Float {
    fun smootherStep(value: Float): Float {
        val x = value.coerceIn(0f, 1f)
        return x * x * x * (x * (x * 6f - 15f) + 10f)
    }
    return when {
        phase < 0.38f -> smootherStep(phase / 0.38f)
        phase < 0.82f -> 1f - smootherStep((phase - 0.38f) / 0.44f)
        else -> 0f
    }
}

@Composable
fun SharedConnectionMethodCard(
    failedLabel: String,
    viewportWidth: Float,
    viewportHeight: Float,
    uptimeMillis: () -> Long,
    modifier: Modifier,
    modeIcon: @Composable (Color, Modifier) -> Unit,
    title: String,
    accent: Color,
    materialSeed: Int,
    steps: List<String>,
    modeSelector: (@Composable () -> Unit)? = null,
    selected: Boolean,
    success: Boolean,
    attentionActive: Boolean,
    attentionPhaseOffset: Float,
    selectionSceneProgress: () -> Float,
    successEffectProgress: () -> Float,
    error: String? = null,
    goldBurst: Boolean = false,
    feedback: ConnectionCardFeedback? = null,
    feedbackFollowsModeSelector: Boolean = false,
    footer: (@Composable ColumnScope.() -> Unit)? = null,
    dimmed: Boolean = false,
    onCardClick: (() -> Unit)? = null,
) {
    val colors = AppTheme.colors
    val shape = remember { RoundedCornerShape(24.dp) }
    val badgeShape = remember { RoundedCornerShape(13.dp) }
    // 这是连接页最基本的状态提示，不再依赖 Compose 的动画帧时钟。若某些 Android 16
    // 设备上该时钟停滞，InfiniteTransition 会始终留在首帧。用单调系统时间按约 120fps
    // 的固定时间表更新，只在未选定连接方式的短暂页面存活期运行。
    var attentionPhase by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(attentionActive, attentionPhaseOffset) {
        if (!attentionActive) {
            return@LaunchedEffect
        }
        val startedAtMs = uptimeMillis()
        var nextFrameAtMs = startedAtMs
        while (isActive) {
            val nowMs = uptimeMillis()
            val elapsed = nowMs - startedAtMs
            attentionPhase = (
                (elapsed % CONNECTION_ATTENTION_MS).toFloat() / CONNECTION_ATTENTION_MS +
                    attentionPhaseOffset
                ).mod(1f)
            nextFrameAtMs += CONNECTION_ATTENTION_FRAME_MS
            if (nextFrameAtMs <= nowMs) {
                val skippedFrames =
                    (nowMs - nextFrameAtMs) / CONNECTION_ATTENTION_FRAME_MS + 1L
                nextFrameAtMs += skippedFrames * CONNECTION_ATTENTION_FRAME_MS
            }
            delay((nextFrameAtMs - uptimeMillis()).coerceAtLeast(1L))
        }
    }
    var iconCenterInRoot by remember { mutableStateOf<Offset?>(null) }
    var cardPressed by remember { mutableStateOf(false) }
    var pressDirection by remember { mutableStateOf(0f) }
    var footerHeightPx by remember { mutableIntStateOf(0) }
    val pressDeformation by animateFloatAsState(
        targetValue = if (cardPressed && !success) 1f else 0f,
        animationSpec = if (cardPressed && !success) {
            tween(70)
        } else {
            spring(dampingRatio = 0.42f, stiffness = 500f)
        },
        label = "connectionCardPress"
    )
    val probeProgress = animateFloatAsState(
        targetValue = if (feedback?.busy == true && !selected) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.62f, stiffness = 420f),
        label = "connectionProbeLift"
    )
    // 状态切换时让呼吸与卡片淡化一起收束，避免 GPS 开关导致两张卡瞬间跳回静态样式。
    val attentionIntensity by animateFloatAsState(
        targetValue = if (attentionActive) 1f else 0f,
        animationSpec = tween(durationMillis = 320, easing = FastOutSlowInEasing),
        label = "connectionAttentionIntensity",
    )
    val cardDimProgress by animateFloatAsState(
        targetValue = if (dimmed) 1f else 0f,
        animationSpec = tween(durationMillis = 320, easing = FastOutSlowInEasing),
        label = "connectionCardDimProgress",
    )

    fun eased(value: Float): Float {
        val x = value.coerceIn(0f, 1f)
        return x * x * (3f - 2f * x)
    }
    // 场景进度只在图层阶段求值，避免动画状态把整张卡片带入逐帧重组。
    fun cardExitProgress(): Float {
        val scene = eased(selectionSceneProgress())
        // 失败时让胜出卡恢复，继续承载错误信息；正常流程中两张卡一起退场。
        return if (selected && error != null) 0f else scene
    }
    fun heroProgress(): Float = if (selected && error == null) {
        eased(selectionSceneProgress())
    } else {
        0f
    }
    // 用真实屏幕坐标定位飞出终点：横向严格居中，纵向落在屏幕上三分之一处。
    val targetCenterX = viewportWidth / 2f
    val targetCenterY = viewportHeight / 3f
    val heroTravelX = iconCenterInRoot?.let { targetCenterX - it.x } ?: 0f
    val heroTravelY = iconCenterInRoot?.let { targetCenterY - it.y } ?: 0f

    Box(
        modifier = modifier
            .zIndex(if (selected) 3f else 0f)
            // 呼吸和按压放在共同父层：玻璃卡、文字、按钮、模式图标始终同步形变。
            .graphicsLayer {
                val attention = connectionAttention(attentionPhase) * attentionIntensity
                val breathingScale = 1f + attention * 0.04f
                val deformation = pressDeformation
                scaleX = breathingScale * (1f + deformation * 0.012f)
                scaleY = breathingScale * (1f - deformation * 0.024f)
                rotationZ = pressDirection * deformation * 1.15f
                translationX = pressDirection * deformation * 1.5.dp.toPx()
            }
    ) {
        ConnectionCardSurface(
            modifier = Modifier
                .fillMaxSize()
                .then(
                    if (onCardClick != null) {
                        Modifier.clickable(onClick = onCardClick)
                    } else {
                        Modifier
                    },
                )
                .graphicsLayer {
                    val exitProgress = cardExitProgress()
                    val exitScale = 1f - exitProgress * 0.045f
                    scaleX = exitScale
                    scaleY = exitScale
                    translationY = exitProgress * 8.dp.toPx()
                    alpha = 1f - exitProgress
                },
            shape = shape,
            tint = when {
                error != null -> colors.statusError.copy(alpha = 0.055f)
                feedback != null && !feedback.busy ->
                    feedback.accent.copy(alpha = 0.045f)
                attentionActive -> accent.copy(alpha = 0.018f)
                else -> Color.Transparent
            }
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .connectionCardMaterialFrame(shape),
            ) {
                // 空白区负责卡片形变；前景按钮拥有独立手势，不与卡片反馈竞争。
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .pointerInput(success, footerHeightPx) {
                            if (success) return@pointerInput
                            awaitEachGesture {
                                val down = awaitFirstDown()
                                val footerTop = size.height - footerHeightPx - 16.dp.toPx()
                                if (footerHeightPx > 0 && down.position.y >= footerTop) {
                                    return@awaitEachGesture
                                }
                                pressDirection = if (size.width == 0) 0f else {
                                    ((down.position.x / size.width) * 2f - 1f)
                                        .coerceIn(-1f, 1f)
                                }
                                cardPressed = true
                                var pressed = true
                                while (pressed) {
                                    val event = awaitPointerEvent(PointerEventPass.Final)
                                    pressed = event.changes.any {
                                        it.id == down.id && it.pressed
                                    }
                                }
                                cardPressed = false
                            }
                        }
                )

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 14.dp, vertical = 16.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // 图标由下方独立图层绘制，这里只保留原始排版占位。
                        Spacer(Modifier.size(42.dp))
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = title,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = colors.onBackground,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }

                    Spacer(Modifier.height(if (modeSelector == null) 20.dp else 10.dp))
                    modeSelector?.let {
                        it()
                        Spacer(
                            Modifier.height(
                                if (feedbackFollowsModeSelector && feedback != null) 4.dp
                                else 12.dp,
                            ),
                        )
                    }
                    if (feedbackFollowsModeSelector && footer != null) {
                        // STA 的步骤与失败提示共用固定的弹性内容槽。状态切换只在槽内淡变，
                        // 不再改变 footer 的测量位置，也不会把下方三个小按钮向上托起。
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .clipToBounds(),
                        ) {
                            AnimatedContent(
                                targetState = feedback,
                                transitionSpec = {
                                    fadeIn(
                                        tween(
                                            durationMillis = 220,
                                            delayMillis = 50,
                                            easing = LinearOutSlowInEasing,
                                        ),
                                    ) togetherWith fadeOut(
                                        tween(
                                            durationMillis = 130,
                                            easing = FastOutLinearInEasing,
                                        ),
                                    )
                                },
                                contentAlignment = Alignment.TopStart,
                                label = "staConnectionCardStatus",
                                // Fill the reserved slot so AnimatedContent never animates its
                                // own measured height while the two text layouts cross-fade.
                                modifier = Modifier.fillMaxSize(),
                            ) { animatedFeedback ->
                                if (animatedFeedback == null) {
                                    Column(modifier = Modifier.fillMaxWidth()) {
                                        steps.forEachIndexed { index, text ->
                                            ConnectionStep(index + 1, text, accent)
                                            if (index != steps.lastIndex) {
                                                Spacer(Modifier.height(13.dp))
                                            }
                                        }
                                    }
                                } else {
                                    ConnectionCardFeedbackContent(
                                        feedback = animatedFeedback,
                                        verticalPadding = 5.dp,
                                    )
                                }
                            }
                        }
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .onSizeChanged { footerHeightPx = it.height },
                            content = footer,
                        )
                    } else {
                        steps.forEachIndexed { index, text ->
                            ConnectionStep(index + 1, text, accent)
                            if (index != steps.lastIndex) Spacer(Modifier.height(13.dp))
                        }

                        AnimatedContent(
                            targetState = feedback,
                            transitionSpec = {
                                when {
                                    initialState == null && targetState != null ->
                                        (
                                            fadeIn(
                                                animationSpec = tween(
                                                    durationMillis = 220,
                                                    delayMillis = 35,
                                                    easing = FastOutSlowInEasing
                                                )
                                            ) + slideInVertically(
                                                animationSpec = tween(
                                                    durationMillis = 260,
                                                    easing = FastOutSlowInEasing
                                                ),
                                                initialOffsetY = { it / 4 }
                                            )
                                        ) togetherWith fadeOut(tween(90))

                                    initialState != null && targetState == null ->
                                        fadeIn(tween(90)) togetherWith (
                                            fadeOut(tween(150)) + slideOutVertically(
                                                animationSpec = tween(
                                                    durationMillis = 180,
                                                    easing = FastOutSlowInEasing
                                                ),
                                                targetOffsetY = { it / 8 }
                                            )
                                        )

                                    else ->
                                        fadeIn(
                                            tween(
                                                durationMillis = 180,
                                                easing = FastOutSlowInEasing
                                            )
                                        ) togetherWith fadeOut(tween(120))
                                }
                            },
                            label = "connectionCardFeedback"
                        ) { animatedFeedback ->
                            if (animatedFeedback != null) {
                                ConnectionCardFeedbackContent(
                                    feedback = animatedFeedback,
                                    topSpacing = 12.dp,
                                )
                            }
                        }

                        if (error != null) {
                            Spacer(Modifier.height(12.dp))
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(colors.statusError.copy(alpha = 0.10f))
                                    .padding(horizontal = 9.dp, vertical = 7.dp)
                            ) {
                                Text(
                                    text = failedLabel,
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = colors.statusError
                                )
                                Text(
                                    text = error,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = colors.onSurfaceVariant,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }

                        Spacer(Modifier.weight(1f))
                        if (footer != null) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .onSizeChanged { footerHeightPx = it.height },
                                content = footer,
                            )
                        }
                    }
                }

            }
        }

        // 42dp 飞行容器保持原本卡片内的精确位置；成功效果用 requiredSize 从该中心
        // 向外溢出，不让 220dp 动画画布及负偏移参与卡片布局。
        Box(
            modifier = Modifier
                .offset(x = 14.dp, y = 16.dp)
                .size(42.dp)
                .zIndex(4f)
                .onGloballyPositioned { coordinates ->
                    if (!selected || iconCenterInRoot == null) {
                        iconCenterInRoot = coordinates.boundsInRoot().center
                    }
                }
                .graphicsLayer {
                    val heroSceneProgress = heroProgress()
                    translationX = heroTravelX * heroSceneProgress
                    translationY = heroTravelY * heroSceneProgress -
                        kotlin.math.sin(heroSceneProgress * kotlin.math.PI.toFloat()) * 10.dp.toPx() -
                        probeProgress.value * 5.dp.toPx()
                }
        ) {
            val badgeAccent = if (success) colors.statusConnected else accent
            ConnectionModeBadge(
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val heroSceneProgress = heroProgress()
                        val exitProgress = cardExitProgress()
                        val heroScale = (1f + heroSceneProgress * 1.12f) *
                            (1f + probeProgress.value * 0.04f)
                        scaleX = heroScale
                        scaleY = heroScale
                        alpha = if (selected) 1f else 1f - exitProgress
                    },
                shape = badgeShape,
                accentColor = badgeAccent,
                contentColor = accent,
                success = success,
                attentionActive = attentionActive,
                probeProgress = probeProgress,
                textureSeed = materialSeed,
                modeIcon = modeIcon,
            )

            ConnectionSuccessOverlay(
                success = success,
                goldBurst = goldBurst,
                progress = successEffectProgress,
                modifier = Modifier
                    .align(Alignment.Center)
                    .requiredSize(220.dp)
                    // 免费版双脉冲压到飞行图标后方；高级版保持原有前景光效层级。
                    .zIndex(if (goldBurst) 1f else -1f)
            )
        }

        // Do not dim the whole card with graphicsLayer alpha: that creates a rectangular
        // offscreen layer around the rounded card and some GPUs expose its four corners. A
        // shape-drawn scrim keeps the disabled cue inside the card while leaving its shadow
        // and rounded silhouette untouched.
        Box(
            modifier = Modifier
                .matchParentSize()
                .zIndex(5f)
                .background(
                    color = colors.background.copy(alpha = 0.28f * cardDimProgress),
                    shape = shape,
                ),
        )
    }
}

@Composable
private fun ConnectionCardFeedbackContent(
    feedback: ConnectionCardFeedback,
    topSpacing: Dp = 0.dp,
    verticalPadding: Dp = 7.dp,
) {
    val colors = AppTheme.colors
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.Start,
    ) {
        if (topSpacing > 0.dp) {
            Spacer(Modifier.height(topSpacing))
        }
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(10.dp))
                .background(feedback.accent.copy(alpha = 0.10f))
                .padding(
                    horizontal = 9.dp,
                    vertical = verticalPadding,
                ),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (feedback.busy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    color = feedback.accent,
                    strokeWidth = 1.5.dp,
                )
                Spacer(Modifier.width(7.dp))
            }
            Column {
                Text(
                    text = feedback.title,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = feedback.accent,
                    maxLines = if (feedback.multiline) 2 else 1,
                    overflow = TextOverflow.Ellipsis,
                )
                feedback.body?.let { body ->
                    Text(
                        text = body,
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.onSurfaceVariant,
                        maxLines = if (feedback.multiline) 3 else 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}


@Composable
private fun ConnectionModeBadge(
    modifier: Modifier,
    shape: RoundedCornerShape,
    accentColor: Color,
    contentColor: Color,
    success: Boolean,
    attentionActive: Boolean,
    probeProgress: State<Float>,
    textureSeed: Int,
    modeIcon: @Composable (Color, Modifier) -> Unit,
) {
    val probe = probeProgress.value
    SkinMaterialBadge(
        modifier = modifier,
        shape = shape,
        accentColor = accentColor,
        contentColor = contentColor,
        emphasis = if (success) {
            1f
        } else {
            (if (attentionActive) 0.18f else 0.08f) + probe * 0.48f
        },
        textureSeed = textureSeed,
    ) { badgeContentColor ->
        modeIcon(
            badgeContentColor,
            Modifier
                .size(22.dp)
                .align(Alignment.Center)
        )
    }
}

@Composable
private fun ConnectionStep(index: Int, text: String, accent: Color) {
    val colors = AppTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth()
    ) {
        Box(
            modifier = Modifier
                .size(21.dp)
                .alignByBaseline()
                .clip(CircleShape)
                .background(accent.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = index.toString(),
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = accent
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Medium,
            color = colors.onSurfaceVariant,
            modifier = Modifier
                .weight(1f)
                .alignByBaseline()
        )
    }
}

@Composable
private fun ConnectionSuccessOverlay(
    success: Boolean,
    goldBurst: Boolean,
    progress: () -> Float,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    if (!success) return

    Canvas(modifier = modifier) {
        val p = progress()
        if (!goldBurst) {
            drawFreeSuccessPulses(
                progress = p,
                color = colors.statusConnected,
            )
            return@Canvas
        }

        // 高级版成功效果保持原有绘制与节奏；免费版已在上方走独立的双脉冲分支。
        val reveal = (p * 5f).coerceAtMost(1f)
        drawPremiumSuccessEffect(p)

        repeat(2) { index ->
            val ringProgress = ((p - index * 0.14f) / 0.72f).coerceIn(0f, 1f)
            val ringScale = 0.72f + ringProgress * 1.72f
            drawCircle(
                color = colors.statusConnected.copy(
                    alpha = (1f - ringProgress) * 0.62f * reveal,
                ),
                radius = (41.dp.toPx() - 0.75.dp.toPx()) * ringScale,
                style = Stroke(width = 1.5.dp.toPx() * ringScale),
            )
        }

        repeat(10) { index ->
            val angle = (index * 36f + if (index % 2 == 0) 7f else -5f) *
                (kotlin.math.PI.toFloat() / 180f)
            val distance = (48 + (index % 3) * 11).dp.toPx() * p
            drawCircle(
                color = (if (index % 2 == 0) {
                    Color(0xFFFFE082)
                } else {
                    Color(0xFFF0A93B)
                }).copy(alpha = (p * 5f).coerceAtMost(1f) * (1f - p)),
                radius = (if (index % 3 == 0) 3.dp else 2.dp).toPx(),
                center = Offset(
                    center.x + cos(angle) * distance,
                    center.y + sin(angle) * distance,
                ),
            )
        }

        // 不再绘制另一枚“成功图标”；只给原模式图标增加一圈确认脉冲。
        val coreScale = 0.82f + kotlin.math.sin(p * kotlin.math.PI.toFloat()) * 0.22f
        val coreAlpha = (1f - p).coerceAtLeast(0.16f)
        drawCircle(
            color = colors.statusConnected.copy(alpha = 0.08f * coreAlpha * reveal),
            radius = 39.dp.toPx() * coreScale,
        )
        drawCircle(
            color = colors.statusConnected.copy(alpha = 0.70f * coreAlpha * reveal),
            radius = (39.dp.toPx() - 0.75.dp.toPx()) * coreScale,
            style = Stroke(width = 1.5.dp.toPx() * coreScale),
        )
    }
}

/** 免费版成功反馈：从模式图标外缘依次发出两圈波纹，各自扩散后彻底消失。 */
private fun DrawScope.drawFreeSuccessPulses(progress: Float, color: Color) {
    val p = progress.coerceIn(0f, 1f)
    val startRadius = 42.dp.toPx()
    val endRadius = 102.dp.toPx()

    repeat(2) { index ->
        val ringProgress = freeConnectionPulseProgress(p, index)
        val visibility = freeConnectionPulseVisibility(ringProgress)
        if (visibility <= 0f) return@repeat

        val radius = startRadius + (endRadius - startRadius) * ringProgress
        val strength = if (index == 0) 1f else 0.84f
        // 每圈都由同半径的柔光与细环组成；柔光不单独移动，因此视觉上仍是两圈脉冲。
        drawCircle(
            color = color.copy(alpha = 0.12f * visibility * strength),
            radius = radius,
            style = Stroke(width = (5.2f - 2.2f * ringProgress).dp.toPx()),
        )
        drawCircle(
            color = color.copy(alpha = 0.68f * visibility * strength),
            radius = radius,
            style = Stroke(width = (1.9f - 0.8f * ringProgress).dp.toPx()),
        )
    }
}

private const val FREE_CONNECTION_PULSE_STAGGER = 0.14f
private const val FREE_CONNECTION_PULSE_SPAN = 0.82f


fun freeConnectionPulseProgress(progress: Float, index: Int): Float =
    (
        (progress.coerceIn(0f, 1f) - index.coerceIn(0, 1) * FREE_CONNECTION_PULSE_STAGGER) /
            FREE_CONNECTION_PULSE_SPAN
        ).coerceIn(0f, 1f)

fun freeConnectionPulseVisibility(progress: Float): Float {
    val p = progress.coerceIn(0f, 1f)
    if (p <= 0f || p >= 1f) return 0f
    val appear = (p / 0.10f).coerceIn(0f, 1f)
    return appear * (1f - p)
}


private fun DrawScope.drawPremiumSuccessEffect(progress: Float) {
    val gold = Color(0xFFFFD66B)
    val warmGold = Color(0xFFF0A93B)
    val p = progress.coerceIn(0f, 1f)
    val appear = (p / 0.16f).coerceIn(0f, 1f)
    val fade = ((1f - p) / 0.30f).coerceIn(0f, 1f)
    val visibility = appear * fade
    val center = this.center

    // 短促的暖金光晕先托起图标，不形成持续的大色块。
    val haloPulse = sin((p.coerceAtMost(0.72f) / 0.72f) * kotlin.math.PI.toFloat())
        .coerceAtLeast(0f)
    drawCircle(
        color = gold.copy(alpha = 0.12f * haloPulse),
        radius = size.minDimension * (0.16f + p * 0.16f),
        center = center
    )
    drawCircle(
        color = warmGold.copy(alpha = 0.07f * haloPulse),
        radius = size.minDimension * (0.24f + p * 0.12f),
        center = center
    )

    // 三段旋转断续光环，比免费版完整绿色圆环更精致，也不会抢模式图标。
    rotate(degrees = -32f + p * 118f, pivot = center) {
        val orbitRadius = size.minDimension * (0.22f + p * 0.10f)
        val orbitTopLeft = Offset(center.x - orbitRadius, center.y - orbitRadius)
        val orbitSize = androidx.compose.ui.geometry.Size(orbitRadius * 2f, orbitRadius * 2f)
        repeat(3) { index ->
            drawArc(
                color = if (index == 1) gold.copy(alpha = 0.92f * visibility)
                else warmGold.copy(alpha = 0.72f * visibility),
                startAngle = index * 120f + 8f,
                sweepAngle = 54f,
                useCenter = false,
                topLeft = orbitTopLeft,
                size = orbitSize,
                style = Stroke(width = 1.6.dp.toPx(), cap = StrokeCap.Round)
            )
        }
    }

    // 六枚星芒沿轻微旋转的轨迹展开；长短交错，让高级版具有可辨识的“签名”。
    repeat(6) { index ->
        val phase = ((p - index * 0.025f) / 0.78f).coerceIn(0f, 1f)
        val angle = index * 60f * (kotlin.math.PI.toFloat() / 180f) + phase * 0.28f
        val distance = size.minDimension * (0.19f + phase * 0.25f)
        val sparkleCenter = Offset(
            center.x + cos(angle) * distance,
            center.y + sin(angle) * distance
        )
        val sparkleFade = (phase * 5f).coerceAtMost(1f) * (1f - phase)
        val longArm = (if (index % 2 == 0) 7.dp else 5.dp).toPx() *
            (0.7f + sparkleFade * 0.6f)
        val shortArm = longArm * 0.42f
        val sparkleColor = if (index % 2 == 0) gold else Color.White
        val alpha = sparkleFade * 0.95f
        drawLine(
            sparkleColor.copy(alpha = alpha),
            Offset(sparkleCenter.x, sparkleCenter.y - longArm),
            Offset(sparkleCenter.x, sparkleCenter.y + longArm),
            strokeWidth = 1.5.dp.toPx(),
            cap = StrokeCap.Round
        )
        drawLine(
            sparkleColor.copy(alpha = alpha),
            Offset(sparkleCenter.x - shortArm, sparkleCenter.y),
            Offset(sparkleCenter.x + shortArm, sparkleCenter.y),
            strokeWidth = 1.5.dp.toPx(),
            cap = StrokeCap.Round
        )
    }
}


fun connectionHeroProgress(elapsedMs: Long): Float =
    (elapsedMs.toFloat() / CONNECTION_HERO_DURATION_MS).coerceIn(0f, 1f)

fun connectionSuccessProgress(elapsedMs: Long): Float {
    val linearProgress = (
        (elapsedMs - CONNECT_CELEBRATE_DELAY_MS).toFloat() / CONNECTION_SUCCESS_DURATION_MS
        ).coerceIn(0f, 1f)
    return FastOutSlowInEasing.transform(linearProgress)
}

const val CONNECT_CELEBRATE_DELAY_MS = 500L
const val CONNECTION_HERO_DURATION_MS = 620L
const val CONNECTION_SUCCESS_DURATION_MS = 760L
