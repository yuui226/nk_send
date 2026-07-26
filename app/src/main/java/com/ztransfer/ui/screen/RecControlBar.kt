package com.ztransfer.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme

/**
 * 取景器画面录制控制条（玻璃面板）：
 * [● 录制 / ■ 停止] [⏸ 暂停 / ▶ 继续（仅录制中可点）] [M:SS 计时]
 *
 * 三个槽位全部定宽——暂停键与计时器在空闲态只是隐形占位，录制开始/结束时
 * 整条宽度一个像素都不变，不会把同行右侧的按钮挤出屏幕。
 *
 * [enabled]（免费版）：录制为高级版功能。控制条保持可见（藏起来的功能卖不动升级），
 * 整条压暗（alpha 0.4）但所有槽位尺寸与解锁态完全一致；录制按钮不再触发 [onStart]，
 * 改走 [onLockedTap]（由调用方弹"高级版功能"提示）。
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
    onLockedTap: () -> Unit = {},
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

    val startDesc = stringResource(R.string.cd_remote_rec_start)
    val stopDesc = stringResource(R.string.cd_remote_rec_stop)
    val pauseDesc = stringResource(R.string.cd_remote_rec_pause)
    val resumeDesc = stringResource(R.string.cd_remote_rec_resume)

    GlassSurface(
        modifier = modifier,
        shape = RoundedCornerShape(18.dp),
        panel = true
    ) {
        Row(
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .graphicsLayer { alpha = if (enabled) 1f else 0.4f },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            // ---- 录制 / 停止 ----
            GlassButton(
                onClick = {
                    if (isRecording) onStop()
                    else if (!enabled) onLockedTap()
                    else onStart()
                },
                shape = CircleShape,
                contentPadding = iconPadding,
                showSheen = false,
                modifier = Modifier
                    .size(buttonSize)
                    .semantics { contentDescription = if (isRecording) stopDesc else startDesc }
            ) {
                Canvas(modifier = Modifier.size(iconSize)) {
                    if (showDone) {
                        // 绿色对勾：录制完成反馈，覆盖待机与录制两种状态
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
                    } else if (isRecording) {
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

            // ---- 暂停 / 继续：定宽占位，空闲时淡出但仍占位，保持总宽稳定 ----
            // 用透明度/缩放做显隐（不用 AnimatedVisibility 的横向展开），槽位尺寸恒定。
            val pauseAlpha by animateFloatAsState(
                targetValue = if (isRecording) 1f else 0f,
                animationSpec = tween(150),
                label = "recPauseAlpha"
            )
            Box(modifier = Modifier.size(buttonSize), contentAlignment = Alignment.Center) {
                if (pauseAlpha > 0.01f) {
                    GlassButton(
                        onClick = onPauseResume,
                        enabled = isRecording,
                        shape = CircleShape,
                        contentPadding = iconPadding,
                        showSheen = false,
                        modifier = Modifier
                            .size(buttonSize)
                            .graphicsLayer {
                                alpha = pauseAlpha
                                scaleX = 0.7f + 0.3f * pauseAlpha
                                scaleY = 0.7f + 0.3f * pauseAlpha
                            }
                            .semantics { contentDescription = if (isPaused) resumeDesc else pauseDesc }
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

            // ---- 计时：等宽字体 + 定宽槽位（容纳 "88:88"），跳秒不引起重排 ----
            Text(
                text = if (isRecording) formatted else "0:00",
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                textAlign = TextAlign.Center,
                color = if (isRecording) colors.onBackground else colors.onSurfaceVariant,
                modifier = Modifier.width(40.dp)
            )
        }
    }
}
