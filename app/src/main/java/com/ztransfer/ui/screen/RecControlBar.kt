package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion
import kotlinx.coroutines.delay

/**
 * 取景器画面录制控制条（玻璃面板）：
 * [● 录制 / ■ 停止] [⏸ 暂停 / ▶ 继续（仅录制中可点）]，计时悬浮在按钮上方。
 *
 * 待机时收成一个普通工具格；开始录制后左侧按钮位置不动、胶囊向右弹性展开为两个
 * 工具格，露出暂停按钮与时间气泡。保存成功对号结束后再收回，节奏与传输队列胶囊一致。
 *
 * [enabled]（免费版）：录制为高级版功能。控制条保持可见（藏起来的功能卖不动升级），
 * 整条压暗（alpha 0.4）但所有槽位尺寸与解锁态完全一致；点击录制按钮时在按钮正上方
 * 弹出高级版提示，不占布局高度。
 * isRecording 在 !enabled 时恒为 false——isPro 门控保证免费用户绝不可能在录制中，
 * 但停止路径作为防御仍保持可用（录音中切回免费版的边界理论上不存在）。
 */
@Composable
fun RecControlBar(
    isRecording: Boolean,
    isPaused: Boolean,
    elapsedSeconds: Int,
    onStart: () -> Unit,
    onPauseResume: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    isFinalizing: Boolean = false,
    showDone: Boolean = false
) {
    val colors = AppTheme.colors
    val recRed = colors.statusError
    val formatted = "%d:%02d".format(elapsedSeconds / 60, elapsedSeconds % 60)
    // 按钮 28dp、内容内边距 7dp、图标 14dp：在外层 36dp 高度约束（上下各 4dp 面板
    // 内边距）下正好铺满——此前 40dp 按钮 + 10dp 内边距被压缩到 0 高，图标画不出来。
    val buttonSize = 28.dp
    val iconSize = 14.dp
    val iconPadding = PaddingValues(7.dp)
    // 小工具改为 36dp 圆形后，录制控件仍按一格 / 两格加间距占位。
    // 展开胶囊本身略窄于两格占位，左侧录制按钮位置保持不动。
    val collapsedLayoutWidth = 36.dp
    val expandedLayoutWidth = 78.dp
    val collapsedSurfaceWidth = 36.dp
    val expandedSurfaceWidth = 70.dp
    val expanded = isRecording || isFinalizing || showDone
    val animatedLayoutWidth by animateDpAsState(
        targetValue = if (expanded) expandedLayoutWidth else collapsedLayoutWidth,
        animationSpec = Motion.bouncy(),
        label = "recControlLayoutWidth"
    )
    val animatedSurfaceWidth by animateDpAsState(
        targetValue = if (expanded) expandedSurfaceWidth else collapsedSurfaceWidth,
        animationSpec = Motion.bouncy(),
        label = "recControlSurfaceWidth"
    )

    val startDesc = stringResource(R.string.cd_remote_rec_start)
    val stopDesc = stringResource(R.string.cd_remote_rec_stop)
    val pauseDesc = stringResource(R.string.cd_remote_rec_pause)
    val resumeDesc = stringResource(R.string.cd_remote_rec_resume)
    val savedDesc = stringResource(R.string.cd_remote_rec_saved)
    val lockedHintText = stringResource(R.string.remote_rec_pro_only)
    var lockedHintNonce by remember { mutableIntStateOf(0) }
    var lockedHintVisible by remember { mutableStateOf(false) }
    LaunchedEffect(lockedHintNonce) {
        if (lockedHintNonce == 0) return@LaunchedEffect
        lockedHintVisible = true
        delay(1_800)
        lockedHintVisible = false
    }

    Box(modifier = modifier.width(animatedLayoutWidth)) {
        GlassSurface(
            modifier = Modifier
                .width(animatedSurfaceWidth)
                .fillMaxHeight(),
            shape = RoundedCornerShape(18.dp),
            panel = true,
            borderColor = Color.Transparent
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer { alpha = if (enabled) 1f else 0.4f },
            ) {
                // ---- 录制 / 停止 ----
                GlassButton(
                    onClick = {
                        if (!showDone && !isFinalizing) {
                            if (isRecording) onStop()
                            else if (!enabled) lockedHintNonce++
                            else onStart()
                        }
                    },
                    shape = CircleShape,
                    contentPadding = iconPadding,
                    showSheen = false,
                    shadowElevation = 0.dp,
                    active = showDone,
                    activeColor = colors.statusConnected,
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .offset(x = 4.dp)
                        .size(buttonSize)
                        .semantics {
                            contentDescription = when {
                                showDone -> savedDesc
                                isRecording -> stopDesc
                                else -> startDesc
                            }
                        }
                ) {
                    AnimatedContent(
                        targetState = showDone,
                        transitionSpec = {
                            (fadeIn(tween(150)) +
                                scaleIn(initialScale = 0.52f, animationSpec = Motion.bouncy()))
                                .togetherWith(
                                    fadeOut(tween(90)) +
                                        scaleOut(targetScale = 0.72f, animationSpec = tween(110))
                                )
                        },
                        contentAlignment = Alignment.Center,
                        label = "recSaveSuccess",
                        modifier = Modifier.size(iconSize)
                    ) { saved ->
                        Canvas(modifier = Modifier.size(iconSize)) {
                            if (saved) {
                                // 绿色对勾弹入，同时按钮玻璃底泛起一层绿色确认光。
                                val path = Path().apply {
                                    moveTo(size.width * 0.20f, size.height * 0.55f)
                                    lineTo(size.width * 0.40f, size.height * 0.80f)
                                    lineTo(size.width * 0.80f, size.height * 0.25f)
                                }
                                drawPath(
                                    path = path,
                                    color = colors.statusConnected,
                                    style = Stroke(
                                        width = 2.dp.toPx(),
                                        cap = StrokeCap.Round,
                                        join = StrokeJoin.Round
                                    )
                                )
                            } else if (isRecording || isFinalizing) {
                                // 红色圆角方块（停止）。
                                val inset = size.minDimension * 0.14f
                                drawRoundRect(
                                    color = recRed,
                                    topLeft = Offset(inset, inset),
                                    size = Size(size.width - inset * 2, size.height - inset * 2),
                                    cornerRadius = CornerRadius(2.dp.toPx())
                                )
                            } else {
                                // 红色实心圆点（开始录制）。
                                drawCircle(color = recRed)
                            }
                        }
                    }
                }

                // ---- 暂停 / 继续：定宽占位，空闲时淡出但仍占位，保持总宽稳定 ----
                // 用透明度/缩放做显隐（不用 AnimatedVisibility 的横向展开），槽位尺寸恒定。
                val pauseAlpha by animateFloatAsState(
                    targetValue = if (isRecording) 1f else 0f,
                    animationSpec = tween(150),
                    label = "recPauseAlpha"
                )
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .offset(x = 38.dp)
                        .size(buttonSize),
                    contentAlignment = Alignment.Center
                ) {
                    if (pauseAlpha > 0.01f) {
                        GlassButton(
                            onClick = onPauseResume,
                            enabled = isRecording,
                            shape = CircleShape,
                            contentPadding = iconPadding,
                            showSheen = false,
                            shadowElevation = 0.dp,
                            modifier = Modifier
                                .size(buttonSize)
                                .graphicsLayer {
                                    alpha = pauseAlpha
                                    scaleX = 0.7f + 0.3f * pauseAlpha
                                    scaleY = 0.7f + 0.3f * pauseAlpha
                                }
                                .semantics {
                                    contentDescription = if (isPaused) resumeDesc else pauseDesc
                                }
                        ) {
                            val markColor = colors.onBackground
                            Canvas(modifier = Modifier.size(iconSize)) {
                                if (isPaused) {
                                    // 右向三角（继续）。
                                    val path = Path().apply {
                                        val margin = size.minDimension * 0.18f
                                        moveTo(margin + 1.dp.toPx(), margin)
                                        lineTo(size.width - margin, size.height / 2f)
                                        lineTo(margin + 1.dp.toPx(), size.height - margin)
                                        close()
                                    }
                                    drawPath(path = path, color = markColor)
                                } else {
                                    // 两根竖条（暂停）。
                                    val barW = size.width * 0.26f
                                    val insetX = size.width * 0.16f
                                    val insetY = size.height * 0.14f
                                    drawRoundRect(
                                        color = markColor,
                                        topLeft = Offset(insetX, insetY),
                                        size = Size(barW, size.height - insetY * 2),
                                        cornerRadius = CornerRadius(barW / 2f)
                                    )
                                    drawRoundRect(
                                        color = markColor,
                                        topLeft = Offset(size.width - insetX - barW, insetY),
                                        size = Size(barW, size.height - insetY * 2),
                                        cornerRadius = CornerRadius(barW / 2f)
                                    )
                                }
                            }
                        }
                    }
                }

            }
        }

        // 录制时间独立悬浮在左侧录制按钮上方，不参与工具行测量，也不挤压胶囊内部按钮。
        AnimatedVisibility(
            visible = isRecording,
            enter = fadeIn(tween(140)) +
                scaleIn(
                    initialScale = 0.82f,
                    animationSpec = Motion.bouncy(),
                    transformOrigin = TransformOrigin(0.5f, 1f)
                ) +
                slideInVertically(
                    animationSpec = Motion.bouncy(),
                    initialOffsetY = { it / 3 }
                ),
            exit = fadeOut(tween(120)) +
                scaleOut(
                    targetScale = 0.90f,
                    animationSpec = tween(130),
                    transformOrigin = TransformOrigin(0.5f, 1f)
                ) +
                slideOutVertically(
                    animationSpec = tween(130),
                    targetOffsetY = { it / 4 }
                ),
            modifier = Modifier
                .align(Alignment.TopStart)
                .wrapContentWidth(Alignment.Start, unbounded = true)
                .graphicsLayer {
                    translationY = -size.height - 5.dp.toPx()
                }
        ) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = colors.glassSurfaceHeavy.copy(alpha = 0.72f),
                border = BorderStroke(0.5.dp, colors.glassPanelBorder.copy(alpha = 0.65f)),
                shadowElevation = 3.dp
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                ) {
                    Text(
                        text = "●",
                        color = recRed,
                        fontSize = 8.sp,
                        lineHeight = 10.sp
                    )
                    Text(
                        text = " $formatted",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        lineHeight = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.onBackground,
                        maxLines = 1
                    )
                }
            }
        }

        // 高级版提示与录制胶囊同层，布局尺寸仍只有 36dp；绘制时整体上移到按钮上方，
        // 因而不会把竖屏第二排或横屏工具行顶开，也能随应用内横屏旋转保持方向一致。
        AnimatedVisibility(
            visible = lockedHintVisible,
            enter = fadeIn(tween(160)) +
                scaleIn(
                    initialScale = 0.86f,
                    animationSpec = tween(180),
                    transformOrigin = TransformOrigin(0.5f, 1f)
                ),
            exit = fadeOut(tween(140)) +
                scaleOut(
                    targetScale = 0.92f,
                    animationSpec = tween(140),
                    transformOrigin = TransformOrigin(0.5f, 1f)
                ),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .wrapContentWidth(Alignment.CenterHorizontally, unbounded = true)
                .graphicsLayer {
                    translationY = -size.height - 6.dp.toPx()
                }
        ) {
            Surface(
                shape = RoundedCornerShape(18.dp),
                color = colors.glassSurfaceHeavy,
                border = BorderStroke(1.dp, colors.glassPanelBorder),
                shadowElevation = 6.dp
            ) {
                Text(
                    text = lockedHintText,
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.onBackground,
                    maxLines = 1,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp)
                )
            }
        }
    }
}
